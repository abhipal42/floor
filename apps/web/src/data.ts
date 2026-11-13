// The landing page's one data snapshot. Every figure and claim the page shows comes from here,
// copied exactly from the design mock the owner locked on 2026-11-12, which was built from the
// sources each block names. Nothing here is computed from live data yet: when the site starts
// reading the API, these blocks are what it has to reproduce. `data.test.ts` checks the invariants
// (splits sum to totals, grids match their stats, segments sum to totals) that catch a mistyped number.

import type { ApiMember } from "./locate.js";
import type { Split, VotePos } from "./logic.js";

export interface Sourced {
  source: string;
  /** The date the figures in the block were current to (ISO date). */
  asOf: string;
}

/** Semantic colour names; each maps to a CSS custom property in styles.css. */
export type Tone = "yea" | "nay" | "ink" | "muted" | "accent";

export type MemberId =
  | "J000294"
  | "S000148"
  | "G000555"
  | "C001035"
  | "M001153"
  | "M001184"
  | "F000466"
  | "G000592"
  | "C001063"
  | "F000479";

/** Official portraits, by bioguide ID, served from public/img. */
export function portrait(id: MemberId): string {
  return "img/" + id + ".jpg";
}

/** The demo user's three members, in the order the page's member tabs show them. */
export const YOUR_THREE = ["J000294", "S000148", "G000555"] as const;
export type YourMember = (typeof YOUR_THREE)[number];

/**
 * The sample district, as `/v1/reps` returns it for Brooklyn (40.6782, -73.9442), in the page's
 * tab order. The "your members" strip shows it until someone finds their own.
 */
export const sampleReps: Sourced & { label: string; members: ApiMember[] } = {
  source: "Floor API /v1/reps (U.S. Census geocoder; members from Congress.gov)",
  asOf: "2026-11-12",
  label: "New York's 8th District",
  members: [
    { bioguideId: "J000294", firstName: "Hakeem", lastName: "Jeffries", party: "D", state: "NY", district: 8, chamber: "house" },
    { bioguideId: "S000148", firstName: "Chuck", lastName: "Schumer", party: "D", state: "NY", district: null, chamber: "senate" },
    { bioguideId: "G000555", firstName: "Kirsten", lastName: "Gillibrand", party: "D", state: "NY", district: null, chamber: "senate" },
  ],
};

const CLERKS = "Clerk of the House and Senate roll call votes";

// ---------------------------------------------------------------- hero

export interface HeroStat {
  /** A count-up animates from 0; a fixed stat is shown as is, in the yea colour. */
  kind: "count" | "fixed";
  value: number;
  label: string;
}

export const hero: Sourced & { stats: HeroStat[] } = {
  source: CLERKS + ", 118th and 119th Congresses",
  asOf: "2026-11-11",
  stats: [
    { kind: "count", value: 3532, label: "roll calls since Jan 2023" },
    { kind: "count", value: 995806, label: "member votes on the record" },
    { kind: "fixed", value: 0, label: "off the official count" },
  ],
};

// ---------------------------------------------------------------- split-flap board

export interface FlapMessage {
  rows: [string, string, string];
  /** Colour of the bottom (score) row. */
  tone: Tone;
}

export const flap: Sourced & { messages: FlapMessage[] } = {
  source: CLERKS + "; Congress.gov",
  asOf: "2026-11-11",
  messages: [
    { rows: ["HOUSE  ROLL 321", "H.R. 1013 PASSED", "YEA 295   NAY 128"], tone: "yea" },
    { rows: ["SENATE  ROLL 253", "STOP INSIDER TRADING", "53-47  NEEDED 60"], tone: "nay" },
    { rows: ["S. 2403 RETIREMENT", "SIGNED INTO LAW", "PUBLIC LAW 119-124"], tone: "yea" },
    { rows: ["HOUSE  ROLL 312", "RATEPAYER PROTECTION", "YEA 417   NAY 3"], tone: "yea" },
    { rows: ["SENATE  ROLL 254", "RATEPAYER PROTECTION", "57-43  3 SHORT OF 60"], tone: "nay" },
  ],
};

// ---------------------------------------------------------------- ticker

export interface TickerItem {
  chamber: "HOUSE" | "SENATE";
  title: string;
  yea: number;
  nay: number;
  result: string;
}

export const ticker: Sourced & { items: TickerItem[] } = {
  source: CLERKS,
  asOf: "2026-11-11",
  items: [
    { chamber: "HOUSE", title: "H.R. 1013", yea: 295, nay: 128, result: "Passed" },
    { chamber: "HOUSE", title: "H.Res. 1247", yea: 245, nay: 175, result: "Passed" },
    { chamber: "SENATE", title: "H.R. 2347", yea: 62, nay: 21, result: "Agreed to" },
    { chamber: "HOUSE", title: "H.Res. 1655", yea: 211, nay: 204, result: "Referred" },
    { chamber: "HOUSE", title: "H.R. 9612", yea: 394, nay: 3, result: "Passed" },
    { chamber: "HOUSE", title: "H.R. 3978", yea: 397, nay: 2, result: "Passed" },
    { chamber: "SENATE", title: "PN1129 Sonderling", yea: 47, nay: 41, result: "Confirmed" },
    { chamber: "SENATE", title: "H.R. 7008", yea: 53, nay: 47, result: "Short of 60" },
  ],
};

// ---------------------------------------------------------------- 01 · five finals

export interface RepCall {
  member: YourMember;
  pos: "Yea" | "Nay";
}

export interface Final {
  chamber: "HOUSE" | "SENATE";
  cite: string;
  date: string;
  title: string;
  blurb: string;
  yea: number;
  nay: number;
  /** Where the threshold line sits on the yea bar, in percent. */
  line: number;
  need: string;
  passed: boolean;
  result: "PASSED" | "FAILED";
  splits: Split[];
  twist: string;
  reps: RepCall[];
}

export const finals: Sourced & { cards: Final[] } = {
  source: CLERKS + "; Congress.gov bill titles and CRS summaries",
  asOf: "2026-09-30",
  cards: [
    {
      chamber: "SENATE",
      cite: "H.R. 7008 · Cloture",
      date: "Sep 30",
      title: "Stop Insider Trading Act",
      blurb: "Bans members of Congress, their spouses and dependent children from buying stocks, and requires public notice before they sell.",
      yea: 53,
      nay: 47,
      line: 60,
      need: "Needed 60 of 100",
      passed: false,
      result: "FAILED",
      splits: [
        { party: "R", yea: 53, nay: 0 },
        { party: "D", yea: 0, nay: 45 },
        { party: "I", yea: 0, nay: 2 },
      ],
      twist: "A majority voted yes and it still lost: seven short of the sixty cloture needs.",
      reps: [
        { member: "S000148", pos: "Nay" },
        { member: "G000555", pos: "Nay" },
      ],
    },
    {
      chamber: "HOUSE",
      cite: "H.J.Res. 1 · Suspension",
      date: "Sep 2",
      title: "Fix the Supreme Court at nine justices",
      blurb: "A constitutional amendment: one Chief Justice and eight Associate Justices, permanently.",
      yea: 212,
      nay: 206,
      line: 66.7,
      need: "Needed two-thirds",
      passed: false,
      result: "FAILED",
      splits: [
        { party: "R", yea: 211, nay: 1 },
        { party: "D", yea: 1, nay: 205 },
      ],
      twist: "Won the room by six, and fell 67 votes short of two-thirds.",
      reps: [{ member: "J000294", pos: "Nay" }],
    },
    {
      chamber: "SENATE",
      cite: "S. 4668 · Passage",
      date: "Sep 29",
      title: "Protect College Sports Act",
      blurb: "Sets rules for name, image and likeness deals for college athletes, and lets conferences pool and sell media rights.",
      yea: 77,
      nay: 22,
      line: 50,
      need: "Needed a majority",
      passed: true,
      result: "PASSED",
      splits: [
        { party: "R", yea: 50, nay: 2 },
        { party: "D", yea: 26, nay: 19 },
        { party: "I", yea: 1, nay: 1 },
      ],
      twist: "Democrats split almost down the middle; both your senators were on the losing side of a 77–22 win.",
      reps: [
        { member: "S000148", pos: "Nay" },
        { member: "G000555", pos: "Nay" },
      ],
    },
    {
      chamber: "HOUSE",
      cite: "H.R. 9340 · Suspension",
      date: "Sep 16",
      title: "Ratepayer Protection Act",
      blurb: "Pushes utility regulators to make very large power customers, like data centers, pay for the grid upgrades they need.",
      yea: 417,
      nay: 3,
      line: 66.7,
      need: "Needed two-thirds",
      passed: true,
      result: "PASSED",
      splits: [
        { party: "R", yea: 211, nay: 0 },
        { party: "D", yea: 206, nay: 3 },
      ],
      twist: "Three votes against in the entire House. Hold that thought.",
      reps: [{ member: "J000294", pos: "Yea" }],
    },
    {
      chamber: "SENATE",
      cite: "H.R. 9340 · Cloture",
      date: "Sep 30",
      title: "Ratepayer Protection Act, in the Senate",
      blurb: "The same bill that passed the House 417–3, two weeks later.",
      yea: 57,
      nay: 43,
      line: 60,
      need: "Needed 60 of 100",
      passed: false,
      result: "FAILED",
      splits: [
        { party: "R", yea: 53, nay: 0 },
        { party: "D", yea: 4, nay: 41 },
        { party: "I", yea: 0, nay: 2 },
      ],
      twist: "Same bill, opposite ending: three votes short of sixty.",
      reps: [
        { member: "S000148", pos: "Nay" },
        { member: "G000555", pos: "Nay" },
      ],
    },
  ],
};

// ---------------------------------------------------------------- 02 · six levels to law

export interface Level {
  name: string;
  need: string;
  /** A boss level is one a simple majority can't win. */
  boss: boolean;
  body: string;
  example: { when: string; title: string; yea: string; nay: string; result: string; tone: Tone };
}

export const levels: Sourced & { items: Level[] } = {
  source: CLERKS + "; Congress.gov bill actions",
  asOf: "2026-10-15",
  items: [
    {
      name: "Introduced",
      need: "Any one member",
      boss: false,
      body: "A member files it, it gets a number and a sponsor. No vote needed — anyone in Congress can start a bill.",
      example: { when: "H.R. 1013", title: "Sponsored by Rep. Frank Lucas (R-OK-3)", yea: "—", nay: "—", result: "FILED", tone: "ink" },
    },
    {
      name: "Committee",
      need: "Committee majority",
      boss: false,
      body: "The committee that owns the subject can hold hearings, rewrite it, and send it to the floor — or never take it up, which is how most bills end.",
      example: { when: "Committee", title: "Committee votes aren’t floor roll calls", yea: "—", nay: "—", result: "NO SCORE", tone: "muted" },
    },
    {
      name: "House floor",
      need: "2/3 on the fast lane",
      boss: true,
      body: "A simple majority after the House adopts a rule for debate — or the fast lane, suspension of the rules, which needs two-thirds.",
      example: { when: "Sep 2 · suspension", title: "H.J.Res. 1 — Supreme Court at nine justices", yea: "212", nay: "206", result: "FAILED", tone: "nay" },
    },
    {
      name: "Senate floor",
      need: "60 to end debate",
      boss: true,
      body: "Most Senate bills need cloture to start or end debate: 60 of 100, whatever the party split. A clear majority can still stall here.",
      example: { when: "Sep 30 · cloture", title: "H.R. 9340 — Ratepayer Protection Act", yea: "57", nay: "43", result: "3 SHORT", tone: "nay" },
    },
    {
      name: "Same text",
      need: "Both chambers agree",
      boss: false,
      body: "Both chambers must pass the exact same words. Changes go back and forth (\"ping-pong\") or through a conference committee.",
      example: { when: "Sep 16 · House concurs", title: "H.R. 5334 — SEED Act", yea: "262", nay: "159", result: "AGREED", tone: "yea" },
    },
    {
      name: "Signed",
      need: "2/3 to override a veto",
      boss: true,
      body: "The President signs it into law or vetoes it. Overriding a veto takes two-thirds of both chambers.",
      example: { when: "Oct 15", title: "S. 2403 — Retire through Ownership Act", yea: "401", nay: "14", result: "LAW", tone: "yea" },
    },
  ],
};

// ---------------------------------------------------------------- 02 · drive chart

export interface Drive {
  label: string;
  cite: string;
  title: string;
  status: string;
  tone: Tone;
  /** 0..100: how far the bill has driven toward law. */
  pos: number;
  mid: string;
  plays: { when: string; what: string; score: string; tone: Tone }[];
}

export const drives: Sourced & { items: Drive[] } = {
  source: "Congress.gov bill actions; " + CLERKS,
  asOf: "2026-11-11",
  items: [
    {
      label: "Retire through Ownership Act",
      cite: "S. 2403",
      title: "Retire through Ownership Act",
      status: "TOUCHDOWN",
      tone: "yea",
      pos: 100,
      mid: "SENATE ✓ · HOUSE ✓",
      plays: [
        { when: "Earlier", what: "Passed the Senate", score: "✓", tone: "ink" },
        { when: "Sep 16", what: "House passes it under suspension", score: "401–14", tone: "yea" },
        { when: "Oct 15", what: "Signed: Public Law 119-124", score: "LAW", tone: "yea" },
      ],
    },
    {
      label: "Ratepayer Protection Act",
      cite: "H.R. 9340",
      title: "Ratepayer Protection Act",
      status: "STOPPED AT THE 60",
      tone: "nay",
      pos: 50,
      mid: "HOUSE ✓ · SENATE ✗",
      plays: [
        { when: "Sep 16", what: "House passes it, two-thirds needed", score: "417–3", tone: "yea" },
        { when: "Sep 30", what: "Senate cloture, 60 needed", score: "57–43", tone: "nay" },
        { when: "Now", what: "Stalled in the Senate", score: "—", tone: "muted" },
      ],
    },
    {
      label: "Protect College Sports Act",
      cite: "S. 4668",
      title: "Protect College Sports Act of 2026",
      status: "MIDFIELD",
      tone: "ink",
      pos: 50,
      mid: "SENATE ✓ · HOUSE NEXT",
      plays: [
        { when: "Sep 29", what: "Senate passes it, both parties split", score: "77–22", tone: "yea" },
        { when: "Next", what: "Heads to the House", score: "—", tone: "muted" },
      ],
    },
    {
      label: "H.R. 1013",
      cite: "H.R. 1013",
      title: "Retirement Fairness for Charities and Educational Institutions Act",
      status: "MIDFIELD",
      tone: "ink",
      pos: 50,
      mid: "HOUSE ✓ · SENATE NEXT",
      plays: [
        { when: "Nov 10", what: "House adopts the rule for debate", score: "215–209", tone: "yea" },
        { when: "Nov 11", what: "House passes it", score: "295–128", tone: "yea" },
        { when: "Next", what: "Heads to the Senate", score: "—", tone: "muted" },
      ],
    },
  ],
};

// ---------------------------------------------------------------- 03 · bills, explained

export interface Explainer {
  cite: string;
  label: string;
  sponsor: string;
  area: string;
  /** AI-written one-line summary of the CRS summary. */
  tldr: string;
  tone: Tone;
  stands: string;
  /** AI-written points; `src` is the 1-based CRS paragraph each one cites. */
  points: { src: number; head: string; body: string }[];
  who: string[];
  not: string;
  /** The Congressional Research Service summary, excerpted, one entry per paragraph. */
  paras: string[];
}

export const explainers: Sourced & { bills: Explainer[] } = {
  source: "Congressional Research Service bill summaries (Library of Congress, via Congress.gov)",
  asOf: "2026-11-11",
  bills: [
    {
      cite: "H.R. 7008",
      label: "Stop Insider Trading Act",
      sponsor: "Rep. Bryan Steil (R-WI-1)",
      area: "Congress",
      tldr: "Members of Congress and their families couldn’t buy stocks — and would announce every sale a week or two early.",
      tone: "nay",
      stands: "STALLED · SENATE CLOTURE 53–47, NEEDED 60",
      points: [
        { src: 2, head: "No new stock buys", body: "Members, their spouses and dependent children may not buy shares of publicly traded companies." },
        { src: 2, head: "Sales announced in advance", body: "7 to 14 days before selling, they file a public notice that the Clerk or the Secretary of the Senate posts online." },
        { src: 3, head: "Funds are allowed", body: "Widely held investment funds and certain trusts are exempt." },
        { src: 4, head: "A penalty with teeth", body: "The greater of $2,000 or 10% of the trade, plus any net gain — and it can’t be paid from campaign money." },
      ],
      who: ["Members of Congress", "Spouses", "Dependent children"],
      not: "It doesn’t touch widely held funds — index funds and similar stay allowed (¶3).",
      paras: [
        "This bill generally prohibits Members of Congress and their spouses and dependent children from purchasing stocks and requires public notice before these individuals may sell stocks.",
        "Members of Congress and the spouses and dependent children of Members of Congress may not purchase covered investments. Between 7 and 14 days before a Member or a covered spouse or dependent sells a covered investment, the relevant Member must file public notice of the intent to sell with the Clerk of the House of Representatives or the Secretary of the Senate, as appropriate.",
        "A covered investment is a security issued by a publicly traded company or a comparable economic interest. Some investments are exempt, including interest in a widely held investment fund and certain investments held in a trust.",
        "Violations are subject to a fee and, in the case of a purchase, a requirement to sell the covered investment. The fee must equal the greater of $2,000 or 10% of the transaction value, and any net gain realized. The fee may not be paid using campaign donations or Members’ official allowances.",
      ],
    },
    {
      cite: "H.R. 9340",
      label: "Ratepayer Protection Act",
      sponsor: "Rep. Gabe Evans (R-CO-8)",
      area: "Energy",
      tldr: "Asks every state to consider making giant data centers pay the full cost of the grid built for them.",
      tone: "nay",
      stands: "PASSED HOUSE 417–3 · STALLED IN SENATE",
      points: [
        { src: 1, head: "Who counts as a giant", body: "Non-residential customers using power mainly for data storage and computing, with 100 megawatts or more of peak demand at one site." },
        { src: 2, head: "They pay for their upgrades", body: "Their rates must recover the full extra cost of any generation, transmission or distribution upgrade built to serve them." },
        { src: 2, head: "Walking away isn’t free", body: "The cost includes what the utility is left with if the customer ends the contract." },
        { src: 3, head: "Money up front", body: "The utility must get financial assurances before it builds anything for them." },
      ],
      who: ["Data centers", "Electric utilities", "State regulators", "Everyone’s power bill"],
      not: "It doesn’t make states adopt the standard — it requires them to consider it (¶1).",
      paras: [
        "The bill requires state utility regulators and nonregulated utilities to consider implementing a standard to hold certain large-load customers responsible for the costs of any generation, transmission, or distribution upgrade necessary to serve them. A large-load customer means a non-residential consumer buying power primarily for data storage and computational services (e.g., data centers) with a peak demand of 100 megawatts or more at a single site.",
        "The standard must require rates charged to a large-load customer to recover the full, incremental cost of any generation, transmission, or distribution upgrade necessary to serve it, including the costs incurred if the customer terminates its agreement or stops buying power.",
        "An electric utility must require the large-load customer to provide financial assurances or contributions to cover the cost of any upgrade before the utility makes it.",
      ],
    },
    {
      cite: "S. 4668",
      label: "Protect College Sports Act",
      sponsor: "Sen. Ted Cruz (R-TX)",
      area: "Sports and Recreation",
      tldr: "Writes the rules for paying college athletes into federal law — and lets conferences sell TV rights together.",
      tone: "yea",
      stands: "PASSED SENATE 77–22 · HELD AT THE HOUSE DESK",
      points: [
        { src: 2, head: "Athletes can sign NIL deals", body: "Schools and the NCAA can’t block name, image and likeness deals; athletes report anything over $600." },
        { src: 3, head: "Agents get rules", body: "Agents must register with a state, and their fees on endorsement deals are capped at 5%." },
        { src: 4, head: "One free transfer", body: "Athletes can transfer once without losing eligibility." },
        { src: 5, head: "The pay cap becomes law", body: "The revenue-sharing limit from the House settlement is made permanent and adjusted for inflation." },
        { src: 6, head: "Smaller sports protected", body: "Schools with $80M+ in athletics revenue must keep their non-revenue teams and scholarships, for nine years." },
        { src: 7, head: "TV rights, pooled", body: "A limited antitrust exemption lets conferences sell media rights together if 75% of FBS schools join." },
      ],
      who: ["College athletes", "Schools & conferences", "Agents", "Broadcasters"],
      not: "It doesn’t lift the cap on what schools share with athletes — it makes the cap permanent (¶5).",
      paras: [
        "This bill establishes requirements for name, image, or likeness (NIL) agreements for college student athletes and provides a limited antitrust exemption for schools and conferences to pool and sell certain college sports media rights.",
        "It prohibits institutions, conferences, or associations (e.g., the NCAA) from restricting student athletes from entering NIL agreements. Students must report NIL compensation greater than $600.",
        "The bill requires agents to register with a state and caps agent endorsement contract fees at 5%.",
        "It provides student athletes with one transfer without losing athletic eligibility.",
        "It prohibits compensation that circumvents the limit on sharing revenue with student athletes established under the House settlement, makes the limit permanent and provides for an annual inflation adjustment.",
        "Large institutions ($80 million or more in annual athletics revenue) must maintain as many grant-in-aid opportunities and roster spots for sports that do not generate positive net revenue as in 2024-25. The requirements expire nine years after enactment.",
        "It establishes a limited antitrust exemption for joint agreements to transfer sports telecasting rights, requiring participation from at least 75% of Football Bowl Subdivision institutions.",
      ],
    },
  ],
};

// ---------------------------------------------------------------- 04 · scouting report

/** [roll, date, measure, question, position, yea, nay, result as recorded] */
export type GridRow = readonly [number, string, string, string, VotePos, number, number, string];

export interface Scout {
  id: YourMember;
  label: string;
  full: string;
  seat: string;
  chamber: "House" | "Senate";
  /** Percent with party, as stated (one decimal); equals withParty / partyVotes. */
  unity: number;
  withParty: number;
  /** Votes where the member's party majority had a clear side. */
  partyVotes: number;
  /** Of the last 40 calls: how many the member cast a vote on (yea, nay or present). */
  played: number;
  playedSub: string;
  /** Winning-side calls, out of `of` yea/nay votes cast, in the last 40. */
  won: number;
  of: number;
  /** Crossovers since 2023: partyVotes − withParty. */
  cross: number;
  note: string;
  fact: string;
  /** The last 40 roll calls, oldest first. */
  grid: GridRow[];
}

const GRID: Record<YourMember, GridRow[]> = {
  J000294: [
    [282, "Jul 23", "H.Con.Res. 89", "Resolution", "Y", 214, 208, "Passed"],
    [283, "Jul 23", "H.R. 8884", "Passage", "N", 232, 188, "Passed"],
    [284, "Aug 31", "S. 307", "Suspension", "Y", 376, 8, "Passed"],
    [285, "Aug 31", "S. 32", "Suspension", "Y", 378, 10, "Passed"],
    [286, "Sep 1", "H.R. 6500", "Suspension", "Y", 370, 48, "Passed"],
    [287, "Sep 1", "H.Res. 1499", "Previous question", "N", 212, 205, "Passed"],
    [288, "Sep 1", "H.Res. 1499", "Resolution", "N", 210, 208, "Passed"],
    [289, "Sep 1", "H.Res. 1490", "Resolution", "N", 220, 192, "Passed"],
    [290, "Sep 1", "H.R. 9436", "Motion to Recommit", "Y", 202, 212, "Failed"],
    [291, "Sep 1", "H.R. 9436", "Passage", "N", 219, 196, "Passed"],
    [292, "Sep 1", "H.Res. 1498", "Resolution", "Y", 413, 2, "Passed"],
    [293, "Sep 2", "H.J.Res. 1", "Suspension", "N", 212, 206, "Failed"],
    [294, "Sep 2", "H.R. 1501", "Passage", "N", 218, 201, "Passed"],
    [295, "Sep 3", "H.R. 4795", "Passage", "N", 237, 169, "Passed"],
    [296, "Sep 14", "H.R. 4219", "Suspension", "Y", 371, 33, "Passed"],
    [297, "Sep 14", "H.R. 3276", "Suspension", "Y", 345, 60, "Passed"],
    [298, "Sep 15", "H.Res. 1486", "Motion to Table", "P", 232, 147, "Passed"],
    [299, "Sep 15", "H.Res. 1530", "Previous question", "N", 214, 208, "Passed"],
    [300, "Sep 15", "H.Res. 1530", "Resolution", "N", 214, 211, "Passed"],
    [301, "Sep 16", "H.R. 2978", "Suspension", "Y", 414, 7, "Passed"],
    [302, "Sep 16", "H.R. 8278", "Suspension", "Y", 417, 7, "Passed"],
    [303, "Sep 16", "H.R. 4646", "Suspension", "Y", 424, 0, "Passed"],
    [304, "Sep 16", "H.R. 2140", "Suspension", "Y", 343, 79, "Passed"],
    [305, "Sep 16", "H.R. 9500", "Suspension", "Y", 408, 17, "Passed"],
    [306, "Sep 16", "H.J.Res. 210", "Passage", "N", 216, 211, "Passed"],
    [307, "Sep 16", "H.Con.Res. 93", "Resolution", "Y", 220, 204, "Passed"],
    [308, "Sep 16", "H.R. 5334", "Concur", "N", 262, 159, "Passed"],
    [309, "Sep 16", "H.R. 9576", "Passage", "Y", 352, 72, "Passed"],
    [310, "Sep 16", "H.R. 10326", "Passage", "N", 217, 207, "Passed"],
    [311, "Sep 16", "H.J.Res. 213", "Passage", "N", 214, 208, "Passed"],
    [312, "Sep 16", "H.R. 9340", "Suspension", "Y", 417, 3, "Passed"],
    [313, "Sep 16", "H.R. 9497", "Suspension", "Y", 415, 9, "Passed"],
    [314, "Sep 16", "S. 2403", "Suspension", "Y", 401, 14, "Passed"],
    [315, "Nov 9", "H.R. 3978", "Suspension", "Y", 397, 2, "Passed"],
    [316, "Nov 10", "H.R. 9612", "Suspension", "Y", 394, 3, "Passed"],
    [317, "Nov 10", "H.Res. 1655", "Motion to Refer", "N", 211, 204, "Passed"],
    [318, "Nov 10", "H.Res. 1650", "Previous question", "N", 213, 207, "Passed"],
    [319, "Nov 10", "H.Res. 1650", "Resolution", "N", 215, 209, "Passed"],
    [320, "Nov 11", "H.Res. 1247", "Motion to Discharge", "Y", 245, 175, "Passed"],
    [321, "Nov 11", "H.R. 1013", "Passage", "N", 295, 128, "Passed"],
  ],
  S000148: [
    [219, "Aug 5", "PN932", "Cloture", "N", 51, 43, "Cloture Agreed to"],
    [220, "Aug 5", "PN932", "Nomination", "N", 51, 44, "Nomination Confirmed"],
    [221, "Aug 5", "Amendment", "Cloture", "N", 50, 44, "Cloture Agreed to"],
    [222, "Aug 5", "S.J.Res. 187", "Motion to Proceed", "Y", 48, 50, "Motion Rejected"],
    [223, "Aug 7", "Amendment", "Amendment", "Y", 32, 64, "Amendment Rejected"],
    [224, "Aug 7", "H.R. 5334", "Passage", "Y", 86, 11, "Bill Passed"],
    [225, "Aug 7", "Amendment", "Nomination", "N", 51, 47, "Nomination Confirmed"],
    [226, "Aug 7", "Amendment", "Cloture", "Y", 91, 6, "Cloture Agreed to"],
    [227, "Aug 8", "Amendment", "Motion to Table", "Y", 61, 32, "Motion to Table Agreed"],
    [228, "Aug 8", "H.R. 6500", "Passage", "Y", 90, 6, "Bill Passed"],
    [229, "Aug 8", "PN1078", "Cloture", "N", 50, 49, "Cloture Agreed to"],
    [230, "Aug 8", "PN1078", "Nomination", "N", 50, 49, "Nomination Confirmed"],
    [231, "Aug 8", "S. 5271", "Cloture", "N", 52, 46, "Cloture Rejected"],
    [232, "Sep 14", "PN1093-3", "Cloture", "N", 47, 46, "Cloture Agreed to"],
    [233, "Sep 15", "PN1093-3", "Nomination", "N", 52, 45, "Nomination Confirmed"],
    [234, "Sep 15", "H.R. 3633", "Cloture", "N", 49, 50, "Cloture Rejected"],
    [235, "Sep 15", "S. 4668", "Cloture", "Y", 74, 24, "Cloture Agreed to"],
    [236, "Sep 17", "S. 4668", "Motion to Proceed", "Y", 77, 22, "Motion Agreed to"],
    [237, "Sep 17", "PN999-4", "Cloture", "N", 49, 47, "Cloture Agreed to"],
    [238, "Sep 17", "PN999-4", "Nomination", "N", 49, 45, "Nomination Confirmed"],
    [239, "Sep 22", "PN999-1", "Cloture", "N", 52, 43, "Cloture Agreed to"],
    [240, "Sep 22", "Amendment", "Cloture", "N", 70, 21, "Cloture Agreed to"],
    [241, "Sep 23", "PN999-1", "Nomination", "N", 50, 47, "Nomination Confirmed"],
    [242, "Sep 24", "Amendment", "Amendment", "N", 77, 23, "Amendment Agreed to"],
    [243, "Sep 24", "S. 4668", "Cloture", "N", 74, 25, "Cloture Agreed to"],
    [244, "Sep 24", "H.Con.Res. 89", "Concur", "Y", 49, 50, "Concurrent Resolution "],
    [245, "Sep 28", "Amendment", "Amendment", "Y", 96, 1, "Amendment Agreed to"],
    [246, "Sep 28", "Amendment", "Amendment", "N", 1, 94, "Amendment Rejected"],
    [247, "Sep 29", "Amendment", "Amendment", "Y", 42, 54, "Amendment Rejected"],
    [248, "Sep 29", "Amendment", "Amendment", "Y", 49, 50, "Amendment Rejected"],
    [249, "Sep 29", "Amendment", "Amendment", "Y", 47, 52, "Amendment Rejected"],
    [250, "Sep 29", "S. 4668", "Passage", "N", 77, 22, "Bill Passed"],
    [251, "Sep 29", "S.J.Res. 197", "Motion to Proceed", "Y", 48, 51, "Motion Rejected"],
    [252, "Sep 29", "S.Res. 852", "Motion to Discharge", "Y", 47, 51, "Motion to Discharge Re"],
    [253, "Sep 30", "H.R. 7008", "Cloture", "N", 53, 47, "Cloture Rejected"],
    [254, "Sep 30", "H.R. 9340", "Cloture", "N", 57, 43, "Cloture Rejected"],
    [255, "Sep 30", "PN1129", "Cloture", "N", 53, 47, "Cloture Agreed to"],
    [256, "Oct 1", "PN1129", "Nomination", "N", 47, 41, "Nomination Confirmed"],
    [257, "Nov 9", "H.R. 2347", "Cloture", "Y", 73, 25, "Cloture Agreed to"],
    [258, "Nov 11", "H.R. 2347", "Motion to Proceed", "Y", 62, 21, "Motion Agreed to"],
  ],
  G000555: [
    [219, "Aug 5", "PN932", "Cloture", "N", 51, 43, "Cloture Agreed to"],
    [220, "Aug 5", "PN932", "Nomination", "N", 51, 44, "Nomination Confirmed"],
    [221, "Aug 5", "Amendment", "Cloture", "N", 50, 44, "Cloture Agreed to"],
    [222, "Aug 5", "S.J.Res. 187", "Motion to Proceed", "Y", 48, 50, "Motion Rejected"],
    [223, "Aug 7", "Amendment", "Amendment", "N", 32, 64, "Amendment Rejected"],
    [224, "Aug 7", "H.R. 5334", "Passage", "Y", 86, 11, "Bill Passed"],
    [225, "Aug 7", "Amendment", "Nomination", "N", 51, 47, "Nomination Confirmed"],
    [226, "Aug 7", "Amendment", "Cloture", "Y", 91, 6, "Cloture Agreed to"],
    [227, "Aug 8", "Amendment", "Motion to Table", "N", 61, 32, "Motion to Table Agreed"],
    [228, "Aug 8", "H.R. 6500", "Passage", "Y", 90, 6, "Bill Passed"],
    [229, "Aug 8", "PN1078", "Cloture", "N", 50, 49, "Cloture Agreed to"],
    [230, "Aug 8", "PN1078", "Nomination", "N", 50, 49, "Nomination Confirmed"],
    [231, "Aug 8", "S. 5271", "Cloture", "N", 52, 46, "Cloture Rejected"],
    [232, "Sep 14", "PN1093-3", "Cloture", "N", 47, 46, "Cloture Agreed to"],
    [233, "Sep 15", "PN1093-3", "Nomination", "N", 52, 45, "Nomination Confirmed"],
    [234, "Sep 15", "H.R. 3633", "Cloture", "N", 49, 50, "Cloture Rejected"],
    [235, "Sep 15", "S. 4668", "Cloture", "N", 74, 24, "Cloture Agreed to"],
    [236, "Sep 17", "S. 4668", "Motion to Proceed", "N", 77, 22, "Motion Agreed to"],
    [237, "Sep 17", "PN999-4", "Cloture", "N", 49, 47, "Cloture Agreed to"],
    [238, "Sep 17", "PN999-4", "Nomination", "N", 49, 45, "Nomination Confirmed"],
    [239, "Sep 22", "PN999-1", "Cloture", "N", 52, 43, "Cloture Agreed to"],
    [240, "Sep 22", "Amendment", "Cloture", "N", 70, 21, "Cloture Agreed to"],
    [241, "Sep 23", "PN999-1", "Nomination", "N", 50, 47, "Nomination Confirmed"],
    [242, "Sep 24", "Amendment", "Amendment", "N", 77, 23, "Amendment Agreed to"],
    [243, "Sep 24", "S. 4668", "Cloture", "N", 74, 25, "Cloture Agreed to"],
    [244, "Sep 24", "H.Con.Res. 89", "Concur", "Y", 49, 50, "Concurrent Resolution "],
    [245, "Sep 28", "Amendment", "Amendment", "Y", 96, 1, "Amendment Agreed to"],
    [246, "Sep 28", "Amendment", "Amendment", "N", 1, 94, "Amendment Rejected"],
    [247, "Sep 29", "Amendment", "Amendment", "Y", 42, 54, "Amendment Rejected"],
    [248, "Sep 29", "Amendment", "Amendment", "Y", 49, 50, "Amendment Rejected"],
    [249, "Sep 29", "Amendment", "Amendment", "Y", 47, 52, "Amendment Rejected"],
    [250, "Sep 29", "S. 4668", "Passage", "N", 77, 22, "Bill Passed"],
    [251, "Sep 29", "S.J.Res. 197", "Motion to Proceed", "Y", 48, 51, "Motion Rejected"],
    [252, "Sep 29", "S.Res. 852", "Motion to Discharge", "Y", 47, 51, "Motion to Discharge Re"],
    [253, "Sep 30", "H.R. 7008", "Cloture", "N", 53, 47, "Cloture Rejected"],
    [254, "Sep 30", "H.R. 9340", "Cloture", "N", 57, 43, "Cloture Rejected"],
    [255, "Sep 30", "PN1129", "Cloture", "N", 53, 47, "Cloture Agreed to"],
    [256, "Oct 1", "PN1129", "Nomination", "M", 47, 41, "Nomination Confirmed"],
    [257, "Nov 9", "H.R. 2347", "Cloture", "Y", 73, 25, "Cloture Agreed to"],
    [258, "Nov 11", "H.R. 2347", "Motion to Proceed", "Y", 62, 21, "Motion Agreed to"],
  ],
};

export const scouting: Sourced & { members: Scout[] } = {
  source: CLERKS + "; party-unity counts since Jan 2023",
  asOf: "2026-11-11",
  members: [
    {
      id: "J000294",
      label: "Jeffries",
      full: "Hakeem Jeffries",
      seat: "House · New York 8th · Democrat",
      chamber: "House",
      unity: 98.7,
      withParty: 1860,
      partyVotes: 1884,
      played: 40,
      playedSub: "40 of 40 · 1 present",
      won: 21,
      of: 39,
      cross: 24,
      note: "Votes against his party’s majority, out of 1,884 where it had a clear side.",
      fact: "16 of his last 40 calls came up under suspension, the two-thirds fast lane. He voted yea on 15 — the exception was H.J.Res. 1, the Supreme Court amendment.",
      grid: GRID.J000294,
    },
    {
      id: "S000148",
      label: "Schumer",
      full: "Chuck Schumer",
      seat: "Senate · New York · Democrat",
      chamber: "Senate",
      unity: 97.7,
      withParty: 1563,
      partyVotes: 1600,
      played: 40,
      playedSub: "40 of 40",
      won: 14,
      of: 40,
      cross: 37,
      note: "Votes against his party’s majority, out of 1,600 where it had a clear side.",
      fact: "Your two senators voted the same way on 35 of the 39 calls they both cast — they split on S. 4668 twice, and on two August votes.",
      grid: GRID.S000148,
    },
    {
      id: "G000555",
      label: "Gillibrand",
      full: "Kirsten Gillibrand",
      seat: "Senate · New York · Democrat",
      chamber: "Senate",
      unity: 96.6,
      withParty: 1527,
      partyVotes: 1580,
      played: 39,
      playedSub: "39 of 40 · 1 missed",
      won: 12,
      of: 39,
      cross: 53,
      note: "Votes against her party’s majority, out of 1,580 where it had a clear side.",
      fact: "Your two senators voted the same way on 35 of the 39 calls they both cast. Her one missed vote: the Sonderling confirmation, Oct 1.",
      grid: GRID.G000555,
    },
  ],
};

// ---------------------------------------------------------------- 05 · the players

export interface Maverick {
  id: MemberId;
  full: string;
  pos: string;
  badge: string;
  chamber: "house" | "senate";
  /** Votes where the member's party had a clear side, since Jan 2023. */
  votes: number;
  withParty: number;
  /** votes − withParty. */
  crossovers: number;
}

export const mavericks: Sourced & { members: Maverick[]; fan: MemberId[]; fanDefault: MemberId } = {
  source: CLERKS + "; party-unity counts since Jan 2023",
  asOf: "2026-11-11",
  members: [
    { id: "C001035", full: "Susan Collins", pos: "Senate · Maine · R", badge: "R-ME", chamber: "senate", votes: 1606, withParty: 1143, crossovers: 463 },
    { id: "F000466", full: "Brian Fitzpatrick", pos: "House · PA-1 · R", badge: "PA-1", chamber: "house", votes: 1888, withParty: 1431, crossovers: 457 },
    { id: "M001184", full: "Thomas Massie", pos: "House · KY-4 · R", badge: "KY-4", chamber: "house", votes: 1743, withParty: 1311, crossovers: 432 },
    { id: "M001153", full: "Lisa Murkowski", pos: "Senate · Alaska · R", badge: "R-AK", chamber: "senate", votes: 1543, withParty: 1124, crossovers: 419 },
    { id: "G000592", full: "Jared Golden", pos: "House · ME-2 · D", badge: "ME-2", chamber: "house", votes: 1824, withParty: 1451, crossovers: 373 },
    { id: "C001063", full: "Henry Cuellar", pos: "House · TX-28 · D", badge: "TX-28", chamber: "house", votes: 1855, withParty: 1510, crossovers: 345 },
    { id: "F000479", full: "John Fetterman", pos: "Senate · Pennsylvania · D", badge: "D-PA", chamber: "senate", votes: 1403, withParty: 1231, crossovers: 172 },
  ],
  /** The five cards fanned out, left to right; the middle one is raised first. */
  fan: ["C001035", "F000466", "M001184", "G000592", "F000479"],
  fanDefault: "M001184",
};

// ---------------------------------------------------------------- 06 · who funds them

export interface PacCheck {
  name: string;
  kind: string;
  amount: number;
}

export interface Funding {
  member: YourMember;
  period: string;
  total: number;
  cash: number;
  cashAsOf: string;
  small: number;
  itemized: number;
  pac: number;
  other: number;
  otherNote: string;
  /** Biggest PAC checks, from FEC itemized receipts. Empty: not pulled for this member yet. */
  pacs: PacCheck[];
}

export const funding: Sourced & { members: Funding[] } = {
  source: "Federal Election Commission filings for each member's principal campaign committee",
  asOf: "2026-10-14",
  members: [
    {
      member: "J000294",
      period: "2026 cycle · Jan 2025 – Oct 14, 2026",
      total: 17893352,
      cash: 4234848,
      cashAsOf: "as of Oct 14, 2026",
      small: 8147893,
      itemized: 4542828,
      pac: 2765400,
      other: 2437231,
      otherNote: "mostly transfers from his joint fundraising committees",
      pacs: [
        { name: "American Trucking Associations PAC", kind: "Trade group", amount: 10000 },
        { name: "Sazerac Company PAC", kind: "Company", amount: 10000 },
        { name: "Associated Equipment Distributors PAC", kind: "Trade group", amount: 10000 },
        { name: "Verizon PAC", kind: "Company", amount: 10000 },
        { name: "Society for Vascular Surgery PAC", kind: "Professional", amount: 10000 },
        { name: "UA Plumbers & Pipefitters VOTE! PAC", kind: "Union", amount: 5000 },
        { name: "National Treasury Employees Union", kind: "Union", amount: 5000 },
        { name: "Procter & Gamble Good Government Fund", kind: "Company", amount: 5000 },
        { name: "TIAA PAC", kind: "Company", amount: 5000 },
        { name: "Planned Parenthood Federal PAC", kind: "Advocacy", amount: 5000 },
        { name: "Major League Baseball PAC", kind: "Company", amount: 5000 },
      ],
    },
    {
      member: "S000148",
      period: "Last full campaign · 2017 – 2022",
      total: 41884545,
      cash: 7853430,
      cashAsOf: "as of Sep 30, 2026",
      small: 4542115,
      itemized: 32122614,
      pac: 4079615,
      other: 1140201,
      otherNote: "transfers, refunds and other receipts",
      pacs: [],
    },
    {
      member: "G000555",
      period: "Last full campaign · 2019 – 2024",
      total: 15722159,
      cash: 2713530,
      cashAsOf: "as of Sep 30, 2026",
      small: 2224331,
      itemized: 5268485,
      pac: 884398,
      other: 7344945,
      otherNote: "transfers, refunds and other receipts",
      pacs: [],
    },
  ],
};

// ---------------------------------------------------------------- 06 · who's giving, explained

export interface RelatedVote {
  pos: "YEA" | "NAY";
  title: string;
  meta: string;
  score: string;
  why: string;
}

export interface DonorContext {
  name: string;
  kind: string;
  amount: number;
  how: string;
  /** AI-written from public sources. */
  who: string;
  lobby: string;
  vote?: RelatedVote;
  /** Shown instead of a related vote; falls back to `contextNone`. */
  none?: string;
}

export const contextNone = "Nothing in his last 40 House votes touches this directly. In the app, Floor checks his whole record.";

export const donorContext: Sourced & { member: YourMember; donors: DonorContext[]; defaultIndex: number } = {
  source: "FEC itemized receipts, Jan 2025 – Oct 14, 2026; descriptions AI-written from public sources",
  asOf: "2026-10-14",
  member: "J000294",
  defaultIndex: 2,
  donors: [
    { name: "American Trucking Associations PAC", kind: "Trade group", amount: 10000, how: "PAC contribution · cycle max", who: "The national trade association for the trucking industry.", lobby: "Highway and freight funding, truck size and weight rules, driver hours and licensing." },
    { name: "Verizon PAC", kind: "Company", amount: 10000, how: "PAC contribution · cycle max", who: "The political action committee of Verizon, the wireless and broadband carrier.", lobby: "Spectrum auctions, broadband programs, telecom regulation." },
    {
      name: "TIAA PAC",
      kind: "Company",
      amount: 5000,
      how: "PAC contribution",
      who: "The PAC of TIAA, which runs retirement plans for teachers, universities and nonprofits — many of them 403(b) plans.",
      lobby: "Retirement savings rules, annuities, financial regulation.",
      vote: {
        pos: "NAY",
        title: "H.R. 1013 — Retirement Fairness for Charities and Educational Institutions Act",
        meta: "House · On Passage · Nov 11, 2026 · Passed",
        score: "295–128",
        why: "The bill lets 403(b) plans invest in collective investment trusts — the kind of plan TIAA administers. Shown because the topics overlap, not because one caused the other.",
      },
    },
    { name: "UA Plumbers & Pipefitters VOTE! PAC", kind: "Union", amount: 5000, how: "PAC contribution", who: "The political arm of the United Association, the union of plumbers, pipefitters, welders and HVAC technicians.", lobby: "Construction and energy projects, prevailing wages, apprenticeship programs." },
    { name: "National Treasury Employees Union", kind: "Union", amount: 5000, how: "PAC contribution", who: "A union representing federal employees at the IRS, Customs and Border Protection and other agencies.", lobby: "Federal pay and benefits, agency staffing, collective bargaining rights." },
    { name: "Planned Parenthood Federal PAC", kind: "Advocacy", amount: 5000, how: "PAC contribution", who: "The federal PAC of Planned Parenthood Action Fund, the political arm of the reproductive health care provider.", lobby: "Abortion access, Title X family planning funding, Medicaid coverage." },
    { name: "Major League Baseball PAC", kind: "Company", amount: 5000, how: "PAC contribution", who: "The PAC of the Office of the Commissioner of Baseball.", lobby: "Baseball’s antitrust exemption, broadcast rights, minor-league and player rules." },
    {
      name: "AIPAC PAC",
      kind: "Advocacy",
      amount: 7000,
      how: "earmarked gifts from individuals, passed through the PAC",
      who: "AIPAC, the American Israel Public Affairs Committee, lobbies on U.S.–Israel relations. Its PAC, started in 2021, passes contributions from individual donors to candidates it backs.",
      lobby: "Security aid to Israel, sanctions on Iran, U.S. policy in the Middle East.",
      none: "Nothing in his last 40 House votes is about Israel or the Middle East. In the app, Floor checks his whole record.",
    },
  ],
};

// ---------------------------------------------------------------- 07 · the portfolio

export interface AssetYear {
  year: string;
  /** Summary range of reported assets (sum of the filed line-item ranges). */
  low: number;
  high: number;
  label: string;
  tone: "past" | "yea";
}

export interface Trade {
  side: "P" | "S";
  asset: string;
  who: "Self" | "Child";
  date: string;
}

export const portfolio: Sourced & {
  member: YourMember;
  scaleMax: number;
  years: AssetYear[];
  stats: { big: string; label: string; tone: Tone }[];
  aiNote: string;
  trades: Trade[];
  tradeRange: string;
  ptrs2026: number;
  board: { name: string; seat: string; reports: number }[];
  report: {
    filer: string;
    buys: number;
    sells: number;
    lag: string;
    aiNote: string;
    tape: { ticker: string; name: string; side: "P" | "S"; date: string }[];
  };
} = {
  source: "Financial disclosure reports and periodic transaction reports filed with the Clerk of the House",
  asOf: "2026-08-10",
  member: "J000294",
  scaleMax: 1200000,
  years: [
    { year: "2024", low: 297026, high: 932000, label: "$297K – $932K", tone: "past" },
    { year: "2025", low: 305033, high: 1051000, label: "$305K – $1.05M", tone: "yea" },
  ],
  stats: [
    { big: "+$119K", label: "top of the asset range, 2024 → 2025", tone: "yea" },
    { big: "$50K–100K", label: "new: book royalties, \"ABC’s of Democracy\"", tone: "ink" },
    { big: "0", label: "individual stocks among 37 holdings — all funds, accounts, pensions", tone: "ink" },
    { big: "$515K–1.18M", label: "reported debts, mostly two home mortgages", tone: "nay" },
  ],
  aiNote:
    "His money is mostly retirement funds, bank accounts and a book. The top of his asset range rose about $119K in a year, and the new line is book royalties. Every 2025 trade was a fund, none over $15,000 — five of the seven in his child's accounts. Debts are mostly mortgages on two homes, and homes themselves aren't reportable, so \"assets minus debts\" would understate him. We don't print a net-worth number we can't stand behind.",
  trades: [
    { side: "S", asset: "Lord Abbett Floating Rate Fund", who: "Self", date: "Jan 2" },
    { side: "S", asset: "Vanguard 500 Index Fund", who: "Child", date: "Feb 24" },
    { side: "P", asset: "NY 529 college plan", who: "Child", date: "May 16" },
    { side: "P", asset: "Lord Abbett Floating Rate Fund", who: "Self", date: "May 23" },
    { side: "P", asset: "Vanguard S&P 500 ETF", who: "Child", date: "Sep 2" },
    { side: "S", asset: "Vanguard S&P 500 ETF (partial)", who: "Child", date: "Dec 1" },
    { side: "S", asset: "Vanguard S&P 500 ETF (partial)", who: "Child", date: "Dec 15" },
  ],
  tradeRange: "$1K–15K",
  ptrs2026: 0,
  board: [
    { name: "Rep. David Taylor", seat: "R-OH-2", reports: 18 },
    { name: "Rep. Diana Harshbarger", seat: "R-TN-1", reports: 17 },
    { name: "Rep. Kelly Morrison", seat: "D-MN-3", reports: 14 },
    { name: "Rep. Kevin Hern", seat: "R-OK-1", reports: 13 },
    { name: "Rep. Cleo Fields", seat: "D-LA-6", reports: 13 },
    { name: "Rep. Suzan DelBene", seat: "D-WA-1", reports: 13 },
    { name: "Rep. Mike Kelly", seat: "R-PA-16", reports: 12 },
    { name: "Rep. Josh Gottheimer", seat: "D-NJ-5", reports: 11 },
  ],
  report: {
    filer: "Rep. Josh Gottheimer (D-NJ-5) · joint account · filed Aug 10, 2026",
    buys: 8,
    sells: 5,
    lag: "17–27 days",
    aiNote: "Individual-stock purchases like these are what H.R. 7008, the Stop Insider Trading Act, would bar for members and their families. That bill stalled in the Senate 53–47 on Sep 30.",
    tape: [
      { ticker: "GOOGM", name: "Alphabet Series A conv. pref.", side: "P", date: "Jul 24" },
      { ticker: "GOOGN", name: "Alphabet Series B conv. pref.", side: "P", date: "Jul 23" },
      { ticker: "GOOGN", name: "Alphabet Series B conv. pref.", side: "P", date: "Jul 24" },
      { ticker: "CRWD", name: "CrowdStrike", side: "P", date: "Jul 15" },
      { ticker: "PANW", name: "Palo Alto Networks", side: "P", date: "Jul 16" },
      { ticker: "MNST", name: "Monster Beverage", side: "P", date: "Jul 17" },
      { ticker: "NICE", name: "NICE Ltd ADS", side: "P", date: "Jul 20" },
      { ticker: "SAIL", name: "SailPoint Technologies", side: "P", date: "Jul 20" },
      { ticker: "FN", name: "Fabrinet", side: "S", date: "Jul 14" },
      { ticker: "IBM", name: "IBM (partial)", side: "S", date: "Jul 15" },
      { ticker: "IBM", name: "IBM", side: "S", date: "Jul 16" },
      { ticker: "GTLS", name: "Chart Industries", side: "S", date: "Jul 17" },
      { ticker: "CCI", name: "Crown Castle", side: "S", date: "Jul 23" },
    ],
  },
};

// ---------------------------------------------------------------- 08 · live (coming next)

export type IslandMode = "idle" | "open" | "rep" | "final";

export interface IslandStep {
  mode: IslandMode;
  width: string;
  height: string;
  radius: string;
  /** The advance button's label while this step shows. */
  next: string;
}

/** A replay of H.R. 1013 in the Dynamic Island: a preview of a feature in development. */
export const live: Sourced & {
  steps: IslandStep[];
  vote: { chamber: string; title: string; needs: string; rep: YourMember; repLabel: string; repPos: "YEA" | "NAY"; yea: number; nay: number; result: string; final: string };
  lockDate: string;
  lockTime: string;
} = {
  source: CLERKS + " (House roll 321)",
  asOf: "2026-11-11",
  steps: [
    { mode: "idle", width: "126px", height: "36px", radius: "20px", next: "Replay: vote opens →" },
    { mode: "open", width: "calc(100% - 24px)", height: "76px", radius: "38px", next: "Next: your rep votes →" },
    { mode: "rep", width: "calc(100% - 24px)", height: "76px", radius: "38px", next: "Next: the final →" },
    { mode: "final", width: "calc(100% - 24px)", height: "84px", radius: "42px", next: "Replay from the start" },
  ],
  vote: {
    chamber: "VOTE OPEN · HOUSE",
    title: "H.R. 1013 · On Passage",
    needs: "NEEDS 212",
    rep: "J000294",
    repLabel: "Jeffries",
    repPos: "NAY",
    yea: 295,
    nay: 128,
    result: "PASSED",
    final: "FINAL · H.R. 1013",
  },
  lockDate: "Tuesday, November 11",
  lockTime: "2:43",
};
