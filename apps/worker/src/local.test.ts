import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { beforeEach, describe, expect, it } from "vitest";
import * as api from "../../api/src/jurisdictions.js";
import type { Db } from "./db.js";
import { gnewsUrl } from "./gnews.js";
import * as worker from "./jurisdictions.js";
import {
  LEGISTAR,
  chamberBody,
  classifyBill,
  councilPassage,
  countVotes,
  ingestLocal,
  keepMatter,
  legistarMattersPath,
  openStatesBillsUrl,
  parseLocalArgs,
  parseTally,
  type LegistarHistory,
  type LegistarMatter,
  type OsBill,
} from "./local.js";
import type { FetchText } from "./rollcalls.js";

const here = dirname(fileURLToPath(import.meta.url));
const raw = (name: string) => readFileSync(join(here, "../fixtures/local", name), "utf8");
const json = <T>(name: string) => JSON.parse(raw(name)) as T;
const NOW = new Date("2026-11-17T12:00:00Z");
const SINCE = "2026-10-18";
const TODAY = "2026-11-17";

describe("the registry", () => {
  it("is the API's, entry for entry", () => {
    expect(worker.JURISDICTIONS).toEqual(api.JURISDICTIONS);
    expect(JSON.stringify(worker.JURISDICTIONS.map(worker.localNewsQuery))).toBe(JSON.stringify(api.JURISDICTIONS.map(api.localNewsQuery)));
  });

  it("has 50 states and the nine cities, ids unique", () => {
    const js = worker.JURISDICTIONS;
    expect(js.filter((j) => j.kind === "state")).toHaveLength(50);
    expect(js.filter((j) => j.kind === "city").map((j) => [j.id, j.placeGeoid, j.records?.source ?? null])).toEqual([
      ["nyc", "3651000", "legistar"],
      ["seattle", "5363000", "legistar"],
      ["sf", "0667000", "legistar"],
      ["boston", "2507000", "legistar"],
      ["denver", "0820000", "legistar"],
      ["los-angeles", "0644000", null],
      ["chicago", "1714000", null],
      ["houston", "4835000", null],
      ["philadelphia", "4260000", null],
    ]);
    expect(new Set(js.map((j) => j.id)).size).toBe(js.length);
  });

  it("asks Google News for a council by its own name", () => {
    const q = (id: string) => worker.localNewsQuery(worker.jurisdictionById(id)!);
    expect(q("nyc")).toBe('"New York City Council" when:7d');
    expect(q("seattle")).toBe('"Seattle City Council" when:7d');
    expect(q("sf")).toBe('"San Francisco Board of Supervisors" when:7d');
    expect(q("ny")).toBe('("New York Legislature" OR "New York State Senate" OR "New York State Assembly" OR "New York General Assembly") when:7d');
  });
});

describe("Open States (doc-derived fixture: no key yet)", () => {
  const bills = json<{ results: OsBill[] }>("openstates-bills-doc-derived.json").results;
  const rows = bills.map((b) => classifyBill(b, "nc", SINCE));

  it("reads signed, became law and waiting from the actions; one chamber, vetoed and old signings are left out", () => {
    expect(rows.map((r) => (r ? [r.identifier, r.status, r.date, r.body] : null))).toEqual([
      ["SB 113", "signed", "2026-11-11", "State Senate"],
      ["HB 1105", "became_law", "2026-11-05", "State House"],
      ["SB 200", "awaiting_governor", "2026-11-09", "State Senate"],
      null,
      null,
      null,
      ["LB 1", "awaiting_governor", "2026-11-12", "Legislature"],
    ]);
  });

  it("keeps the first non-empty abstract as the summary, and the Open States page as the url", () => {
    expect(rows[0]).toMatchObject({
      id: "openstates:ocd-bill/f0049138-1ad8-4506-a2a4-f4dd1251bbba",
      summary: "This bill designates a new state arachnid.",
      url: "https://openstates.org/nc/bills/2025/SB113/",
      yes: null,
      no: null,
    });
    expect(rows[2]!.summary).toBeNull();
  });

  it("names the chambers as the hub does", () => {
    expect(chamberBody({ classification: "lower", name: "Assembly" })).toBe("Assembly");
    expect(chamberBody({ classification: "lower", name: "House of Delegates" })).toBe("House of Delegates");
    expect(chamberBody({ classification: "lower", name: "House" })).toBe("State House");
  });

  it("asks for a state's bills with recent actions, newest first, in the documented parameters", () => {
    const url = new URL(openStatesBillsUrl(worker.jurisdictionById("ny") as never, SINCE, 1));
    expect(url.origin + url.pathname).toBe("https://v3.openstates.org/bills");
    expect(url.searchParams.get("jurisdiction")).toBe("ocd-jurisdiction/country:us/state:ny/government");
    expect(url.searchParams.get("action_since")).toBe(SINCE);
    expect(url.searchParams.get("sort")).toBe("latest_action_desc");
    expect(url.searchParams.getAll("include")).toEqual(["actions", "abstracts"]);
    expect(url.searchParams.has("apikey")).toBe(false);
  });
});

describe("Legistar (real Seattle responses, 2026-11-17)", () => {
  const matters = json<LegistarMatter[]>("legistar-seattle-matters.json");

  it("keeps passed legislation; skips what did not pass, minutes, calendars and appointments", () => {
    expect(matters.filter((m) => keepMatter(m, SINCE, TODAY)).map((m) => m.MatterFile)).toEqual(["CB 121276", "CB 121297", "Res 32216"]);
  });

  it("finds the council's own passing vote, not the committee's", () => {
    const p = councilPassage(json<LegistarHistory[]>("legistar-seattle-histories-17402.json"));
    expect(p).toMatchObject({ MatterHistoryId: 126852, MatterHistoryActionName: "passed", MatterHistoryActionBodyName: "City Council" });
  });

  it("counts the roll call", () => {
    expect(countVotes(json("legistar-seattle-votes-126852.json"))).toEqual({ yes: 8, no: 0 });
    expect(countVotes(json("legistar-seattle-votes-126476.json"))).toEqual({ yes: 8, no: 1 });
    expect(countVotes([])).toBeNull();
    expect(parseTally("44-5")).toEqual({ yes: 44, no: 5 });
    expect(parseTally("9:0")).toEqual({ yes: 9, no: 0 });
    expect(parseTally(null)).toBeNull();
  });

  it("skips Denver's test records and Boston's reports", () => {
    const denver = json<LegistarMatter[]>("legistar-denver-matters.json").filter((m) => keepMatter(m, SINCE, TODAY));
    expect(denver.some((m) => m.MatterFile?.startsWith("HIST"))).toBe(false);
    const boston = json<LegistarMatter[]>("legistar-boston-matters.json").filter((m) => keepMatter(m, SINCE, TODAY));
    expect(boston.some((m) => /report/i.test(m.MatterTypeName ?? ""))).toBe(false);
  });
});

async function freshDb() {
  const pg = new PGlite();
  await pg.exec(`create schema auth; create table auth.users (id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;`);
  for (const m of loadMigrations()) await pg.exec(m.sql);
  return pg;
}

describe("ingestLocal", () => {
  let pg: PGlite;
  beforeEach(async () => {
    pg = await freshDb();
  });

  const table: Record<string, string> = {
    [legistarMattersPath("seattle", SINCE, TODAY)]: raw("legistar-seattle-matters.json"),
    [`${LEGISTAR}/seattle/matters/17402/histories`]: raw("legistar-seattle-histories-17402.json"),
    [`${LEGISTAR}/seattle/matters/17532/histories`]: raw("legistar-seattle-histories-17532.json"),
    [`${LEGISTAR}/seattle/matters/17429/histories`]: raw("legistar-seattle-histories-17429.json"),
    [`${LEGISTAR}/seattle/eventitems/126852/votes`]: raw("legistar-seattle-votes-126852.json"),
    [`${LEGISTAR}/seattle/eventitems/126614/votes`]: raw("legistar-seattle-votes-126614.json"),
    [`${LEGISTAR}/seattle/eventitems/126476/votes`]: raw("legistar-seattle-votes-126476.json"),
    [gnewsUrl(worker.localNewsQuery(worker.jurisdictionById("seattle")!))]: raw("gnews-seattle.xml"),
    [gnewsUrl(worker.localNewsQuery(worker.jurisdictionById("ny")!))]: raw("gnews-ny.xml"),
  };
  const routes =
    (seen: string[]): FetchText =>
    async (url) => {
      seen.push(url);
      return url in table ? { status: 200, text: table[url]! } : { status: 404, text: "" };
    };

  it("stores state bills, council matters with tallies and headlines; skips NYC without its token", async () => {
    const seen: string[] = [];
    const logs: string[] = [];
    const osUrls: string[] = [];
    const r = await ingestLocal(
      pg as unknown as Db,
      {
        openStates: async (url) => {
          osUrls.push(url);
          return { status: 200, text: raw("openstates-bills-doc-derived.json") };
        },
        fetchText: routes(seen),
        sleep: async () => {},
        log: (m) => logs.push(m),
      },
      { now: NOW, only: ["ny", "seattle", "nyc", "los-angeles"] },
    );
    expect(r).toMatchObject({ states: 1, enacted: 2, waiting: 2, cities: 1, passed: 3, skipped: ["nyc"] });
    expect(osUrls).toHaveLength(1);
    expect(logs).toContain("nyc: NYC_LEGISTAR_TOKEN unset: council records skipped");

    const { rows } = await pg.query<{ jurisdiction_id: string; identifier: string; status: string; yes: number | null; no: number | null; date: string }>(
      "select jurisdiction_id, identifier, status, yes, no, date::text as date from local_items order by jurisdiction_id, identifier",
    );
    expect(rows).toEqual([
      { jurisdiction_id: "ny", identifier: "HB 1105", status: "became_law", yes: null, no: null, date: "2026-11-05" },
      { jurisdiction_id: "ny", identifier: "LB 1", status: "awaiting_governor", yes: null, no: null, date: "2026-11-12" },
      { jurisdiction_id: "ny", identifier: "SB 113", status: "signed", yes: null, no: null, date: "2026-11-11" },
      { jurisdiction_id: "ny", identifier: "SB 200", status: "awaiting_governor", yes: null, no: null, date: "2026-11-09" },
      { jurisdiction_id: "seattle", identifier: "CB 121276", status: "passed", yes: 8, no: 0, date: "2026-11-13" },
      { jurisdiction_id: "seattle", identifier: "CB 121297", status: "passed", yes: 9, no: 0, date: "2026-11-05" },
      { jurisdiction_id: "seattle", identifier: "Res 32216", status: "passed", yes: 8, no: 1, date: "2026-10-23" },
    ]);
    const { rows: cb } = await pg.query<{ title: string; summary: string | null; url: string; body: string }>(
      "select title, summary, url, body from local_items where identifier = 'CB 121276'",
    );
    expect(cb[0]).toEqual({
      title: "An ordinance relating to land use and zoning; amending Sections 23.45.506, 23.45.570, and 23.51.A.004 of the Seattle Municipal Code to modify development standards for institutions in multifamily zones.",
      summary: null,
      url: "https://seattle.legistar.com/LegislationDetail.aspx?ID=17402&GUID=91B44AED-559E-47DF-BD93-DEC4DD5D6D92",
      body: "City Council",
    });
    const { rows: news } = await pg.query<{ jurisdiction_id: string; n: number }>(
      "select jurisdiction_id, count(*)::int as n from local_news group by 1 order by 1",
    );
    expect(news).toEqual([
      { jurisdiction_id: "ny", n: 12 },
      { jurisdiction_id: "seattle", n: 12 },
    ]);

    // A second run asks Legistar for the list only: stored matters are not fetched again.
    const before = seen.filter((u) => u.startsWith(LEGISTAR)).length;
    await ingestLocal(pg as unknown as Db, { fetchText: routes(seen), sleep: async () => {} }, { now: NOW, only: ["seattle"], news: false });
    expect(seen.filter((u) => u.startsWith(LEGISTAR)).length - before).toBe(1);
  });

  it("drops a waiting bill the next pass no longer sees, and never logs NYC's token", async () => {
    const logs: string[] = [];
    const deps = {
      openStates: async () => ({ status: 200, text: raw("openstates-bills-doc-derived.json") }),
      fetchText: async () => ({ status: 500, text: "" }),
      tokens: { NYC_LEGISTAR_TOKEN: "SECRET-TOKEN" },
      sleep: async () => {},
      log: (m: string) => logs.push(m),
    };
    await ingestLocal(pg as unknown as Db, deps, { now: NOW, only: ["ny", "nyc"] });
    await ingestLocal(pg as unknown as Db, { ...deps, openStates: async () => ({ status: 200, text: '{"results":[],"pagination":{"max_page":1}}' }) }, {
      now: NOW,
      only: ["ny"],
    });
    const { rows } = await pg.query<{ status: string }>("select status from local_items where jurisdiction_id = 'ny' order by status");
    expect(rows.map((r) => r.status)).toEqual(["became_law", "signed"]);
    expect(logs.some((l) => l.includes("nyc: Legistar failed"))).toBe(true);
    expect(logs.join("\n")).not.toContain("SECRET-TOKEN");
  });

  it("skips the states without a key, and stops them on a 429", async () => {
    const logs: string[] = [];
    const none = await ingestLocal(pg as unknown as Db, { fetchText: async () => ({ status: 404, text: "" }), sleep: async () => {}, log: (m) => logs.push(m) }, {
      now: NOW,
      only: ["ny"],
      news: false,
    });
    expect(none.skipped).toEqual(["openstates"]);
    expect(logs).toContain("OPENSTATES_API_KEY unset: state records skipped");
    let calls = 0;
    const limited = await ingestLocal(
      pg as unknown as Db,
      { openStates: async () => (calls++, { status: 429, text: "" }), fetchText: async () => ({ status: 404, text: "" }), sleep: async () => {} },
      { now: NOW, only: ["ny", "ca", "tx"], news: false },
    );
    expect(calls).toBe(1);
    expect(limited.states).toBe(0);
  });
});

describe("parseLocalArgs", () => {
  it("reads jurisdictions and --no-news, refuses an unknown id", () => {
    expect(parseLocalArgs(["--only", "seattle", "--no-news"])).toEqual({ only: ["seattle"], news: false });
    expect(() => parseLocalArgs(["--only", "atlantis"])).toThrow();
  });
});
