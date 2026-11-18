import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { beforeAll, describe, expect, it } from "vitest";
import { NO_CONTACT, createApp, type AppDeps, type Member } from "./app.js";
import { JURISDICTIONS } from "./jurisdictions.js";
import { LEGISLATORS_TTL_MS, openStatesLegislators, parsePeople, peopleUrl, type LegislatorLookup } from "./local.js";
import { memberNews, type Headline } from "./news.js";
import { pgLocal, pgNews, type Db } from "./pg.js";

// v0.2.60: members' news and polls, and the Local tab, end to end through Postgres (PGlite).

const NOW = new Date("2026-11-18T04:00:00Z");

let db: PGlite;

beforeAll(async () => {
  db = new PGlite();
  await db.exec(`create schema auth; create table auth.users (id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;`);
  for (const m of loadMigrations()) await db.exec(m.sql);
  // Headlines and polls as the worker stores them, from the real items (fixture-news-raw, 2026-11-17).
  await db.exec(`
    insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end) values
      ('S000148', 'Chuck', 'Schumer', 'D', 'NY', null, 'senate', '2023-01-03', '2029-01-03'),
      ('G000555', 'Kirsten', 'Gillibrand', 'D', 'NY', null, 'senate', '2025-01-03', '2031-01-03');
    insert into member_news_stories (id, member_id, title) values
      ('S000148:1:1', 'S000148', 'Van Hollen challenges Schumer for Senate leader'),
      ('S000148:2:1', 'S000148', 'A story left with one headline');
    insert into member_news (id, member_id, title, source, source_url, url, published_at, tone, story_id, read_at) values
      ('S000148:a', 'S000148', 'Schumer declares he has votes to beat Van Hollen and become majority leader', 'The Hill', 'https://thehill.com', 'https://news.google.com/rss/articles/a', '2026-11-17T20:23:00Z', 'favorable', null, '2026-11-18T03:00:00Z'),
      ('S000148:b', 'S000148', 'The Angry Democratic Base Powering the Challenge to Chuck Schumer', 'WSJ', 'https://www.wsj.com', 'https://news.google.com/rss/articles/b', '2026-11-17T20:01:00Z', 'critical', 'S000148:1:1', '2026-11-18T03:00:00Z'),
      ('S000148:c', 'S000148', 'Van Hollen''s bid to replace Schumer puts pressure on Democrats to take sides', 'PBS', 'https://www.pbs.org', 'https://news.google.com/rss/articles/c', '2026-11-17T19:52:58Z', 'neutral', 'S000148:1:1', '2026-11-18T03:00:00Z'),
      ('S000148:d', 'S000148', 'Schumer statement on the shutdown', 'Senator Schumer (.gov)', 'https://www.schumer.senate.gov', 'https://news.google.com/rss/articles/d', '2026-11-16T12:00:00Z', 'office', 'S000148:1:1', '2026-11-18T03:00:00Z'),
      ('S000148:e', 'S000148', 'Chuck Schumer - Britannica', 'Britannica', 'https://www.britannica.com', 'https://news.google.com/rss/articles/e', '2026-11-13T08:00:00Z', null, 'S000148:2:1', null),
      ('S000148:old', 'S000148', 'Older than the window', 'NPR', 'https://www.npr.org', 'https://news.google.com/rss/articles/old', '2026-11-09T00:00:00Z', 'critical', null, '2026-11-10T00:00:00Z'),
      ('G000555:a', 'G000555', 'Kirsten Gillibrand is dreaming of a Democratic supermajority', 'Politico', 'https://www.politico.com', 'https://news.google.com/rss/articles/g', '2026-11-14T15:00:00Z', null, null, null);
    insert into member_news_checks (member_id, checked_at) values ('S000148', '2026-11-18T03:00:00Z');
    insert into polls (id, pollster, fielded_from, fielded_to, population, sample_size, positive_label, positive_pct, negative_label, negative_pct, other_label, other_pct, url) values
      ('2026-11-economist-yougov-schumer', 'Economist/YouGov', '2026-11-13', '2026-11-16', 'U.S. adults', 1628, 'favorable', 22, 'unfavorable', 50, 'don''t know', 28, 'https://thehill.com/the-120/6225885-chuck-schumer-democrats-unpopularity-poll-results'),
      ('2026-11-data-for-progress-schumer-leader', 'Data for Progress', '2026-11-13', '2026-11-15', 'Democratic or Democratic-leaning likely voters', 538, 'Chuck Schumer should remain the Senate Democratic leader', 32, 'Senate Democrats should choose a new leader', 56, null, null, 'https://www.dataforprogress.org/blog/2026/11/16/democratic-leaning-voters-favor-van-hollen-over-schumer-for-majority-leader'),
      ('old-poll', 'Old Pollster', '2026-07-01', '2026-07-02', 'adults', null, 'yes', 40, 'no', 40, null, null, 'https://example.org/old');
    insert into poll_members (poll_id, member_id) values
      ('2026-11-economist-yougov-schumer', 'S000148'), ('2026-11-data-for-progress-schumer-leader', 'S000148'), ('old-poll', 'S000148');
    insert into local_items (id, jurisdiction_id, identifier, title, summary, body, date, status, yes, no, url) values
      ('legistar:nyc:1', 'nyc', 'Int. 891-A', 'Surveillance pricing ban', null, 'City Council', '2026-11-12', 'passed', 44, 5, null),
      ('legistar:seattle:17402', 'seattle', 'CB 121276', 'An ordinance relating to land use and zoning', null, 'City Council', '2026-11-13', 'passed', 8, 0, 'https://seattle.legistar.com/LegislationDetail.aspx?ID=17402'),
      ('openstates:a', 'ny', 'S 1', 'Signed bill', 'A summary', 'State Senate', '2026-11-11', 'signed', null, null, null),
      ('openstates:b', 'ny', 'A 2', 'Waiting bill', null, 'Assembly', '2026-06-10', 'awaiting_governor', null, null, null),
      ('openstates:c', 'ny', 'S 3', 'Signed long ago', null, 'State Senate', '2026-09-01', 'signed', null, null, null);
    insert into local_news (id, jurisdiction_id, title, source, source_url, url, published_at) values
      ('nyc:a', 'nyc', 'Julie Menin''s surveillance pricing ban passes the council', 'City & State New York', 'https://www.cityandstateny.com', 'https://news.google.com/rss/articles/n', '2026-11-12T21:47:47Z');
    insert into local_checks (jurisdiction_id, source, checked_at) values ('nyc', 'news', '2026-11-17T06:20:00Z'), ('nyc', 'records', '2026-11-17T06:30:00Z');
  `);
});

const people: Member[] = [
  { bioguideId: "S000148", firstName: "Chuck", lastName: "Schumer", party: "D", state: "NY", district: null, chamber: "senate" },
  { bioguideId: "G000555", firstName: "Kirsten", lastName: "Gillibrand", party: "D", state: "NY", district: null, chamber: "senate" },
];

const app = (extra: Partial<AppDeps> = {}) =>
  createApp({
    votes: { getVote: async () => null, recentVotes: async () => [], voteBreakdown: async () => ({ partyTotals: [], candidateTotals: [], positions: [], measure: null }) },
    members: {
      membersFor: async () => [],
      recentVotes: async () => [],
      getMember: async (id) => people.find((m) => m.bioguideId === id) ?? null,
      search: async () => [],
      partyLoyalty: async () => ({ votes: 0, withParty: 0, againstParty: 0 }),
      funding: async () => null,
      contact: async () => NO_CONTACT,
    },
    bills: { getBill: async () => null, getAnalysis: async () => null },
    nominations: { getNomination: async () => null },
    status: { lastRuns: async () => [] },
    live: { chambers: async () => [], liveVotes: async () => [] },
    locate: async () => null,
    now: () => NOW,
    news: pgNews(db as unknown as Db),
    local: pgLocal(db as unknown as Db),
    ...extra,
  });

describe("GET /v1/members/{id}/news", () => {
  it("serves the week: tone over the headlines (office apart), stories of two or more, polls from 90 days", async () => {
    const res = await app().request("/v1/members/S000148/news");
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toMatch(/max-age=300/);
    const body = await res.json();
    expect(body.memberId).toBe("S000148");
    expect(body.checkedAt).toBe("2026-11-18T03:00:00.000Z");
    expect(body.window).toEqual({ from: "2026-11-11T04:00:00.000Z", to: "2026-11-18T04:00:00.000Z" });
    expect(body.tone).toEqual({ favorable: 1, neutral: 1, critical: 1, office: 1 });
    expect(body.headlines.map((h: Headline) => [h.id, h.tone, h.storyId])).toEqual([
      ["S000148:a", "favorable", null],
      ["S000148:b", "critical", "S000148:1:1"],
      ["S000148:c", "neutral", "S000148:1:1"],
      ["S000148:d", "office", "S000148:1:1"],
      // Its story has one headline in the window, so it is not served and the headline is unattached.
      ["S000148:e", null, null],
    ]);
    expect(body.headlines[0]).toEqual({
      id: "S000148:a",
      title: "Schumer declares he has votes to beat Van Hollen and become majority leader",
      source: "The Hill",
      url: "https://news.google.com/rss/articles/a",
      publishedAt: "2026-11-17T20:23:00.000Z",
      tone: "favorable",
      storyId: null,
    });
    expect(body.stories).toEqual([
      {
        id: "S000148:1:1",
        title: "Van Hollen challenges Schumer for Senate leader",
        tone: { favorable: 0, neutral: 1, critical: 1, office: 1 },
        headlineIds: ["S000148:b", "S000148:c", "S000148:d"],
      },
    ]);
    expect(body.polls).toEqual([
      {
        id: "2026-11-economist-yougov-schumer",
        pollster: "Economist/YouGov",
        fieldedFrom: "2026-11-13",
        fieldedTo: "2026-11-16",
        population: "U.S. adults",
        sampleSize: 1628,
        positive: { label: "favorable", pct: 22 },
        negative: { label: "unfavorable", pct: 50 },
        other: { label: "don't know", pct: 28 },
        url: "https://thehill.com/the-120/6225885-chuck-schumer-democrats-unpopularity-poll-results",
      },
      {
        id: "2026-11-data-for-progress-schumer-leader",
        pollster: "Data for Progress",
        fieldedFrom: "2026-11-13",
        fieldedTo: "2026-11-15",
        population: "Democratic or Democratic-leaning likely voters",
        sampleSize: 538,
        positive: { label: "Chuck Schumer should remain the Senate Democratic leader", pct: 32 },
        negative: { label: "Senate Democrats should choose a new leader", pct: 56 },
        other: null,
        url: "https://www.dataforprogress.org/blog/2026/11/16/democratic-leaning-voters-favor-van-hollen-over-schumer-for-majority-leader",
      },
    ]);
  });

  it("serves tone null and no stories when nothing was AI-read, and no polls", async () => {
    const body = await (await app().request("/v1/members/G000555/news")).json();
    expect(body).toMatchObject({ checkedAt: null, tone: null, stories: [], polls: [] });
    expect(body.headlines).toHaveLength(1);
  });

  it("answers 404 for an unknown member and 400 for a malformed id", async () => {
    expect((await app().request("/v1/members/A000001/news")).status).toBe(404);
    expect((await app().request("/v1/members/schumer/news")).status).toBe(400);
  });

  it("answers an empty week before the migration rather than failing", async () => {
    const bare = new PGlite();
    await bare.exec("create table members (bioguide_id text primary key)");
    const body = await (await app({ news: pgNews(bare as unknown as Db), local: pgLocal(bare as unknown as Db) }).request("/v1/members/S000148/news")).json();
    expect(body).toMatchObject({ checkedAt: null, tone: null, stories: [], headlines: [], polls: [] });
    const hub = await (await app({ local: pgLocal(bare as unknown as Db) }).request("/v1/local/nyc")).json();
    expect(hub).toMatchObject({ updatedAt: null, enacted: [], waiting: [], news: [] });
  });

  it("does not count office headlines as AI-read", () => {
    const office: Headline = { id: "x", title: "t", source: "s", url: "u", publishedAt: NOW.toISOString(), tone: "office", storyId: null };
    const r = memberNews("S000148", { checkedAt: null, headlines: [office], storyTitles: new Map(), polls: [] }, NOW);
    expect(r.tone).toBeNull();
  });
});

describe("GET /v1/local", () => {
  it("lists all 50 states and nine cities, coverage derived from what is stored", async () => {
    const body = await (await app().request("/v1/local")).json();
    expect(body.jurisdictions).toHaveLength(59);
    const by = (id: string) => body.jurisdictions.find((j: { id: string }) => j.id === id);
    expect(by("ny")).toEqual({ id: "ny", kind: "state", name: "New York State", state: "NY", placeGeoid: null, coverage: "records" });
    expect(by("ca")).toMatchObject({ kind: "state", name: "California", coverage: "pending" });
    expect(by("nyc")).toEqual({ id: "nyc", kind: "city", name: "New York City", state: "NY", placeGeoid: "3651000", coverage: "records" });
    expect(by("seattle").coverage).toBe("records");
    expect(by("sf").coverage).toBe("pending");
    expect(by("philadelphia")).toMatchObject({ placeGeoid: "4260000", coverage: "news_only" });
    expect(JURISDICTIONS.map((j) => j.id)).toEqual(body.jurisdictions.map((j: { id: string }) => j.id));
  });
});

describe("GET /v1/local/{id}", () => {
  it("serves a state's hub: enacted in 30 days, waiting, headlines", async () => {
    const body = await (await app().request("/v1/local/ny")).json();
    expect(body.jurisdiction.id).toBe("ny");
    expect(body.enacted.map((i: { identifier: string }) => i.identifier)).toEqual(["S 1"]);
    expect(body.enacted[0]).toEqual({
      id: "openstates:a", identifier: "S 1", title: "Signed bill", summary: "A summary", body: "State Senate",
      date: "2026-11-11", status: "signed", yes: null, no: null, url: null,
    });
    // A waiting bill whose last passage is past 90 days (A 2, June) is not served: the worker keeps 90 days.
    expect(body.waiting).toEqual([]);
  });

  it("serves a city's hub: passed with the tally, no waiting, headlines with tone null", async () => {
    const body = await (await app().request("/v1/local/nyc")).json();
    expect(body.updatedAt).toBe("2026-11-17T06:30:00.000Z");
    expect(body.enacted).toEqual([
      { id: "legistar:nyc:1", identifier: "Int. 891-A", title: "Surveillance pricing ban", summary: null, body: "City Council", date: "2026-11-12", status: "passed", yes: 44, no: 5, url: null },
    ]);
    expect(body.waiting).toEqual([]);
    expect(body.news).toEqual([
      {
        id: "nyc:a",
        title: "Julie Menin's surveillance pricing ban passes the council",
        source: "City & State New York",
        url: "https://news.google.com/rss/articles/n",
        publishedAt: "2026-11-12T21:47:47.000Z",
        tone: null,
        storyId: null,
      },
    ]);
  });

  it("answers 404 for an unknown jurisdiction", async () => {
    expect((await app().request("/v1/local/atlantis")).status).toBe(404);
  });
});

describe("GET /v1/local/{state}/legislators", () => {
  const fake: LegislatorLookup = async (state, chamber, district) => [
    { id: `ocd-person/${state}-${chamber}-${district}`, name: `${chamber} ${district}`, party: "Democratic", chamber, district, photoUrl: null, url: null },
  ];

  it("asks for each chamber given, senate first", async () => {
    const body = await (await app({ legislators: fake }).request("/v1/local/NY/legislators?upper=27&lower=66")).json();
    expect(body.legislators.map((l: { id: string }) => l.id)).toEqual(["ocd-person/NY-upper-27", "ocd-person/NY-lower-66"]);
  });

  it("answers [] without a key, and 404 for a city or an unknown state", async () => {
    expect(await (await app().request("/v1/local/ny/legislators?upper=27")).json()).toEqual({ legislators: [] });
    expect((await app().request("/v1/local/zz/legislators")).status).toBe(404);
    expect((await app().request("/v1/local/nyc/legislators")).status).toBe(400);
  });

  it("reads Open States people (doc-derived shape), sends the key in a header, caches a day", async () => {
    // Shape from the Person schema's examples in https://v3.openstates.org/openapi.json (no key yet).
    const page = {
      results: [
        {
          id: "ocd-person/adb58f21-f2fd-4830-85b6-f490b0867d14",
          name: "Angela Augusta",
          party: "Democratic",
          image: "https://example.com/ncimg/3.png",
          openstates_url: "https://openstates.org/person/angela-augusta-5aDDEM5k2rMPKmUELdALsA/",
          current_role: { title: "Senator", org_classification: "upper", district: 3, division_id: "ocd-division/country:us/state:nc/sldu:3" },
        },
        { id: "ocd-person/other", name: "Not a senator", party: "Republican", image: "", current_role: { org_classification: "lower", district: "3" } },
      ],
      pagination: { per_page: 10, page: 1, max_page: 1, total_items: 2 },
    };
    expect(parsePeople(page, "upper", "3")).toEqual([
      {
        id: "ocd-person/adb58f21-f2fd-4830-85b6-f490b0867d14",
        name: "Angela Augusta",
        party: "Democratic",
        chamber: "upper",
        district: "3",
        photoUrl: "https://example.com/ncimg/3.png",
        url: "https://openstates.org/person/angela-augusta-5aDDEM5k2rMPKmUELdALsA/",
      },
    ]);
    const calls: { url: string; key: string | null }[] = [];
    let t = 0;
    const lookup = openStatesLegislators("KEY", {
      now: () => t,
      fetch: (async (url: string, init?: RequestInit) => {
        calls.push({ url, key: new Headers(init?.headers).get("x-api-key") });
        return new Response(JSON.stringify(page), { status: 200 });
      }) as typeof fetch,
    });
    await lookup("NC", "upper", "3");
    await lookup("NC", "upper", "3");
    expect(calls).toEqual([{ url: peopleUrl("NC", "upper", "3"), key: "KEY" }]);
    expect(calls[0]!.url).not.toContain("KEY");
    t = LEGISLATORS_TTL_MS + 1;
    await lookup("NC", "upper", "3");
    expect(calls).toHaveLength(2);
    const url = new URL(calls[0]!.url);
    expect([url.searchParams.get("jurisdiction"), url.searchParams.get("org_classification"), url.searchParams.get("district")]).toEqual([
      "ocd-jurisdiction/country:us/state:nc/government",
      "upper",
      "3",
    ]);
  });

  it("answers [] when Open States fails, without caching it", async () => {
    let n = 0;
    const lookup = openStatesLegislators("KEY", { fetch: (async () => (n++, new Response("", { status: 500 }))) as unknown as typeof fetch });
    expect(await lookup("NY", "lower", "66")).toEqual([]);
    expect(await lookup("NY", "lower", "66")).toEqual([]);
    expect(n).toBe(2);
  });
});
