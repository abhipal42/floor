import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { beforeEach, describe, expect, it } from "vitest";
import type { Db } from "./db.js";
import type { FetchText } from "./rollcalls.js";
import {
  SOCIAL_URL,
  ingestPosts,
  ingestSocial,
  mastodonHandle,
  nameMatches,
  parseBlueskyFeed,
  parseMastodonStatuses,
  parseYouTubeFeed,
  pickBlueskyAccount,
  statusText,
  storePosts,
  toSocial,
  type PostRow,
  type SocialEntry,
} from "./social.js";

// Real responses, recorded 2026-11-16 and trimmed (fixtures/said).
const here = dirname(fileURLToPath(import.meta.url));
const fixture = (name: string) => readFileSync(join(here, "../fixtures/said", name), "utf8");
const json = (name: string) => JSON.parse(fixture(name));

async function freshDb() {
  const pg = new PGlite();
  await pg.exec(`create schema auth; create table auth.users (id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;`);
  for (const m of loadMigrations()) await pg.exec(m.sql);
  await pg.exec(`insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end) values
    ('S000148', 'Chuck', 'Schumer', 'D', 'NY', null, 'senate', '2023-01-03', '2099-01-03'),
    ('G000555', 'Kirsten', 'Gillibrand', 'D', 'NY', null, 'senate', '2025-01-03', '2099-01-03'),
    ('B001292', 'Don', 'Beyer', 'D', 'VA', 8, 'house', '2025-01-03', '2099-01-03'),
    ('X000001', 'Gone', 'Member', 'R', 'TX', 1, 'house', '2021-01-03', '2023-01-03')`);
  return pg;
}

/** A FetchText answering from a URL → body table; anything else is a 404. */
const routes =
  (table: Record<string, string>, seen: string[] = []): FetchText =>
  async (url) => {
    seen.push(url);
    return url in table ? { status: 200, text: table[url]! } : { status: 404, text: "" };
  };

const search = (q: string) => `https://public.api.bsky.app/xrpc/app.bsky.actor.searchActors?q=${encodeURIComponent(q)}&limit=25`;

describe("toSocial", () => {
  it("keeps the handles and the YouTube channel ID, nothing else", () => {
    const entries = json("legislators-social-media.json") as SocialEntry[];
    const schumer = entries.find((e) => e.id.bioguide === "S000148")!;
    expect(toSocial(schumer)).toEqual({
      twitter: "SenSchumer",
      facebook: "senschumer",
      instagram: "senschumer",
      youtube: "SenatorSchumer",
      youtubeId: "UC-ABttxh8uQv_10qmwGaidw",
    });
    expect(toSocial(entries.find((e) => e.id.bioguide === "B001292")!).mastodon).toBe("@RepDonBeyer@mas.to");
  });
});

describe("pickBlueskyAccount", () => {
  it("picks Schumer's .senate.gov account out of look-alikes and parodies", () => {
    const { actors } = json("bsky-search-chuck-schumer.json");
    // The unverified chuckschumer.com uses his exact display name: it must not be picked.
    expect(actors.some((a: { handle: string }) => a.handle === "chuckschumer.com")).toBe(true);
    expect(pickBlueskyAccount(actors, "Chuck", "Schumer")).toBe("schumer.senate.gov");
  });

  it("picks Gillibrand's verified account, not the unverified 'Senator Kirsten Gillibrand'", () => {
    const { actors } = json("bsky-search-kirsten-gillibrand.json");
    expect(pickBlueskyAccount(actors, "Kirsten", "Gillibrand")).toBe("kirstengillibrand.bsky.social");
  });

  it("answers null for an unverified match, a verified other person, or two verified look-alikes", () => {
    const v = { verifiedStatus: "valid" };
    expect(pickBlueskyAccount([{ handle: "chuckschumer.com", displayName: "Chuck Schumer" }], "Chuck", "Schumer")).toBeNull();
    expect(pickBlueskyAccount([{ handle: "benjaminweiss.bsky.social", displayName: "Benjamin S. Weiss", verification: v }], "Chuck", "Schumer")).toBeNull();
    expect(
      pickBlueskyAccount(
        [
          { handle: "a.bsky.social", displayName: "Jane Doe", verification: v },
          { handle: "b.bsky.social", displayName: "Jane Doe", verification: v },
        ],
        "Jane",
        "Doe",
      ),
    ).toBeNull();
    // Another member's official handle is not this member's.
    expect(pickBlueskyAccount([{ handle: "padilla.senate.gov", displayName: "Alex Padilla" }], "Adam", "Schiff")).toBeNull();
  });
});

describe("nameMatches", () => {
  it("ignores titles, middle names, accents and a trailing party label", () => {
    expect(nameMatches("Senator Kirsten E. Gillibrand (D-NY)", "Kirsten", "Gillibrand")).toBe(true);
    expect(nameMatches("Rep. Nydia Velázquez", "Nydia", "Velázquez")).toBe(true);
    expect(nameMatches("Chuck Schumer's other tulpa", "Chuck", "Schumer")).toBe(false);
    expect(nameMatches("Resign Chuck Schumer", "Chuck", "Schumer")).toBe(false);
  });
});

describe("ingestSocial (PGlite)", () => {
  let pg: PGlite;
  beforeEach(async () => {
    pg = await freshDb();
  });

  it("stores each current member's accounts and a verified Bluesky handle, and nothing for a former member", async () => {
    const seen: string[] = [];
    const fetchText = routes(
      {
        [SOCIAL_URL]: fixture("legislators-social-media.json"),
        [search("Chuck Schumer")]: fixture("bsky-search-chuck-schumer.json"),
        [search("Kirsten Gillibrand")]: fixture("bsky-search-kirsten-gillibrand.json"),
        [search("Don Beyer")]: JSON.stringify({ actors: [] }),
      },
      seen,
    );
    expect(await ingestSocial(pg as unknown as Db, fetchText)).toEqual({ members: 3, bluesky: 2, failed: 0 });
    const { rows } = await pg.query<{ bioguide_id: string; social: unknown }>("select bioguide_id, social from members order by 1");
    expect(rows).toEqual([
      { bioguide_id: "B001292", social: expect.objectContaining({ mastodon: "@RepDonBeyer@mas.to" }) },
      { bioguide_id: "G000555", social: expect.objectContaining({ bluesky: "kirstengillibrand.bsky.social", youtubeId: "UCVEloQogVsmnkd5vxJInmYg" }) },
      { bioguide_id: "S000148", social: expect.objectContaining({ bluesky: "schumer.senate.gov", twitter: "SenSchumer" }) },
      { bioguide_id: "X000001", social: null },
    ]);
    expect(seen.some((u) => u.includes("Gone"))).toBe(false);
  });

  it("keeps the stored Bluesky handle when the search fails", async () => {
    await pg.exec(`update members set social = '{"bluesky":"schumer.senate.gov"}' where bioguide_id = 'S000148'`);
    const fetchText = routes({ [SOCIAL_URL]: fixture("legislators-social-media.json") });
    const r = await ingestSocial(pg as unknown as Db, fetchText);
    expect(r.failed).toBe(3);
    const { rows } = await pg.query<{ social: { bluesky?: string; twitter?: string } }>("select social from members where bioguide_id = 'S000148'");
    expect(rows[0]!.social).toMatchObject({ bluesky: "schumer.senate.gov", twitter: "SenSchumer" });
  });
});

describe("the post parsers", () => {
  it("reads a YouTube channel feed: title, watch link, thumbnail", () => {
    const posts = parseYouTubeFeed(fixture("youtube-schumer.xml"), "S000148");
    expect(posts).toHaveLength(3);
    expect(posts[0]).toEqual({
      id: "youtube:JlA2eRiVeB8",
      member_id: "S000148",
      network: "youtube",
      posted_at: "2026-11-16T20:04:48.000Z",
      text: "Speaking live from the floor of the U.S. Senate",
      url: "https://www.youtube.com/watch?v=JlA2eRiVeB8",
      media_url: "https://i3.ytimg.com/vi/JlA2eRiVeB8/hqdefault.jpg",
    });
  });

  it("reads a Bluesky author feed with images and video thumbnails, and skips reposts", () => {
    const feed = json("bsky-feed-schumer.json");
    const repost = { ...feed.feed[0], reason: { $type: "app.bsky.feed.defs#reasonRepost" } };
    const posts = parseBlueskyFeed({ feed: [...feed.feed, repost] }, "S000148", "schumer.senate.gov");
    expect(posts.map((p) => [p.id, p.url, p.posted_at])).toEqual([
      ["bluesky:at://did:plc:zlgotdjaxzuhw4nefvkxxvxa/app.bsky.feed.post/3n2hjpq5urk2i", "https://bsky.app/profile/schumer.senate.gov/post/3n2hjpq5urk2i", "2026-11-16T22:01:27.090Z"],
      ["bluesky:at://did:plc:zlgotdjaxzuhw4nefvkxxvxa/app.bsky.feed.post/3n25dkegsmc2c", "https://bsky.app/profile/schumer.senate.gov/post/3n25dkegsmc2c", "2026-11-12T20:44:27.193Z"],
      ["bluesky:at://did:plc:zlgotdjaxzuhw4nefvkxxvxa/app.bsky.feed.post/3mzyaa62py22q", "https://bsky.app/profile/schumer.senate.gov/post/3mzyaa62py22q", "2026-11-10T20:01:45.049Z"],
    ]);
    expect(posts[0]!.media_url).toBeNull();
    expect(posts[1]!.media_url).toMatch(/^https:\/\/cdn\.bsky\.app\/img\/feed_thumbnail\//);
    expect(posts[2]!.media_url).toMatch(/^https:\/\/video\.bsky\.app\/.*thumbnail/);
    expect(posts[0]!.text).toMatch(/^Grocery prices are higher than ever/);
  });

  it("reads Mastodon statuses as text, with the first attachment's preview", () => {
    const posts = parseMastodonStatuses(json("mastodon-beyer-statuses.json"), "B001292");
    expect(posts).toHaveLength(3);
    expect(posts[0]!.id).toBe("mastodon:mas.to/113506125827095453");
    expect(posts[0]!.url).toBe("https://mas.to/@RepDonBeyer/113506125827095453");
    expect(posts[0]!.text).not.toMatch(/<|&amp;/);
    expect(posts[2]!.media_url).toMatch(/^https:\/\/media\.mas\.to\//);
    expect(parseMastodonStatuses([{ ...json("mastodon-beyer-statuses.json")[0], reblog: {} }], "B001292")).toEqual([]);
  });

  it("splits handles and strips status HTML", () => {
    expect(mastodonHandle("@RepDonBeyer@mas.to")).toEqual({ user: "RepDonBeyer", host: "mas.to" });
    expect(mastodonHandle("RepDonBeyer")).toBeNull();
    expect(statusText("<p>One &amp; two</p><p>Three<br>four</p>")).toBe("One & two\n\nThree\nfour");
  });
});

describe("ingestPosts (PGlite)", () => {
  let pg: PGlite;
  beforeEach(async () => {
    pg = await freshDb();
    await pg.exec(`update members set social = '{"youtubeId":"UC-ABttxh8uQv_10qmwGaidw","bluesky":"schumer.senate.gov"}' where bioguide_id = 'S000148';
                   update members set social = '{"mastodon":"@RepDonBeyer@mas.to"}' where bioguide_id = 'B001292';
                   update members set social = '{"twitter":"GillibrandNY"}' where bioguide_id = 'G000555'`);
  });

  const fetchText = routes({
    "https://www.youtube.com/feeds/videos.xml?channel_id=UC-ABttxh8uQv_10qmwGaidw": fixture("youtube-schumer.xml"),
    "https://public.api.bsky.app/xrpc/app.bsky.feed.getAuthorFeed?actor=schumer.senate.gov&filter=posts_no_replies&limit=30": fixture("bsky-feed-schumer.json"),
    "https://mas.to/api/v1/accounts/lookup?acct=RepDonBeyer": fixture("mastodon-beyer-lookup.json"),
    "https://mas.to/api/v1/accounts/109321777116021054/statuses?exclude_replies=true&exclude_reblogs=true&limit=30": fixture("mastodon-beyer-statuses.json"),
  });

  it("stores every network's posts and drops those older than 30 days", async () => {
    const r = await ingestPosts(pg as unknown as Db, fetchText, { now: new Date("2026-11-17T00:00:00Z") });
    expect(r).toEqual({ members: 2, posts: 9, failed: 0 });
    const { rows } = await pg.query<{ member_id: string; network: string; n: number }>(
      "select member_id, network, count(*)::int as n from member_posts group by 1, 2 order by 1, 2",
    );
    // Beyer's Mastodon posts are from November 2024: fetched, then not kept.
    expect(rows).toEqual([
      { member_id: "S000148", network: "bluesky", n: 3 },
      { member_id: "S000148", network: "youtube", n: 3 },
    ]);
  });

  it("counts a feed that fails and carries on", async () => {
    const broken = routes({ "https://mas.to/api/v1/accounts/lookup?acct=RepDonBeyer": fixture("mastodon-beyer-lookup.json") });
    const r = await ingestPosts(pg as unknown as Db, broken, { now: new Date("2024-11-20T00:00:00Z") });
    expect(r).toEqual({ members: 0, posts: 0, failed: 3 });
    const { rows } = await pg.query<{ failed: number; error: string | null }>("select failed, error from ingest_runs where source = 'posts'");
    expect(rows).toEqual([{ failed: 3, error: null }]);
  });

  it("keeps at most 30 posts per member, the newest", async () => {
    const posts: PostRow[] = Array.from({ length: 35 }, (_, i) => ({
      id: `youtube:v${i}`,
      member_id: "S000148",
      network: "youtube",
      posted_at: new Date(Date.UTC(2026, 10, 1, i)).toISOString(),
      text: `Video ${i}`,
      url: `https://www.youtube.com/watch?v=v${i}`,
      media_url: null,
    }));
    await storePosts(pg as unknown as Db, posts, new Date("2026-11-17T00:00:00Z"));
    const { rows } = await pg.query<{ n: number; oldest: string }>("select count(*)::int as n, min(id) filter (where id = 'youtube:v5') as oldest from member_posts");
    expect(rows[0]).toEqual({ n: 30, oldest: "youtube:v5" });
  });
});
