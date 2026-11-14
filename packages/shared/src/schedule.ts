import { XMLParser } from "fast-xml-parser";
import { easternWallClock, plainText } from "./floor.js";

/*
 * The House's weekly floor schedule: the Majority Leader's list of what may come up, published by the
 * Clerk at docs.house.gov/floor/Download.aspx?file=/billsthisweek/YYYYMMDD/YYYYMMDD.xml (YYYYMMDD = the
 * Monday). Each item sits in a category ("Items that may be considered under suspension of the rules",
 * "... pursuant to a rule", "Items that may be considered"), carries its own add-date, and gets a
 * remove-date when it is taken off. A week that has no file is answered with an HTML "File Not Found"
 * page and HTTP 200.
 *
 * The Senate publishes no such list. What it does publish, officially and in a form a parser can
 * trust, is two things (docs/HANDOFF.md §3, the schedule lesson):
 *
 * - When it next convenes: senate.gov's session-day file (legislative/schedule/floor_schedule.xml),
 *   one entry per day this session with `NextConveneDate` and `IsNextConveneProforma`, updated about a
 *   minute after the Senate adjourns.
 * - What it plans to do then: the Daily Digest's "Next Meeting of the SENATE" paragraph ("Program for
 *   Monday: Senate will resume consideration of ..."), written prose in the Congressional Record. It is
 *   published the morning after the day it describes, so it lags the convene time by about 16 hours.
 */

export type ScheduleCategory = "suspension" | "rule" | "other";

export interface HouseWeeklyItem {
  /** The Clerk's `floor-item id`; stable while the item stays on the week's list. */
  itemId: string;
  category: ScheduleCategory;
  /** The category as the Clerk words it. */
  categoryText: string;
  /** "H.R. 5267", "H. Res. 1650", or a placeholder such as "H. Res. ___" for a resolution not yet numbered. */
  legisNum: string;
  /** The Clerk's description: usually the bill's short title, sometimes its long title. */
  floorText: string;
  /** Local Eastern "YYYY-MM-DDTHH:mm:ss(.sss)". */
  addedAtEastern: string | null;
  /** Set when the item was taken off the week's list. Local Eastern. */
  removedAtEastern: string | null;
  sortOrder: number;
}

export interface HouseWeekly {
  /** The Monday, "YYYY-MM-DD". */
  weekOf: string;
  congress: number;
  /** When the Clerk last edited the week, local Eastern. */
  updatedAtEastern: string | null;
  items: HouseWeeklyItem[];
}

export const houseWeeklyUrl = (weekOf: string) => {
  const d = weekOf.replaceAll("-", "");
  return `https://docs.house.gov/floor/Download.aspx?file=/billsthisweek/${d}/${d}.xml`;
};

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "@_",
  parseTagValue: false,
  parseAttributeValue: false,
  trimValues: true,
  isArray: (name) => name === "category" || name === "floor-item",
});

/** True for the page docs.house.gov serves (with HTTP 200) for a week it has no schedule for. */
export function isHouseWeeklyNotFound(body: string): boolean {
  return !/<floorschedule\b/.test(body) && /requested file was not found/i.test(body);
}

export function scheduleCategory(text: string): ScheduleCategory {
  if (/suspension of the rules/i.test(text)) return "suspension";
  if (/pursuant to a rule/i.test(text)) return "rule";
  return "other";
}

const local = (value: unknown): string | null => {
  const s = String(value ?? "").trim();
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(s) ? s : null;
};

const text = (value: unknown): string => {
  if (value == null) return "";
  if (typeof value === "object") return plainText(String((value as Record<string, unknown>)["#text"] ?? ""));
  return plainText(String(value));
};

/** Parses one week of the House floor schedule. Throws on anything that is not one. */
export function parseHouseWeekly(xml: string): HouseWeekly {
  const doc = parser.parse(xml)["floorschedule"];
  if (!doc) throw new Error("Not a House floor schedule document");
  const weekOf = String(doc["@_week-date"] ?? "");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(weekOf)) throw new Error("House floor schedule has no week-date");
  const congress = Number(doc["@_congress-num"] ?? 0);
  if (!Number.isInteger(congress) || congress <= 0) throw new Error("House floor schedule has no Congress");

  const items: HouseWeeklyItem[] = [];
  for (const cat of (doc["category"] ?? []) as Record<string, unknown>[]) {
    const categoryText = String(cat["@_type"] ?? "").trim();
    const list = ((cat["floor-items"] as Record<string, unknown> | undefined)?.["floor-item"] ?? []) as Record<string, unknown>[];
    for (const it of list) {
      const itemId = String(it["@_id"] ?? "").trim();
      if (!itemId) continue;
      items.push({
        itemId,
        category: scheduleCategory(categoryText),
        categoryText,
        legisNum: text(it["legis-num"]),
        // The Clerk appends ", as amended" to a suspension's title; it is part of what will be considered.
        floorText: text(it["floor-text"]),
        addedAtEastern: local(it["@_add-date"]),
        removedAtEastern: local(it["@_remove-date"]),
        sortOrder: Number(it["@_sort-order"] ?? 0) || 0,
      });
    }
  }
  return { weekOf, congress, updatedAtEastern: local(doc["@_update-date"]), items };
}

const sessionParser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "@_",
  parseTagValue: false,
  trimValues: true,
  isArray: (name) => name === "LegislativeDay" || name === "SessionDay",
});

export const SENATE_SESSION_DAYS_URL = "https://www.senate.gov/legislative/schedule/floor_schedule.xml";

export interface SenateNextConvene {
  /** ISO 8601 with offset, as senate.gov writes it: "2026-11-16T15:00:00-05:00". */
  convenesAt: string;
  /** A pro forma session: the Senate meets for seconds and does no business. */
  proForma: boolean;
  /** When senate.gov last edited that session day, ISO 8601 with offset. */
  updatedAt: string | null;
}

/**
 * The Senate's next convening, from its session-day file: the `NextConveneDate` of the session day
 * senate.gov edited last. Null when the file names no next convening (the last day of a session).
 */
export function parseSenateSessionDays(xml: string): SenateNextConvene | null {
  const doc = sessionParser.parse(xml)["CongressSessionDayConvenings"];
  if (!doc) throw new Error("Not a Senate session-day file");
  let latest: { next: string; proForma: boolean; updated: string } | null = null;
  for (const day of (doc["LegislativeDay"] ?? []) as Record<string, unknown>[]) {
    for (const sd of (day["SessionDay"] ?? []) as Record<string, unknown>[]) {
      const next = String(sd["NextConveneDate"] ?? "").trim();
      const updated = String(sd["LastUpdateDate"] ?? sd["ConveneDate"] ?? "").trim();
      if (!next || Number.isNaN(Date.parse(next))) continue;
      if (!latest || Date.parse(updated) > Date.parse(latest.updated)) {
        latest = { next, proForma: String(sd["IsNextConveneProforma"] ?? "").trim().toUpperCase() === "Y", updated };
      }
    }
  }
  if (!latest) return null;
  return { convenesAt: latest.next, proForma: latest.proForma, updatedAt: latest.updated || null };
}

export interface SenateProgram {
  /** The day the program is for, "YYYY-MM-DD". */
  date: string;
  /** The Digest's own heading for the meeting: "3 p.m., Monday, November 16". */
  heading: string;
  /** The program as the Digest words it, whitespace collapsed. Null when it gives none. */
  program: string | null;
  /** Bills and resolutions the program names, as printed ("H.R. 2347"), in order, once each. */
  measures: string[];
}

const MONTHS = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];

// "H.R. 2347", "S. 1582", "H.J. Res. 12", "S.Con.Res. 3", "H. Res. 1650". Not preceded by a letter or a
// dot, so "U.S. 5" is not read as S. 5.
const MEASURE = /(?<![A-Za-z.])(H\.\s?R\.|S\.|H\.\s?J\.\s?Res\.|S\.\s?J\.\s?Res\.|H\.\s?Con\.\s?Res\.|S\.\s?Con\.\s?Res\.|H\.\s?Res\.|S\.\s?Res\.)\s?(\d+)/g;

/**
 * Reads the "Next Meeting of the SENATE" block of a Daily Digest article. `issueDate` ("YYYY-MM-DD",
 * the Record's date) supplies the year the heading leaves out. Null when the article has no Senate
 * meeting block (the Senate set no next meeting, or this is not that article).
 */
export function parseSenateProgram(html: string, issueDate: string): SenateProgram | null {
  const raw = html.replace(/<[^>]*>/g, "").replace(/\r/g, "");
  const block = /Next Meeting of the SENATE\s*\n\s*([^\n]+)([\s\S]*?)(?=Next Meeting of the HOUSE|_{10,}|$)/.exec(raw);
  if (!block) return null;
  const heading = plainText(block[1]!);
  const day = /\b(january|february|march|april|may|june|july|august|september|october|november|december)\s+(\d{1,2})\b/i.exec(heading);
  if (!day) throw new Error(`Daily Digest Senate meeting has no date: ${heading}`);
  const month = MONTHS.indexOf(day[1]!.toLowerCase()) + 1;
  const [issueYear, issueMonth] = issueDate.split("-").map(Number) as [number, number];
  // A December issue announcing a January meeting is for the next year.
  const year = month < issueMonth ? issueYear + 1 : issueYear;
  const date = `${year}-${String(month).padStart(2, "0")}-${day[2]!.padStart(2, "0")}`;
  const prog = /Program for [^:]+:\s*([\s\S]*)$/.exec(block[2]!);
  const program = prog ? plainText(prog[1]!) || null : null;
  const measures: string[] = [];
  for (const m of (program ?? "").matchAll(MEASURE)) {
    const label = `${m[1]!.replace(/\s+/g, " ")} ${m[2]}`;
    if (!measures.includes(label)) measures.push(label);
  }
  return { date, heading, program, measures };
}

/** The Monday of the week `at` falls in, in Washington: "YYYY-MM-DD". */
export function weekOfEastern(at: Date): string {
  const day = easternWallClock(at).slice(0, 10);
  const d = new Date(`${day}T12:00:00Z`);
  const back = (d.getUTCDay() + 6) % 7; // Monday = 0
  d.setUTCDate(d.getUTCDate() - back);
  return d.toISOString().slice(0, 10);
}

/** The Monday `weeks` weeks after the Monday `weekOf`. */
export function addWeeks(weekOf: string, weeks: number): string {
  const d = new Date(`${weekOf}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + weeks * 7);
  return d.toISOString().slice(0, 10);
}
