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
    else c[p.position]++;
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
