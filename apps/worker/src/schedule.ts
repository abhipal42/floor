import {
  SENATE_SESSION_DAYS_URL,
  addWeeks,
  congressSessionOn,
  easternToDate,
  easternWallClock,
  houseWeeklyUrl,
  isHouseWeeklyNotFound,
  parseHouseWeekly,
  parseSenateProgram,
  parseSenateSessionDays,
  weekOfEastern,
  type HouseWeekly,
  type SenateNextConvene,
  type SenateProgram,
} from "@floor/shared";
import { billId, list, parseMeasureRef, type CongressGet, type Json } from "./bills.js";
import { errorText, startRun, type Db } from "./db.js";
import type { FetchText } from "./rollcalls.js";

/*
 * The week-ahead schedule. Runs hourly with the other ingests.
 *
 * - House (`floor_schedule`): the Clerk's weekly list, this week and next.
 * - Senate (`senate_meetings`, plus `floor_schedule` rows for the measures its program names): the
 *   next convening from senate.gov's session-day file, and the Daily Digest's program for that day
 *   from the latest Congressional Record (Congress.gov lists the issue; the text is read from
 *   govinfo). The Senate publishes no list like the House's (docs/HANDOFF.md §3, the schedule lesson).
 */

/** The bill a schedule item names ("H.R. 5267" → "119-hr-5267"), or null for a placeholder or a non-bill. */
export function scheduleBillId(congress: number, legisNum: string): string | null {
  const ref = parseMeasureRef(legisNum);
  return ref?.kind === "bill" ? billId(congress, ref.type, ref.number) : null;
}

const instant = (eastern: string | null) => (eastern ? easternToDate(eastern).toISOString() : null);

/**
 * Stores one week of the House schedule. Items still on the list are upserted (an item that comes
 * back after being pulled loses its `removed_at`); items no longer in the file are marked removed
 * now, never deleted. `bill_id` is resolved against `bills` on every run.
 */
export async function upsertHouseWeek(db: Db, week: HouseWeekly): Promise<{ items: number; removed: number }> {
  const rows = week.items.map((it) => ({
    item_id: it.itemId,
    category: it.category,
    category_text: it.categoryText,
    legis_num: it.legisNum,
    bill_ref: scheduleBillId(week.congress, it.legisNum),
    title: it.floorText,
    sort_order: it.sortOrder,
    added_at: instant(it.addedAtEastern),
    removed_at: instant(it.removedAtEastern),
  }));
  const updated = instant(week.updatedAtEastern);
  if (rows.length > 0) {
    await db.query(
      `insert into floor_schedule (chamber, week_of, item_id, category, category_text, legis_num, bill_id, title,
                                   sort_order, added_at, removed_at, source_updated_at, updated_at)
       select 'house', $1::date, x.item_id, x.category, x.category_text, x.legis_num, b.id, x.title,
              x.sort_order, x.added_at, x.removed_at, $3::timestamptz, now()
         from jsonb_to_recordset($2::jsonb) as x(
                item_id text, category text, category_text text, legis_num text, bill_ref text, title text,
                sort_order integer, added_at timestamptz, removed_at timestamptz)
         left join bills b on b.id = x.bill_ref
       on conflict (chamber, week_of, item_id) do update set
         category = excluded.category, category_text = excluded.category_text, legis_num = excluded.legis_num,
         bill_id = excluded.bill_id, title = excluded.title, sort_order = excluded.sort_order,
         added_at = excluded.added_at, removed_at = excluded.removed_at,
         source_updated_at = excluded.source_updated_at, updated_at = now()`,
      [week.weekOf, JSON.stringify(rows), updated],
    );
  }
  const { rows: gone } = await db.query<{ n: number }>(
    `with u as (
       update floor_schedule set removed_at = now(), source_updated_at = coalesce($3::timestamptz, source_updated_at),
                                 updated_at = now()
        where chamber = 'house' and week_of = $1::date and removed_at is null and not (item_id = any($2::text[]))
       returning 1)
     select count(*)::int as n from u`,
    [week.weekOf, rows.map((r) => r.item_id), updated],
  );
  return { items: rows.length, removed: gone[0]?.n ?? 0 };
}

/**
 * Fetches one week of the House schedule; null when docs.house.gov has none for it (not published
 * yet, or a week the House is out). Anything else that is not a schedule throws.
 */
export async function fetchHouseWeek(fetchText: FetchText, weekOf: string): Promise<HouseWeekly | null> {
  const res = await fetchText(houseWeeklyUrl(weekOf));
  if (res.status === 404) return null;
  if (res.status !== 200) throw new Error(`House floor schedule for ${weekOf}: HTTP ${res.status}`);
  if (isHouseWeeklyNotFound(res.text)) return null;
  const week = parseHouseWeekly(res.text);
  if (week.weekOf !== weekOf) throw new Error(`House floor schedule for ${weekOf} is for ${week.weekOf}`);
  return week;
}

/** The Washington calendar day of an instant: "YYYY-MM-DD". */
const easternDay = (iso: string) => easternWallClock(new Date(iso)).slice(0, 10);

/** Records the Senate's next convening. A program already stored for that day is kept. */
export async function upsertSenateConvene(db: Db, next: SenateNextConvene): Promise<string> {
  const day = easternDay(next.convenesAt);
  await db.query(
    `insert into senate_meetings (meeting_date, convenes_at, pro_forma, source_updated_at, updated_at)
     values ($1::date, $2::timestamptz, $3, $4::timestamptz, now())
     on conflict (meeting_date) do update set convenes_at = excluded.convenes_at, pro_forma = excluded.pro_forma,
       source_updated_at = greatest(senate_meetings.source_updated_at, excluded.source_updated_at), updated_at = now()`,
    [day, next.convenesAt, next.proForma, next.updatedAt],
  );
  return day;
}

/**
 * Records a day's Daily Digest program, and the measures it names as that day's `floor_schedule`
 * items. A measure a later printing of the program no longer names is marked removed.
 */
export async function upsertSenateProgram(
  db: Db,
  program: SenateProgram,
  issue: { id: string; updatedAt: string | null },
): Promise<{ items: number; removed: number }> {
  await db.query(
    `insert into senate_meetings (meeting_date, digest_heading, program, record_issue, source_updated_at, updated_at)
     values ($1::date, $2, $3, $4, $5::timestamptz, now())
     on conflict (meeting_date) do update set digest_heading = excluded.digest_heading, program = excluded.program,
       record_issue = excluded.record_issue,
       source_updated_at = greatest(senate_meetings.source_updated_at, excluded.source_updated_at), updated_at = now()`,
    [program.date, program.heading, program.program, issue.id, issue.updatedAt],
  );
  const { congress } = congressSessionOn(easternToDate(`${program.date}T12:00`));
  const weekOf = weekOfEastern(easternToDate(`${program.date}T12:00`));
  const rows = program.measures.map((legisNum, i) => {
    const ref = scheduleBillId(congress, legisNum);
    return {
      item_id: `${program.date}:${ref ? ref.split("-").slice(1).join("") : legisNum}`,
      legis_num: legisNum,
      bill_ref: ref,
      sort_order: i + 1,
    };
  });
  if (rows.length > 0) {
    await db.query(
      `insert into floor_schedule (chamber, week_of, item_id, category, category_text, legis_num, bill_id, title,
                                   sort_order, added_at, removed_at, source_updated_at, updated_at)
       select 'senate', $1::date, x.item_id, 'other', $3, x.legis_num, b.id,
              coalesce(b.short_title, b.title, x.legis_num), x.sort_order, now(), null, $4::timestamptz, now()
         from jsonb_to_recordset($2::jsonb) as x(item_id text, legis_num text, bill_ref text, sort_order integer)
         left join bills b on b.id = x.bill_ref
       on conflict (chamber, week_of, item_id) do update set
         legis_num = excluded.legis_num, bill_id = excluded.bill_id, title = excluded.title,
         category_text = excluded.category_text, sort_order = excluded.sort_order, removed_at = null,
         source_updated_at = excluded.source_updated_at, updated_at = now()`,
      [weekOf, JSON.stringify(rows), `Named in the Daily Digest's program for ${program.heading}`, issue.updatedAt],
    );
  }
  const { rows: gone } = await db.query<{ n: number }>(
    `with u as (
       update floor_schedule set removed_at = now(), updated_at = now()
        where chamber = 'senate' and week_of = $1::date and item_id like $2 and removed_at is null
          and not (item_id = any($3::text[]))
       returning 1)
     select count(*)::int as n from u`,
    [weekOf, `${program.date}:%`, rows.map((r) => r.item_id)],
  );
  return { items: rows.length, removed: gone[0]?.n ?? 0 };
}

/** govinfo's copy of a Congressional Record granule, from the Congress.gov "Formatted Text" link. */
export function govinfoGranuleUrl(congressGovUrl: string): string | null {
  const m = /\/(CREC-(\d{4}-\d{2}-\d{2})-[^/]+\.htm)$/.exec(congressGovUrl);
  return m ? `https://www.govinfo.gov/content/pkg/CREC-${m[2]}/html/${m[1]}` : null;
}

/**
 * The latest Congressional Record's Senate program: which issue, and the Digest's "Next Meeting of
 * the SENATE" block. Null when the latest issue has no such article (the Senate set no next meeting).
 */
export async function fetchSenateProgram(
  get: CongressGet,
  fetchText: FetchText,
): Promise<{ program: SenateProgram; issue: { id: string; updatedAt: string | null } } | null> {
  const latest = list((await get("/daily-congressional-record?limit=1"))["dailyCongressionalRecord"])[0];
  if (!latest) throw new Error("Congress.gov lists no Congressional Record issue");
  const volume = String(latest["volumeNumber"] ?? "");
  const number = String(latest["issueNumber"] ?? "");
  const issueDate = String(latest["issueDate"] ?? "").slice(0, 10);
  if (!volume || !number || !/^\d{4}-\d{2}-\d{2}$/.test(issueDate)) throw new Error("Congress.gov issue has no volume, number or date");
  const articles = await get(`/daily-congressional-record/${volume}/${number}/articles?limit=250`);
  const digest = list(articles["articles"]).find((s) => s["name"] === "Daily Digest");
  const article = list(digest?.["sectionArticles"]).find((a) =>
    /^Daily Digest\/Next Meeting of the SENATE/i.test(String(a["title"] ?? "")),
  );
  if (!article) return null;
  const text = list(article["text"]).find((t: Json) => t["type"] === "Formatted Text");
  const url = govinfoGranuleUrl(String(text?.["url"] ?? ""));
  if (!url) throw new Error(`Record ${volume}/${number}: the Senate meeting article has no text link`);
  const res = await fetchText(url);
  if (res.status !== 200) throw new Error(`Record ${volume}/${number} Daily Digest: HTTP ${res.status} from govinfo`);
  const program = parseSenateProgram(res.text, issueDate);
  if (!program) return null;
  return { program, issue: { id: `${volume}/${number}`, updatedAt: (latest["updateDate"] as string | undefined) ?? null } };
}

/**
 * House this week and next, then the Senate, recorded as one `schedule` run. The parts are
 * independent: one failing still runs the others, and the run records the failure as its error.
 * Without `congress` (no CONGRESS_API_KEY) the Senate's program is skipped; its convening is not.
 */
export async function ingestSchedule(
  db: Db,
  fetchText: FetchText,
  opts: { now?: Date; congress?: CongressGet; log?: (msg: string) => void } = {},
): Promise<{ weeks: number; items: number; removed: number; senateMeeting: string | null; senateProgram: string | null }> {
  const finish = await startRun(db, "schedule");
  let weeks = 0;
  let items = 0;
  let removed = 0;
  let senateMeeting: string | null = null;
  let senateProgram: string | null = null;
  const errors: string[] = [];
  const part = async (name: string, fn: () => Promise<void>) => {
    try {
      await fn();
    } catch (err) {
      errors.push(`${name}: ${errorText(err)}`);
      opts.log?.(`${name}: ${errorText(err)}`);
    }
  };
  const current = weekOfEastern(opts.now ?? new Date());
  for (const weekOf of [current, addWeeks(current, 1)]) {
    await part(`house ${weekOf}`, async () => {
      const week = await fetchHouseWeek(fetchText, weekOf);
      if (!week) {
        opts.log?.(`house ${weekOf}: no schedule published`);
        return;
      }
      const r = await upsertHouseWeek(db, week);
      weeks++;
      items += r.items;
      removed += r.removed;
      opts.log?.(`house ${weekOf}: ${r.items} items, ${r.removed} newly removed`);
    });
  }
  await part("senate convening", async () => {
    const res = await fetchText(SENATE_SESSION_DAYS_URL);
    if (res.status !== 200) throw new Error(`HTTP ${res.status}`);
    const next = parseSenateSessionDays(res.text);
    if (!next) {
      opts.log?.("senate: no next convening published");
      return;
    }
    senateMeeting = await upsertSenateConvene(db, next);
    items++;
    opts.log?.(`senate: convenes ${next.convenesAt}${next.proForma ? " (pro forma)" : ""}`);
  });
  if (opts.congress) {
    const get = opts.congress;
    await part("senate program", async () => {
      const found = await fetchSenateProgram(get, fetchText);
      if (!found) {
        opts.log?.("senate: the latest Record has no Senate program");
        return;
      }
      const r = await upsertSenateProgram(db, found.program, found.issue);
      senateProgram = found.program.date;
      items += r.items;
      removed += r.removed;
      opts.log?.(`senate ${found.program.date}: program from Record ${found.issue.id}, ${r.items} measures`);
    });
  }
  await finish(items, errors.length ? errors.join("; ") : undefined);
  if (errors.length) throw new Error(errors.join("; "));
  return { weeks, items, removed, senateMeeting, senateProgram };
}
