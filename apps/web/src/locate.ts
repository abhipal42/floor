// "Your members, from your location": the state machine behind the strip under the site header, and
// the pure mapping from the API's responses (apps/api/openapi.json: Reps, MemberDetail, MemberVote)
// to what the strip and the scouting report show. No DOM, no fetch, so all of it runs in Node.

import { carried, type CellPos } from "./logic.js";

// ---------------------------------------------------------------- API shapes (subset of openapi.json)

export interface ApiMember {
  bioguideId: string;
  firstName: string;
  lastName: string;
  party: string;
  state: string;
  /** 0 for an at-large seat or a delegate; null for a senator. */
  district: number | null;
  chamber: "house" | "senate";
}

export interface ApiReps {
  district: { congress: number; state: string; district: number; countyFips: string | null };
  members: ApiMember[];
}

export interface ApiLoyalty {
  votes: number;
  withParty: number;
  againstParty: number;
}

export interface ApiMemberVote {
  vote: {
    id: string;
    kind: "question" | "election";
    chamber: "house" | "senate";
    rollNumber: number | null;
    question: string;
    occurredAt: string | null;
    totals: { yea: number; nay: number; present: number; notVoting: number };
    result: string | null;
  };
  position: "yea" | "nay" | "present" | "not_voting" | "candidate";
  choice: string | null;
  measure: { id: string; kind: "bill" | "nomination"; citation: string; title: string } | null;
}

// ---------------------------------------------------------------- the request

/** The API rounds to this too; the page rounds first so the precise point never leaves the browser. */
export const COORD_DECIMALS = 4;

export function roundCoord(x: number): number {
  return Number(x.toFixed(COORD_DECIMALS));
}

export type Place = { lat: number; lng: number } | { address: string };

export function repsUrl(base: string, place: Place): string {
  const q =
    "address" in place
      ? new URLSearchParams({ address: place.address.trim() })
      : new URLSearchParams({ lat: String(roundCoord(place.lat)), lng: String(roundCoord(place.lng)) });
  return base + "/v1/reps?" + q.toString();
}

export function memberUrl(base: string, id: string): string {
  return base + "/v1/members/" + encodeURIComponent(id);
}

export function votesUrl(base: string, id: string, limit = 40): string {
  return base + "/v1/members/" + encodeURIComponent(id) + "/votes?limit=" + limit;
}

/**
 * The mock's rule: an address must be at least six characters and not a bare five-digit ZIP, which
 * can straddle two districts. Anything else goes to the Census geocoder, which judges the rest.
 */
export function addressOk(text: string): boolean {
  const a = text.trim();
  return a.length >= 6 && !/^\d{5}$/.test(a);
}

/** How a /v1/reps answer reads: found, not in any U.S. district (404), or no usable answer. */
export type RepsOutcome = "ok" | "outside" | "error";

/** `status` is the HTTP status, or null when fetch itself threw (offline, or CORS refused it). */
export function repsOutcome(status: number | null): RepsOutcome {
  if (status === null) return "error";
  if (status >= 200 && status < 300) return "ok";
  if (status === 404) return "outside";
  return "error";
}

// ---------------------------------------------------------------- the state machine

export type Step = "idle" | "asking" | "loading" | "found" | "denied" | "nofix" | "outside" | "error" | "address";

export interface Found {
  /** "Texas's 37th District" */
  label: string;
  members: ApiMember[];
}

export interface LocState {
  step: Step;
  /** The district and members on show while `step` is "found". */
  found: Found | null;
  /** Their records (loyalty and votes), fetched after the district is found. */
  records: "loading" | "ready" | "error";
  addrErr: boolean;
}

export type LocEvent =
  | { type: "locate"; supported: boolean }
  | { type: "geoFix" }
  | { type: "geoError"; code: number }
  | { type: "toAddress" }
  | { type: "submitAddress"; text: string }
  | { type: "typed" }
  | { type: "reps"; outcome: RepsOutcome; found?: Found }
  | { type: "records"; ok: boolean }
  | { type: "retry" }
  | { type: "reset" }
  | { type: "restore"; found: Found };

export const INITIAL: LocState = { step: "idle", found: null, records: "loading", addrErr: false };

/** GeolocationPositionError.PERMISSION_DENIED; 2 (unavailable) and 3 (timeout) are "no fix". */
const PERMISSION_DENIED = 1;

export function nextState(s: LocState, e: LocEvent): LocState {
  switch (e.type) {
    case "locate":
      // No geolocation in this browser: straight to typing an address.
      return e.supported ? { ...s, step: "asking", addrErr: false } : { ...s, step: "address", addrErr: false };
    case "geoFix":
      return s.step === "asking" ? { ...s, step: "loading" } : s;
    case "geoError":
      if (s.step !== "asking") return s;
      return { ...s, step: e.code === PERMISSION_DENIED ? "denied" : "nofix" };
    case "toAddress":
      return { ...s, step: "address", addrErr: false };
    case "typed":
      return s.addrErr ? { ...s, addrErr: false } : s;
    case "submitAddress":
      return addressOk(e.text) ? { ...s, step: "loading", addrErr: false } : { ...s, addrErr: true };
    case "reps":
      if (s.step !== "loading") return s;
      if (e.outcome === "ok" && e.found?.members.length) return { ...s, step: "found", found: e.found, records: "loading" };
      if (e.outcome === "outside") return { ...s, step: "outside" };
      return { ...s, step: "error" };
    case "records":
      if (s.step !== "found" || s.records !== "loading") return s;
      return { ...s, records: e.ok ? "ready" : "error" };
    case "retry":
      return s.step === "found" && s.records === "error" ? { ...s, records: "loading" } : s;
    case "reset":
      return INITIAL;
    case "restore":
      return { step: "found", found: e.found, records: "loading", addrErr: false };
  }
}

/** Whether the page is showing the New York sample rather than someone's own members. */
export function isSample(s: LocState): boolean {
  return s.step !== "found";
}

export interface StripView {
  kicker: string;
  /** "muted" for neutral states, "yea" once found, "nay" for a problem. */
  tone: "muted" | "yea" | "nay";
  title: string;
  note: string;
  chips: "sample" | "found" | "skeleton";
  /** Sample chips are faded while the page is busy finding yours, or failed to. */
  dim: boolean;
  locate: "Use my location" | "Waiting for your browser…" | null;
  address: boolean;
  /** The secondary link: to the address field, and from a found district back to the sample. */
  addressLink: string | null;
  back: boolean;
}

const SAMPLE_KICKER = "SAMPLE · NEW YORK'S 8TH DISTRICT";

export function stripView(s: LocState): StripView {
  const base = { note: "", chips: "sample", dim: true, locate: null, address: false, addressLink: null, back: false } as const;
  switch (s.step) {
    case "idle":
      return { ...base, kicker: SAMPLE_KICKER, tone: "muted", title: "Make it your three.", dim: false, locate: "Use my location", addressLink: "or type an address" };
    case "asking":
      return { ...base, kicker: "WAITING FOR YOUR BROWSER", tone: "muted", title: "Allow, or type it.", locate: "Waiting for your browser…", addressLink: "or type an address" };
    case "loading":
      return { ...base, kicker: "FINDING YOUR DISTRICT…", tone: "muted", title: "One moment.", chips: "skeleton" };
    case "found": {
      const one = s.found?.members.length === 1 ? s.found.members[0] : undefined;
      return {
        ...base,
        kicker: "YOUR DISTRICT · " + (s.found?.label ?? "").toUpperCase(),
        tone: "yea",
        title: "",
        note: one ? oneMemberNote(one) : "",
        chips: "found",
        dim: false,
        addressLink: "Not your district? Type an address",
        back: true,
      };
    }
    case "denied":
      return {
        ...base,
        kicker: "LOCATION IS BLOCKED FOR THIS SITE",
        tone: "nay",
        title: "Type an address instead.",
        note: "Floor uses it once to find your district. To use location later, allow it in your browser’s site settings.",
        address: true,
      };
    case "nofix":
      return {
        ...base,
        kicker: "YOUR BROWSER COULDN'T FIND YOU",
        tone: "nay",
        title: "Type an address instead.",
        note: "Location was allowed, but your device didn’t return a position in time. An address works just as well.",
        address: true,
      };
    case "outside":
      return {
        ...base,
        kicker: "NOT IN A U.S. DISTRICT",
        tone: "nay",
        title: "Try a U.S. address.",
        note: "That point isn’t inside any U.S. congressional district — abroad, or out at sea. Floor covers the House and Senate, so it needs a U.S. address.",
        address: true,
      };
    case "error":
      return {
        ...base,
        kicker: "COULDN'T REACH FLOOR'S VOTE SERVER",
        tone: "nay",
        title: "Still the sample.",
        note: "Floor’s vote server didn’t answer, so the page is still showing New York’s 8th. Nothing you sent was kept.",
        locate: "Use my location",
        addressLink: "or type an address",
      };
    case "address":
      return { ...base, kicker: SAMPLE_KICKER, tone: "muted", title: "Your address.", dim: false, address: true };
  }
}

export const PRIVACY =
  "Your browser asks first. Floor rounds the point to about 11 m, finds the district, and keeps neither the point nor the address.";

// ---------------------------------------------------------------- places and seats

const STATES: Record<string, string> = {
  AL: "Alabama", AK: "Alaska", AZ: "Arizona", AR: "Arkansas", CA: "California", CO: "Colorado", CT: "Connecticut",
  DE: "Delaware", FL: "Florida", GA: "Georgia", HI: "Hawaii", ID: "Idaho", IL: "Illinois", IN: "Indiana", IA: "Iowa",
  KS: "Kansas", KY: "Kentucky", LA: "Louisiana", ME: "Maine", MD: "Maryland", MA: "Massachusetts", MI: "Michigan",
  MN: "Minnesota", MS: "Mississippi", MO: "Missouri", MT: "Montana", NE: "Nebraska", NV: "Nevada", NH: "New Hampshire",
  NJ: "New Jersey", NM: "New Mexico", NY: "New York", NC: "North Carolina", ND: "North Dakota", OH: "Ohio",
  OK: "Oklahoma", OR: "Oregon", PA: "Pennsylvania", RI: "Rhode Island", SC: "South Carolina", SD: "South Dakota",
  TN: "Tennessee", TX: "Texas", UT: "Utah", VT: "Vermont", VA: "Virginia", WA: "Washington", WV: "West Virginia",
  WI: "Wisconsin", WY: "Wyoming",
  DC: "District of Columbia", PR: "Puerto Rico", GU: "Guam", VI: "U.S. Virgin Islands", AS: "American Samoa",
  MP: "Northern Mariana Islands",
};

/** Places with a non-voting member of the House and no senators. */
const NON_STATES = new Set(["DC", "PR", "GU", "VI", "AS", "MP"]);

export function stateName(code: string): string {
  return STATES[code] ?? code;
}

export function ordinal(n: number): string {
  const t = n % 100;
  if (t >= 11 && t <= 13) return n + "th";
  return n + (["th", "st", "nd", "rd"][n % 10] ?? "th");
}

/** "Texas's 37th District", "Wyoming's at-large district", "District of Columbia". */
export function districtLabel(d: { state: string; district: number }): string {
  if (NON_STATES.has(d.state)) return stateName(d.state);
  const name = stateName(d.state) + "'s";
  return d.district === 0 ? name + " at-large district" : name + " " + ordinal(d.district) + " District";
}

/** A delegate (or Puerto Rico's resident commissioner) sits in the House but can't vote to pass a bill. */
export function isDelegate(m: ApiMember): boolean {
  return m.chamber === "house" && NON_STATES.has(m.state);
}

function delegateTitle(m: ApiMember): string {
  return m.state === "PR" ? "resident commissioner" : "delegate";
}

function shortPlace(state: string): string {
  return state === "DC" ? "D.C." : stateName(state);
}

/** The strip's note when a place has one member instead of three. */
export function oneMemberNote(m: ApiMember): string {
  if (!isDelegate(m)) return "";
  return "One member, not three: " + shortPlace(m.state) + " has a " + delegateTitle(m) + " in the House and no senators.";
}

const PARTY: Record<string, string> = { D: "Democrat", R: "Republican", I: "Independent", ID: "Independent" };

export function partyName(p: string): string {
  return PARTY[p] ?? p;
}

/** The chip's line: "House · TX-37", "Senate · TX", "House · WY-AL", "Delegate · DC". */
export function seatShort(m: ApiMember): string {
  if (isDelegate(m)) return (m.state === "PR" ? "Res. Commissioner" : "Delegate") + " · " + m.state;
  if (m.chamber === "senate") return "Senate · " + m.state;
  return "House · " + m.state + "-" + (m.district ? m.district : "AL");
}

/** The scouting card's line, as the sample's: "House · Texas 37th · Democrat". */
export function seatLong(m: ApiMember): string {
  const party = partyName(m.party);
  if (isDelegate(m)) return (m.state === "PR" ? "Resident Commissioner" : "Delegate") + " · " + stateName(m.state) + " · " + party;
  if (m.chamber === "senate") return "Senate · " + stateName(m.state) + " · " + party;
  return "House · " + stateName(m.state) + " " + (m.district ? ordinal(m.district) : "at-large") + " · " + party;
}

export function portraitUrl(id: string): string {
  return "https://unitedstates.github.io/images/congress/225x275/" + encodeURIComponent(id) + ".jpg";
}

// ---------------------------------------------------------------- records → the scouting card

export type FoundPos = CellPos;

/** One cell of the grid: [roll, date, measure, question, position, yea, nay, result as recorded]. */
export type FoundRow = readonly [number, string, string, string, FoundPos, number, number, string];

export function posLetter(p: ApiMemberVote["position"]): FoundPos {
  switch (p) {
    case "yea":
      return "Y";
    case "nay":
      return "N";
    case "present":
      return "P";
    case "not_voting":
      return "M";
    case "candidate":
      return "C";
  }
}

/** "Nov 11", on the Capitol's clock: a vote at 9 p.m. Eastern is still that day. */
export function shortDate(iso: string | null): string {
  if (!iso) return "";
  return new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "America/New_York" });
}

/** The clerks' question, shortened the way the sample grid names it. */
export function shortQuestion(q: string): string {
  const rules: [RegExp, string][] = [
    [/Suspend the Rules/i, "Suspension"],
    [/Motion to Recommit/i, "Motion to Recommit"],
    [/Previous Question/i, "Previous question"],
    [/Motion to Table/i, "Motion to Table"],
    [/Motion to Proceed/i, "Motion to Proceed"],
    [/Cloture/i, "Cloture"],
    [/Amendment/i, "Amendment"],
    [/Veto/i, "Veto override"],
    [/Nomination/i, "Nomination"],
    [/Election of the Speaker/i, "Speaker election"],
    [/Passage/i, "Passage"],
    [/Agreeing to the (Concurrent |Joint )?Resolution/i, "Resolution"],
    [/Quorum/i, "Quorum"],
  ];
  for (const [re, name] of rules) if (re.test(q)) return name;
  return q.replace(/^On (the )?/i, "");
}

/** API votes (newest first) → grid rows, oldest first like the sample's. */
export function gridRows(votes: readonly ApiMemberVote[]): FoundRow[] {
  return votes
    .map((v): FoundRow => [
      v.vote.rollNumber ?? 0,
      shortDate(v.vote.occurredAt),
      v.measure?.citation ?? "Procedural",
      shortQuestion(v.vote.question),
      posLetter(v.position),
      v.vote.totals.yea,
      v.vote.totals.nay,
      v.vote.result ?? "",
    ])
    .reverse();
}

export interface GridCounts {
  Y: number;
  N: number;
  P: number;
  M: number;
  C: number;
}

export function gridCounts(rows: readonly { readonly 4: FoundPos }[]): GridCounts {
  const t: GridCounts = { Y: 0, N: 0, P: 0, M: 0, C: 0 };
  for (const r of rows) t[r[4]]++;
  return t;
}

/** The grid's accessible summary: "Last 40 calls, oldest first: 25 yea, 12 nay, 1 present, 2 missed." */
export function gridLabel(rows: readonly { readonly 4: FoundPos }[]): string {
  const t = gridCounts(rows);
  const parts = [t.Y + " yea", t.N + " nay", t.P + " present", t.M + " missed"];
  if (t.C) parts.push(t.C + " for a Speaker candidate");
  return "Last " + rows.length + " calls, oldest first: " + parts.join(", ") + ".";
}

export interface FoundScout {
  id: string;
  label: string;
  full: string;
  seat: string;
  chamber: "House" | "Senate";
  /** Percent with party, one decimal; null when there are no counted party votes yet. */
  unity: number | null;
  withParty: number;
  partyVotes: number;
  played: number;
  playedSub: string;
  won: number;
  of: number;
  cross: number;
  note: string;
  latest: string;
  delegate: string;
  grid: FoundRow[];
}

/** Builds a scouting card from the API: loyalty from /v1/members/{id}, everything else from its votes. */
export function scoutFrom(m: ApiMember, loyalty: ApiLoyalty, votes: readonly ApiMemberVote[]): FoundScout {
  const grid = gridRows(votes);
  const t = gridCounts(grid);
  const played = t.Y + t.N + t.P;
  const extras = [t.P ? t.P + " present" : "", t.M ? t.M + " missed" : ""].filter(Boolean);
  const cast = grid.filter((r) => r[4] === "Y" || r[4] === "N");
  const won = cast.filter((r) => (r[4] === "Y") === carried(r[7])).length;
  const newest = votes[0];
  return {
    id: m.bioguideId,
    label: m.lastName,
    full: m.firstName + " " + m.lastName,
    seat: seatLong(m),
    chamber: m.chamber === "house" ? "House" : "Senate",
    unity: loyalty.votes ? Math.round((1000 * loyalty.withParty) / loyalty.votes) / 10 : null,
    withParty: loyalty.withParty,
    partyVotes: loyalty.votes,
    played,
    playedSub: [played + " of " + grid.length, ...extras].join(" · "),
    won,
    of: cast.length,
    cross: loyalty.againstParty,
    note: "Votes against their party’s majority, out of " + loyalty.votes.toLocaleString("en-US") + " where it had a clear side.",
    latest: newest ? latestLine(newest) : "",
    delegate: isDelegate(m) ? delegateNote(m, votes) : "",
    grid,
  };
}

const WORD: Record<FoundPos, string> = { Y: "YEA", N: "NAY", P: "PRESENT", M: "MISSED", C: "VOTED" };

/** "NAY · H.R. 1013 · Passage · Passed · Nov 11" */
export function latestLine(v: ApiMemberVote): string {
  const pos = v.position === "candidate" && v.choice ? "VOTED " + v.choice.toUpperCase() : WORD[posLetter(v.position)];
  return [pos, v.measure?.citation ?? "Procedural", shortQuestion(v.vote.question), v.vote.result ?? "", shortDate(v.vote.occurredAt)]
    .filter(Boolean)
    .join(" · ");
}

/**
 * A delegate can vote only in the Committee of the Whole, which is to say on amendments. The note
 * counts that from the votes rather than asserting it.
 */
export function delegateNote(m: ApiMember, votes: readonly ApiMemberVote[]): string {
  const where = shortPlace(m.state);
  const title = delegateTitle(m);
  const head = where + " has one " + title + " to the House and no senators. A " + title + " can't vote to pass a bill";
  if (!votes.length) return head + ".";
  const amend = votes.filter((v) => /Amendment/i.test(v.vote.question)).length;
  const latest = shortDate(votes[0]?.vote.occurredAt ?? null);
  const share =
    amend === votes.length
      ? "every one of " + m.lastName + "'s last " + votes.length + " recorded votes is on an amendment"
      : amend + " of " + m.lastName + "'s last " + votes.length + " recorded votes are on amendments";
  return head + ", so " + share + (latest ? " — the latest on " + latest : "") + ".";
}

// ---------------------------------------------------------------- remembering a district

export const STORE_KEY = "floor.yours.v1";

/** What a return visit needs: the district's label and members. Never the point or the address. */
export function serializeFound(f: Found): string {
  return JSON.stringify({
    label: f.label,
    members: f.members.map((m) => ({
      bioguideId: m.bioguideId,
      firstName: m.firstName,
      lastName: m.lastName,
      party: m.party,
      state: m.state,
      district: m.district,
      chamber: m.chamber,
    })),
  });
}

/** Reads back what serializeFound wrote; anything else (old, edited, corrupt) is null. */
export function parseFound(raw: string | null): Found | null {
  if (!raw) return null;
  let v: unknown;
  try {
    v = JSON.parse(raw);
  } catch {
    return null;
  }
  const o = v as { label?: unknown; members?: unknown };
  if (typeof o?.label !== "string" || !Array.isArray(o.members) || o.members.length < 1 || o.members.length > 3) return null;
  const members: ApiMember[] = [];
  for (const x of o.members as Record<string, unknown>[]) {
    if (
      typeof x?.bioguideId !== "string" || !/^[A-Z]\d{6}$/.test(x.bioguideId) ||
      typeof x.firstName !== "string" || typeof x.lastName !== "string" || typeof x.party !== "string" ||
      typeof x.state !== "string" || (x.chamber !== "house" && x.chamber !== "senate") ||
      !(x.district === null || typeof x.district === "number")
    ) {
      return null;
    }
    members.push({
      bioguideId: x.bioguideId, firstName: x.firstName, lastName: x.lastName, party: x.party,
      state: x.state, district: x.district as number | null, chamber: x.chamber,
    });
  }
  return { label: o.label, members };
}

export function foundFrom(r: ApiReps): Found {
  return { label: districtLabel(r.district), members: r.members };
}
