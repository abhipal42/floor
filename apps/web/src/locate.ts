// "Your members, from your location": the state machine behind the strip under the site header, and
// the pure mapping from the API's responses (apps/api/openapi.json: Reps, MemberDetail, MemberVote)
// to what the strip and the scouting report show. No DOM, no fetch, so all of it runs in Node.

import { formatMoney, winningSide, type CellPos } from "./logic.js";

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

/**
 * How a /v1/reps answer reads. A 404 means different things for the two kinds of request: for a
 * point it is outside every U.S. district; for an address the Census geocoder couldn't match it
 * (`apps/api/src/app.ts`, "We couldn't find that address"). 400 on an address is the API refusing
 * its shape; 429 is the lookup rate limit.
 */
export type RepsOutcome = "ok" | "outside" | "notfound" | "badaddr" | "busy" | "error";

/** `status` is the HTTP status, or null when fetch itself threw (offline, or CORS refused it). */
export function repsOutcome(status: number | null, kind: "coords" | "address"): RepsOutcome {
  if (status === null) return "error";
  if (status >= 200 && status < 300) return "ok";
  if (status === 404) return kind === "address" ? "notfound" : "outside";
  if (status === 429) return "busy";
  if (status === 400 && kind === "address") return "badaddr";
  return "error";
}

/** Whether a member's own record calls (`/v1/members/{id}`, `/votes`) answered. */
export function httpOk(status: number | null): boolean {
  return status !== null && status >= 200 && status < 300;
}

// ---------------------------------------------------------------- the state machine

export type Step =
  | "idle" | "asking" | "loading" | "found" | "denied" | "nofix" | "outside" | "notfound" | "badaddr" | "busy" | "vacant" | "error" | "address";

/** Steps that show the address field; each has a Cancel back to where the person came from. */
const ADDRESS_STEPS: readonly Step[] = ["address", "denied", "nofix", "outside", "notfound", "badaddr"];

export interface Found {
  /** "Texas's 37th District" */
  label: string;
  /** The Congress the members were looked up for; a saved district from an older one is dropped. */
  congress: number;
  members: ApiMember[];
}

export interface LocState {
  step: Step;
  /** The district and members on show while `step` is "found" (kept while typing a new address). */
  found: Found | null;
  /**
   * Their records (loyalty and votes), fetched after the district is found. "partial" is some
   * members loaded and some didn't.
   */
  records: "loading" | "ready" | "partial" | "error";
  addrErr: boolean;
  /** Where Cancel on the address field goes. */
  returnTo: "idle" | "found";
  /** A 200 with no members: the district's label, for the vacant-seat wording. */
  vacant: string;
}

export type LocEvent =
  | { type: "locate"; supported: boolean }
  | { type: "geoFix" }
  | { type: "geoError"; code: number }
  | { type: "toAddress" }
  | { type: "cancel" }
  | { type: "submitAddress"; text: string }
  | { type: "typed" }
  | { type: "reps"; outcome: RepsOutcome; found?: Found }
  | { type: "records"; loaded: number; of: number }
  | { type: "retry" }
  | { type: "reset" }
  | { type: "restore"; found: Found };

export const INITIAL: LocState = { step: "idle", found: null, records: "loading", addrErr: false, returnTo: "idle", vacant: "" };

/** GeolocationPositionError.PERMISSION_DENIED; 2 (unavailable) and 3 (timeout) are "no fix". */
const PERMISSION_DENIED = 1;

export function nextState(s: LocState, e: LocEvent): LocState {
  switch (e.type) {
    case "locate":
      // No geolocation in this browser: straight to typing an address.
      return { ...s, step: e.supported ? "asking" : "address", addrErr: false, returnTo: "idle" };
    case "geoFix":
      return s.step === "asking" ? { ...s, step: "loading" } : s;
    case "geoError":
      if (s.step !== "asking") return s;
      return { ...s, step: e.code === PERMISSION_DENIED ? "denied" : "nofix" };
    case "toAddress":
      if (ADDRESS_STEPS.includes(s.step)) return s;
      return { ...s, step: "address", addrErr: false, returnTo: s.step === "found" && s.found ? "found" : "idle" };
    case "cancel":
      if (!ADDRESS_STEPS.includes(s.step)) return s;
      return s.returnTo === "found" && s.found ? { ...s, step: "found", addrErr: false } : { ...INITIAL };
    case "typed":
      return s.addrErr ? { ...s, addrErr: false } : s;
    case "submitAddress":
      return addressOk(e.text) ? { ...s, step: "loading", addrErr: false } : { ...s, addrErr: true };
    case "reps":
      if (s.step !== "loading") return s;
      if (e.outcome === "ok" && e.found) {
        if (!e.found.members.length) return { ...s, step: "vacant", vacant: e.found.label };
        return { ...s, step: "found", found: e.found, records: "loading", returnTo: "idle" };
      }
      return { ...s, step: e.outcome === "ok" ? "error" : e.outcome };
    case "records":
      if (s.step !== "found" || s.records !== "loading") return s;
      return { ...s, records: e.loaded === e.of ? "ready" : e.loaded > 0 ? "partial" : "error" };
    case "retry":
      return s.step === "found" && (s.records === "error" || s.records === "partial") ? { ...s, records: "loading" } : s;
    case "reset":
      return INITIAL;
    case "restore":
      return { ...INITIAL, step: "found", found: e.found };
  }
}

/** Steps that offer the address field's Cancel. */
export function canCancel(s: LocState): boolean {
  return ADDRESS_STEPS.includes(s.step);
}

/**
 * The records-error copy. It names the one member who failed when the others loaded, and never
 * says "three" for a place with one member.
 */
export function recordsError(count: number, failedName?: string): { title: string; body: string } {
  if (failedName) {
    return {
      title: "Couldn't load " + failedName + "'s records",
      body: "Floor's vote server didn't answer for " + failedName + ". The others loaded; nothing else is lost.",
    };
  }
  const kept = count === 1 ? "Your member is kept" : count === 3 ? "Your three are kept" : "Your members are kept";
  return { title: "Couldn't load their records", body: "Floor found your district but its vote server didn't answer. " + kept + "; nothing else is lost." };
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
    case "notfound":
      return {
        ...base,
        kicker: "WE COULDN'T FIND THAT ADDRESS",
        tone: "nay",
        title: "Check the address.",
        note: "We couldn't find that address. Try adding the city, state and ZIP code.",
        address: true,
      };
    case "badaddr":
      return {
        ...base,
        kicker: "THAT ADDRESS DIDN'T GO THROUGH",
        tone: "nay",
        title: "Check the address.",
        note: "Floor couldn't read that as an address. Type a street address with the city, state and ZIP, in under 200 characters.",
        address: true,
      };
    case "busy":
      return {
        ...base,
        kicker: "TOO MANY LOOKUPS",
        tone: "nay",
        title: "Try again in a minute.",
        note: "Too many lookups, try again in a minute. Floor limits how often a district can be looked up.",
        locate: "Use my location",
        addressLink: "or type an address",
      };
    case "vacant":
      return {
        ...base,
        kicker: "NO SITTING MEMBERS FOUND",
        tone: "nay",
        title: "Those seats look vacant.",
        note: "Floor found " + (s.vacant || "your district") + ", but no one holds its seats in Floor's records right now — they may be vacant until a special election. The page is still showing the sample.",
        locate: "Use my location",
        addressLink: "or type an address",
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

/**
 * Says only what this page does. The locked mock said Floor "keeps neither the point nor the
 * address", but /v1/reps takes both as GET query strings, which the host's request logs may record
 * (HANDOFF › The landing page, open item). Until that is settled, the page doesn't claim it.
 */
export const PRIVACY = "Your browser asks first. Floor rounds the point to about 11 m and uses it once to find your district; this page stores only the district.";

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
  return Object.hasOwn(STATES, code) ? STATES[code]! : code;
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
  return Object.hasOwn(PARTY, p) ? PARTY[p]! : p;
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

const POSITIONS: Record<ApiMemberVote["position"], FoundPos> = { yea: "Y", nay: "N", present: "P", not_voting: "M", candidate: "C" };

/** The grid letter for an API position; anything outside the five the API documents throws. */
export function posLetter(p: ApiMemberVote["position"]): FoundPos {
  if (typeof p !== "string" || !Object.hasOwn(POSITIONS, p)) throw new Error("unknown vote position: " + String(p));
  return POSITIONS[p];
}

/** Throws unless a vote has the fields the card reads, so a bad row fails the member, not the page. */
function checkVote(v: ApiMemberVote): void {
  posLetter(v?.position);
  const t = v?.vote?.totals;
  if (!t || !Number.isFinite(t.yea) || !Number.isFinite(t.nay) || typeof v.vote.question !== "string") {
    throw new Error("malformed vote");
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
  votes.forEach(checkVote);
  return votes
    .map((v): FoundRow => [
      Number(v.vote.rollNumber ?? 0),
      shortDate(v.vote.occurredAt),
      v.measure?.citation ?? "Procedural",
      shortQuestion(v.vote.question),
      posLetter(v.position),
      Number(v.vote.totals.yea),
      Number(v.vote.totals.nay),
      String(v.vote.result ?? ""),
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
  /** Percent with party, one decimal; null when there are no counted party votes (an independent). */
  unity: number | null;
  /** "1,782 of 1,839", or "—" with no party votes to count. */
  withPartySub: string;
  played: number;
  playedSub: string;
  won: number;
  of: number;
  /** Crossovers; null with no party votes to count, shown as "—" rather than a made-up 0. */
  cross: number | null;
  note: string;
  latest: string;
  delegate: string;
  grid: FoundRow[];
}

/** Builds a scouting card from the API: loyalty from /v1/members/{id}, everything else from its votes. */
export function scoutFrom(m: ApiMember, loyalty: ApiLoyalty, votes: readonly ApiMemberVote[]): FoundScout {
  const grid = gridRows(votes);
  const t = gridCounts(grid);
  // A Speaker ballot for a named candidate is a vote cast: it counts as showing up, though it has
  // no winning side.
  const played = t.Y + t.N + t.P + t.C;
  const extras = [t.P ? t.P + " present" : "", t.M ? t.M + " missed" : ""].filter(Boolean);
  const { won, of } = winningSide(grid);
  const newest = votes[0];
  const counted = Number(loyalty.votes);
  const fmt = (n: number) => Number(n).toLocaleString("en-US");
  const independent = m.party === "I" || m.party === "ID";
  return {
    id: m.bioguideId,
    label: m.lastName,
    full: m.firstName + " " + m.lastName,
    seat: seatLong(m),
    chamber: m.chamber === "house" ? "House" : "Senate",
    unity: counted ? Math.round((1000 * loyalty.withParty) / counted) / 10 : null,
    withPartySub: counted ? fmt(loyalty.withParty) + " of " + fmt(counted) : "—",
    played,
    playedSub: [played + " of " + grid.length, ...extras].join(" · "),
    won,
    of,
    cross: counted ? Number(loyalty.againstParty) : null,
    note: counted
      ? "Votes against their party’s majority, out of " + fmt(counted) + " where it had a clear side."
      : independent
        ? "No party bloc to measure against: an independent has no party majority to vote with or against, so Floor counts no crossovers."
        : "No votes yet where their party’s majority had a clear side, so there are no crossovers to count.",
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
    congress: f.congress,
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

/**
 * The Congress sitting on a date: each starts at noon on Jan 3 of an odd year (the 119th in 2025),
 * so on 2027-01-03 a district saved for the 119th stops being trusted (lesson 4). Day precision;
 * the morning of Jan 3 is a few hours early, which only drops a saved district a little sooner.
 */
export function congressOn(date: Date): number {
  const y = date.getUTCFullYear();
  const beforeJan3 = date.getUTCMonth() === 0 && date.getUTCDate() < 3;
  return Math.floor(((beforeJan3 ? y - 1 : y) - 1789) / 2) + 1;
}

/**
 * Reads back what serializeFound wrote; anything else (old, edited, corrupt, or saved for a
 * different Congress, when the members may have changed) is null.
 */
export function parseFound(raw: string | null, congress: number): Found | null {
  if (!raw) return null;
  let v: unknown;
  try {
    v = JSON.parse(raw);
  } catch {
    return null;
  }
  const o = v as { label?: unknown; congress?: unknown; members?: unknown };
  if (typeof o?.label !== "string" || o.congress !== congress) return null;
  if (!Array.isArray(o.members) || o.members.length < 1 || o.members.length > 3) return null;
  const members: ApiMember[] = [];
  for (const x of o.members as Record<string, unknown>[]) {
    if (
      typeof x?.bioguideId !== "string" || !/^[A-Z]\d{6}$/.test(x.bioguideId) ||
      typeof x.firstName !== "string" || typeof x.lastName !== "string" || typeof x.party !== "string" ||
      typeof x.state !== "string" || (x.chamber !== "house" && x.chamber !== "senate") ||
      !(x.district === null || (Number.isInteger(x.district) && (x.district as number) >= 0))
    ) {
      return null;
    }
    members.push({
      bioguideId: x.bioguideId, firstName: x.firstName, lastName: x.lastName, party: x.party,
      state: x.state, district: x.district as number | null, chamber: x.chamber,
    });
  }
  return { label: o.label, congress, members };
}

export function foundFrom(r: ApiReps): Found {
  return { label: districtLabel(r.district), congress: r.district.congress, members: Array.isArray(r.members) ? r.members : [] };
}

// ---------------------------------------------------------------- campaign money (MemberFunding)

export interface ApiPacCheck {
  committeeId: string;
  name: string;
  kind: string | null;
  orgType: string | null;
  connectedOrg: string | null;
  direct: number;
  earmarked: number;
}

export interface ApiFunding {
  cycle: number;
  coverageStart: string | null;
  coverageEnd: string | null;
  receipts: number;
  smallDollar: number;
  itemized: number;
  pac: number;
  party: number;
  other: number;
  cashOnHand: number | null;
  committeesCycle: number | null;
  committees: ApiPacCheck[];
}

export interface ApiMemberFunding {
  member: ApiMember;
  /** Null: the FEC has no totals for the member's current campaign. */
  funding: ApiFunding | null;
}

/** How many PAC checks the money section lists. */
export const PAC_LIST = 10;

export function fundingUrl(base: string, id: string, committees = PAC_LIST): string {
  return base + "/v1/members/" + encodeURIComponent(id) + "/funding?committees=" + committees;
}

/** Kept in capitals: initialisms the FEC spells out in full elsewhere, or that read wrong title-cased. */
const ACRONYMS = new Set(["PAC", "AFL", "CIO", "IBEW", "SEIU", "UAW", "NEA", "AFT", "AMA", "ADA", "AARP", "NRA", "UA", "USA", "US", "UPS", "CVS", "IBM", "GE", "BP", "LLC", "LLP", "TIAA", "AT&T", "II", "III"]);
const SMALL = new Set(["of", "and", "the", "for", "on", "in", "to", "a", "an", "at", "by"]);

function casePart(part: string, first: boolean, keep: Set<string>): string {
  const bare = part.replace(/[^A-Za-z0-9&]/g, "");
  const upper = bare.toUpperCase();
  // Y is a vowel in a word of three letters or more (BYRD, LYNN).
  const vowel = bare.length >= 3 ? /[AEIOUY]/i : /[AEIOU]/i;
  if (ACRONYMS.has(upper) || keep.has(upper) || /\d/.test(bare) || (bare.length > 3 && upper.endsWith("PAC")) || (bare.length > 1 && !vowel.test(bare)))
    return part.toUpperCase();
  const lower = part.toLowerCase();
  if (!first && SMALL.has(lower)) return lower;
  // O'BRIEN, D'AMATO: the letter after a leading O' or D' is a capital too. The app's
  // `CommitteeName.casePart` is the same rule.
  return lower.replace(/[a-z]/, (c) => c.toUpperCase()).replace(/^([OD]['’])([a-z])/, (_m, p: string, c: string) => p + c.toUpperCase());
}

/**
 * FEC committee names are filed in capitals: "EXXON MOBIL CORPORATION POLITICAL ACTION COMMITTEE
 * (EXXONMOBIL PAC)" reads as "Exxon Mobil Corporation PAC". Drops parenthetical nicknames, closes up
 * letter-spaced words (P E O P L E), and keeps initialisms in capitals.
 */
export function committeeName(raw: string): string {
  // Letter-spaced words are spelled out on purpose (AFSCME's P E O P L E): close them up, keep the capitals.
  const keep = new Set<string>();
  const s = raw
    .replace(/\s*\([^)]*\)/g, "")
    .replace(/\b(?:[A-Z] ){2,}[A-Z]\b/g, (m) => {
      const w = m.replace(/ /g, "");
      keep.add(w);
      return w;
    })
    .replace(/POLITICAL ACTION COMMITTEE/gi, "PAC")
    .replace(/\s+/g, " ")
    .trim();
  return s
    .split(" ")
    .map((w, i) => w.split("-").map((p, k) => casePart(p, i === 0 && k === 0, keep)).join("-"))
    .join(" ");
}

const day = (iso: string, opts: Intl.DateTimeFormatOptions) => new Date(iso + "T12:00:00Z").toLocaleDateString("en-US", { ...opts, timeZone: "UTC" });

/** "Jan 2025 – Oct 14, 2026" */
export function coverageRange(start: string | null, end: string | null): string {
  const a = start ? day(start, { month: "short", year: "numeric" }) : "";
  const b = end ? day(end, { month: "short", day: "numeric", year: "numeric" }) : "";
  return a && b ? a + " – " + b : a || b;
}

/** "2025–26": the two-year FEC cycle ending in `cycle`. */
export function cycleYears(cycle: number): string {
  return cycle - 1 + "–" + String(cycle).slice(2);
}

/** One member's money, as the money section draws it: the same shape for the sample and the API. */
export interface FundView {
  period: string;
  total: number;
  cash: number | null;
  cashAsOf: string;
  small: number;
  itemized: number;
  pac: number;
  other: number;
  otherNote: string;
  /** What the shares are of: the parts as drawn. Absent (the sample) means `total`. */
  shareBase?: number;
  /** Shown under the figures when "Transfers & other" came to less than nothing. */
  adjustNote?: string | null;
  pacs: { name: string; kind: string | null; amount: number }[];
  /** Above the PAC list: what period it covers and what a check can be. */
  pacsNote: string;
  /** Shown instead of the list when it is empty. */
  pacsNone: { title: string; body: string };
}

export const PAC_LIMIT_NOTE = "A PAC can give $5,000 per election — primary and general — so $10,000 is the usual most for one race.";

export function fundingFrom(f: ApiFunding): FundView {
  const range = coverageRange(f.coverageStart, f.coverageEnd);
  const years = f.committeesCycle ? cycleYears(f.committeesCycle) : null;
  // The worker computes `other` as receipts minus the rest (apps/worker/src/fec.ts), so refunds and
  // adjustments can push it below zero. The bar and the legend both draw it as 0, the shares are of
  // the parts drawn, and a note says why. The app does the same (`Funding.shown`).
  const rawOther = f.party + f.other;
  const other = Math.max(0, rawOther);
  const pos = (n: number) => Math.max(0, n);
  return {
    period: f.cycle + " campaign" + (range ? " · " + range : ""),
    total: f.receipts,
    cash: f.cashOnHand,
    cashAsOf: f.coverageEnd ? "as of " + day(f.coverageEnd, { month: "short", day: "numeric", year: "numeric" }) : "",
    small: f.smallDollar,
    itemized: f.itemized,
    pac: f.pac,
    // The bar has four parts; party money is rarely more than a sliver, so it rides with transfers.
    other,
    shareBase: pos(f.smallDollar) + pos(f.itemized) + pos(f.pac) + other,
    adjustNote:
      rawOther < 0
        ? "Transfers & other came to " + formatMoney(rawOther) + ": it includes refunds/adjustments, so it shows as 0 and the shares are of the other three."
        : null,
    otherNote: f.party > 0 ? "transfers, party money, refunds and the candidate's own money" : "transfers, refunds and the candidate's own money",
    pacs: f.committees
      .filter((c) => c.direct > 0)
      .slice(0, PAC_LIST)
      .map((c) => ({ name: committeeName(c.name), kind: c.kind, amount: c.direct })),
    pacsNote: (years ? "Each PAC's own checks, from its " + years + " filings. " : "") + PAC_LIMIT_NOTE,
    pacsNone: {
      title: "No PAC checks on file" + (years ? " for " + years : "") + ".",
      body: "No committee has reported giving to this campaign" + (years ? " in the " + years + " FEC files" : "") + ".",
    },
  };
}

/** The FEC has no current-campaign totals: newly appointed, or not filed yet. */
export function noFundingCopy(m: ApiMember): { title: string; body: string } {
  return {
    title: "No campaign filings yet",
    body:
      m.firstName + " " + m.lastName + " has no totals at the FEC for a current campaign. A newly appointed member, or one who hasn't filed for the next race, shows up here once the FEC lists their campaign.",
  };
}
