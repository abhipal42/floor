import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  INITIAL,
  PRIVACY,
  STORE_KEY,
  addressOk,
  canCancel,
  committeeName,
  coverageRange,
  cycleYears,
  fundingFrom,
  fundingUrl,
  noFundingCopy,
  congressOn,
  districtLabel,
  foundFrom,
  gridCounts,
  gridLabel,
  gridRows,
  httpOk,
  isDelegate,
  isSample,
  latestLine,
  nextState,
  oneMemberNote,
  ordinal,
  parseFound,
  partyName,
  portraitUrl,
  posLetter,
  recordsError,
  stateName,
  repsOutcome,
  repsUrl,
  roundCoord,
  scoutFrom,
  seatLong,
  seatShort,
  serializeFound,
  shortDate,
  shortQuestion,
  stripView,
  type ApiMemberFunding,
  type ApiMemberVote,
  type ApiReps,
  type LocEvent,
  type LocState,
} from "./locate.js";

// Real responses from https://floor-api.vercel.app, captured with curl on 2026-11-12.
const fixture = (name: string) => JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "../fixtures", name), "utf8"));
const austin: ApiReps = fixture("reps-austin.json");
const dc: ApiReps = fixture("reps-dc.json");
const cheyenne: ApiReps = fixture("reps-cheyenne.json");
const votes = (id: string): ApiMemberVote[] => fixture("votes-" + id + ".json").votes;
const loyalty = (id: string) => fixture("member-" + id + ".json").partyLoyalty;

const run = (...events: LocEvent[]): LocState => events.reduce(nextState, INITIAL);
const found = foundFrom(austin);

describe("the request", () => {
  it("rounds coordinates to 4 decimals (about 11 m) before they leave the page", () => {
    expect(roundCoord(30.27471234)).toBe(30.2747);
    expect(roundCoord(-97.74046)).toBe(-97.7405);
    expect(roundCoord(51.5074)).toBe(51.5074);
    expect(repsUrl("https://x.test", { lat: 30.274712345, lng: -97.740412345 })).toBe("https://x.test/v1/reps?lat=30.2747&lng=-97.7404");
  });

  it("sends an address trimmed and encoded", () => {
    expect(repsUrl("https://x.test", { address: " 1100 Congress Ave, Austin, TX 78701 " })).toBe(
      "https://x.test/v1/reps?address=1100+Congress+Ave%2C+Austin%2C+TX+78701",
    );
  });

  it("refuses a bare ZIP and anything under six characters, as the mock does", () => {
    expect(addressOk("78701")).toBe(false);
    expect(addressOk("  78701 ")).toBe(false);
    expect(addressOk("Main")).toBe(false);
    expect(addressOk("")).toBe(false);
    expect(addressOk("1100 Congress Ave, Austin, TX 78701")).toBe(true);
    expect(addressOk("78701-1234")).toBe(true);
  });

  it("a 404 for a point is outside the U.S.", () => {
    expect(fixture("reps-london.json").error).toMatch(/isn't in a U.S. congressional district/);
    expect(repsOutcome(200, "coords")).toBe("ok");
    expect(repsOutcome(404, "coords")).toBe("outside");
  });

  it("a 404 for an address is the geocoder not finding it, as the API says", () => {
    expect(fixture("reps-mistyped.json").error).toBe("We couldn't find that address. Try adding the city, state and ZIP code.");
    expect(repsOutcome(404, "address")).toBe("notfound");
    expect(repsOutcome(200, "address")).toBe("ok");
  });

  it("400 on an address is an address problem; 429 is the rate limit; the rest are errors", () => {
    expect(repsOutcome(400, "address")).toBe("badaddr");
    expect(repsOutcome(400, "coords")).toBe("error");
    expect(repsOutcome(429, "address")).toBe("busy");
    expect(repsOutcome(429, "coords")).toBe("busy");
    expect(repsOutcome(500, "coords")).toBe("error");
    // fetch threw: offline, or the browser refused a response with no CORS header.
    expect(repsOutcome(null, "address")).toBe("error");
    expect(httpOk(200)).toBe(true);
    expect(httpOk(404)).toBe(false);
    expect(httpOk(null)).toBe(false);
  });
});

describe("the state machine", () => {
  it("allow → loading → found → records ready", () => {
    expect(run({ type: "locate", supported: true }).step).toBe("asking");
    expect(run({ type: "locate", supported: true }, { type: "geoFix" }).step).toBe("loading");
    const s = run({ type: "locate", supported: true }, { type: "geoFix" }, { type: "reps", outcome: "ok", found });
    expect(s).toMatchObject({ step: "found", records: "loading", found: { label: "Texas's 37th District" } });
    expect(nextState(s, { type: "records", loaded: 3, of: 3 }).records).toBe("ready");
  });

  it("block → denied; unavailable or timeout → no fix", () => {
    expect(run({ type: "locate", supported: true }, { type: "geoError", code: 1 }).step).toBe("denied");
    expect(run({ type: "locate", supported: true }, { type: "geoError", code: 2 }).step).toBe("nofix");
    expect(run({ type: "locate", supported: true }, { type: "geoError", code: 3 }).step).toBe("nofix");
  });

  it("no geolocation in the browser goes straight to the address field", () => {
    expect(run({ type: "locate", supported: false }).step).toBe("address");
  });

  it("a 404 is outside; a network or CORS failure is the error state, on the sample", () => {
    const loading = run({ type: "toAddress" }, { type: "submitAddress", text: "10 Downing St, London" });
    expect(loading.step).toBe("loading");
    expect(nextState(loading, { type: "reps", outcome: "outside" }).step).toBe("outside");
    const err = nextState(loading, { type: "reps", outcome: "error" });
    expect(err.step).toBe("error");
    expect(isSample(err)).toBe(true);
  });

  it("a ZIP alone flags the field and stays put; typing clears the flag", () => {
    const s = run({ type: "toAddress" }, { type: "submitAddress", text: "78701" });
    expect(s).toMatchObject({ step: "address", addrErr: true });
    expect(nextState(s, { type: "typed" }).addrErr).toBe(false);
  });

  it("records failing keeps the found members; Try again reloads them", () => {
    const s = run({ type: "restore", found }, { type: "records", loaded: 0, of: 3 });
    expect(s).toMatchObject({ step: "found", records: "error", found });
    expect(nextState(s, { type: "retry" }).records).toBe("loading");
  });

  it("one member failing is partial: the others show, and Try again is offered", () => {
    const s = run({ type: "restore", found }, { type: "records", loaded: 2, of: 3 });
    expect(s.records).toBe("partial");
    expect(isSample(s)).toBe(false);
    expect(nextState(s, { type: "retry" }).records).toBe("loading");
  });

  it("an address 404, a 400 and a 429 each have their own step", () => {
    const loading = run({ type: "toAddress" }, { type: "submitAddress", text: "zzzz nowhere qqq" });
    expect(nextState(loading, { type: "reps", outcome: "notfound" }).step).toBe("notfound");
    expect(nextState(loading, { type: "reps", outcome: "badaddr" }).step).toBe("badaddr");
    expect(nextState(loading, { type: "reps", outcome: "busy" }).step).toBe("busy");
  });

  it("a 200 with no members is a vacant seat, not a found district", () => {
    const loading = run({ type: "toAddress" }, { type: "submitAddress", text: "1100 Congress Ave, Austin" });
    const s = nextState(loading, { type: "reps", outcome: "ok", found: { ...found, members: [] } });
    expect(s).toMatchObject({ step: "vacant", vacant: "Texas's 37th District" });
    expect(isSample(s)).toBe(true);
  });

  it("Cancel on the address field goes back where it came from", () => {
    expect(run({ type: "toAddress" }, { type: "cancel" })).toEqual(INITIAL);
    const fromFound = run({ type: "restore", found }, { type: "records", loaded: 3, of: 3 }, { type: "toAddress" });
    expect(fromFound).toMatchObject({ step: "address", returnTo: "found" });
    expect(canCancel(fromFound)).toBe(true);
    expect(nextState(fromFound, { type: "cancel" })).toMatchObject({ step: "found", found, records: "ready" });
    // A lookup that fails after "Not your district?" still cancels back to the district on show.
    const failed = [{ type: "submitAddress", text: "zzzz nowhere qqq" }, { type: "reps", outcome: "notfound" }] as const;
    const after = failed.reduce(nextState, fromFound);
    expect(after.step).toBe("notfound");
    expect(nextState(after, { type: "cancel" }).step).toBe("found");
    // Denied from the sample cancels to the sample.
    expect(run({ type: "locate", supported: true }, { type: "geoError", code: 1 }, { type: "cancel" })).toEqual(INITIAL);
    expect(canCancel(INITIAL)).toBe(false);
    expect(nextState(INITIAL, { type: "cancel" })).toEqual(INITIAL);
  });

  it("ignores late answers that no longer apply", () => {
    const idle = run({ type: "locate", supported: true }, { type: "reset" });
    expect(nextState(idle, { type: "reps", outcome: "ok", found })).toEqual(INITIAL);
    expect(nextState(idle, { type: "geoFix" })).toEqual(INITIAL);
    const ready = run({ type: "restore", found }, { type: "records", loaded: 3, of: 3 });
    expect(nextState(ready, { type: "records", loaded: 0, of: 3 }).records).toBe("ready");
  });

  it("the records error never says three for one member, and names a single failure", () => {
    expect(recordsError(1).body).toContain("Your member is kept");
    expect(recordsError(1).body).not.toMatch(/three/);
    expect(recordsError(3).body).toContain("Your three are kept");
    expect(recordsError(2).body).toContain("Your members are kept");
    expect(recordsError(3, "Cruz")).toEqual({
      title: "Couldn't load Cruz's records",
      body: "Floor's vote server didn't answer for Cruz. The others loaded; nothing else is lost.",
    });
  });

  it("Back to the sample returns to idle", () => {
    expect(run({ type: "restore", found }, { type: "reset" })).toEqual(INITIAL);
  });
});

describe("the strip's copy", () => {
  it("each state reads as the mock", () => {
    expect(stripView(INITIAL)).toMatchObject({ kicker: "SAMPLE · NEW YORK'S 8TH DISTRICT", title: "Make it your three.", locate: "Use my location", addressLink: "or type an address", back: false });
    expect(stripView(run({ type: "locate", supported: true }))).toMatchObject({ locate: "Waiting for your browser…", dim: true });
    expect(stripView(run({ type: "toAddress" }, { type: "submitAddress", text: "1100 Congress Ave" }))).toMatchObject({ chips: "skeleton", kicker: "FINDING YOUR DISTRICT…" });
    expect(stripView(run({ type: "restore", found }))).toMatchObject({
      kicker: "YOUR DISTRICT · TEXAS'S 37TH DISTRICT",
      tone: "yea",
      chips: "found",
      addressLink: "Not your district? Type an address",
      back: true,
      note: "",
    });
    expect(stripView(run({ type: "locate", supported: true }, { type: "geoError", code: 1 }))).toMatchObject({ kicker: "LOCATION IS BLOCKED FOR THIS SITE", address: true, tone: "nay" });
    expect(stripView(run({ type: "toAddress" }, { type: "submitAddress", text: "London, UK" }, { type: "reps", outcome: "outside" }))).toMatchObject({
      kicker: "NOT IN A U.S. DISTRICT",
      title: "Try a U.S. address.",
      address: true,
    });
  });

  it("D.C. gets the one-member note", () => {
    expect(stripView(run({ type: "restore", found: foundFrom(dc) })).note).toBe(
      "One member, not three: D.C. has a delegate in the House and no senators.",
    );
  });

  it("the privacy line claims only what the page does (diverges from the mock on purpose)", () => {
    expect(PRIVACY).toBe("Your browser asks first. Floor rounds the point to about 11 m and uses it once to find your district; this page stores only the district.");
    expect(PRIVACY).not.toMatch(/keeps neither/);
  });

  it("the new failure steps say what happened", () => {
    const at = (outcome: "notfound" | "badaddr" | "busy") =>
      stripView(run({ type: "toAddress" }, { type: "submitAddress", text: "zzzz nowhere qqq" }, { type: "reps", outcome }));
    expect(at("notfound")).toMatchObject({ kicker: "WE COULDN'T FIND THAT ADDRESS", address: true, note: "We couldn't find that address. Try adding the city, state and ZIP code." });
    expect(at("notfound").note).not.toMatch(/abroad|at sea/);
    expect(at("badaddr")).toMatchObject({ address: true, title: "Check the address." });
    expect(at("busy").note).toMatch(/^Too many lookups, try again in a minute/);
    const vacant = run({ type: "toAddress" }, { type: "submitAddress", text: "1100 Congress Ave" }, { type: "reps", outcome: "ok", found: { ...found, members: [] } });
    expect(stripView(vacant).note).toMatch(/^Floor found Texas's 37th District, but no one holds its seats/);
  });
});

describe("places and seats", () => {
  it("labels districts as the mock does", () => {
    expect(districtLabel(austin.district)).toBe("Texas's 37th District");
    expect(districtLabel(cheyenne.district)).toBe("Wyoming's at-large district");
    expect(districtLabel(dc.district)).toBe("District of Columbia");
    expect(districtLabel({ state: "NY", district: 8 })).toBe("New York's 8th District");
  });

  it("ordinals", () => {
    expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 52].map(ordinal)).toEqual(["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "52nd"]);
  });

  it("finds delegates: D.C.'s one member is, Wyoming's at-large rep and senators are not", () => {
    expect(dc.members).toHaveLength(1);
    expect(isDelegate(dc.members[0]!)).toBe(true);
    expect(cheyenne.members.map(isDelegate)).toEqual([false, false, false]);
    expect(austin.members.map(isDelegate)).toEqual([false, false, false]);
    expect(oneMemberNote(austin.members[0]!)).toBe("");
  });

  it("writes seats short for chips and long for the card", () => {
    expect(austin.members.map(seatShort)).toEqual(["House · TX-37", "Senate · TX", "Senate · TX"]);
    expect(seatShort(cheyenne.members[0]!)).toBe("House · WY-AL");
    expect(seatShort(dc.members[0]!)).toBe("Delegate · DC");
    expect(seatLong(austin.members[0]!)).toBe("House · Texas 37th · Democrat");
    expect(seatLong(austin.members[1]!)).toBe("Senate · Texas · Republican");
    expect(seatLong(cheyenne.members[0]!)).toBe("House · Wyoming at-large · Republican");
    expect(seatLong(dc.members[0]!)).toBe("Delegate · District of Columbia · Democrat");
  });

  it("portraits come from the unitedstates.github.io host", () => {
    expect(portraitUrl("D000399")).toBe("https://unitedstates.github.io/images/congress/225x275/D000399.jpg");
  });
});

describe("records → scouting card", () => {
  it("Doggett: loyalty, grid counts and winning side", () => {
    // Expected values counted from the fixture by hand (python, not this module).
    const sc = scoutFrom(austin.members[0]!, loyalty("D000399"), votes("D000399"));
    expect(sc.unity).toBe(96.9);
    expect(sc.withPartySub).toBe("1,782 of 1,839");
    expect(sc.cross).toBe(57);
    expect(sc.grid).toHaveLength(40);
    expect(gridCounts(sc.grid)).toEqual({ Y: 19, N: 19, P: 0, M: 2, C: 0 });
    expect(sc.played).toBe(38);
    expect(sc.playedSub).toBe("38 of 40 · 2 missed");
    expect(sc.of).toBe(38);
    expect(sc.won).toBe(19);
    expect(sc.delegate).toBe("");
    expect(sc.latest).toBe("NAY · H.R. 1013 · Passage · Passed · Nov 11");
    expect(gridLabel(sc.grid)).toBe("Last 40 calls, oldest first: 19 yea, 19 nay, 0 present, 2 missed.");
  });

  it("the grid runs oldest first, as the sample's does", () => {
    const g = gridRows(votes("D000399"));
    expect(g[0]).toEqual([282, "Jul 23", "H.Con.Res. 89", "Resolution", "Y", g[0]![5], g[0]![6], g[0]![7]]);
    expect(g[39]![0]).toBe(321);
  });

  it("Cornyn: a missed latest vote, dated on Eastern time", () => {
    const sc = scoutFrom(austin.members[1]!, loyalty("C001056"), votes("C001056"));
    expect(sc.unity).toBe(96.3);
    expect(gridCounts(sc.grid)).toEqual({ Y: 27, N: 9, P: 0, M: 4, C: 0 });
    expect(sc.of).toBe(36);
    expect(sc.won).toBe(31);
    // 2026-11-11T00:37Z is 7:37 p.m. on Nov 10 in Washington.
    expect(sc.latest).toBe("MISSED · H.R. 2347 · Motion to Proceed · Motion to Proceed Agreed to · Nov 10");
  });

  it("Norton: the delegate note is counted from her votes, not asserted", () => {
    const sc = scoutFrom(dc.members[0]!, loyalty("N000147"), votes("N000147"));
    expect(sc.seat).toBe("Delegate · District of Columbia · Democrat");
    expect(sc.unity).toBe(97.9);
    expect(sc.cross).toBe(13);
    expect(gridCounts(sc.grid)).toEqual({ Y: 4, N: 36, P: 0, M: 0, C: 0 });
    expect(sc.delegate).toBe(
      "D.C. has one delegate to the House and no senators. A delegate can't vote to pass a bill, so every one of Norton's last 40 recorded votes is on an amendment — the latest on Jul 22.",
    );
  });

  it("a delegate note says how many when not all are amendments", () => {
    const v = votes("N000147");
    const mixed = [{ ...v[0]!, vote: { ...v[0]!.vote, question: "On Motion to Adjourn" } }, ...v.slice(1)];
    expect(scoutFrom(dc.members[0]!, loyalty("N000147"), mixed).delegate).toContain("39 of Norton's last 40 recorded votes are on amendments");
  });

  it("maps every API position, including a Speaker-election candidate vote", () => {
    const v = votes("D000399")[0]!;
    const pos = (position: ApiMemberVote["position"]) => gridRows([{ ...v, position }])[0]![4];
    expect(["yea", "nay", "present", "not_voting", "candidate"].map((p) => pos(p as ApiMemberVote["position"]))).toEqual(["Y", "N", "P", "M", "C"]);
    expect(latestLine({ ...v, position: "candidate", choice: "Jeffries", measure: null, vote: { ...v.vote, question: "Election of the Speaker", result: "Johnson" } })).toBe(
      "VOTED JEFFRIES · Procedural · Speaker election · Johnson · Nov 11",
    );
  });

  it("no counted party votes yet shows no percentage rather than 0%", () => {
    expect(scoutFrom(austin.members[0]!, { votes: 0, withParty: 0, againstParty: 0 }, []).unity).toBeNull();
  });

  it("an independent has no party bloc: dashes, not zeros", () => {
    // Real: /v1/reps for Burlington, VT, and Sanders' /v1/members/S000033 (partyLoyalty all zeros).
    const vermont: ApiReps = fixture("reps-vermont.json");
    const sanders = vermont.members.find((m) => m.bioguideId === "S000033")!;
    expect(loyalty("S000033")).toEqual({ votes: 0, withParty: 0, againstParty: 0 });
    const sc = scoutFrom(sanders, loyalty("S000033"), votes("S000033"));
    expect(sc.unity).toBeNull();
    // His own record still counts: 10 yea, 29 nay, 1 missed in the last 40.
    expect(gridCounts(sc.grid)).toEqual({ Y: 10, N: 29, P: 0, M: 1, C: 0 });
    expect(sc.played).toBe(39);
    expect(sc.cross).toBeNull();
    expect(sc.withPartySub).toBe("—");
    expect(sc.note).toMatch(/^No party bloc to measure against/);
    expect(sc.seat).toBe("Senate · Vermont · Independent");
  });

  it("a Speaker ballot counts as showing up but has no winning side", () => {
    const v = votes("D000399");
    const ballot = { ...v[0]!, position: "candidate" as const, choice: "Jeffries", vote: { ...v[0]!.vote, kind: "election" as const, result: "Johnson" } };
    const sc = scoutFrom(austin.members[0]!, loyalty("D000399"), [ballot, ...v.slice(1)]);
    // Doggett's newest vote was a nay on a bill that passed (a loss); swapping it for a ballot
    // keeps him at 38 shown up (the ballot replaces a cast vote), takes one call out of `of`, and
    // leaves `won` alone.
    expect(gridCounts(sc.grid)).toEqual({ Y: 19, N: 18, P: 0, M: 2, C: 1 });
    expect(sc.played).toBe(38);
    expect(sc.of).toBe(37);
    expect(sc.won).toBe(19);
  });

  it("a vote with an unknown position fails that member, loudly", () => {
    const v = votes("D000399");
    const bad = [{ ...v[0]!, position: "abstain" as unknown as ApiMemberVote["position"] }, ...v.slice(1)];
    expect(() => scoutFrom(austin.members[0]!, loyalty("D000399"), bad)).toThrow(/unknown vote position/);
    expect(() => scoutFrom(austin.members[0]!, loyalty("D000399"), [{ ...v[0]!, vote: { ...v[0]!.vote, totals: undefined as never } }])).toThrow();
    expect(() => posLetter("toString" as ApiMemberVote["position"])).toThrow();
  });

  it("Senate results that are truncated or unfamiliar are left out of winning side", () => {
    const odd = votes("D000399").map((x) => ({ ...x, vote: { ...x.vote, result: "Motion to Discharge Re" } }));
    const sc = scoutFrom(austin.members[0]!, loyalty("D000399"), odd);
    expect([sc.won, sc.of, sc.played]).toEqual([0, 0, 38]);
    const senate = votes("C001056").map((x) => ({ ...x, vote: { ...x.vote, result: "Veto Overridden" } }));
    // Cornyn: 27 yea and 9 nay; an override carried, so the 27 yeas are the winning side.
    expect(scoutFrom(austin.members[1]!, loyalty("C001056"), senate)).toMatchObject({ won: 27, of: 36 });
  });

  it("shortens the clerks' questions", () => {
    expect(shortQuestion("On Motion to Suspend the Rules and Pass, as Amended")).toBe("Suspension");
    expect(shortQuestion("On the Cloture Motion")).toBe("Cloture");
    expect(shortQuestion("On the Nomination")).toBe("Nomination");
    expect(shortQuestion("On Ordering the Previous Question")).toBe("Previous question");
    expect(shortQuestion("On Something New")).toBe("Something New");
    expect(shortDate(null)).toBe("");
  });
});

describe("remembering a district", () => {
  const coords = /30\.27|97\.74|lat|lng|address|Congress Ave|78701/i;

  it("stores the district, its Congress and members, never the point or the address", () => {
    const raw = serializeFound(found);
    expect(raw).not.toMatch(coords);
    expect(STORE_KEY).not.toMatch(coords);
    expect(found.congress).toBe(119);
    expect(parseFound(raw, 119)).toEqual(found);
  });

  it("drops a district saved for an older Congress", () => {
    expect(parseFound(serializeFound(found), 120)).toBeNull();
    expect(parseFound(JSON.stringify({ label: "x", members: JSON.parse(serializeFound(found)).members }), 119)).toBeNull();
  });

  it("knows which Congress is sitting: the 120th from 2027-01-03 (lesson 4)", () => {
    expect(congressOn(new Date("2026-11-12T12:00:00Z"))).toBe(119);
    expect(congressOn(new Date("2025-01-03T18:00:00Z"))).toBe(119);
    expect(congressOn(new Date("2027-01-02T12:00:00Z"))).toBe(119);
    expect(congressOn(new Date("2027-01-03T18:00:00Z"))).toBe(120);
    expect(congressOn(new Date("2029-02-01T00:00:00Z"))).toBe(121);
  });

  it("requires an integer district, or null for a senator", () => {
    const member = (district: unknown) =>
      JSON.stringify({ label: "x", congress: 119, members: [{ bioguideId: "D000399", firstName: "a", lastName: "b", party: "D", state: "TX", district, chamber: "house" }] });
    expect(parseFound(member(37), 119)).not.toBeNull();
    expect(parseFound(member(null), 119)).not.toBeNull();
    expect(parseFound(member(3.5), 119)).toBeNull();
    expect(parseFound(member(-1), 119)).toBeNull();
    expect(parseFound(member("37"), 119)).toBeNull();
  });

  it("looks state and party names up as own keys only", () => {
    expect(stateName("toString")).toBe("toString");
    expect(stateName("__proto__")).toBe("__proto__");
    expect(partyName("constructor")).toBe("constructor");
    expect(stateName("VT")).toBe("Vermont");
    expect(partyName("I")).toBe("Independent");
  });

  it("drops anything extra a response carries, such as county", () => {
    const withExtra = { ...found, members: found.members.map((m) => ({ ...m, lat: 30.2747, address: "1100 Congress Ave" })) };
    const raw = serializeFound(withExtra);
    expect(raw).not.toMatch(coords);
    expect(raw).not.toContain("48453");
  });

  it("rejects corrupt or foreign values", () => {
    expect(parseFound(null, 119)).toBeNull();
    expect(parseFound("{", 119)).toBeNull();
    expect(parseFound('{"label":"x","congress":119,"members":[]}', 119)).toBeNull();
    expect(parseFound('{"label":"x","congress":119,"members":[{"bioguideId":"<img>","firstName":"a","lastName":"b","party":"D","state":"TX","district":1,"chamber":"house"}]}', 119)).toBeNull();
    expect(parseFound(serializeFound(foundFrom(dc)), 119)?.members[0]?.bioguideId).toBe("N000147");
  });
});

describe("campaign money (real /funding responses, captured 2026-11-13)", () => {
  const money = (id: string): ApiMemberFunding => fixture("funding-" + id + ".json");

  it("asks for the ten biggest PAC checks", () => {
    expect(fundingUrl("https://x.test", "C001098")).toBe("https://x.test/v1/members/C001098/funding?committees=10");
  });

  it("matches the landing page's Jeffries figures to the dollar", () => {
    const v = fundingFrom(money("J000294").funding!);
    expect(v).toMatchObject({
      period: "2026 campaign · Jan 2025 – Oct 14, 2026",
      cashAsOf: "as of Oct 14, 2026",
      pac: 2765400,
    });
    expect(Math.round(v.total)).toBe(17893352);
    expect(Math.round(v.small)).toBe(8147893);
    expect(v.small + v.itemized + v.pac + v.other).toBeCloseTo(v.total, 2);
  });

  it("covers a senator's whole campaign, and dates the PAC list by its own FEC cycle", () => {
    const v = fundingFrom(money("C001098").funding!);
    expect(v.period).toBe("2030 campaign · Jan 2025 – Sep 30, 2026");
    expect(v.pacsNote.startsWith("Each PAC's own checks, from its 2025–26 filings.")).toBe(true);
    expect(v.pacs).toHaveLength(10);
    expect(v.pacs[0]).toEqual({ name: "Motorola Solutions, Inc. PAC", kind: "Company", amount: 10000 });
  });

  it("every member's parts add up to what they raised", () => {
    for (const id of ["J000294", "D000399", "C001056", "C001098"]) {
      const v = fundingFrom(money(id).funding!);
      expect(v.small + v.itemized + v.pac + v.other, id).toBeCloseTo(v.total, 2);
      expect(v.pacs.every((p) => p.amount > 0), id).toBe(true);
    }
  });

  it("says why there is nothing for an appointed senator with no campaign", () => {
    const body = money("A000383");
    expect(body.funding).toBeNull();
    expect(noFundingCopy(body.member)).toEqual({
      title: "No campaign filings yet",
      body: expect.stringContaining("Alan Armstrong has no totals at the FEC for a current campaign"),
    });
  });

  it("draws a negative remainder as 0 in the bar and the legend, and says why", () => {
    const f = { ...money("J000294").funding!, receipts: 1_000_000, smallDollar: 500_000, itemized: 400_000, pac: 112_000, party: 0, other: -12_000 };
    const v = fundingFrom(f);
    expect(v.other).toBe(0);
    expect(v.shareBase).toBe(1_012_000);
    expect(v.adjustNote).toContain("−$12K");
    expect(v.adjustNote).toContain("includes refunds/adjustments");
    // A real campaign with a positive remainder: no note, and the shares are of what it raised.
    const j = fundingFrom(money("J000294").funding!);
    expect(j.adjustNote).toBeNull();
    expect(j.shareBase).toBeCloseTo(j.total, 2);
  });

  it("lists nobody but committees", () => {
    for (const id of ["J000294", "D000399", "C001056", "C001098"]) {
      for (const p of fundingFrom(money(id).funding!).pacs) expect(Object.keys(p).sort()).toEqual(["amount", "kind", "name"]);
    }
  });
});

describe("committee names", () => {
  it.each([
    ["MOTOROLA SOLUTIONS, INC. POLITICAL ACTION COMMITTEE", "Motorola Solutions, Inc. PAC"],
    ["EXXON MOBIL CORPORATION POLITICAL ACTION COMMITTEE (EXXONMOBIL PAC)", "Exxon Mobil Corporation PAC"],
    ["AMERICAN FEDERATION OF STATE COUNTY & MUNICIPAL EMPLOYEES  P E O P L E", "American Federation of State County & Municipal Employees PEOPLE"],
    ["AMERICAN FEDERATION OF TEACHERS, AFL-CIO COMMITTEE ON POLITICAL EDUCATION", "American Federation of Teachers, AFL-CIO Committee on Political Education"],
    ["SOUTHERN GLAZER'S WINE AND SPIRITS PAC", "Southern Glazer's Wine and Spirits PAC"],
    ["TRANSPORTATION INTERMEDIARIES ASSOCIATION'S TIAPAC", "Transportation Intermediaries Association's TIAPAC"],
    ["L3HARRIS TECHNOLOGIES, INC. PAC", "L3HARRIS Technologies, Inc. PAC"],
    ["THE AMERICAN OCCUPATIONAL THERAPY ASSOCIATION, INC. POLITICAL ACTION COMMITTEE (AOTPAC)", "The American Occupational Therapy Association, Inc. PAC"],
    ["PERATON CORP. POLITICAL ACTION COMMITTEE (A.K.A. 'PERATON PAC')", "Peraton Corp. PAC"],
    // A capital after a leading O' or D', and Y as a vowel in a word of three letters or more.
    ["FRIENDS OF JOHN O'BRIEN", "Friends of John O'Brien"],
    ["D'AMATO FOR SENATE", "D'Amato for Senate"],
    ["LYNN FOR CONGRESS", "Lynn for Congress"],
  ])("%s", (raw, want) => {
    expect(committeeName(raw)).toBe(want);
  });
});

describe("dates", () => {
  it("reads FEC dates without sliding a day west of UTC", () => {
    expect(coverageRange("2021-01-01", "2026-10-14")).toBe("Jan 2021 – Oct 14, 2026");
    expect(coverageRange(null, "2026-09-30")).toBe("Sep 30, 2026");
    expect(cycleYears(2026)).toBe("2025–26");
  });
});
