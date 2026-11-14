import { describe, expect, it } from "vitest";
import { RULE_TITLE, UNEXPLAINED, VOTE_KINDS, explainVote, type VoteChamber } from "./votekinds.js";

/**
 * Every distinct (chamber, question) stored in production on 2026-11-14, 118th and 119th Congress:
 * `select distinct chamber, question from votes`. Each must have a line or be named in UNEXPLAINED.
 */
const PRODUCTION: [VoteChamber, string][] = [
  ["house", "On Agreeing to the Amendment"],
  ["house", "On Passage"],
  ["house", "On Motion to Suspend the Rules and Pass, as Amended"],
  ["house", "On Agreeing to the Resolution"],
  ["house", "On Motion to Suspend the Rules and Pass"],
  ["house", "On Motion to Recommit"],
  ["house", "On Ordering the Previous Question"],
  ["house", "On Motion to Suspend the Rules and Agree"],
  ["house", "Election of the Speaker"],
  ["house", "On Motion to Table"],
  ["house", "On Agreeing to the Resolution, as Amended"],
  ["house", "On Motion to Adjourn"],
  ["house", "On Motion to Suspend the Rules and Agree, as Amended"],
  ["house", "On Motion to Refer"],
  ["house", "Passage, Objections of the President To The Contrary Notwithstanding"],
  ["house", "On Motion to Discharge"],
  ["house", "Call of the House"],
  ["house", "On Consideration of the Resolution"],
  ["house", "On Motion to Suspend the Rules and Concur in the Senate Amendment"],
  ["house", "On Motion to Commit"],
  ["house", "On Motion to Reconsider"],
  ["house", "On Motion to Concur in the Senate Amendment"],
  ["house", "On Motion to Concur in the Senate Amendments"],
  ["house", "On Motion to Suspend the Rules and Concur in the Senate Amendments"],
  ["house", "On Motion to Instruct Conferees"],
  ["house", "On Motion to Suspend the Rules and Agree to the Conference Report"],
  ["house", "On Retaining Division A"],
  ["house", "On Motion to go to Conference"],
  ["house", "On Motion to Suspend the Rules and Concur in Senate Adt to House Adt to Senate Adt"],
  ["house", "On Motion to Commit with Instructions"],
  ["house", "Call By States"],
  ["house", "On Closing Portions of the Conference"],
  ["house", "Table Motion to Reconsider"],
  ["house", "On Motion to Table the Motion to Discharge Committee"],
  ["house", "On Retaining Divisions B and C"],
  ["house", "On Motion to Suspend the Rules and Agree to the Resolution, as Amended"],
  ["house", "On Agreeing to the Amendment, as Modified"],
  ["house", "On Motion to Concur in the Senate Amendment with an Amendment"],
  ["house", "Call by States"],
  ["house", "On Motion to Suspend the Rules and Agree, As Amended"],
  ["senate", "On the Cloture Motion"],
  ["senate", "On the Nomination"],
  ["senate", "On the Amendment"],
  ["senate", "On the Motion to Proceed"],
  ["senate", "On the Motion"],
  ["senate", "On Cloture on the Motion to Proceed"],
  ["senate", "On the Joint Resolution"],
  ["senate", "On Passage of the Bill"],
  ["senate", "On the Motion to Table"],
  ["senate", "On the Motion to Discharge"],
  ["senate", "On the Resolution"],
  ["senate", "On the Motion to Recommit"],
  ["senate", "On the Point of Order"],
  ["senate", "On the Motion to Adjourn"],
  ["senate", "On the Concurrent Resolution"],
  ["senate", "On Overriding the Veto"],
  ["senate", "On the Decision of the Chair"],
  ["senate", "On the Motion to Reconsider"],
  ["senate", "On the Motion for Attendance"],
  ["senate", "On the Motion to Refer"],
  ["senate", "On the Conference Report"],
  ["senate", "On the Resolution of Ratification"],
];

const facts = (chamber: VoteChamber, question: string, more: { onRule?: boolean; threshold?: "majority" | "three_fifths_sworn" | "two_thirds" } = {}) => ({
  chamber,
  question,
  onRule: more.onRule ?? false,
  threshold: more.threshold ?? (chamber === "senate" && /cloture/i.test(question) ? "three_fifths_sworn" : "majority"),
});

describe("vote explainers", () => {
  it.each(PRODUCTION)("covers %s: %s, or names it as left out", (chamber, question) => {
    const line = explainVote(facts(chamber, question));
    if (question in UNEXPLAINED) expect(line).toBeNull();
    else expect(line, `${chamber}: ${question}`).not.toBeNull();
  });

  it("uses the approved lines", () => {
    expect(explainVote(facts("senate", "On the Cloture Motion"))).toEqual({
      kind: "cloture",
      text: "A vote to end debate so the Senate can move to a final vote. On a bill it needs three-fifths of senators sworn in, 60 when the Senate is full. Passing cloture doesn't pass the bill.",
      source: "Senate Rule XXII, paragraph 2",
    });
    expect(explainVote(facts("house", "On Motion to Suspend the Rules and Pass"))?.text).toBe(
      "House fast track for bills with broad support. Short debate, no amendments, needs two-thirds.",
    );
    expect(explainVote(facts("house", "On Ordering the Previous Question", { onRule: true }))?.text).toBe(
      "Ends debate on a rule and blocks changes to it. Usually splits by party. Not a vote on the bill.",
    );
    expect(explainVote(facts("house", "On Agreeing to the Resolution", { onRule: true }))?.text).toBe(
      "Sets the terms for debating a bill: time, amendments allowed. Not the bill itself.",
    );
    expect(explainVote(facts("house", "On Motion to Recommit"))?.text).toBe(
      "The minority's last motion before passage: send the bill back to committee. Rarely passes.",
    );
    expect(explainVote(facts("senate", "On the Motion to Proceed"))?.text).toBe("Senate: whether to start debating a bill at all.");
    expect(explainVote(facts("senate", "On the Nomination"))?.text).toBe("The confirmation vote. A simple majority.");
    expect(explainVote(facts("house", "On Motion to Table"))?.text).toBe("Sets the item aside, which in practice kills it.");
  });

  it("says cloture on a nomination needs only a majority", () => {
    expect(explainVote(facts("senate", "On the Cloture Motion", { threshold: "majority" }))?.text).toMatch(/only a simple majority/);
  });

  it("tells a rule from any other resolution", () => {
    expect(explainVote(facts("house", "On Agreeing to the Resolution", { onRule: true }))?.kind).toBe("rule");
    expect(explainVote(facts("house", "On Agreeing to the Resolution"))?.kind).toBe("resolution");
  });

  it("matches the floor summary's lower-case wording and stray spacing", () => {
    expect(explainVote(facts("house", "On agreeing to the  resolution ", { onRule: true }))?.kind).toBe("rule");
    expect(explainVote(facts("house", "On motion to refer"))?.kind).toBe("refer");
  });

  it("keeps a chamber's line to its chamber, and guesses nothing", () => {
    // "On the Motion to Proceed" is the Senate's wording; the House has no such question.
    expect(explainVote(facts("house", "On the Motion to Proceed"))).toBeNull();
    expect(explainVote(facts("house", "On Motion to Suspend the Rules and Pass the Bill With Flair"))).toBeNull();
  });

  it("reads special rules' titles, and not other resolutions'", () => {
    for (const t of [
      "Providing for consideration of the bill (H.R. 5267) to amend title 10",
      "Providing consideration of the bill (H.R. 7176) to repeal",
      "Providing for further consideration of the bill (H.R. 2670)",
      "Relating to consideration of the Senate amendment to the bill (H.R. 4366)",
      "Providing for disposition of the Senate amendment to the bill",
    ])
      expect(RULE_TITLE.test(t), t).toBe(true);
    for (const t of ["Condemning Iran's unprecedented drone and missile attack on Israel.", "Adopting the Rules of the House of Representatives for the One Hundred Nineteenth Congress"])
      expect(RULE_TITLE.test(t), t).toBe(false);
  });

  it("writes every line short, sourced, and without a guess at an outcome", () => {
    for (const k of VOTE_KINDS) {
      expect(k.text.length, k.kind).toBeLessThanOrEqual(220);
      expect(k.source.length, k.kind).toBeGreaterThan(0);
      expect(k.questions.length, k.kind).toBeGreaterThan(0);
    }
  });
});
