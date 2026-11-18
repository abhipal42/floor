import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { beforeEach, describe, expect, it } from "vitest";
import type { Complete, ModelCall } from "./analysis.js";
import type { Db } from "./db.js";
import { gnewsUrl, isGov, memberNewsQuery, namesMember, parseGoogleNews } from "./gnews.js";
import { checkReply, ingestNews, memberHeadlines, parseNewsArgs, promptFor, type NewsMember } from "./news.js";
import type { FetchText } from "./rollcalls.js";

// Real Google News RSS answers, recorded 2026-11-17/18 and trimmed (fixtures/news, fixtures/local).
const here = dirname(fileURLToPath(import.meta.url));
const fixture = (name: string) => readFileSync(join(here, "../fixtures", name), "utf8");
const NOW = new Date("2026-11-18T04:07:18Z");

const schumer: NewsMember = { bioguide_id: "S000148", first_name: "Chuck", last_name: "Schumer", chamber: "senate" };
const gillibrand: NewsMember = { bioguide_id: "G000555", first_name: "Kirsten", last_name: "Gillibrand", chamber: "senate" };

describe("parseGoogleNews", () => {
  it("reads every item: the headline without its publisher suffix, the publisher, its site, the link and date", () => {
    const items = parseGoogleNews(fixture("news/gnews-schumer.xml"));
    expect(items).toHaveLength(30);
    expect(items[0]).toMatchObject({
      title: "Chris Van Hollen says he can beat Chuck Schumer. Here's his case",
      source: "NPR",
      sourceUrl: "https://www.npr.org",
      publishedAt: "2026-11-16T11:39:14.000Z",
    });
    expect(items[0]!.url).toMatch(/^https:\/\/news\.google\.com\/rss\/articles\//);
    expect(items[0]!.guid).toMatch(/^CBMi/);
    // No item keeps the " - Publisher" suffix.
    expect(items.filter((i) => i.title.endsWith(` - ${i.source}`))).toEqual([]);
  });

  it("decodes entities in titles", () => {
    const items = parseGoogleNews(fixture("news/gnews-gillibrand.xml"));
    expect(items.some((i) => i.title.includes("’"))).toBe(true);
    expect(items.some((i) => /&(amp|quot|#\d+);/.test(i.title))).toBe(false);
  });

  it("marks .gov publishers, and only those", () => {
    const items = parseGoogleNews(fixture("local/gnews-seattle.xml"));
    const gov = items.filter((i) => isGov(i.sourceUrl)).map((i) => i.sourceUrl);
    expect(gov).toHaveLength(1);
    expect(gov[0]).toMatch(/\.gov$/);
    expect(isGov("https://www.merkley.senate.gov")).toBe(true);
    expect(isGov("https://www.govexec.com")).toBe(false);
    expect(isGov(null)).toBe(false);
  });
});

describe("the member's query and filter", () => {
  it("builds the chamber's query, seven days", () => {
    expect(memberNewsQuery(schumer)).toBe('"Chuck Schumer" (senator OR sen OR congress) when:7d');
    expect(memberNewsQuery({ ...schumer, chamber: "house" })).toBe('"Chuck Schumer" (rep OR congressman OR congresswoman OR congress) when:7d');
    expect(gnewsUrl("a b")).toBe("https://news.google.com/rss/search?q=a%20b&hl=en-US&gl=US&ceid=US:en");
  });

  it("keeps a headline only when it names the member's surname as a word", () => {
    expect(namesMember("GILLIBRAND STATEMENT ON NATIONWIDE GROUND STOP", "Gillibrand")).toBe(true);
    expect(namesMember("Ocasio-Cortez rallies", "Ocasio-Cortez")).toBe(true);
    expect(namesMember("Schumerville news", "Schumer")).toBe(false);
    expect(namesMember("Sen. Gillibrand's comments to reporters in Buffalo", "Gillibrand")).toBe(true);
    expect(namesMember("Polls on Schumer’s standing", "Schumer")).toBe(true);
  });

  it("drops the Gillibrand results whose headline does not name her", () => {
    const rows = memberHeadlines(parseGoogleNews(fixture("news/gnews-gillibrand.xml")), gillibrand, NOW);
    expect(rows).toHaveLength(15);
    expect(rows.every((r) => /gillibrand/i.test(r.title))).toBe(true);
    expect(rows.find((r) => r.title.startsWith("At hearing, US Navy chief"))).toBeUndefined();
    expect(rows[0]!.id).toMatch(/^G000555:CBMi/);
  });

  it("drops what is older than seven days, and sets office for a .gov publisher", () => {
    const items = parseGoogleNews(fixture("news/gnews-schumer.xml"));
    expect(memberHeadlines(items, schumer, new Date("2026-11-25T00:00:00Z"))).toEqual([]);
    const gov = { ...items[0]!, sourceUrl: "https://www.schumer.senate.gov", source: "Senator Schumer (.gov)" };
    expect(memberHeadlines([gov], schumer, NOW)[0]!.tone).toBe("office");
    expect(memberHeadlines([items[0]!], schumer, NOW)[0]!.tone).toBeNull();
  });
});

const eval_ = JSON.parse(fixture("news/tone-reply-schumer.json")) as { reply: unknown };

describe("checkReply (the hand-labelled Schumer reply)", () => {
  const sent = Array.from({ length: 30 }, (_, i) => `h${i + 1}`);
  const r = checkReply(eval_.reply, sent);

  it("keeps tones for ids sent, nulls a tone outside the three, ignores an id never sent", () => {
    expect(r.tones.get("h1")).toBe("favorable");
    expect(r.tones.get("h2")).toBe("critical");
    expect(r.tones.get("h7")).toBeNull();
    expect(r.tones.get("h9")).toBeNull();
    expect(r.tones.has("h99")).toBe(false);
  });

  it("keeps stories of two or more known headlines, each headline in one story", () => {
    expect(r.stories).toEqual([
      { title: "Van Hollen challenges Schumer for Senate leader", headlineIds: ["h2", "h3", "h5", "h8"] },
      { title: "Polls on Schumer's standing", headlineIds: ["h4", "h10"] },
    ]);
  });

  it("refuses a reply that is not the schema's shape", () => {
    expect(() => checkReply({ headlines: "no" }, sent)).toThrow(/schema/);
  });

  it("sends short ids, the date, the publisher and the headline, nothing else", () => {
    const { user, ids } = promptFor("Chuck Schumer", [{ id: "S000148:x", title: "T", source: "NPR", published_at: "2026-11-16T11:39:14.000Z" }]);
    expect(ids).toEqual(["h1"]);
    expect(user).toBe("Member: Chuck Schumer\n\nHeadlines (id | date | publisher | headline):\nh1 | 2026-11-16 | NPR | T");
  });
});

async function freshDb() {
  const pg = new PGlite();
  await pg.exec(`create schema auth; create table auth.users (id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;`);
  for (const m of loadMigrations()) await pg.exec(m.sql);
  await pg.exec(`insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end) values
    ('S000148', 'Chuck', 'Schumer', 'D', 'NY', null, 'senate', '2023-01-03', '2099-01-03'),
    ('G000555', 'Kirsten', 'Gillibrand', 'D', 'NY', null, 'senate', '2025-01-03', '2099-01-03'),
    ('X000001', 'Gone', 'Member', 'R', 'TX', 1, 'house', '2021-01-03', '2023-01-03')`);
  return pg;
}

const feeds: Record<string, string> = {
  [gnewsUrl(memberNewsQuery(schumer))]: fixture("news/gnews-schumer.xml"),
  [gnewsUrl(memberNewsQuery(gillibrand))]: fixture("news/gnews-gillibrand.xml"),
};
const routes =
  (seen: string[] = []): FetchText =>
  async (url) => {
    seen.push(url);
    return url in feeds ? { status: 200, text: feeds[url]! } : { status: 404, text: "" };
  };

/** The model, stubbed at the seam: the hand-labelled reply for Schumer, nothing for anyone else. */
const stub = (calls: ModelCall[]): Complete => async (call) => {
  calls.push(call);
  return {
    data: call.user.includes("Chuck Schumer") ? eval_.reply : { headlines: [], stories: [] },
    model: "claude-sonnet-5-5",
    parts: [{ model: "claude-sonnet-5-5", usage: { input_tokens: 1500, output_tokens: 400, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 } }],
  };
};

describe("ingestNews", () => {
  let pg: PGlite;
  let db: Db;
  beforeEach(async () => {
    pg = await freshDb();
    db = pg as unknown as Db;
  });

  it("stores the current members' headlines, reads them once, and does not ask again within 12 hours", async () => {
    const seen: string[] = [];
    const calls: ModelCall[] = [];
    const slept: number[] = [];
    const r = await ingestNews(db, routes(seen), { complete: stub(calls), now: NOW, sleep: async (ms) => void slept.push(ms) });
    expect(r).toMatchObject({ ran: true, checked: 2, headlines: 45, failed: 0, read: 45, stories: 2, stoppedBy: "done" });
    expect(seen).toHaveLength(2);
    expect(slept).toEqual([1200]);
    expect(calls).toHaveLength(2);

    const { rows } = await pg.query<{ tone: string | null; n: number }>(
      "select tone, count(*)::int as n from member_news where member_id = 'S000148' group by tone order by tone nulls last",
    );
    expect(rows).toEqual([
      { tone: "critical", n: 4 },
      { tone: "favorable", n: 1 },
      { tone: "neutral", n: 3 },
      { tone: null, n: 22 },
    ]);
    const { rows: stories } = await pg.query<{ title: string; n: number }>(
      `select s.title, count(n.id)::int as n from member_news_stories s join member_news n on n.story_id = s.id
        group by s.title order by n desc`,
    );
    expect(stories).toEqual([
      { title: "Van Hollen challenges Schumer for Senate leader", n: 4 },
      { title: "Polls on Schumer's standing", n: 2 },
    ]);
    const { rows: read } = await pg.query<{ n: number }>("select count(*)::int as n from member_news where read_at is null");
    expect(read[0]!.n).toBe(0);

    // An hour later nobody is due: no request, no call.
    const again = await ingestNews(db, routes(seen), { complete: stub(calls), now: new Date(NOW.getTime() + 3_600_000), sleep: async () => {} });
    expect(again.checked).toBe(0);
    expect(seen).toHaveLength(2);
    expect(calls).toHaveLength(2);
  });

  it("stores headlines and skips tone without a model", async () => {
    const r = await ingestNews(db, routes(), { now: NOW, sleep: async () => {} });
    expect(r).toMatchObject({ checked: 2, headlines: 45, read: 0, stories: 0 });
    const { rows } = await pg.query<{ n: number }>("select count(*)::int as n from member_news where tone is not null or read_at is not null");
    expect(rows[0]!.n).toBe(0);
  });

  it("stops asking when Google News rate-limits, without failing the run", async () => {
    const r = await ingestNews(db, async () => ({ status: 503, text: "" }), { now: NOW, sleep: async () => {} });
    expect(r).toMatchObject({ ran: true, checked: 0, stoppedBy: "rate-limited", failed: 0 });
    const { rows } = await pg.query<{ error: string | null }>("select error from ingest_runs where source = 'news'");
    expect(rows).toEqual([{ error: null }]);
  });

  it("deletes headlines past 14 days and the stories left empty", async () => {
    await ingestNews(db, routes(), { complete: stub([]), now: NOW, sleep: async () => {} });
    await ingestNews(db, async () => ({ status: 200, text: "<rss></rss>" }), { now: new Date(NOW.getTime() + 15 * 86_400_000), sleep: async () => {} });
    const { rows } = await pg.query<{ n: number; s: number }>(
      "select (select count(*)::int from member_news) as n, (select count(*)::int from member_news_stories) as s",
    );
    expect(rows[0]).toEqual({ n: 0, s: 0 });
  });
});

describe("parseNewsArgs", () => {
  it("reads a budget and members, refuses the rest", () => {
    expect(parseNewsArgs(["--budget", "5", "--member", "S000148"])).toEqual({ budget: 5, members: ["S000148"] });
    expect(() => parseNewsArgs(["--budget", "0"])).toThrow();
    expect(() => parseNewsArgs(["--member", "schumer"])).toThrow();
  });
});
