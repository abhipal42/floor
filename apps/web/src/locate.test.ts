import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  INITIAL,
  PRIVACY,
  STORE_KEY,
  addressOk,
  districtLabel,
  foundFrom,
  gridCounts,
  gridLabel,
  gridRows,
  isDelegate,
  isSample,
  latestLine,
  nextState,
  oneMemberNote,
  ordinal,
  parseFound,
  portraitUrl,
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

  it("maps a 404 to outside the U.S. and everything else that isn't 2xx to an error", () => {
    expect(fixture("reps-london.json").error).toMatch(/isn't in a U.S. congressional district/);
    expect(repsOutcome(200)).toBe("ok");
    expect(repsOutcome(404)).toBe("outside");
    expect(repsOutcome(400)).toBe("error");
    expect(repsOutcome(429)).toBe("error");
    expect(repsOutcome(500)).toBe("error");
    // fetch threw: offline, or the browser refused a response with no CORS header (today's case).
    expect(repsOutcome(null)).toBe("error");
  });
});

describe("the state machine", () => {
  it("allow → loading → found → records ready", () => {
    expect(run({ type: "locate", supported: true }).step).toBe("asking");
    expect(run({ type: "locate", supported: true }, { type: "geoFix" }).step).toBe("loading");
    const s = run({ type: "locate", supported: true }, { type: "geoFix" }, { type: "reps", outcome: "ok", found });
    expect(s).toMatchObject({ step: "found", records: "loading", found: { label: "Texas's 37th District" } });
    expect(nextState(s, { type: "records", ok: true }).records).toBe("ready");
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
    const s = run({ type: "restore", found }, { type: "records", ok: false });
    expect(s).toMatchObject({ step: "found", records: "error", found });
    expect(nextState(s, { type: "retry" }).records).toBe("loading");
  });

  it("ignores late answers that no longer apply", () => {
    const idle = run({ type: "locate", supported: true }, { type: "reset" });
    expect(nextState(idle, { type: "reps", outcome: "ok", found })).toEqual(INITIAL);
    expect(nextState(idle, { type: "geoFix" })).toEqual(INITIAL);
    const ready = run({ type: "restore", found }, { type: "records", ok: true });
    expect(nextState(ready, { type: "records", ok: false }).records).toBe("ready");
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

  it("the privacy line is the mock's", () => {
    expect(PRIVACY).toBe("Your browser asks first. Floor rounds the point to about 11 m, finds the district, and keeps neither the point nor the address.");
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
    expect(sc.withParty).toBe(1782);
    expect(sc.partyVotes).toBe(1839);
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

  it("stores the district and members, never the point or the address", () => {
    const raw = serializeFound(found);
    expect(raw).not.toMatch(coords);
    expect(STORE_KEY).not.toMatch(coords);
    expect(parseFound(raw)).toEqual(found);
  });

  it("drops anything extra a response carries, such as county", () => {
    const withExtra = { ...found, members: found.members.map((m) => ({ ...m, lat: 30.2747, address: "1100 Congress Ave" })) };
    const raw = serializeFound(withExtra);
    expect(raw).not.toMatch(coords);
    expect(raw).not.toContain("48453");
  });

  it("rejects corrupt or foreign values", () => {
    expect(parseFound(null)).toBeNull();
    expect(parseFound("{")).toBeNull();
    expect(parseFound('{"label":"x","members":[]}')).toBeNull();
    expect(parseFound('{"label":"x","members":[{"bioguideId":"<img>","firstName":"a","lastName":"b","party":"D","state":"TX","district":1,"chamber":"house"}]}')).toBeNull();
    expect(parseFound(serializeFound(foundFrom(dc)))?.members[0]?.bioguideId).toBe("N000147");
  });
});
