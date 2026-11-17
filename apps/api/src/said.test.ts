import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { beforeAll, describe, expect, it } from "vitest";
import { NO_CONTACT, POSTS_CACHE_CONTROL, createApp, postLinks, type Member } from "./app.js";
import { pgSaid, type Db } from "./pg.js";

// Round 13: social accounts, campaign promises and posts, end to end through Postgres (PGlite).

const REAL = "In the Senate, Elissa will work every day to bring critical supply chains and manufacturing back home.";

let db: PGlite;
let said: ReturnType<typeof pgSaid>;

beforeAll(async () => {
  db = new PGlite();
  await db.exec(`create schema auth; create table auth.users (id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;`);
  for (const m of loadMigrations()) await db.exec(m.sql);
  await db.exec(`
    insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end, social) values
      ('S000148', 'Chuck', 'Schumer', 'D', 'NY', null, 'senate', '2023-01-03', '2029-01-03',
       '{"twitter":"SenSchumer","facebook":"senschumer","youtubeId":"UC-ABttxh8uQv_10qmwGaidw","bluesky":"schumer.senate.gov","extra":"x"}'),
      ('S001208', 'Elissa', 'Slotkin', 'D', 'MI', null, 'senate', '2025-01-03', '2031-01-03', null),
      ('G000555', 'Kirsten', 'Gillibrand', 'D', 'NY', null, 'senate', '2025-01-03', '2031-01-03', '{"twitter":"GillibrandNY","instagram":"senkirstengillibrand"}'),
      ('B001292', 'Don', 'Beyer', 'D', 'VA', 8, 'house', '2025-01-03', '2027-01-03', '{"mastodon":"@RepDonBeyer@mas.to"}'),
      ('X000001', 'Failed', 'Look', 'R', 'TX', 1, 'house', '2025-01-03', '2027-01-03', null);
    insert into campaign_sites (member_id, election_year, site_url, source, snapshot_url, snapshot_at, page_url, status) values
      ('S001208', 2024, 'https://elissaslotkin.org/', 'fec', 'https://web.archive.org/web/20241027183232/https://elissaslotkin.org/priorities/',
       '2024-10-27T18:32:32Z', 'https://elissaslotkin.org/priorities/', 'promises'),
      ('G000555', 2024, 'https://www.kirstengillibrand.com/', 'fec', 'https://web.archive.org/web/20241102220058/https://kirstengillibrand.com/',
       '2024-11-02T22:00:58Z', null, 'no_platform'),
      ('X000001', 2024, null, 'fec', null, null, null, 'failed');
    insert into campaign_promises (member_id, position, heading, quote, headline, topic) values
      ('S001208', 2, 'Protecting our Rights and Democracy', 'Elissa has made defending and expanding voting rights a priority.', 'defending and expanding voting rights', null),
      ('S001208', 1, 'Making Things in America', '${REAL}', 'bring critical supply chains and manufacturing back home', 'Commerce');
    insert into member_posts (id, member_id, network, posted_at, text, url, media_url) values
      ('youtube:a', 'S000148', 'youtube', '2026-11-16T20:04:48Z', 'Floor speech', 'https://www.youtube.com/watch?v=a', 'https://i3.ytimg.com/vi/a/hqdefault.jpg'),
      ('bluesky:b', 'S000148', 'bluesky', '2026-11-16T22:01:27Z', 'Grocery prices', 'https://bsky.app/profile/schumer.senate.gov/post/b', null),
      ('mastodon:c', 'B001292', 'mastodon', '2026-11-15T10:00:00Z', 'Hello', 'https://mas.to/@RepDonBeyer/c', null);
  `);
  said = pgSaid(db as unknown as Db);
});

describe("pgSaid", () => {
  it("serves only the known social keys, {} for a member with none, and nothing for an unknown ID", async () => {
    const s = await said.social(["S000148", "S001208", "Z999999"]);
    expect(s.get("S000148")).toEqual({
      twitter: "SenSchumer",
      facebook: "senschumer",
      youtubeId: "UC-ABttxh8uQv_10qmwGaidw",
      bluesky: "schumer.senate.gov",
    });
    expect(s.get("S001208")).toEqual({});
    expect(s.has("Z999999")).toBe(false);
  });

  it("serves promises in the page's order, no_platform with its snapshot, and a failed or missing look as unchecked", async () => {
    const p = await said.promises("S001208");
    expect(p).toMatchObject({
      status: "promises",
      electionYear: 2024,
      siteUrl: "https://elissaslotkin.org/",
      snapshotAt: "2024-10-27T18:32:32.000Z",
      pageUrl: "https://elissaslotkin.org/priorities/",
    });
    expect(p.promises.map((x) => x.heading)).toEqual(["Making Things in America", "Protecting our Rights and Democracy"]);
    expect(p.promises[0]).toEqual({ heading: "Making Things in America", quote: REAL, headline: "bring critical supply chains and manufacturing back home", topic: "Commerce" });
    expect(p.promises[1]!.topic).toBeNull();
    expect(await said.promises("G000555")).toMatchObject({ status: "no_platform", promises: [], pageUrl: null });
    expect((await said.promises("X000001")).status).toBe("unchecked");
    expect(await said.promises("S000148")).toEqual({
      status: "unchecked", electionYear: null, siteUrl: null, snapshotUrl: null, snapshotAt: null, pageUrl: null, promises: [],
    });
  });

  it("serves posts newest first across members, within the limit", async () => {
    const posts = await said.posts(["S000148", "B001292"], 2);
    expect(posts.map((p) => [p.id, p.memberId, p.postedAt])).toEqual([
      ["bluesky:b", "S000148", "2026-11-16T22:01:27.000Z"],
      ["youtube:a", "S000148", "2026-11-16T20:04:48.000Z"],
    ]);
    expect((await said.posts(["B001292"], 30)).map((p) => p.network)).toEqual(["mastodon"]);
  });

  it("answers empty before the migration rather than failing", async () => {
    const bare = new PGlite();
    await bare.exec("create table members (bioguide_id text primary key)");
    const old = pgSaid(bare as unknown as Db);
    expect((await old.social(["S000148"])).size).toBe(0);
    expect((await old.promises("S000148")).status).toBe("unchecked");
    expect(await old.posts(["S000148"], 30)).toEqual([]);
  });
});

describe("the routes", () => {
  const people: Member[] = [
    { bioguideId: "S000148", firstName: "Chuck", lastName: "Schumer", party: "D", state: "NY", district: null, chamber: "senate" },
    { bioguideId: "S001208", firstName: "Elissa", lastName: "Slotkin", party: "D", state: "MI", district: null, chamber: "senate" },
    { bioguideId: "G000555", firstName: "Kirsten", lastName: "Gillibrand", party: "D", state: "NY", district: null, chamber: "senate" },
  ];
  const app = () =>
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
      said,
    });

  it("puts the member's accounts on their detail", async () => {
    const res = await app().request("/v1/members/S000148");
    expect((await res.json()).member.social).toEqual({
      twitter: "SenSchumer",
      facebook: "senschumer",
      youtubeId: "UC-ABttxh8uQv_10qmwGaidw",
      bluesky: "schumer.senate.gov",
    });
  });

  it("serves promises, unchecked before the worker looked, and 404 for an unknown member", async () => {
    const slotkin = await (await app().request("/v1/members/S001208/promises")).json();
    expect(slotkin.status).toBe("promises");
    expect(slotkin.promises[0].quote).toBe(REAL);
    expect((await (await app().request("/v1/members/S000148/promises")).json()).status).toBe("unchecked");
    expect((await app().request("/v1/members/Z999999/promises")).status).toBe(404);
    expect((await app().request("/v1/members/slotkin/promises")).status).toBe(400);
  });

  it("serves a member's posts with links to the networks Floor cannot read", async () => {
    const res = await app().request("/v1/members/S000148/posts");
    expect(res.headers.get("cache-control")).toBe(POSTS_CACHE_CONTROL);
    const body = await res.json();
    expect(body.posts.map((p: { id: string }) => p.id)).toEqual(["bluesky:b", "youtube:a"]);
    expect(body.posts[0]).not.toHaveProperty("memberId");
    expect(body.links).toEqual({ x: "https://x.com/SenSchumer", facebook: "https://www.facebook.com/senschumer" });
    expect((await (await app().request("/v1/members/S001208/posts")).json())).toEqual({ posts: [], links: {} });
  });

  it("serves the wall: posts together, and who posts only where Floor links out", async () => {
    const body = await (await app().request("/v1/posts?members=S000148,G000555,B001292,Z999999")).json();
    expect(body.posts.map((p: { id: string; memberId: string }) => [p.id, p.memberId])).toEqual([
      ["bluesky:b", "S000148"],
      ["youtube:a", "S000148"],
      ["mastodon:c", "B001292"],
    ]);
    expect(body.unreadable).toEqual(["G000555"]);
    const thirteen = Array.from({ length: 13 }, (_, i) => `A${String(i).padStart(6, "0")}`).join(",");
    expect((await app().request(`/v1/posts?members=${thirteen}`)).status).toBe(400);
    expect((await app().request("/v1/posts?members=schumer")).status).toBe(400);
  });

  it("documents the routes", async () => {
    const doc = await (await app().request("/openapi.json")).json();
    expect(Object.keys(doc.paths)).toEqual(expect.arrayContaining(["/v1/members/{id}/promises", "/v1/members/{id}/posts", "/v1/posts"]));
    expect(doc.components.schemas.MemberPromises.required).toEqual(
      expect.arrayContaining(["status", "electionYear", "siteUrl", "snapshotUrl", "snapshotAt", "pageUrl", "promises"]),
    );
  });

  it("encodes handles in the links", () => {
    expect(postLinks({ instagram: "a b" })).toEqual({ instagram: "https://www.instagram.com/a%20b" });
    expect(postLinks(undefined)).toEqual({});
  });
});
