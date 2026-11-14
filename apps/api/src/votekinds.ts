/*
 * What each kind of roll call is, in a line: the registry behind `explainer` on every vote and
 * `GET /v1/vote-kinds`. One table, read top to bottom; the first entry whose question, chamber and
 * condition all match wins, so a conditional entry sits above its general one.
 *
 * Every line is written by hand (not AI), neutral, and cites the rule or law it rests on. The rule
 * citations were checked against the 119th Congress House Rules and the Standing Rules of the Senate
 * on 2026-11-14 (docs/HANDOFF.md §3, the vote-kinds lesson).
 *
 * Questions match exactly, ignoring case and spacing: the roll call XML says "On Agreeing to the
 * Resolution", the House floor summary "On agreeing to the resolution". A question not in this table
 * gets no explainer (null), never the nearest guess. Every distinct question stored in production on
 * 2026-11-14 (118th and 119th Congress) is covered except these, left out on purpose:
 *
 * - "On the Motion" (Senate, 107 votes): the roll call does not say which motion. It is used for
 *   motions to waive the Budget Act, to concur, to instruct and more; any one line would be wrong for
 *   most of them.
 * - "On Retaining Division A", "On Retaining Divisions B and C" (House, one each): what is being
 *   kept depends on the special rule that divided the question; there is no general meaning.
 * - "On Closing Portions of the Conference" (House, once, 118th): a one-off procedural vote.
 */

export type VoteChamber = "house" | "senate";

/** Questions seen in production that have no line on purpose, with why (the list above). */
export const UNEXPLAINED: Record<string, string> = {
  "On the Motion": "The Senate roll call does not say which motion; no one line is right for most of them",
  "On Retaining Division A": "Its meaning depends on the special rule that divided the question",
  "On Retaining Divisions B and C": "Its meaning depends on the special rule that divided the question",
  "On Closing Portions of the Conference": "A one-off procedural vote (118th Congress)",
};

/** What a vote row offers the registry to decide on. */
export interface VoteFacts {
  question: string;
  chamber: VoteChamber;
  threshold: "majority" | "three_fifths_sworn" | "two_thirds";
  /** The measure is an H.Res. "providing for consideration of" a bill: a special rule. */
  onRule: boolean;
}

export interface VoteExplainer {
  kind: string;
  text: string;
  source: string;
}

type Condition = "rule" | "not_rule" | "majority_threshold";

export interface VoteKind extends VoteExplainer {
  /** The questions as roll calls print them. */
  questions: string[];
  /** Only this chamber's votes; null for both. */
  chamber: VoteChamber | null;
  /** Only when this holds; null for always. */
  when: Condition | null;
}

/** What each condition means, for `/v1/vote-kinds`. */
export const CONDITIONS: Record<Condition, string> = {
  rule: "The measure is a special rule: an H.Res. providing for the consideration of a bill",
  not_rule: "The measure is not a special rule",
  majority_threshold: "The vote needed a simple majority (cloture on a nomination)",
};

const HOUSE_DEBATE_MOTIONS = "House Rule XVI, clause 4";
const SENATE_MOTIONS = "Senate Rule XXII, paragraph 1";
const GLOSSARY = "Congress.gov legislative glossary";

const k = (
  kind: string,
  chamber: VoteChamber | null,
  questions: string[],
  text: string,
  source: string,
  when: Condition | null = null,
): VoteKind => ({ kind, chamber, when, questions, text, source });

export const VOTE_KINDS: VoteKind[] = [
  // Senate: cloture, confirmation, taking a bill up.
  k(
    "cloture",
    "senate",
    ["On the Cloture Motion"],
    "A vote to end debate so the Senate can move to a final vote. On nominations it needs only a simple " +
      "majority. Passing cloture isn't the final vote.",
    "Senate Rule XXII; precedents of Nov. 21, 2013 and Apr. 6, 2017",
    "majority_threshold",
  ),
  k(
    "cloture",
    "senate",
    ["On the Cloture Motion"],
    "A vote to end debate so the Senate can move to a final vote. On a bill it needs three-fifths of senators " +
      "sworn in, 60 when the Senate is full. Passing cloture doesn't pass the bill.",
    "Senate Rule XXII, paragraph 2",
  ),
  k(
    "cloture_motion_to_proceed",
    "senate",
    ["On Cloture on the Motion to Proceed"],
    "A vote to end debate on whether to take up a bill. It needs three-fifths of senators sworn in, 60 when " +
      "the Senate is full. Passing it lets the Senate start on the bill, not pass it.",
    "Senate Rule XXII, paragraph 2",
  ),
  k("motion_to_proceed", "senate", ["On the Motion to Proceed"], "Senate: whether to start debating a bill at all.", "Senate Rule VIII, paragraph 2"),
  k(
    "nomination",
    "senate",
    ["On the Nomination"],
    "The confirmation vote. A simple majority.",
    "U.S. Constitution, Art. II, Sec. 2; Senate Rule XXXI",
  ),
  k(
    "treaty",
    "senate",
    ["On the Resolution of Ratification"],
    "The vote to approve a treaty. It needs two-thirds of senators present.",
    "U.S. Constitution, Art. II, Sec. 2; Senate Rule XXX",
  ),

  // House: how a bill reaches the floor.
  k(
    "suspension",
    "house",
    [
      "On Motion to Suspend the Rules and Pass",
      "On Motion to Suspend the Rules and Pass, as Amended",
      "On Motion to Suspend the Rules and Agree",
      "On Motion to Suspend the Rules and Agree, as Amended",
      "On Motion to Suspend the Rules and Agree to the Resolution, as Amended",
      "On Motion to Suspend the Rules and Agree to the Conference Report",
      "On Motion to Suspend the Rules and Concur in the Senate Amendment",
      "On Motion to Suspend the Rules and Concur in the Senate Amendments",
      "On Motion to Suspend the Rules and Concur in Senate Adt to House Adt to Senate Adt",
    ],
    "House fast track for bills with broad support. Short debate, no amendments, needs two-thirds.",
    "House Rule XV, clause 1",
  ),
  k(
    "previous_question",
    "house",
    ["On Ordering the Previous Question"],
    "Ends debate on a rule and blocks changes to it. Usually splits by party. Not a vote on the bill.",
    "House Rule XIX, clause 1",
    "rule",
  ),
  k(
    "previous_question",
    "house",
    ["On Ordering the Previous Question"],
    "Ends debate on the resolution and blocks changes to it, bringing it straight to a vote. Not the vote on " +
      "the resolution itself.",
    "House Rule XIX, clause 1",
  ),
  k(
    "rule",
    "house",
    ["On Agreeing to the Resolution", "On Agreeing to the Resolution, as Amended"],
    "Sets the terms for debating a bill: time, amendments allowed. Not the bill itself.",
    "House Rule XIII, clause 6",
    "rule",
  ),
  k(
    "consideration",
    "house",
    ["On Consideration of the Resolution"],
    "Whether the House will take up the resolution at all.",
    "House Rule XVI, clause 3",
  ),

  // Final votes.
  k(
    "passage",
    null,
    ["On Passage", "On Passage of the Bill"],
    "The vote on the measure itself. Passing sends it to the other chamber, or to the President once both " +
      "have passed it. A simple majority.",
    "U.S. Constitution, Art. I, Sec. 7",
  ),
  k(
    "joint_resolution",
    "senate",
    ["On the Joint Resolution"],
    "The vote on the joint resolution itself. Like a bill, once both chambers pass it, it goes to the " +
      "President, unless it proposes a constitutional amendment.",
    "U.S. Constitution, Art. I, Sec. 7",
  ),
  k(
    "resolution",
    null,
    ["On Agreeing to the Resolution", "On Agreeing to the Resolution, as Amended", "On the Resolution"],
    "A vote to adopt a resolution. A resolution doesn't go to the President and doesn't become law.",
    GLOSSARY,
    "not_rule",
  ),
  k(
    "concurrent_resolution",
    "senate",
    ["On the Concurrent Resolution"],
    "A resolution both chambers adopt, such as a budget resolution. It doesn't go to the President and isn't law.",
    GLOSSARY,
  ),
  k(
    "veto_override",
    null,
    ["Passage, Objections of the President To The Contrary Notwithstanding", "On Overriding the Veto"],
    "A vote to override a veto. It needs two-thirds of those voting, in each chamber.",
    "U.S. Constitution, Art. I, Sec. 7, cl. 2",
  ),
  k(
    "conference_report",
    "senate",
    ["On the Conference Report"],
    "The vote on the final text House and Senate negotiators agreed on. It can't be amended.",
    "Senate Rule XXVIII",
  ),

  // Changing the text.
  k(
    "amendment",
    "house",
    ["On Agreeing to the Amendment", "On Agreeing to the Amendment, as Modified"],
    "A vote to change the measure's text. Adopting an amendment doesn't pass the measure.",
    "House Rule XVIII, clause 5",
  ),
  k(
    "amendment",
    "senate",
    ["On the Amendment"],
    "A vote to change the measure's text. Adopting an amendment doesn't pass the measure.",
    "Senate Rule XV",
  ),

  // Working out a final version with the other chamber.
  k(
    "concur",
    "house",
    ["On Motion to Concur in the Senate Amendment", "On Motion to Concur in the Senate Amendments"],
    "Whether the House accepts the Senate's changes, so both chambers have passed the same text.",
    "House Rule XXII, clause 4",
  ),
  k(
    "concur_with_amendment",
    "house",
    ["On Motion to Concur in the Senate Amendment with an Amendment"],
    "The House accepts the Senate's changes with a further change of its own, which goes back to the Senate.",
    "House Rule XXII, clause 4",
  ),
  k(
    "go_to_conference",
    "house",
    ["On Motion to go to Conference"],
    "Whether to negotiate a final version with the Senate in a conference committee.",
    "House Rule XXII, clause 1",
  ),
  k(
    "instruct_conferees",
    "house",
    ["On Motion to Instruct Conferees"],
    "Tells the House's negotiators what position to take with the Senate. The instruction isn't binding.",
    "House Rule XXII, clause 7",
  ),

  // Sending it elsewhere, setting it aside, taking it back.
  k(
    "recommit",
    "house",
    ["On Motion to Recommit"],
    "The minority's last motion before passage: send the bill back to committee. Rarely passes.",
    "House Rule XIX, clause 2",
  ),
  k(
    "commit",
    "house",
    ["On Motion to Commit", "On Motion to Commit with Instructions"],
    "The minority's motion to send the measure to a committee instead of voting on it now. Rarely passes.",
    "House Rule XIX, clause 2",
  ),
  k("recommit", "senate", ["On the Motion to Recommit"], "Whether to send the measure back to committee.", SENATE_MOTIONS),
  k(
    "refer",
    "house",
    ["On Motion to Refer"],
    "Whether to send the measure to a committee instead of acting on it now.",
    HOUSE_DEBATE_MOTIONS,
  ),
  k(
    "refer",
    "senate",
    ["On the Motion to Refer"],
    "Whether to send the measure to a committee instead of acting on it now.",
    SENATE_MOTIONS,
  ),
  k(
    "table",
    "house",
    ["On Motion to Table", "On Motion to Table the Motion to Discharge Committee"],
    "Sets the item aside, which in practice kills it.",
    HOUSE_DEBATE_MOTIONS,
  ),
  k("table", "senate", ["On the Motion to Table"], "Sets the item aside, which in practice kills it.", SENATE_MOTIONS),
  k(
    "table_reconsider",
    "house",
    ["Table Motion to Reconsider"],
    "Sets aside a motion to reconsider, which makes the vote just taken final.",
    "House Rule XIX, clause 3",
  ),
  k(
    "reconsider",
    "house",
    ["On Motion to Reconsider"],
    "Whether to vote again on a question already decided.",
    "House Rule XIX, clause 3",
  ),
  k("reconsider", "senate", ["On the Motion to Reconsider"], "Whether to vote again on a question already decided.", "Senate Rule XIII"),
  k(
    "discharge",
    "house",
    ["On Motion to Discharge"],
    "Takes a measure away from a committee that hasn't acted on it, so the House can vote on it. It comes up " +
      "once a majority of the House has signed a discharge petition.",
    "House Rule XV, clause 2",
  ),
  k(
    "discharge",
    "senate",
    ["On the Motion to Discharge"],
    "Whether to take a measure away from the committee holding it so the full Senate can act on it. These " +
      "votes come under laws that fast-track certain measures, such as war powers and arms sales resolutions.",
    "Expedited-procedure statutes, e.g. the War Powers Resolution (50 U.S.C. 1546a)",
  ),

  // Running the floor.
  k("adjourn", "house", ["On Motion to Adjourn"], "Whether to end the day's sitting now.", HOUSE_DEBATE_MOTIONS),
  k("adjourn", "senate", ["On the Motion to Adjourn"], "Whether to end the day's sitting now.", SENATE_MOTIONS),
  k(
    "quorum_call",
    "house",
    ["Call of the House", "Call by States"],
    "A quorum call: members record that they are present. Nothing is decided.",
    "House Rule XX, clauses 5-7; U.S. Constitution, Art. I, Sec. 5",
  ),
  k(
    "attendance",
    "senate",
    ["On the Motion for Attendance"],
    "Directs the Sergeant at Arms to ask absent senators to come to the chamber, so there is a quorum.",
    "Senate Rule VI, paragraph 4",
  ),
  k(
    "point_of_order",
    "senate",
    ["On the Point of Order"],
    "Whether the Senate upholds an objection that the pending business breaks its rules or a law that binds " +
      "it, such as the Budget Act.",
    "Senate Rule XX",
  ),
  k(
    "appeal",
    "senate",
    ["On the Decision of the Chair"],
    "Whether the presiding officer's ruling on the rules stands.",
    "Senate Rule XX, paragraph 1",
  ),
  k(
    "speaker_election",
    "house",
    ["Election of the Speaker"],
    "The House elects its Speaker by calling each member's name. Winning takes a majority of those who vote " +
      "for a person by name.",
    "U.S. Constitution, Art. I, Sec. 2, cl. 5",
  ),
];

/**
 * The H.Res. titles of special rules, which the Rules Committee writes to a formula: "Providing for
 * consideration of the bill (H.R. 5267) ...", "Providing for further consideration of ...", "Relating
 * to consideration of the Senate amendment ...", "Providing for disposition of the Senate amendment
 * ...". Of 300 House resolutions voted on in the 118th and 119th Congress, 245 match. Others that were
 * also reported by the Rules Committee, such as the opening-day rules package or a one-line waiver of
 * Rule XIII, do not, and get the general resolution line: they do not set the terms for debating a bill.
 */
export const RULE_TITLE =
  /^(providing (for )?(the )?(further )?consideration|relating to (the )?consideration|providing for (the )?disposition)/i;

/** `RULE_TITLE` as a Postgres string literal, for `~*`. It holds no quote. */
export const RULE_TITLE_SQL = `'${RULE_TITLE.source}'`;

const norm = (q: string) => q.toLowerCase().replace(/\s+/g, " ").trim();

const byQuestion = new Map<string, VoteKind[]>();
for (const entry of VOTE_KINDS) {
  for (const q of entry.questions) byQuestion.set(norm(q), [...(byQuestion.get(norm(q)) ?? []), entry]);
}

const holds = (when: Condition | null, v: VoteFacts) =>
  when === null ||
  (when === "rule" && v.onRule) ||
  (when === "not_rule" && !v.onRule) ||
  (when === "majority_threshold" && v.threshold === "majority");

/** The explainer for a vote, or null when its question is not one we have written a line for. */
export function explainVote(v: VoteFacts): VoteExplainer | null {
  const entry = (byQuestion.get(norm(v.question)) ?? []).find(
    (e) => (e.chamber === null || e.chamber === v.chamber) && holds(e.when, v),
  );
  return entry ? { kind: entry.kind, text: entry.text, source: entry.source } : null;
}
