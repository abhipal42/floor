import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { SENATE_SESSION_DAYS_URL, houseWeeklyUrl } from "@floor/shared";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { CongressGet } from "./bills.js";
import type { Db } from "./db.js";
import type { FetchText } from "./rollcalls.js";
import { govinfoGranuleUrl, ingestSchedule, scheduleBillId } from "./schedule.js";

const here = dirname(fileURLToPath(import.meta.url));
const read = (p: string) => readFileSync(join(here, p), "utf8");
const shared = (name: string) => read(`../../../packages/shared/fixtures/${name}`);
const week16 = shared("house-weekly-20261116.xml");
const notFound = shared("house-weekly-not-found.html");
const sessionDays = shared("senate-session-days-119-2.xml");
const digest = shared("digest-next-meeting-20261112.htm");
const recordList = JSON.parse(read("../fixtures/congress/record/daily-record-list.json")) as Record<string, unknown>;
const recordArticles = JSON.parse(read("../fixtures/congress/record/daily-record-172-171-articles.json")) as Record<string, unknown>;
const DIGEST_URL = "https://www.govinfo.gov/content/pkg/CREC-2026-11-12/html/CREC-2026-11-12-pt1-PgD1019-5.htm";

// Saturday 2026-11-14 in Washington: "this week" is the week of 11-09 (no file served here), next is 11-16.
const NOW = new Date("2026-11-14T17:00:00Z");

let pg: PGlite;
let db: Db;
let pages: Record<string, { status: number; text: string }>;
const fetched: string[] = [];
const fetchText: FetchText = async (url) => {
  fetched.push(url);
  return pages[url] ?? { status: 404, text: "" };
};
const congress: CongressGet = async (path) => {
  if (path === "/daily-congressional-record?limit=1") return recordList;
  if (path === "/daily-congressional-record/172/171/articles?limit=250") return recordArticles;
  throw new Error(`unexpected ${path}`);
};

beforeAll(async () => {
  pg = new PGlite();
  await pg.exec(`
    create schema auth;
    create table auth.users (id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
  `);
  for (const m of loadMigrations()) await pg.exec(m.sql);
  db = pg as unknown as Db;
  await pg.exec(`
    insert into bills (id, congress, bill_type, number, title, short_title) values
      ('119-hr-5267', 119, 'hr', 5267, 'To amend title 10 ...', 'Example Short Title Act'),
      ('119-hr-2347', 119, 'hr', 2347, 'To amend the Internal Revenue Code ...', 'Survivor Justice Tax Prevention Act');
  `);
});

beforeEach(async () => {
  await pg.exec("delete from floor_schedule; delete from senate_meetings; delete from ingest_runs;");
  fetched.length = 0;
  pages = {
    [houseWeeklyUrl("2026-11-09")]: { status: 200, text: notFound },
    [houseWeeklyUrl("2026-11-16")]: { status: 200, text: week16 },
    [SENATE_SESSION_DAYS_URL]: { status: 200, text: sessionDays },
    [DIGEST_URL]: { status: 200, text: digest },
  };
});

type ScheduleRow = {
  chamber: string;
  item_id: string;
  category: string;
  legis_num: string;
  bill_id: string | null;
  title: string;
  removed_at: Date | null;
  added_at: Date | null;
};
const rows = async (chamber: string) =>
  (
    await pg.query<ScheduleRow>(
      `select chamber, item_id, category, legis_num, bill_id, title, removed_at, added_at
         from floor_schedule where chamber = $1 order by sort_order, item_id`,
      [chamber],
    )
  ).rows;

describe("schedule bill ids", () => {
  it.each([
    ["H.R. 5267", "119-hr-5267"],
    ["H. Res. 1650", "119-hres-1650"],
    ["S.J.Res. 12", "119-sjres-12"],
    ["H. Res. ___", null],
  ])("%s is %s", (legisNum, id) => {
    expect(scheduleBillId(119, legisNum)).toBe(id);
  });

  it("finds govinfo's copy of a Record granule", () => {
    expect(govinfoGranuleUrl("https://www.congress.gov/119/crec/2026/11/12/172/171/modified/CREC-2026-11-12-pt1-PgD1019-5.htm")).toBe(
      DIGEST_URL,
    );
    expect(govinfoGranuleUrl("https://example.com/other.htm")).toBeNull();
  });
});

describe("ingestSchedule", () => {
  it("stores the House week, skips a week with no file, and links bills it has", async () => {
    const result = await ingestSchedule(db, fetchText, { now: NOW, congress, log: () => {} });
    expect(result).toMatchObject({ weeks: 1, senateMeeting: "2026-11-16", senateProgram: "2026-11-16" });
    expect(fetched).toContain(houseWeeklyUrl("2026-11-09"));
    const house = await rows("house");
    expect(house).toHaveLength(15);
    expect(house.filter((r) => r.category === "suspension")).toHaveLength(13);
    const rule = house.find((r) => r.legis_num === "H.R. 5267")!;
    expect(rule).toMatchObject({ category: "rule", bill_id: "119-hr-5267", removed_at: null });
    // A bill not in `bills` yet stays unlinked rather than pointing at nothing.
    expect(house.find((r) => r.legis_num === "H.R. 7254")?.bill_id).toBeNull();
    // add-date is Eastern: 10:29 a.m. EST is 15:29 UTC.
    expect(house[0]!.added_at?.toISOString()).toBe("2026-11-11T15:29:14.330Z");
    const { rows: runs } = await pg.query<{ source: string; items: number; error: string | null }>(
      "select source, items, error from ingest_runs",
    );
    expect(runs).toEqual([{ source: "schedule", items: 15 + 1 + 1, error: null }]);
  });

  it("marks an item removed when it leaves the file, and clears that when it comes back", async () => {
    await ingestSchedule(db, fetchText, { now: NOW, log: () => {} });
    const without = week16.replace(/<floor-item id="409832"[\s\S]*?<\/floor-item>/, "");
    pages[houseWeeklyUrl("2026-11-16")] = { status: 200, text: without };
    const second = await ingestSchedule(db, fetchText, { now: NOW, log: () => {} });
    expect(second.removed).toBe(1);
    expect((await rows("house")).find((r) => r.item_id === "409832")?.removed_at).not.toBeNull();

    pages[houseWeeklyUrl("2026-11-16")] = { status: 200, text: week16 };
    await ingestSchedule(db, fetchText, { now: NOW, log: () => {} });
    expect((await rows("house")).find((r) => r.item_id === "409832")?.removed_at).toBeNull();
  });

  it("takes the House's own remove-date", async () => {
    pages[houseWeeklyUrl("2026-11-16")] = {
      status: 200,
      text: week16.replace(
        'id="409832" add-date="2026-11-11T10:29:34.797" remove-date=""',
        'id="409832" add-date="2026-11-11T10:29:34.797" remove-date="2026-11-13T09:00:00.000"',
      ),
    };
    await ingestSchedule(db, fetchText, { now: NOW, log: () => {} });
    expect((await rows("house")).find((r) => r.item_id === "409832")?.removed_at?.toISOString()).toBe("2026-11-13T14:00:00.000Z");
  });

  it("stores the Senate's next convening and the Digest's program, and the measures it names", async () => {
    await ingestSchedule(db, fetchText, { now: NOW, congress, log: () => {} });
    const { rows: meetings } = await pg.query<Record<string, unknown>>(
      "select meeting_date::text as day, convenes_at, pro_forma, digest_heading, record_issue, program from senate_meetings",
    );
    expect(meetings).toHaveLength(1);
    expect(meetings[0]).toMatchObject({
      day: "2026-11-16",
      pro_forma: false,
      digest_heading: "3 p.m., Monday, November 16",
      record_issue: "172/171",
    });
    expect((meetings[0]!.convenes_at as Date).toISOString()).toBe("2026-11-16T20:00:00.000Z");
    expect(String(meetings[0]!.program)).toMatch(/^Senate will resume consideration of the nomination of Daniel Desmond Domenico/);
    expect(await rows("senate")).toEqual([
      expect.objectContaining({
        item_id: "2026-11-16:hr2347",
        legis_num: "H.R. 2347",
        bill_id: "119-hr-2347",
        title: "Survivor Justice Tax Prevention Act",
        removed_at: null,
      }),
    ]);
  });

  it("stores the Senate convening without a Congress.gov key, skipping only the program", async () => {
    const result = await ingestSchedule(db, fetchText, { now: NOW, log: () => {} });
    expect(result).toMatchObject({ senateMeeting: "2026-11-16", senateProgram: null });
    expect(fetched).not.toContain(DIGEST_URL);
  });

  it("still stores the rest when one source fails, and records the failure as the run's error", async () => {
    pages[SENATE_SESSION_DAYS_URL] = { status: 503, text: "" };
    await expect(ingestSchedule(db, fetchText, { now: NOW, congress, log: () => {} })).rejects.toThrow(/senate convening: HTTP 503/);
    expect(await rows("house")).toHaveLength(15);
    const { rows: runs } = await pg.query<{ error: string | null; finished_at: Date | null }>(
      "select error, finished_at from ingest_runs",
    );
    expect(runs[0]?.error).toMatch(/senate convening: HTTP 503/);
    expect(runs[0]?.finished_at).not.toBeNull();
  });

  it("fails a week whose file is not a schedule rather than reading it as empty", async () => {
    pages[houseWeeklyUrl("2026-11-16")] = { status: 200, text: "<html>Service Unavailable</html>" };
    await expect(ingestSchedule(db, fetchText, { now: NOW, log: () => {} })).rejects.toThrow(/house 2026-11-16: Not a House floor schedule/);
  });
});
