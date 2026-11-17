import { errorText, startRun, type Db } from "./db.js";
import { withRetry, type FetchText } from "./rollcalls.js";

/*
 * Members' official social accounts, and their recent posts on the networks that can be read free.
 *
 * - `ingestSocial`: congress-legislators' legislators-social-media.json into members.social, plus a
 *   Bluesky account when Bluesky itself vouches for it (`pickBlueskyAccount`). X, Facebook and
 *   Instagram stay links only: their APIs are paid.
 * - `ingestPosts`: YouTube's channel feed, Bluesky's public author feed and the 13 Mastodon accounts'
 *   public statuses into member_posts. No keys anywhere, so every URL here is safe to log. Posts are
 *   stored as posted, with no like or repost counts: the app shows them newest first, never ranked.
 */

export const SOCIAL_URL = "https://unitedstates.github.io/congress-legislators/legislators-social-media.json";
export const BSKY = "https://public.api.bsky.app/xrpc";

/** Posts older than this, and past the newest `MAX_POSTS` per member, are deleted each run. */
export const KEEP_DAYS = 30;
export const MAX_POSTS = 30;

/** members.social. Strings or absent; `bluesky` is a handle Bluesky verified (see pickBlueskyAccount). */
export interface Social {
  twitter?: string;
  facebook?: string;
  instagram?: string;
  youtube?: string;
  youtubeId?: string;
  mastodon?: string;
  bluesky?: string;
}

/** An entry of legislators-social-media.json (the fields we use; `*_id` numbers besides youtube_id are dropped). */
export interface SocialEntry {
  id: { bioguide: string };
  social: Record<string, string | number | undefined>;
}

const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : undefined);

/** One entry as members.social, absent fields left out. */
export function toSocial(e: SocialEntry): Social {
  const s = e.social;
  const out: Social = {
    twitter: str(s.twitter),
    facebook: str(s.facebook),
    instagram: str(s.instagram),
    youtube: str(s.youtube),
    youtubeId: str(s.youtube_id),
    mastodon: str(s.mastodon),
  };
  return Object.fromEntries(Object.entries(out).filter(([, v]) => v !== undefined)) as Social;
}

/** Lower case, accents and punctuation folded away, single spaces: "Kirsten E. Gillibrand" → "kirsten e gillibrand". */
export function foldName(s: string): string {
  return s
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/['’]/g, "")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

/** Titles an account puts before the name ("Senator Kirsten Gillibrand"); dropped before comparing. */
const TITLES = new Set(["senator", "sen", "rep", "representative", "congressman", "congresswoman", "dr", "leader", "us", "u", "s"]);

/**
 * Whether an account's display name is the member's name: once folded, with titles in front and
 * anything after "(", "|", "," or " - " dropped, it starts with their first name and ends with their
 * surname ("Kirsten Gillibrand", "Senator Kirsten E. Gillibrand (D-NY)").
 */
export function nameMatches(displayName: string, first: string, last: string): boolean {
  const core = displayName.split(/[(|,]| - | – | — /)[0] ?? "";
  const words = foldName(core).split(" ").filter(Boolean);
  while (words.length && TITLES.has(words[0]!)) words.shift();
  const f = foldName(first).split(" ").filter(Boolean);
  const l = foldName(last).split(" ").filter(Boolean);
  if (!f.length || !l.length || words.length < f.length + l.length) return false;
  const starts = f.every((w, i) => words[i] === w);
  const ends = l.every((w, i) => words[words.length - l.length + i] === w);
  return starts && ends;
}

export interface BskyActor {
  did?: string;
  handle: string;
  displayName?: string;
  verification?: { verifiedStatus?: string };
}

const OFFICIAL = /\.(senate|house)\.gov$/i;

/**
 * The member's Bluesky handle among search results, or null. Only two kinds are accepted:
 * - a handle on .senate.gov or .house.gov (only Congress can publish those domains) carrying the
 *   member's surname in the handle or their name as display name;
 * - an account Bluesky marks verified (`verifiedStatus: "valid"`) whose display name is the member's.
 *
 * An official handle wins over a verified one. Two verified look-alikes and no official handle is
 * ambiguous, and answers null: never guess.
 */
export function pickBlueskyAccount(actors: BskyActor[], first: string, last: string): string | null {
  const surname = foldName(last).replace(/ /g, "");
  const official = actors.filter(
    (a) =>
      OFFICIAL.test(a.handle) &&
      (a.handle.toLowerCase().replace(/[^a-z0-9]/g, "").includes(surname) || nameMatches(a.displayName ?? "", first, last)),
  );
  if (official.length) return official[0]!.handle.toLowerCase();
  const verified = actors.filter(
    (a) => a.handle !== "handle.invalid" && a.verification?.verifiedStatus === "valid" && nameMatches(a.displayName ?? "", first, last),
  );
  return verified.length === 1 ? verified[0]!.handle.toLowerCase() : null;
}

async function getJson<T>(fetchText: FetchText, url: string): Promise<T> {
  const { status, text } = await fetchText(url);
  if (status !== 200) throw new Error(`${url} returned HTTP ${status}`);
  return JSON.parse(text) as T;
}

/** Runs `fn` over `items`, `width` at a time, in order of start. */
async function eachLimited<T>(items: T[], width: number, fn: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  const lane = async () => {
    while (next < items.length) await fn(items[next++]!);
  };
  await Promise.all(Array.from({ length: Math.min(width, items.length) }, lane));
}

interface CurrentMember {
  bioguide_id: string;
  first_name: string;
  last_name: string;
  social: Social | null;
}

const currentMembers = async (db: Db) =>
  (
    await db.query<CurrentMember>(
      "select bioguide_id, first_name, last_name, social from members where term_end > current_date order by bioguide_id",
    )
  ).rows;

/**
 * Refreshes members.social for every current member. A member the file has no entry for gets an
 * empty object (nothing to link), not null (never looked). A Bluesky search that fails keeps the
 * handle stored before, so one bad hour does not unlink an account.
 */
export async function ingestSocial(
  db: Db,
  fetchText: FetchText,
  opts: { log?: (msg: string) => void; width?: number } = {},
): Promise<{ members: number; bluesky: number; failed: number }> {
  const finish = await startRun(db, "social");
  const result = { members: 0, bluesky: 0, failed: 0 };
  try {
    const entries = await getJson<SocialEntry[]>(fetchText, SOCIAL_URL);
    const byId = new Map(entries.map((e) => [e.id.bioguide, toSocial(e)]));
    const rows: { bioguide_id: string; social: Social }[] = [];
    await eachLimited(await currentMembers(db), opts.width ?? 4, async (m) => {
      const social: Social = { ...(byId.get(m.bioguide_id) ?? {}) };
      try {
        const q = encodeURIComponent(`${m.first_name} ${m.last_name}`);
        const { actors } = await getJson<{ actors: BskyActor[] }>(fetchText, `${BSKY}/app.bsky.actor.searchActors?q=${q}&limit=25`);
        const handle = pickBlueskyAccount(actors, m.first_name, m.last_name);
        if (handle) social.bluesky = handle;
      } catch (err) {
        result.failed++;
        if (m.social?.bluesky) social.bluesky = m.social.bluesky;
        opts.log?.(`${m.bioguide_id}: Bluesky search failed: ${errorText(err)}`);
      }
      if (social.bluesky) result.bluesky++;
      rows.push({ bioguide_id: m.bioguide_id, social });
    });
    await withRetry(() =>
      db.query(
        `update members m set social = x.social
           from jsonb_to_recordset($1::jsonb) as x(bioguide_id text, social jsonb)
          where m.bioguide_id = x.bioguide_id`,
        [JSON.stringify(rows)],
      ),
    );
    result.members = rows.length;
    await finish(result.members, undefined, result.failed);
    return result;
  } catch (err) {
    await finish(result.members, errorText(err), result.failed);
    throw err;
  }
}

// ---------------------------------------------------------------------------------------------
// Posts

export interface PostRow {
  id: string;
  member_id: string;
  network: "youtube" | "bluesky" | "mastodon";
  posted_at: string;
  text: string | null;
  url: string;
  media_url: string | null;
}

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };

/** Decodes the HTML/XML entities a feed carries: named ones above, and numeric ones. */
export function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (m, e: string) => {
    if (e[0] === "#") {
      const code = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return Number.isFinite(code) ? String.fromCodePoint(code) : m;
    }
    return ENTITIES[e.toLowerCase()] ?? m;
  });
}

const tag = (xml: string, name: string) => {
  const m = xml.match(new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)</${name}>`));
  return m ? decodeEntities(m[1]!.trim()) : null;
};

/** A YouTube channel feed (videos.xml) as posts: the title is the text, the hqdefault thumbnail the media. */
export function parseYouTubeFeed(xml: string, memberId: string): PostRow[] {
  const out: PostRow[] = [];
  for (const [entry] of xml.matchAll(/<entry>[\s\S]*?<\/entry>/g)) {
    const videoId = tag(entry, "yt:videoId");
    const published = tag(entry, "published");
    if (!videoId || !published) continue;
    const thumb = entry.match(/<media:thumbnail\s+url="([^"]+)"/)?.[1];
    out.push({
      id: `youtube:${videoId}`,
      member_id: memberId,
      network: "youtube",
      posted_at: new Date(published).toISOString(),
      text: tag(entry, "title"),
      url: `https://www.youtube.com/watch?v=${videoId}`,
      media_url: thumb ? decodeEntities(thumb) : null,
    });
  }
  return out;
}

type Json = Record<string, unknown>;
const obj = (v: unknown): Json | undefined => (v && typeof v === "object" ? (v as Json) : undefined);

/** The first image (or video/link card thumbnail) of a Bluesky post's embed view. */
function bskyMedia(embed: Json | undefined): string | null {
  if (!embed) return null;
  const images = embed["images"] as Json[] | undefined;
  if (images?.length) return (images[0]!["thumb"] as string) ?? null;
  if (typeof embed["thumbnail"] === "string") return embed["thumbnail"];
  const external = obj(embed["external"]);
  if (typeof external?.["thumb"] === "string") return external["thumb"];
  return bskyMedia(obj(embed["media"]));
}

/**
 * An author feed (`filter=posts_no_replies`) as posts. Reposts are skipped (they carry a `reason`, or
 * another author): only what the member posted. The URL is the post on bsky.app.
 */
export function parseBlueskyFeed(feed: { feed?: Json[] }, memberId: string, handle: string): PostRow[] {
  const out: PostRow[] = [];
  for (const item of feed.feed ?? []) {
    if (item["reason"]) continue;
    const post = obj(item["post"]);
    const author = obj(post?.["author"]);
    const record = obj(post?.["record"]);
    const uri = post?.["uri"];
    if (!post || !record || typeof uri !== "string" || (author?.["handle"] as string | undefined)?.toLowerCase() !== handle) continue;
    if (record["reply"]) continue;
    const rkey = uri.split("/").at(-1)!;
    const at = (record["createdAt"] as string | undefined) ?? (post["indexedAt"] as string | undefined);
    if (!at || Number.isNaN(Date.parse(at))) continue;
    out.push({
      id: `bluesky:${uri}`,
      member_id: memberId,
      network: "bluesky",
      posted_at: new Date(at).toISOString(),
      text: typeof record["text"] === "string" ? record["text"] : null,
      url: `https://bsky.app/profile/${handle}/post/${rkey}`,
      media_url: bskyMedia(obj(post["embed"])),
    });
  }
  return out;
}

/** "@RepDonBeyer@mas.to" → { user: "RepDonBeyer", host: "mas.to" }; null when it is not one. */
export function mastodonHandle(s: string): { user: string; host: string } | null {
  const m = s.trim().match(/^@?([A-Za-z0-9_]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})$/);
  return m ? { user: m[1]!, host: m[2]!.toLowerCase() } : null;
}

/** A status's HTML as plain text: paragraphs and line breaks kept as newlines, tags dropped. */
export function statusText(html: string): string {
  return decodeEntities(
    html
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<\/p>\s*<p[^>]*>/gi, "\n\n")
      .replace(/<[^>]+>/g, ""),
  ).trim();
}

/** Public statuses (already without replies and boosts) as posts. A boost or reply that slips in is skipped. */
export function parseMastodonStatuses(statuses: Json[], memberId: string): PostRow[] {
  const out: PostRow[] = [];
  for (const s of statuses) {
    if (s["reblog"] || s["in_reply_to_id"]) continue;
    const url = (s["url"] as string | null) ?? (s["uri"] as string);
    if (typeof s["id"] !== "string" || !url || typeof s["created_at"] !== "string") continue;
    const media = (s["media_attachments"] as Json[] | undefined)?.[0];
    const host = new URL(url).host;
    out.push({
      id: `mastodon:${host}/${s["id"]}`,
      member_id: memberId,
      network: "mastodon",
      posted_at: new Date(s["created_at"]).toISOString(),
      text: typeof s["content"] === "string" ? statusText(s["content"]) : null,
      url,
      media_url: (media?.["preview_url"] as string | undefined) ?? null,
    });
  }
  return out;
}

/** One member's posts from every free network they have an account on. Failures are per network. */
async function memberPosts(fetchText: FetchText, m: CurrentMember, log?: (msg: string) => void) {
  const posts: PostRow[] = [];
  let failed = 0;
  const s = m.social ?? {};
  const attempt = async (network: string, fn: () => Promise<PostRow[]>) => {
    try {
      posts.push(...(await fn()));
    } catch (err) {
      failed++;
      log?.(`${m.bioguide_id} ${network}: ${errorText(err)}`);
    }
  };
  if (s.youtubeId) {
    await attempt("youtube", async () => {
      const { status, text } = await fetchText(`https://www.youtube.com/feeds/videos.xml?channel_id=${encodeURIComponent(s.youtubeId!)}`);
      if (status !== 200) throw new Error(`YouTube feed for ${s.youtubeId} returned HTTP ${status}`);
      return parseYouTubeFeed(text, m.bioguide_id);
    });
  }
  if (s.bluesky) {
    await attempt("bluesky", async () =>
      parseBlueskyFeed(
        await getJson(fetchText, `${BSKY}/app.bsky.feed.getAuthorFeed?actor=${encodeURIComponent(s.bluesky!)}&filter=posts_no_replies&limit=${MAX_POSTS}`),
        m.bioguide_id,
        s.bluesky!,
      ),
    );
  }
  const mastodon = s.mastodon ? mastodonHandle(s.mastodon) : null;
  if (mastodon) {
    await attempt("mastodon", async () => {
      const base = `https://${mastodon.host}/api/v1/accounts`;
      const account = await getJson<{ id: string }>(fetchText, `${base}/lookup?acct=${encodeURIComponent(mastodon.user)}`);
      const statuses = await getJson<Json[]>(
        fetchText,
        `${base}/${encodeURIComponent(account.id)}/statuses?exclude_replies=true&exclude_reblogs=true&limit=${MAX_POSTS}`,
      );
      return parseMastodonStatuses(statuses, m.bioguide_id);
    });
  }
  return { posts, failed };
}

/** Upserts posts, then deletes what is past KEEP_DAYS or beyond the newest MAX_POSTS of a member. */
export async function storePosts(db: Db, posts: PostRow[], now: Date): Promise<void> {
  const cutoff = new Date(now.getTime() - KEEP_DAYS * 86_400_000).toISOString();
  const fresh = posts.filter((p) => p.posted_at >= cutoff);
  if (fresh.length) {
    await withRetry(() =>
      db.query(
        `insert into member_posts (id, member_id, network, posted_at, text, url, media_url)
         select distinct on (id) id, member_id, network, posted_at, text, url, media_url
           from jsonb_to_recordset($1::jsonb) as x(id text, member_id text, network text, posted_at timestamptz, text text, url text, media_url text)
          order by id
         on conflict (id) do update set posted_at = excluded.posted_at, text = excluded.text, url = excluded.url, media_url = excluded.media_url`,
        [JSON.stringify(fresh)],
      ),
    );
  }
  await withRetry(() =>
    db.query(
      `delete from member_posts where posted_at < $1::timestamptz
          or id in (select id from (select id, row_number() over (partition by member_id order by posted_at desc, id) as n from member_posts) r where r.n > $2)`,
      [cutoff, MAX_POSTS],
    ),
  );
}

/** Every current member's recent posts from YouTube, Bluesky and Mastodon. */
export async function ingestPosts(
  db: Db,
  fetchText: FetchText,
  opts: { now?: Date; log?: (msg: string) => void; width?: number } = {},
): Promise<{ members: number; posts: number; failed: number }> {
  const finish = await startRun(db, "posts");
  const result = { members: 0, posts: 0, failed: 0 };
  try {
    const all: PostRow[] = [];
    const members = (await currentMembers(db)).filter((m) => m.social && (m.social.youtubeId || m.social.bluesky || m.social.mastodon));
    await eachLimited(members, opts.width ?? 6, async (m) => {
      const r = await memberPosts(fetchText, m, opts.log);
      all.push(...r.posts);
      result.failed += r.failed;
      if (r.posts.length) result.members++;
    });
    await storePosts(db, all, opts.now ?? new Date());
    result.posts = all.length;
    await finish(result.posts, undefined, result.failed);
    return result;
  } catch (err) {
    await finish(result.posts, errorText(err), result.failed);
    throw err;
  }
}
