import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { beforeEach, describe, expect, it } from "vitest";
import { congressClient, type CongressGet, type Json } from "./bills.js";
import {
  RequestBudget,
  BudgetExhausted,
  detailsDue,
  ingestCatalog,
  KeyReserveReached,
  listingStart,
  stageUnstaged,
  looksLikeShortTitle,
  toListedBill,
} from "./catalog.js";
import type { Db } from "./db.js";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = (name: string) => JSON.parse(readFileSync(join(here, "../fixtures/congress", name), "utf8")) as Json;
// Real responses, 2026-11-13: the first page of the 119th Congress oldest-update-first (three
// reserved numbers), a page of bills updated since 2026-11-12, and one of those bills' detail.
const reservedPage = fixture("catalog/list-119-reserved.json");
const sincePage = fixture("catalog/list-119-since-2026-11-12.json");
const hr10976 = fixture("catalog/hr10976-119-bill.json");
const hr2493Actions = fixture("stage/119-hr-2493-actions.json");

/** The detail of another bill on the page: H.R. 10976's real response with its number and title swapped. */
const detailFor = (number: string): Json => {
  const listed = (sincePage["bills"] as Json[]).find((b) => b["number"] === number)!;
  return { ...hr10976, bill: { ...(hr10976["bill"] as Json), number, title: listed["title"] } };
};

const freshDb = async () => {
  const pg = new PGlite();
  await pg.exec(`
    create schema auth;
    create table auth.users (id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
  `);
  for (const m of loadMigrations()) await pg.exec(m.sql);
  return pg;
};

const noWait = { clock: () => 0, sleep: async () => {} };

describe("toListedBill", () => {
  it("skips the numbers reserved for the House leadership", () => {
    expect((reservedPage["bills"] as Json[]).map(toListedBill)).toEqual(["reserved", "reserved", "reserved"]);
  });

  it("skips a row with no updateDate rather than store it undated", () => {
    const undated = { ...(sincePage["bills"] as Json[])[0]!, updateDate: undefined };
    expect(toListedBill(undated)).toBe("undated");
  });

  it("maps a listed bill to the fields the list gives", () => {
    expect(toListedBill((sincePage["bills"] as Json[])[0]!)).toEqual({
      id: "119-hr-10976",
      congress: 119,
      bill_type: "hr",
      number: 10976,
      title: "Community Control of Data Centers Act",
      origin_chamber: "house",
      introduced_on: "2026-11-10",
      latest_action_on: "2026-11-10",
      latest_action_text: "Referred to the House Committee on Energy and Commerce.",
      list_updated_on: "2026-11-12",
    });
  });
});

describe("looksLikeShortTitle", () => {
  it.each([
    ["Community Control of Data Centers Act", true],
    ["EARLY Act Reauthorization of 2025", true],
    ["To modernize Federal firearms laws to account for advancements in technology, and for other purposes.", false],
    ["Making further continuing appropriations for the fiscal year ending September 30, 2024, and for other purposes.", false],
    ["Reserved for the Speaker.", false],
  ])("%s → %s", (title, expected) => {
    expect(looksLikeShortTitle(title)).toBe(expected);
  });
});

describe("RequestBudget", () => {
  it("spaces requests to the hourly rate and stops at the run's limit", async () => {
    let now = 0;
    const waits: number[] = [];
    const budget = new RequestBudget(3, 3600, () => now, async (ms) => {
      waits.push(ms);
      now += ms;
    });
    await budget.take();
    await budget.take();
    await budget.take();
    // 3,600 an hour is one a second: the second and third wait a second each.
    expect(waits).toEqual([1000, 1000]);
    await expect(budget.take()).rejects.toBeInstanceOf(BudgetExhausted);
    expect(budget.used).toBe(3);
  });

  it("refuses once the key itself is below the reserve, whoever spent it", async () => {
    const budget = new RequestBudget(100, 3600, () => 0, async () => {}, 500);
    budget.observe(500);
    await budget.take();
    budget.observe(499);
    expect(budget.keyLow).toBe(true);
    await expect(budget.take()).rejects.toBeInstanceOf(KeyReserveReached);
    expect(budget.used).toBe(1);
  });
});

describe("ingestCatalog", () => {
  let pg: PGlite;
  let requested: string[];
  let get: CongressGet;

  beforeEach(async () => {
    pg = await freshDb();
    requested = [];
    get = async (path) => {
      requested.push(path);
      if (path.startsWith("/bill/119?")) return path.includes("fromDateTime") ? sincePage : { ...sincePage, bills: [...(reservedPage["bills"] as Json[]), ...(sincePage["bills"] as Json[])] };
      if (path.endsWith("/actions?limit=250")) return hr2493Actions;
      const number = /\/bill\/119\/hr\/(\d+)$/.exec(path)?.[1];
      if (number) return number === "10976" ? hr10976 : detailFor(number);
      throw new Error(`Congress.gov ${path} returned HTTP 404`);
    };
  });

  it("lists, fetches details where due, and stages every bill", async () => {
    const result = await ingestCatalog(pg as unknown as Db, (b) => b.wrap(get), { congress: 119, budget: 100, full: true, budgetClock: noWait });
    expect(result).toMatchObject({ listed: 5, reserved: 3, fetched: 5, failed: 0, stillDue: 0, staged: 0, stoppedBy: "done" });
    // One list page, then bill + actions per bill: no summary yet (none written), and no /titles
    // request because every title already reads as a short title.
    expect(result.requests).toBe(1 + 5 * 2);
    expect(requested.some((p) => p.includes("/summaries") || p.includes("/titles"))).toBe(false);

    const { rows } = await pg.query<{ id: string; sponsor_id: string | null; stage: string; list_updated_on: string }>(
      "select id, sponsor_id, stage, to_char(list_updated_on, 'YYYY-MM-DD') as list_updated_on from bills order by id",
    );
    expect(rows.map((r) => r.id)).toEqual(["119-hr-10976", "119-hr-10977", "119-hr-10981", "119-hr-10982", "119-hr-10987"]);
    // The actions handed back are H.R. 2493's, which passed the House.
    expect(new Set(rows.map((r) => r.stage))).toEqual(new Set(["passed_house"]));
    expect(rows[0]?.list_updated_on).toBe("2026-11-12");

    const { rows: run } = await pg.query<{ source: string; items: number; error: string | null }>(
      "select source, items, error from ingest_runs",
    );
    expect(run).toEqual([{ source: "bill_catalog", items: 10, error: null }]);
  });

  it("resumes from the high-water mark and fetches nothing that has not changed", async () => {
    await ingestCatalog(pg as unknown as Db, (b) => b.wrap(get), { congress: 119, budget: 100, full: true, budgetClock: noWait });
    expect(await listingStart(pg as unknown as Db, 119)).toBe("2026-11-11T00:00:00Z");
    requested = [];
    const result = await ingestCatalog(pg as unknown as Db, (b) => b.wrap(get), { congress: 119, budget: 100, budgetClock: noWait });
    expect(requested).toEqual(["/bill/119?limit=250&offset=0&sort=updateDate+asc&fromDateTime=2026-11-11T00:00:00Z"]);
    expect(result).toMatchObject({ fetched: 0, stillDue: 0, stoppedBy: "done" });
  });

  it("stops on its budget and leaves the rest due for the next run", async () => {
    const result = await ingestCatalog(pg as unknown as Db, (b) => b.wrap(get), { congress: 119, budget: 13, full: true, budgetClock: noWait });
    // 1 list request leaves 12: three bills at the worst case of four each. The fourth worker sees
    // that three are in flight and stops, so no bill is cut off half-fetched.
    expect(result).toMatchObject({ fetched: 3, stillDue: 2, stoppedBy: "budget" });
    expect(result.requests).toBe(1 + 3 * 2);
    // Unfetched bills are still listed and searchable by number and title, but not staged: the list's
    // one latest action cannot say where a bill stands, so the API reports null until the details land.
    const { rows } = await pg.query<{ fetched: boolean; stage: string | null }>(
      "select details_fetched_at is not null as fetched, stage from bills order by id",
    );
    expect(rows.filter((r) => !r.fetched).map((r) => r.stage)).toEqual([null, null]);
    expect(rows.filter((r) => r.fetched).map((r) => r.stage)).toEqual(["passed_house", "passed_house", "passed_house"]);
  });

  it("stops quietly when Congress.gov says the key's hourly limit is spent", async () => {
    const limited: CongressGet = async (path) => {
      if (path.startsWith("/bill/119?")) return get(path);
      throw new Error(`Congress.gov ${path.split("?")[0]} returned HTTP 429`);
    };
    const result = await ingestCatalog(pg as unknown as Db, (b) => b.wrap(limited), { congress: 119, budget: 100, full: true, budgetClock: noWait });
    expect(result).toMatchObject({ listed: 5, fetched: 0, failed: 0, stoppedBy: "rate_limit" });
    const { rows } = await pg.query<{ error: string | null }>("select error from ingest_runs");
    expect(rows).toEqual([{ error: null }]);
  });
});

describe("detailsDue", () => {
  it("fetches a bill again once the day it changed is over, then lets it rest", async () => {
    const pg = await freshDb();
    await pg.exec(`
      insert into bills (id, congress, bill_type, number, title, list_updated_on, details_fetched_at) values
        ('119-hr-1', 119, 'hr', 1, 'Never fetched Act', '2026-11-12', null),
        ('119-hr-2', 119, 'hr', 2, 'Fetched before it changed Act', '2026-11-12', '2026-11-11 12:00Z'),
        ('119-hr-3', 119, 'hr', 3, 'Fetched during the day it changed Act', '2026-11-12', '2026-11-12 15:00Z'),
        ('119-hr-4', 119, 'hr', 4, 'Fetched after that day ended Act', '2026-11-12', '2026-11-13 07:00Z'),
        ('118-hr-5', 118, 'hr', 5, 'Another Congress Act', '2026-11-12', null);
    `);
    const due = async (now: string) =>
      (await detailsDue(pg as unknown as Db, 119, 10, new Date(now))).map((b) => b.id);
    // Bills already fetched that changed go first, oldest fetch first; never-fetched ones after.
    expect(await due("2026-11-12T20:00:00Z")).toEqual(["119-hr-2", "119-hr-1"]);
    expect(await due("2026-11-13T08:00:00Z")).toEqual(["119-hr-2", "119-hr-3", "119-hr-1"]);
  });
});

describe("ingestCatalog, the listing", () => {
  let pg: PGlite;
  const page = (bills: Json[], count = bills.length): Json => ({ ...sincePage, bills, pagination: { count } });
  const listed = sincePage["bills"] as Json[];
  const fakeGet = (list: () => Json): CongressGet => async (path) => {
    if (path.startsWith("/bill/119?")) return list();
    if (path.endsWith("/actions?limit=250")) return hr2493Actions;
    const number = /\/bill\/119\/hr\/(\d+)$/.exec(path)?.[1];
    if (number) return number === "10976" ? hr10976 : detailFor(number);
    throw new Error(`Congress.gov ${path} returned HTTP 404`);
  };

  beforeEach(async () => {
    pg = await freshDb();
  });

  it("writes nothing on a re-list that brings no change, and only the bill that moved when one does", async () => {
    let bills = listed;
    const get = fakeGet(() => page(bills));
    // The first run fetches details, whose (borrowed) latest actions differ from the list's; the
    // second re-lists over them. From then on the stored rows match what the list says.
    await ingestCatalog(pg as unknown as Db, (b) => b.wrap(get), { congress: 119, budget: 100, full: true, budgetClock: noWait });
    await ingestCatalog(pg as unknown as Db, (b) => b.wrap(get), { congress: 119, budget: 100, full: true, budgetClock: noWait });
    const stamps = async () =>
      new Map(
        (await pg.query<{ id: string; at: string }>("select id, updated_at::text as at from bills")).rows.map((r) => [r.id, r.at]),
      );
    const before = await stamps();
    await ingestCatalog(pg as unknown as Db, (b) => b.wrap(get), { congress: 119, budget: 100, full: true, budgetClock: noWait });
    expect(await stamps()).toEqual(before);

    bills = listed.map((b, i) => (i === 0 ? { ...b, latestAction: { actionDate: "2026-11-13", text: "Passed House." } } : b));
    await ingestCatalog(pg as unknown as Db, (b) => b.wrap(get), { congress: 119, budget: 100, full: true, budgetClock: noWait });
    const after = await stamps();
    expect([...after].filter(([id, at]) => before.get(id) !== at).map(([id]) => id)).toEqual(["119-hr-10976"]);
  });

  it("takes a page that lists a bill twice, keeping the later row", async () => {
    const twice = [...listed, { ...listed[0]!, latestAction: { actionDate: "2026-11-13", text: "Passed House." } }];
    const get = fakeGet(() => page(twice));
    const result = await ingestCatalog(pg as unknown as Db, (b) => b.wrap(get), { congress: 119, budget: 2, full: true, budgetClock: noWait });
    expect(result.stoppedBy).toBe("budget");
    const { rows } = await pg.query<{ n: number; text: string }>(
      "select count(*) over ()::int as n, latest_action_text as text from bills where id = '119-hr-10976'",
    );
    expect(rows).toEqual([{ n: 1, text: "Passed House." }]);
  });

  it("skips and counts listed rows with no updateDate", async () => {
    const undated = { ...listed[1]!, updateDate: undefined };
    const get = fakeGet(() => page([listed[0]!, undated]));
    const result = await ingestCatalog(pg as unknown as Db, (b) => b.wrap(get), { congress: 119, budget: 1, full: true, budgetClock: noWait });
    expect(result).toMatchObject({ listed: 1, undated: 1 });
  });

  it("warns when a full listing leaves a different number stored than Congress.gov counts", async () => {
    const logs: string[] = [];
    const run = (count: number) =>
      ingestCatalog(pg as unknown as Db, (b) => b.wrap(fakeGet(() => page(listed, count))), {
        congress: 119,
        budget: 1,
        full: true,
        budgetClock: noWait,
        log: (m) => logs.push(m),
      });
    await run(5);
    expect(logs.filter((m) => m.startsWith("warning:"))).toEqual([]);
    await run(482);
    expect(logs.filter((m) => m.startsWith("warning:"))).toEqual([
      "warning: Congress.gov counts 482 bills (0 reserved, 0 undated), so 482 should be stored, but 5 are",
    ]);
  });

  it("stops when the key runs below its reserve, counting what every response says is left", async () => {
    // Through the real client, so the X-RateLimit-Remaining header is what is read.
    const get = fakeGet(() => page(listed));
    let remaining = 506;
    const fakeFetch = (async (input: string | URL | Request) => {
      const path = String(input)
        .slice("https://api.congress.gov/v3".length)
        .replace(/[?&]format=json&api_key=.*$/, "");
      const body = await get(path);
      remaining--;
      return new Response(JSON.stringify(body), { status: 200, headers: { "x-ratelimit-remaining": String(remaining) } });
    }) as typeof fetch;
    const result = await ingestCatalog(pg as unknown as Db, (b) => congressClient("test-key", fakeFetch, b), {
      congress: 119,
      budget: 100,
      full: true,
      concurrency: 1,
      budgetClock: noWait,
    });
    // The list leaves 505; two bills take it to 501; the third's second request reads 499, so it
    // finishes and nothing more starts.
    expect(result).toMatchObject({ listed: 5, fetched: 3, stoppedBy: "key_reserve", requests: 7 });
    const { rows } = await pg.query<{ error: string | null }>("select error from ingest_runs");
    expect(rows).toEqual([{ error: null }]);
  });
});

describe("stageUnstaged", () => {
  it("stages fetched bills and list-only ones that became law, and leaves the rest null", async () => {
    const pg = await freshDb();
    await pg.exec(`
      insert into bills (id, congress, bill_type, number, title, latest_action_text, list_updated_on, details_fetched_at) values
        ('119-s-2', 119, 's', 2, 'Secure America Act', 'Became Public Law No: 119-98.', '2026-11-12', null),
        ('119-hr-5', 119, 'hr', 5, 'Listed only Act', 'Passed House.', '2026-11-12', null),
        ('119-hres-7', 119, 'hres', 7, 'A listed resolution', 'Became Public Law No: 1-1.', '2026-11-12', null),
        ('119-hr-6', 119, 'hr', 6, 'Fetched Act', null, '2026-11-12', '2026-11-12 10:00Z');
    `);
    expect(await stageUnstaged(pg as unknown as Db, 1)).toBe(2);
    const { rows } = await pg.query<{ id: string; stage: string | null }>("select id, stage from bills order by id");
    expect(rows).toEqual([
      { id: "119-hr-5", stage: null },
      { id: "119-hr-6", stage: "introduced" },
      { id: "119-hres-7", stage: null },
      { id: "119-s-2", stage: "law" },
    ]);
  });
});
