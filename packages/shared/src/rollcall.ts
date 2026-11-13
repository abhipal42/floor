import { XMLParser } from "fast-xml-parser";
import type { Chamber, Threshold, VotePosition } from "./index.js";

/** A finished roll call vote, normalized across chambers. */
export interface RollCall {
  /** "election" for Speaker elections, where members vote for a candidate instead of yea/nay. */
  kind: "question" | "election";
  chamber: Chamber;
  congress: number;
  session: number;
  rollNumber: number;
  question: string;
  result: string;
  threshold: Threshold;
  /** Measure as printed by the chamber, e.g. "H CON RES 14" or "S. 9". Null for procedural votes. */
  billRef: string | null;
  /** Local Eastern time of the vote, "YYYY-MM-DDTHH:mm". */
  occurredAtEastern: string | null;
  totals: { yea: number; nay: number; present: number; notVoting: number };
  /** Per-candidate totals for elections; empty for ordinary questions. */
  candidates: { name: string; total: number }[];
  positions: MemberPosition[];
}

export interface MemberPosition {
  /** Bioguide ID for the House, LIS member ID for the Senate. */
  memberId: string;
  idType: "bioguide" | "lis";
  party: string;
  state: string;
  position: VotePosition;
  /** The candidate named, when `position` is "candidate". */
  choice?: string;
}

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "@_",
  parseTagValue: false,
  trimValues: true,
  isArray: (name) =>
    name === "recorded-vote" || name === "member" || name === "totals-by-party" || name === "totals-by-candidate",
});

const MONTHS: Record<string, string> = {
  jan: "01", feb: "02", mar: "03", apr: "04", may: "05", jun: "06",
  jul: "07", aug: "08", sep: "09", oct: "10", nov: "11", dec: "12",
};

function int(value: unknown): number {
  const n = Number.parseInt(String(value ?? "").trim(), 10);
  return Number.isNaN(n) ? 0 : n;
}

function text(value: unknown): string {
  if (value == null) return "";
  if (typeof value === "object" && "#text" in (value as Record<string, unknown>)) {
    return String((value as Record<string, unknown>)["#text"]).trim();
  }
  return typeof value === "object" ? "" : String(value).trim();
}

export function normalizePosition(raw: string): VotePosition {
  switch (raw.trim().toLowerCase()) {
    case "yea":
    case "aye":
    case "guilty":
      return "yea";
    case "nay":
    case "no":
    case "not guilty":
      return "nay";
    case "present":
      return "present";
    case "not voting":
      return "not_voting";
    default:
      throw new Error(`Unknown vote position: "${raw}"`);
  }
}

/** Parses a House Clerk roll call file (clerk.house.gov/evs/{year}/roll{nnn}.xml). */
export function parseHouseRollCall(xml: string): RollCall {
  const doc = parser.parse(xml)["rollcall-vote"];
  if (!doc) throw new Error("Not a House roll call document");
  const meta = doc["vote-metadata"];
  const voteType = text(meta["vote-type"]);
  const byCandidate = meta["vote-totals"]?.["totals-by-candidate"] as Record<string, unknown>[] | undefined;
  const hasCandidateTotals = Array.isArray(byCandidate) && byCandidate.length > 0;
  // The question is a second signal, so a ballot whose file lacks the per-candidate block is still
  // read as an election instead of failing on its first candidate name — `Unknown vote position:
  // "Jeffries"` is exactly what an election read as a yea/nay question looks like.
  const isElection = hasCandidateTotals || SPEAKER_ELECTION.test(text(meta["vote-question"]));

  const date = text(meta["action-date"]); // 10-Apr-2025
  const time = meta["action-time"]?.["@_time-etz"] as string | undefined; // 11:08
  const [day, mon, year] = date.split("-");
  const month = MONTHS[(mon ?? "").slice(0, 3).toLowerCase()];
  const occurredAtEastern =
    day && month && year && time ? `${year}-${month}-${day.padStart(2, "0")}T${time.padStart(5, "0")}` : null;

  const records = (doc["vote-data"]?.["recorded-vote"] ?? []) as Record<string, unknown>[];
  const positions: MemberPosition[] = records.map((r) => {
    const legislator = r["legislator"] as Record<string, string>;
    const vote = text(r["vote"]);
    const base = {
      memberId: legislator["@_name-id"] ?? "",
      idType: "bioguide" as const,
      party: legislator["@_party"] ?? "",
      state: legislator["@_state"] ?? "",
    };
    if (isElection && !NON_CANDIDATE.has(vote.toLowerCase())) {
      return { ...base, position: "candidate" as const, choice: vote };
    }
    return { ...base, position: normalizePosition(vote) };
  });

  let totals: RollCall["totals"];
  let candidates: RollCall["candidates"] = [];
  if (isElection) {
    candidates = hasCandidateTotals
      ? byCandidate
          .map((c) => ({ name: text(c["candidate"]), total: int(c["candidate-total"]) }))
          .filter((c) => !NON_CANDIDATE.has(c.name.toLowerCase()))
      : candidatesFromPositions(positions);
    const count = (p: VotePosition) => positions.filter((x) => x.position === p).length;
    totals = { yea: 0, nay: 0, present: count("present"), notVoting: count("not_voting") };
  } else {
    const t = meta["vote-totals"]["totals-by-vote"];
    totals = {
      yea: int(t["yea-total"]),
      nay: int(t["nay-total"]),
      present: int(t["present-total"]),
      notVoting: int(t["not-voting-total"]),
    };
  }

  const billRef = text(meta["legis-num"]);
  return {
    kind: isElection ? "election" : "question",
    chamber: "house",
    congress: int(meta["congress"]),
    session: int(text(meta["session"])),
    rollNumber: int(meta["rollcall-num"]),
    question: text(meta["vote-question"]),
    result: text(meta["vote-result"]),
    threshold: voteType.includes("2/3") ? "two_thirds" : "majority",
    billRef: billRef && billRef !== "0" ? billRef : null,
    occurredAtEastern,
    totals,
    candidates,
    positions,
  };
}

/** Entries in a Speaker election that aren't candidates. */
const NON_CANDIDATE = new Set(["present", "not voting"]);

/** The House Clerk's question on every Speaker ballot since 2023: "Election of the Speaker". */
const SPEAKER_ELECTION = /^election of (the )?speaker\b/i;

/** Per-candidate totals counted from the recorded votes, most votes first, for a file that omits them. */
function candidatesFromPositions(positions: MemberPosition[]): RollCall["candidates"] {
  const totals = new Map<string, number>();
  for (const p of positions) {
    if (p.position === "candidate" && p.choice) totals.set(p.choice, (totals.get(p.choice) ?? 0) + 1);
  }
  return [...totals]
    .map(([name, total]) => ({ name, total }))
    .sort((a, b) => b.total - a.total || a.name.localeCompare(b.name));
}

/** Parses a senate.gov LIS roll call file (vote_{congress}_{session}_{nnnnn}.xml). */
export function parseSenateRollCall(xml: string): RollCall {
  const doc = parser.parse(xml)["roll_call_vote"];
  if (!doc) throw new Error("Not a Senate roll call document");

  // "March 3, 2025,  06:27 PM"
  const m = /^(\w+)\s+(\d{1,2}),\s*(\d{4}),\s*(\d{1,2}):(\d{2})\s*(AM|PM)$/i.exec(text(doc["vote_date"]));
  let occurredAtEastern: string | null = null;
  if (m) {
    const [, monName, day, year, hh, mm, ampm] = m;
    const month = MONTHS[(monName ?? "").slice(0, 3).toLowerCase()];
    let hour = int(hh) % 12;
    if ((ampm ?? "").toUpperCase() === "PM") hour += 12;
    if (month) occurredAtEastern = `${year}-${month}-${(day ?? "").padStart(2, "0")}T${String(hour).padStart(2, "0")}:${mm}`;
  }

  const requirement = text(doc["majority_requirement"]);
  const threshold: Threshold =
    requirement === "3/5" ? "three_fifths_sworn" : requirement === "2/3" ? "two_thirds" : "majority";

  const members = (doc["members"]?.["member"] ?? []) as Record<string, unknown>[];
  const positions: MemberPosition[] = members.map((mem) => ({
    memberId: text(mem["lis_member_id"]),
    idType: "lis",
    party: text(mem["party"]),
    state: text(mem["state"]),
    position: normalizePosition(text(mem["vote_cast"])),
  }));

  const count = doc["count"] ?? {};
  const billRef = text(doc["document"]?.["document_name"]);
  return {
    kind: "question",
    candidates: [],
    chamber: "senate",
    congress: int(doc["congress"]),
    session: int(doc["session"]),
    rollNumber: int(doc["vote_number"]),
    question: text(doc["question"]) || text(doc["vote_question_text"]),
    result: text(doc["vote_result"]),
    threshold,
    billRef: billRef || null,
    occurredAtEastern,
    totals: {
      yea: int(count["yeas"]),
      nay: int(count["nays"]),
      present: int(count["present"]),
      notVoting: int(count["absent"]),
    },
    positions,
  };
}
