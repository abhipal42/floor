import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { normalizePosition, parseHouseRollCall, parseSenateRollCall, type RollCall } from "./rollcall.js";

const fixture = (name: string) =>
  readFileSync(join(dirname(fileURLToPath(import.meta.url)), "../fixtures", name), "utf8");

function countPositions(rc: RollCall) {
  const c = { yea: 0, nay: 0, present: 0, notVoting: 0 };
  for (const p of rc.positions) {
    if (p.position === "not_voting") c.notVoting++;
    else if (p.position !== "candidate") c[p.position]++;
  }
  return c;
}

describe("parseHouseRollCall (real Clerk file: 2025 roll 100)", () => {
  const rc = parseHouseRollCall(fixture("house-2025-roll100.xml"));

  it("reads vote metadata", () => {
    expect(rc).toMatchObject({
      chamber: "house",
      congress: 119,
      session: 1,
      rollNumber: 100,
      question: "On Motion to Concur in the Senate Amendment",
      result: "Passed",
      threshold: "majority",
      billRef: "H CON RES 14",
      occurredAtEastern: "2025-04-10T11:08",
    });
  });

  it("reads totals", () => {
    expect(rc.totals).toEqual({ yea: 216, nay: 214, present: 0, notVoting: 3 });
  });

  it("reads every member's position keyed by bioguide ID", () => {
    expect(rc.positions).toHaveLength(433);
    expect(rc.positions.find((p) => p.memberId === "A000370")).toEqual({
      memberId: "A000370",
      idType: "bioguide",
      party: "D",
      state: "NC",
      position: "nay",
    });
  });

  it("member positions add up to the official totals", () => {
    expect(countPositions(rc)).toEqual(rc.totals);
  });
});

describe("parseSenateRollCall (real LIS file: 119th, session 1, vote 100)", () => {
  const rc = parseSenateRollCall(fixture("senate-119-1-00100.xml"));

  it("reads vote metadata", () => {
    expect(rc).toMatchObject({
      chamber: "senate",
      congress: 119,
      session: 1,
      rollNumber: 100,
      question: "On Cloture on the Motion to Proceed",
      result: "Cloture on the Motion to Proceed Rejected",
      threshold: "three_fifths_sworn",
      billRef: "S. 9",
      occurredAtEastern: "2025-03-03T18:27",
    });
  });

  it("reads totals, counting absent senators as not voting", () => {
    expect(rc.totals).toEqual({ yea: 51, nay: 45, present: 0, notVoting: 4 });
  });

  it("reads every senator's position keyed by LIS ID", () => {
    expect(rc.positions).toHaveLength(100);
    expect(rc.positions.find((p) => p.memberId === "S428")).toEqual({
      memberId: "S428",
      idType: "lis",
      party: "D",
      state: "MD",
      position: "nay",
    });
  });

  it("member positions add up to the official totals", () => {
    expect(countPositions(rc)).toEqual(rc.totals);
  });
});

describe("parseHouseRollCall (real Speaker election: 2023 roll 2)", () => {
  const rc = parseHouseRollCall(fixture("house-2023-roll002.xml"));

  it("is recognized as an election with per-candidate totals", () => {
    expect(rc.kind).toBe("election");
    expect(rc.question).toBe("Election of the Speaker");
    expect(rc.candidates).toEqual([
      { name: "Jeffries", total: 212 },
      { name: "McCarthy", total: 203 },
      { name: "Biggs", total: 10 },
      { name: "Jordan", total: 6 },
      { name: "Banks", total: 1 },
      { name: "Zeldin", total: 1 },
      { name: "Donalds", total: 1 },
    ]);
    expect(rc.totals).toEqual({ yea: 0, nay: 0, present: 0, notVoting: 0 });
  });

  it("records each member's candidate", () => {
    expect(rc.positions).toHaveLength(434);
    expect(rc.positions.find((p) => p.memberId === "A000370")).toMatchObject({ position: "candidate", choice: "Jeffries" });
    expect(rc.positions.find((p) => p.memberId === "A000055")).toMatchObject({ position: "candidate", choice: "McCarthy" });
  });

  it("member choices add up to the candidate totals", () => {
    const tally = new Map<string, number>();
    for (const p of rc.positions) if (p.choice) tally.set(p.choice, (tally.get(p.choice) ?? 0) + 1);
    expect(Object.fromEntries(tally)).toEqual(Object.fromEntries(rc.candidates.map((c) => [c.name, c.total])));
  });

  it("marks ordinary questions as such", () => {
    expect(parseHouseRollCall(fixture("house-2025-roll100.xml")).kind).toBe("question");
    expect(parseHouseRollCall(fixture("house-2025-roll100.xml")).candidates).toEqual([]);
  });
});

describe("parseHouseRollCall (real Speaker election: 2025 roll 2)", () => {
  const xml = fixture("house-2025-roll002.xml");
  const rc = parseHouseRollCall(xml);
  // The same real ballot with its <totals-by-candidate> blocks cut out: what a file read as a yea/nay
  // question looks like, which is how `Unknown vote position: "Jeffries"` used to come about.
  const stripped = xml.replace(/<totals-by-candidate>[\s\S]*?<\/totals-by-candidate>\s*/g, "");

  it("reads a candidate with a state suffix as one candidate", () => {
    expect(rc.kind).toBe("election");
    expect(rc.result).toBe("Johnson (LA)");
    expect(rc.candidates).toEqual([
      { name: "Johnson (LA)", total: 218 },
      { name: "Jeffries", total: 215 },
      { name: "Emmer", total: 1 },
    ]);
    expect(rc.positions.find((p) => p.memberId === "A000370")).toMatchObject({ position: "candidate", choice: "Jeffries" });
  });

  it("still reads the ballot as an election when the file omits the per-candidate totals", () => {
    expect(stripped).not.toContain("totals-by-candidate");
    const fallback = parseHouseRollCall(stripped);
    expect(fallback.kind).toBe("election");
    expect(fallback.candidates).toEqual(rc.candidates);
    expect(fallback.positions).toEqual(rc.positions);
    expect(fallback.totals).toEqual(rc.totals);
  });

  it("still refuses a candidate name on a question that is not a Speaker election", () => {
    const mislabelled = stripped.replace("<vote-question>Election of the Speaker", "<vote-question>On Passage");
    // Adams (A000370) is the first recorded vote, so this is the exact error production recorded.
    expect(() => parseHouseRollCall(mislabelled)).toThrow('Unknown vote position: "Jeffries"');
  });
});

describe("parseHouseRollCall (questions that only look like Speaker elections)", () => {
  // A real yea/nay file (2025 roll 100) with its question rewritten.
  const yeaNay = fixture("house-2025-roll100.xml");
  const titled = (question: string) =>
    yeaNay.replace(
      "<vote-question>On Motion to Concur in the Senate Amendment</vote-question>",
      `<vote-question>${question}</vote-question>`,
    );

  it("reads a Speaker pro tempore election as the yea/nay question it is", () => {
    const rc = parseHouseRollCall(titled("Election of the Speaker pro tempore"));
    expect(rc.kind).toBe("question");
    expect(rc.totals).toEqual(parseHouseRollCall(yeaNay).totals);
  });

  it("refuses a file titled a Speaker election whose every answer is yea or nay", () => {
    expect(() => parseHouseRollCall(titled("Election of the Speaker"))).toThrow(
      "House roll call 100 is titled a Speaker election but records yea/nay answers",
    );
  });

  it("says which roll call has no totals instead of failing on a missing property", () => {
    const noTotals = yeaNay.replace(/<vote-totals>[\s\S]*?<\/vote-totals>/, "");
    expect(() => parseHouseRollCall(noTotals)).toThrow("House roll call 100 has no vote totals");
  });
});

describe("normalizePosition", () => {
  it("maps chamber vocabularies to one set", () => {
    expect(["Yea", "Aye", "Guilty"].map(normalizePosition)).toEqual(["yea", "yea", "yea"]);
    expect(["Nay", "No", "Not Guilty"].map(normalizePosition)).toEqual(["nay", "nay", "nay"]);
    expect(normalizePosition("Not Voting")).toBe("not_voting");
  });

  it("rejects unknown values instead of guessing", () => {
    expect(() => normalizePosition("Paired")).toThrow(/Unknown vote position/);
  });

  it("rejects documents from the wrong chamber", () => {
    expect(() => parseHouseRollCall(fixture("senate-119-1-00100.xml"))).toThrow();
    expect(() => parseSenateRollCall(fixture("house-2025-roll100.xml"))).toThrow();
  });
});
