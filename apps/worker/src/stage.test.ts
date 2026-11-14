import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { toActionRows } from "./bills.js";
import { carried, deriveStage, isPassageVote, listStage, type StageInput } from "./stage.js";

const here = dirname(fileURLToPath(import.meta.url));
// Real /actions responses (2026-11-13), trimmed to the fields the worker reads.
const actions = (id: string) =>
  toActionRows(JSON.parse(readFileSync(join(here, "../fixtures/congress/stage", `${id}-actions.json`), "utf8")) as Record<string, unknown>);

const stage = (id: string, extra: Partial<StageInput> = {}) => {
  const [, type] = id.split("-");
  return deriveStage({
    type: type!,
    originChamber: type!.startsWith("s") ? "senate" : "house",
    actions: actions(id),
    votes: [],
    ...extra,
  });
};

describe("deriveStage on real bills", () => {
  it.each([
    ["119-s-2", "law"], // Secure America Act, Public Law 119-98
    ["119-hr-997", "law"], // Public Law 119-139, signed 2026-11-10
    ["119-hr-131", "vetoed"], // vetoed 2025-12-29; the override failed in the House
    ["119-hr-2493", "passed_house"], // passed under suspension, waiting on the Senate
    ["119-s-2296", "passed_senate"], // NDAA, passed the Senate with 60
    ["119-hconres-108", "failed"], // "Failed of passage/not agreed to in House"
    ["119-hres-5", "adopted"], // the House rules package: a simple resolution, agreed to
    ["119-hconres-14", "adopted"], // the budget: Senate amended it, House agreed to the amendment
    ["119-sjres-197", "introduced"], // discharged by petition, no passage
    ["119-hr-9238", "introduced"], // failed under suspension, 198–218: not a verdict on the bill
    ["119-s-2503", "passed_senate"], // passed the Senate, then failed under suspension in the House, 264–133
  ])("%s is %s", (id, expected) => {
    expect(stage(id)).toBe(expected);
  });

  it("a bill presented but not yet signed is with the President (H.R. 997 before 2026-11-10)", () => {
    const before = actions("119-hr-997").filter((a) => a.acted_on < "2026-11-10");
    expect(deriveStage({ type: "hr", originChamber: "house", actions: before, votes: [] })).toBe("to_president");
  });

  it("a failed motion to proceed does not move a bill (S.J.Res. 197, 48–51)", () => {
    expect(
      stage("119-sjres-197", {
        votes: [{ chamber: "senate", question: "On the Motion to Proceed", result: "Motion to Proceed Rejected" }],
      }),
    ).toBe("introduced");
  });

  it("the chamber's passage roll call settles it before the marker lands (H.R. 1013)", () => {
    // On 2026-11-13 the stored actions for H.R. 1013 still lacked "Passed/agreed to in House", two
    // days after the House passed it 295–128 (roll 321). The marker has since landed; remove it to
    // reproduce what the database held.
    const lagging = actions("119-hr-1013").filter((a) => !a.text.startsWith("Passed/agreed to in House"));
    expect(deriveStage({ type: "hr", originChamber: "house", actions: lagging, votes: [] })).toBe("introduced");
    expect(
      deriveStage({
        type: "hr",
        originChamber: "house",
        actions: lagging,
        votes: [{ chamber: "house", question: "On Passage", result: "Passed" }],
      }),
    ).toBe("passed_house");
    expect(stage("119-hr-1013")).toBe("passed_house");
  });

  it("a bill that failed under suspension and then passed is not failed", () => {
    const texts = [
      "Failed of passage/not agreed to in House: On motion to suspend the rules and pass the bill Failed by the Yeas and Nays",
      "Passed/agreed to in House: On passage Passed by the Yeas and Nays",
      "Introduced in House",
    ];
    expect(deriveStage({ type: "hr", originChamber: "house", actions: texts.map((text) => ({ text })), votes: [] })).toBe(
      "passed_house",
    );
  });

  it("a failed suspension roll call does not settle a bill either (H.R. 9238, roll 221)", () => {
    expect(
      stage("119-hr-9238", {
        votes: [{ chamber: "house", question: "On Motion to Suspend the Rules and Pass", result: "Failed" }],
      }),
    ).toBe("introduced");
  });

  it("a bill voted down on passage is still failed", () => {
    const texts = ["Failed of passage/not agreed to in House: On passage Failed by the Yeas and Nays: 200 - 220.", "Introduced in House"];
    expect(deriveStage({ type: "hr", originChamber: "house", actions: texts.map((text) => ({ text })), votes: [] })).toBe("failed");
  });

  it("agreeing to the other chamber's amendment with an amendment is not adoption (H.Con.Res. 14, altered)", () => {
    // The real resolution ended when the House agreed to the Senate amendment. Had it agreed with an
    // amendment of its own, the Senate would have had to act again.
    const sentBack = actions("119-hconres-14").map((a) =>
      a.text.startsWith("Resolving differences")
        ? { ...a, text: a.text.replace("agree to the Senate amendment", "agree to the Senate amendment with an amendment") }
        : a,
    );
    expect(deriveStage({ type: "hconres", originChamber: "house", actions: sentBack, votes: [] })).toBe("passed_both");
  });

  it("a concurrent resolution amended by the second chamber is not adopted until the first agrees", () => {
    const amended = actions("119-hconres-14").filter((a) => !a.text.startsWith("Resolving differences"));
    expect(deriveStage({ type: "hconres", originChamber: "house", actions: amended, votes: [] })).toBe("passed_both");
  });
});

describe("roll call readings", () => {
  it.each([
    ["Passed", true],
    ["Agreed to", true],
    ["Motion to Proceed Agreed to", true],
    ["Joint Resolution Passed", true],
    ["Failed", false],
    ["Concurrent Resolution Rejected", false],
    ["Joint Resolution Defeated", false],
    ["Veto Sustained", false],
    ["Decision of Chair Not Sustained", false],
    [null, false],
  ])("carried(%s) is %s", (result, expected) => {
    expect(carried(result)).toBe(expected);
  });

  it.each([
    ["On Passage", "Passed", true],
    ["On Motion to Suspend the Rules and Pass, as Amended", "Passed", true],
    ["On Motion to Suspend the Rules and Agree", "Passed", true],
    ["On the Joint Resolution", "Joint Resolution Passed", true],
    ["On Passage of the Bill", "Bill Passed", true],
    ["On Agreeing to the Resolution", "Agreed to", true],
    ["On Motion to Recommit", "Failed", false],
    ["On the Cloture Motion", "Cloture Motion Agreed to", false],
    ["On the Motion to Proceed", "Motion to Proceed Agreed to", false],
    ["Passage, Objections of the President To The Contrary Notwithstanding", "Passed", false],
    ["On Passage", "Failed", false],
    ["On Motion to Table the Motion to Concur in the Senate Amendment", "Motion to Table Agreed to", false],
    ["On Motion to Refer", "Agreed to", false],
    ["On Motion to Reconsider the Vote on Passage", "Agreed to", false],
    ["On Motion to Concur in the Senate Amendment", "Agreed to", true],
  ])("%s / %s is passage: %s", (question, result, expected) => {
    expect(isPassageVote({ question, result })).toBe(expected);
  });
});

describe("listStage", () => {
  it.each([
    ["s", "Became Public Law No: 119-98.", "law"],
    ["hr", "Became Private Law No: 119-1.", "law"],
    ["hr", "Passed Senate without amendment by Unanimous Consent.", null],
    ["hr", "Referred to the House Committee on Energy and Commerce.", null],
    ["hres", "Became Public Law No: 119-98.", null],
    ["hr", null, null],
  ])("%s with %s is %s", (type, text, expected) => {
    expect(listStage(type, text)).toBe(expected);
  });
});
