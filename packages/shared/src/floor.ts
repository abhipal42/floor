import { XMLParser } from "fast-xml-parser";

/*
 * Floor-event sources for the live layer (M3). Each parser is tested against a real saved response
 * in `packages/shared/fixtures/`; what those responses taught us is in docs/HANDOFF.md §3.
 *
 * - House: the Clerk's floor summary, one XML file per legislative day
 *   (clerk.house.gov/floor/YYYYMMDD.xml). A recorded vote appears as an action carrying a link to its
 *   roll call — with the result already in the text, so it is a record of the vote, not an announcement
 *   that it opened.
 * - Senate: senate.gov publishes nothing per action while the Senate sits. What it does publish is the
 *   next convening time (floor_schedule.json), the last meeting's convene/adjourn times (the floor
 *   activity page), and the session's vote list (vote_menu_{congress}_{session}.xml), which names a vote
 *   by number as soon as the LIS lists it.
 */

export type FloorEventKind = "convene" | "adjourn" | "recess" | "vote" | "other";

export interface HouseFloorAction {
  /** The Clerk's `unique-id`; stable across re-publishes of the day, so it dedupes. */
  uniqueId: string;
  /** The Clerk's action code, e.g. H37100 (vote on passage), H20100 (convened). */
  actId: string;
  kind: FloorEventKind;
  /** When the action happened on the floor, local Eastern, "YYYY-MM-DDTHH:mm:ss". */
  occurredAtEastern: string;
  /** When the Clerk last edited the entry, local Eastern, "YYYY-MM-DDTHH:mm". */
  updatedAtEastern: string | null;
  /** The measure as the Clerk prints it ("H. Res. 1650"), when there is one. */
  item: string | null;
  /** The action text with markup removed and entities decoded. */
  text: string;
  /** Set when the action names a roll call ("(Roll no. 319)"). */
  roll: HouseFloorRoll | null;
}

export interface HouseFloorRoll {
  year: number;
  rollNumber: number;
  /** "On agreeing to the resolution", as the floor summary words it. */
  question: string | null;
  /** "Agreed to", "Passed", "Failed", ... */
  result: string | null;
  yea: number | null;
  nay: number | null;
}

export interface HouseFloorDay {
  /** The legislative day, "YYYY-MM-DD". A legislative day can run past midnight. */
  legislativeDay: string;
  congress: number;
  session: number;
  /** True once the Clerk marks the day finished (`<legislative_day_finished>Yes`). */
  finished: boolean;
  /** When the House next meets, local Eastern, "YYYY-MM-DDTHH:mm"; only set once the day is finished. */
  nextConvenesEastern: string | null;
  /** Newest first, as the Clerk lists them. */
  actions: HouseFloorAction[];
}

const houseParser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "@_",
  parseTagValue: false,
  trimValues: true,
  // The description holds HTML links (<a rel="vote" ...>); keep it raw rather than as nested objects.
  stopNodes: ["*.action_description"],
  isArray: (name) => name === "floor_action",
});

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };

/** Removes tags and decodes the entities the Clerk and senate.gov use. */
export function plainText(html: string): string {
  return html
    .replace(/<[^>]*>/g, "")
    .replace(/&#(\d+);/g, (_, n: string) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n: string) => String.fromCodePoint(Number.parseInt(n, 16)))
    .replace(/&(\w+);/g, (m, name: string) => ENTITIES[name] ?? m)
    .replace(/\s+/g, " ")
    .trim();
}

/** "20261110T18:20:53" → "2026-11-10T18:20:53". */
function stamp(compact: string | undefined): string | null {
  const m = /^(\d{4})(\d{2})(\d{2})T(\d{2}:\d{2}(?::\d{2})?)$/.exec((compact ?? "").trim());
  return m ? `${m[1]}-${m[2]}-${m[3]}T${m[4]}` : null;
}

function str(value: unknown): string {
  if (value == null) return "";
  if (typeof value === "object") {
    const t = (value as Record<string, unknown>)["#text"];
    return t == null ? "" : String(t).trim();
  }
  return String(value).trim();
}

// "On agreeing to the resolution Agreed to by recorded vote: 215 - 209 (Roll no. 319)."
// "On passage Passed by the Yeas and Nays: 392 - 18 (Roll no. 323)."
// The result word is case-sensitive (the Clerk capitalises it) and must be followed by how the vote
// was taken or by the roll number, so a question that merely contains "passed" or "ordered" is not
// split there.
const ROLL_TEXT =
  /^(.*?)\s+(Agreed to|Not Agreed to|Passed|Failed|Sustained|Not Sustained|Ordered|Not Ordered)(?:\s+by (?:the Yeas and Nays|a recorded vote|recorded vote)[^:]*:\s*(\d+)\s*-\s*(\d+)|\s*\(Roll no\.)/;

function classify(actId: string, text: string, roll: HouseFloorRoll | null): FloorEventKind {
  if (roll) return "vote";
  if (/^The House convened\b/i.test(text)) return "convene";
  if (/\bdo now recess\b|\bstands in recess\b/i.test(text)) return "recess";
  if (/\b(House adjourned|do now adjourn)\b/i.test(text) && actId === "H61000") return "adjourn";
  return "other";
}

/** Parses one day of the House Clerk's floor summary (clerk.house.gov/floor/YYYYMMDD.xml). */
export function parseHouseFloor(xml: string): HouseFloorDay {
  const doc = houseParser.parse(xml)["legislative_activity"];
  if (!doc) throw new Error("Not a House floor summary document");
  const day = doc["legislative_day"];
  const congressEl = doc["legislative_congress"];
  const date = String(day?.["@_date"] ?? "");
  if (!/^\d{8}$/.test(date)) throw new Error("House floor summary has no legislative day");
  const floor = doc["floor_actions"] ?? {};
  const finishedEl = floor["legislative_day_finished"];
  const finished = str(finishedEl).toLowerCase() === "yes";
  const next = typeof finishedEl === "object" ? stamp(finishedEl?.["@_next-legislative-day-convenes"]) : null;

  const actions: HouseFloorAction[] = ((floor["floor_action"] ?? []) as Record<string, unknown>[]).map((a) => {
    const time = a["action_time"] as Record<string, string> | undefined;
    const raw = String(a["action_description"] ?? "");
    const text = plainText(raw);
    const link = /rollnumber=(\d+)/i.exec(raw);
    const yearLink = /year=(\d{4})/i.exec(raw);
    const rollNo = link ? Number(link[1]) : (/\(Roll no\. (\d+)\)/i.exec(text)?.[1] ?? null);
    let roll: HouseFloorRoll | null = null;
    if (rollNo !== null) {
      const m = ROLL_TEXT.exec(text);
      roll = {
        year: yearLink ? Number(yearLink[1]) : Number(date.slice(0, 4)),
        rollNumber: Number(rollNo),
        question: m?.[1] ? m[1].trim() : null,
        result: m?.[2] ?? null,
        yea: m?.[3] ? Number(m[3]) : null,
        nay: m?.[4] ? Number(m[4]) : null,
      };
    }
    const actId = String(a["@_act-id"] ?? "");
    const item = str(a["action_item"]);
    return {
      uniqueId: String(a["@_unique-id"] ?? ""),
      actId,
      kind: classify(actId, text, roll),
      occurredAtEastern: stamp(time?.["@_for-search"]) ?? "",
      updatedAtEastern: stamp(String(a["@_update-date-time"] ?? "")),
      item: item ? plainText(item) : null,
      text,
      roll,
    };
  });

  // Every vote id is built from these: a file without them would store votes under Congress 0, where
  // no roll call XML ever lands, and they would sit `open` forever.
  const congress = Number(congressEl?.["@_congress"] ?? 0);
  const session = Number(congressEl?.["@_session"] ?? 0);
  if (!Number.isInteger(congress) || congress <= 0) throw new Error("House floor summary has no Congress");
  if (session !== 1 && session !== 2) throw new Error("House floor summary has no session");

  return {
    legislativeDay: `${date.slice(0, 4)}-${date.slice(4, 6)}-${date.slice(6, 8)}`,
    congress,
    session,
    finished,
    nextConvenesEastern: next,
    actions,
  };
}

export interface SenateSchedule {
  /** When the Senate next convenes (or convened, until senate.gov moves on), local Eastern "YYYY-MM-DDTHH:mm". */
  convenesEastern: string;
  /** senate.gov switches its page to "live" this many minutes before convening. */
  offsetMinutes: number;
  /** When senate.gov last edited the file, as an ISO string with offset. */
  lastUpdated: string | null;
}

/** Parses senate.gov's floor schedule (www.senate.gov/legislative/schedule/floor_schedule.json). */
export function parseSenateSchedule(json: string): SenateSchedule {
  const doc = JSON.parse(json) as { floorProceedings?: Record<string, string>[] };
  const p = doc.floorProceedings?.[0];
  if (!p) throw new Error("Senate floor schedule has no floorProceedings");
  const pad = (v: string | undefined) => String(v ?? "").padStart(2, "0");
  const year = String(p["conveneYear"] ?? "");
  if (!/^\d{4}$/.test(year)) throw new Error("Senate floor schedule has no convene year");
  return {
    convenesEastern: `${year}-${pad(p["conveneMonth"])}-${pad(p["conveneDay"])}T${pad(p["conveneHour"])}:${pad(p["conveneMinutes"])}`,
    // senate.gov spells the key "coveneOffsetMinutes"; accept the correct spelling too in case they fix it.
    offsetMinutes: Number(p["coveneOffsetMinutes"] ?? p["conveneOffsetMinutes"] ?? 0),
    lastUpdated: p["lastUpdated"] ?? null,
  };
}

export interface SenateMeeting {
  /** "YYYY-MM-DD". */
  date: string;
  /** The page's own words for the meeting, e.g. "The Senate convened at 12:00 p.m. and adjourned at 4:52 p.m." */
  text: string;
  /** Local Eastern "HH:mm", when the text says so. */
  convenedAt: string | null;
  adjournedAt: string | null;
  /** Local Eastern "HH:mm" for an upcoming meeting ("Convene at 3:00 p.m."). */
  convenesAt: string | null;
}

const MONTH_NUMBER: Record<string, string> = {
  jan: "01", feb: "02", mar: "03", apr: "04", may: "05", jun: "06",
  jul: "07", aug: "08", sep: "09", oct: "10", nov: "11", dec: "12",
};

/** "4:52 p.m." → "16:52"; "noon" → "12:00". */
function clock(text: string | undefined): string | null {
  if (!text) return null;
  if (/^noon$/i.test(text.trim())) return "12:00";
  const m = /^(\d{1,2})(?::(\d{2}))?\s*([ap])\.?m\.?$/i.exec(text.trim());
  if (!m) return null;
  let hour = Number(m[1]) % 12;
  if (m[3]!.toLowerCase() === "p") hour += 12;
  return `${String(hour).padStart(2, "0")}:${m[2] ?? "00"}`;
}

const TIME = String.raw`(\d{1,2}(?::\d{2})?\s*[ap]\.?m\.?|noon)`;

/**
 * Reads the meeting blocks from senate.gov's floor activity page
 * (www.senate.gov/legislative/floor_activity_pail.htm): the next meeting ("Convene at 3:00 p.m.")
 * and the previous one ("The Senate convened at 12:00 p.m. and adjourned at 4:52 p.m.").
 *
 * Throws when the page has no meeting block: senate.gov answers a missing or broken page with a 200
 * and an error page (lesson 42), and "no meetings" must read as "unknown", not "nothing adjourned".
 */
export function parseSenateFloorActivity(html: string): SenateMeeting[] {
  const meetings: SenateMeeting[] = [];
  const block = /<b>\s*\w+day,\s+(\w{3})\w*\s+(\d{1,2}),\s+(\d{4})\s*<\/b>([\s\S]*?)(?=<b>\s*\w+day,|<\/table>)/g;
  for (const m of html.matchAll(block)) {
    const month = MONTH_NUMBER[m[1]!.toLowerCase()];
    if (!month) continue;
    const body = plainText(m[4]!.replace(/<i>[\s\S]*?<\/i>/g, ""));
    meetings.push({
      date: `${m[3]}-${month}-${m[2]!.padStart(2, "0")}`,
      text: body,
      convenedAt: clock(new RegExp(String.raw`convened at ${TIME}`, "i").exec(body)?.[1]),
      adjournedAt: clock(new RegExp(String.raw`adjourned at ${TIME}`, "i").exec(body)?.[1]),
      convenesAt: clock(new RegExp(String.raw`^Convene at ${TIME}`, "i").exec(body)?.[1]),
    });
  }
  if (meetings.length === 0) throw new Error("Senate floor activity page has no meeting blocks");
  return meetings;
}

export interface SenateMenuVote {
  rollNumber: number;
  /** "YYYY-MM-DD". The menu gives no time of day. */
  date: string;
  /** "PN1181-7", "S. 1234", or empty for a procedural vote. */
  issue: string | null;
  question: string;
  result: string;
  yeas: number;
  nays: number;
  title: string;
}

export interface SenateVoteMenu {
  congress: number;
  session: number;
  year: number;
  /** Newest first, as senate.gov lists them. */
  votes: SenateMenuVote[];
}

const menuParser = new XMLParser({ parseTagValue: false, trimValues: true, isArray: (name) => name === "vote" });

/** Parses the Senate's vote list (senate.gov/legislative/LIS/roll_call_lists/vote_menu_{congress}_{session}.xml). */
export function parseSenateVoteMenu(xml: string): SenateVoteMenu {
  const doc = menuParser.parse(xml)["vote_summary"];
  if (!doc) throw new Error("Not a Senate vote menu");
  const year = Number(str(doc["congress_year"]));
  const raw = (doc["votes"]?.["vote"] ?? []) as Record<string, unknown>[];
  const monthOf = (v: Record<string, unknown>) =>
    MONTH_NUMBER[(str(v["vote_date"]).split("-")[1] ?? "").slice(0, 3).toLowerCase()] ?? "01";
  // The menu dates a vote "12-Nov", with no year. A second session can sit until January 3, so its
  // early-January votes come after December's and belong to the next year: walking oldest to newest,
  // a January vote after any later month is `year + 1`.
  const yearOf = new Map<Record<string, unknown>, number>();
  let pastJanuary = false;
  for (const v of [...raw].sort((a, b) => Number(str(a["vote_number"])) - Number(str(b["vote_number"])))) {
    const month = monthOf(v);
    if (month !== "01") pastJanuary = true;
    yearOf.set(v, month === "01" && pastJanuary ? year + 1 : year);
  }
  const votes = raw.map((v) => {
    const [day] = str(v["vote_date"]).split("-"); // "12-Nov"
    const tally = (v["vote_tally"] ?? {}) as Record<string, unknown>;
    return {
      rollNumber: Number(str(v["vote_number"])),
      date: `${yearOf.get(v) ?? year}-${monthOf(v)}-${(day ?? "").padStart(2, "0")}`,
      issue: str(v["issue"]) || null,
      question: plainText(str(v["question"])),
      result: str(v["result"]),
      yeas: Number(str(tally["yeas"]) || 0),
      nays: Number(str(tally["nays"]) || 0),
      title: plainText(str(v["title"])),
    };
  });
  return { congress: Number(str(doc["congress"])), session: Number(str(doc["session"])), year, votes };
}

/* ---- Eastern time ---- */

const easternFormat = new Intl.DateTimeFormat("en-US", {
  timeZone: "America/New_York",
  hourCycle: "h23",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
});

/** The wall-clock time in Washington at `at`, as "YYYY-MM-DDTHH:mm:ss". */
export function easternWallClock(at: Date): string {
  const p = Object.fromEntries(easternFormat.formatToParts(at).map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}:${p.second}`;
}

/** Minutes Washington is ahead of UTC at `at` (−300 in winter, −240 in summer). */
function easternOffsetMinutes(at: Date): number {
  const wall = new Date(`${easternWallClock(at)}Z`);
  return Math.round((wall.getTime() - at.getTime()) / 60_000);
}

/** The instant a Washington wall-clock time ("YYYY-MM-DDTHH:mm[:ss]") names. */
export function easternToDate(local: string): Date {
  const full = /T\d{2}:\d{2}$/.test(local) ? `${local}:00` : local.includes("T") ? local : `${local}T00:00:00`;
  const asUtc = new Date(`${full}Z`);
  if (Number.isNaN(asUtc.getTime())) throw new Error(`Not an Eastern time: ${local}`);
  // Two passes: the first guess can land on the other side of a daylight-saving switch.
  let at = new Date(asUtc.getTime() - easternOffsetMinutes(asUtc) * 60_000);
  at = new Date(asUtc.getTime() - easternOffsetMinutes(at) * 60_000);
  return at;
}

/**
 * The Congress and session sitting on a date. A Congress starts on January 3 of an odd year, so
 * January 1-2 of an odd year still belong to the outgoing Congress's second session.
 */
export function congressSessionOn(at: Date): { congress: number; session: number } {
  const [y, m, d] = easternWallClock(at).slice(0, 10).split("-").map(Number) as [number, number, number];
  const beforeJan3 = m === 1 && d < 3;
  const year = beforeJan3 ? y - 1 : y;
  const congress = Math.floor((year - 1789) / 2) + 1;
  return { congress, session: (year - 1789) % 2 === 0 ? 1 : 2 };
}
