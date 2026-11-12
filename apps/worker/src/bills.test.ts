import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { beforeAll, describe, expect, it } from "vitest";
import {
  congressClient,
  htmlToText,
  ingestVotedBills,
  parseMeasureRef,
  pickShortTitle,
  toActionRows,
  toBillRow,
  type CongressGet,
} from "./bills.js";
import type { Db } from "./db.js";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = (name: string) =>
  JSON.parse(readFileSync(join(here, "../fixtures/congress", name), "utf8")) as Record<string, unknown>;
const bill = fixture("hconres14-bill.json");
const actions = fixture("hconres14-actions.json");
const summaries = fixture("hconres14-summaries.json");
const titles = fixture("hconres14-titles.json");
const hr1Titles = fixture("hr1-119-titles.json");
// Real /summaries response; only the long summary bodies are shortened so the fixture stays small.
const hr3746Summaries = fixture("hr3746-118-summaries.json");

describe("parseMeasureRef", () => {
  it.each([
    ["H R 2207", { kind: "bill", type: "hr", number: 2207 }],
    ["H.R. 1", { kind: "bill", type: "hr", number: 1 }],
    ["H CON RES 14", { kind: "bill", type: "hconres", number: 14 }],
    ["H.Con.Res. 14", { kind: "bill", type: "hconres", number: 14 }],
    ["H J RES 1", { kind: "bill", type: "hjres", number: 1 }],
    ["S.J.Res. 10", { kind: "bill", type: "sjres", number: 10 }],
    ["S 1003", { kind: "bill", type: "s", number: 1003 }],
    ["S.Res. 13", { kind: "bill", type: "sres", number: 13 }],
    ["PN1093-3", { kind: "nomination", number: 1093, part: 3 }],
    ["PN1", { kind: "nomination", number: 1, part: null }],
  ])("parses %s", (ref, expected) => {
    expect(parseMeasureRef(ref)).toEqual(expected);
  });

  it.each(["QUORUM", "ADJOURN", "Treaty Doc. 112-8", "", null])("ignores %s", (ref) => {
    expect(parseMeasureRef(ref)).toBeNull();
  });
});

describe("Congress.gov mapping (real H.Con.Res. 14 responses)", () => {
  it("maps the bill with its summary, sponsor and CBO estimates", () => {
    const row = toBillRow(bill, summaries, titles);
    expect(row).toMatchObject({
      id: "119-hconres-14",
      short_title: null, // resolutions rarely have a short title
      congress: 119,
      bill_type: "hconres",
      number: 14,
      sponsor_id: "A000375",
      introduced_on: "2025-02-18",
      origin_chamber: "house",
      policy_area: "Economics and Public Finance",
      summary_stage: "Introduced in House",
      latest_action_on: "2025-05-20",
    });
    expect(row.title).toMatch(/^Establishing the congressional budget/);
    expect(row.summary).toMatch(/^This concurrent resolution establishes the congressional budget/);
    expect(row.summary).not.toMatch(/<p>|&nbsp;/);
    expect(row.cbo_estimates.length).toBeGreaterThan(0);
    expect(row.cbo_estimates[0]?.url).toMatch(/^https:\/\/www\.cbo\.gov\//);
  });

  it("maps actions without duplicates and tags the chamber", () => {
    const rows = toActionRows(actions);
    expect(rows.length).toBeGreaterThan(0);
    expect(rows.length).toBeLessThanOrEqual(35);
    expect(new Set(rows.map((r) => `${r.acted_on}|${r.text}`)).size).toBe(rows.length);
    expect(rows[0]).toMatchObject({ acted_on: "2025-05-20", chamber: "senate" });
  });

  it("picks the most advanced short title", () => {
    expect(
      pickShortTitle({
        titles: [
          { titleType: "Official Title as Introduced", title: "To provide for..." },
          { titleType: "Short Title(s) as Introduced", title: "Rural Broadband Act" },
          { titleType: "Short Title(s) as Passed House", title: "Rural Broadband Access Act" },
        ],
      }),
    ).toBe("Rural Broadband Access Act");
    expect(pickShortTitle({ titles: { count: 3, url: "https://api.congress.gov/..." } })).toBeNull();
  });

  it("ignores short titles that name only a portion of the bill (real H.R. 1, 119th)", () => {
    // Congress.gov lists "FEHB Protection Act of 2025" as an enacted short title for a portion of H.R. 1.
    // The measure itself is the One Big Beautiful Bill Act, and that is what the card must show.
    expect(pickShortTitle(hr1Titles)).toBe("One Big Beautiful Bill Act");
    expect(
      pickShortTitle({
        titles: [
          { titleType: "Short Titles as Enacted for portions of this bill", title: "A Division Inside It Act" },
          { titleType: "Short Title(s) as Passed House", title: "The Whole Bill Act" },
        ],
      }),
    ).toBe("The Whole Bill Act");
    // A bill whose only short titles describe portions has no short title of its own.
    expect(
      pickShortTitle({ titles: [{ titleType: "Short Titles as Enacted for portions of this bill", title: "Part Act" }] }),
    ).toBeNull();
  });

  it("takes the summary from the latest legislative stage, not the latest reindex (real H.R. 3746, 118th)", () => {
    // Congress.gov stamped this bill's Public Law summary three minutes BEFORE its Passed Senate one,
    // so ordering by updateDate stored the stale "Passed Senate" text.
    const row = toBillRow(bill, hr3746Summaries, titles);
    expect(row.summary_stage).toBe("Public Law");
  });

  it("converts summary HTML to text", () => {
    expect(htmlToText("<p>One&nbsp;&amp; two.</p><p>Three &ldquo;four&rdquo;</p>")).toBe('One & two.\n\nThree "four"');
  });
});

describe("congressClient", () => {
  it("adds the key, retries rate limits, and keeps the key out of errors", async () => {
    const urls: string[] = [];
    let calls = 0;
    const fakeFetch = (async (url: string) => {
      urls.push(url);
      calls++;
      if (calls === 1) return new Response("slow down", { status: 429 });
      if (url.includes("/missing")) return new Response("nope", { status: 404 });
      return Response.json({ ok: true });
    }) as unknown as typeof fetch;
    const get = congressClient("SECRET-KEY", fakeFetch);

    const realTimeout = globalThis.setTimeout;
    globalThis.setTimeout = ((fn: () => void) => realTimeout(fn, 0)) as typeof setTimeout;
    try {
      expect(await get("/bill/119/hr/1")).toEqual({ ok: true });
      await expect(get("/missing")).rejects.toThrow("Congress.gov /missing returned HTTP 404");
      await get("/missing").catch((e: Error) => expect(e.message).not.toContain("SECRET-KEY"));
    } finally {
      globalThis.setTimeout = realTimeout;
    }
    expect(urls[0]).toBe("https://api.congress.gov/v3/bill/119/hr/1?format=json&api_key=SECRET-KEY");
    expect(urls[1]).toBe(urls[0]);
  });
});

describe("ingestVotedBills", () => {
  let pg: PGlite;

  beforeAll(async () => {
    pg = new PGlite();
    await pg.exec(`
      create schema auth;
      create table auth.users (id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
    `);
    for (const m of loadMigrations()) await pg.exec(m.sql);
    await pg.exec(`
      insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end)
        values ('A000375', 'Jodey', 'Arrington', 'R', 'TX', 19, 'house', '2025-01-03', '2027-01-03');
      insert into votes (id, chamber, congress, session, roll_number, question, bill_ref) values
        ('house-119-1-100', 'house', 119, 1, 100, 'On Motion to Concur', 'H CON RES 14'),
        ('senate-119-1-90', 'senate', 119, 1, 90, 'On the Concurrent Resolution', 'H.Con.Res. 14'),
        ('senate-119-1-91', 'senate', 119, 1, 91, 'On the Nomination', 'PN12'),
        ('house-119-1-5', 'house', 119, 1, 5, 'On Motion to Adjourn', 'ADJOURN'),
        ('house-119-1-6', 'house', 119, 1, 6, 'On Passage', 'H R 9999');
    `);
  });

  it("loads each voted bill once and links both chambers' votes to it", async () => {
    const requested: string[] = [];
    const get: CongressGet = async (path) => {
      requested.push(path);
      if (path.startsWith("/bill/119/hr/9999")) throw new Error("Congress.gov /bill/119/hr/9999 returned HTTP 404");
      if (path.endsWith("/actions?limit=250")) return actions;
      if (path.endsWith("/summaries")) return summaries;
      if (path.endsWith("/titles?limit=250")) return titles;
      return bill;
    };
    const result = await ingestVotedBills(pg as unknown as Db, get);
    expect(result).toEqual({ bills: 1, linkedVotes: 2, failed: 1 });
    expect(requested.filter((p) => p.startsWith("/bill/119/hconres/14"))).toHaveLength(4);

    const { rows: votes } = await pg.query<{ id: string; bill_id: string | null }>("select id, bill_id from votes order by id");
    expect(votes).toEqual([
      { id: "house-119-1-100", bill_id: "119-hconres-14" },
      { id: "house-119-1-5", bill_id: null },
      { id: "house-119-1-6", bill_id: null },
      { id: "senate-119-1-90", bill_id: "119-hconres-14" },
      { id: "senate-119-1-91", bill_id: null },
    ]);
    const { rows: stored } = await pg.query<{ sponsor_id: string; n: number }>(
      "select b.sponsor_id, (select count(*)::int from actions a where a.bill_id = b.id) as n from bills b",
    );
    expect(stored[0]?.sponsor_id).toBe("A000375");
    expect(stored[0]?.n).toBe(toActionRows(actions).length);

    const { rows: run } = await pg.query<{ items: number; error: string }>("select items, error from ingest_runs where source = 'bills'");
    expect(run).toEqual([{ items: 1, error: "1 bills failed" }]);
  });

  it("refresh re-fetches stored bills and leaves the vote links alone", async () => {
    const requested: string[] = [];
    const get: CongressGet = async (path) => {
      requested.push(path);
      if (path.endsWith("/actions?limit=250")) return actions;
      if (path.endsWith("/summaries")) return summaries;
      if (path.endsWith("/titles?limit=250")) return titles;
      return bill;
    };
    const before = await pg.query<{ id: string; bill_id: string | null }>("select id, bill_id from votes order by id");
    const result = await ingestVotedBills(pg as unknown as Db, get, { refresh: true });

    // The one stored bill is re-fetched; the unlinked H.R. 9999 that never loaded is not.
    expect(result).toMatchObject({ bills: 1, linkedVotes: 0, failed: 0 });
    expect(new Set(requested.map((p) => p.split("?")[0]))).toEqual(
      new Set([
        "/bill/119/hconres/14",
        "/bill/119/hconres/14/actions",
        "/bill/119/hconres/14/summaries",
        "/bill/119/hconres/14/titles",
      ]),
    );
    const after = await pg.query<{ id: string; bill_id: string | null }>("select id, bill_id from votes order by id");
    expect(after.rows).toEqual(before.rows);
  });

  it("is idempotent: a second run only retries the bill that failed", async () => {
    const requested: string[] = [];
    const get: CongressGet = async (path) => {
      requested.push(path);
      throw new Error("Congress.gov returned HTTP 404");
    };
    await ingestVotedBills(pg as unknown as Db, get);
    expect(new Set(requested.map((p) => p.split("/").slice(0, 5).join("/")))).toEqual(new Set(["/bill/119/hr/9999"]));
  });
});
