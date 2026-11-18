import { z } from "zod";
import { errorText, startRun, type Db } from "./db.js";
import { isFatal, partsCost, type Complete } from "./analysis.js";
import { gnewsUrl, isGov, memberNewsQuery, namesMember, parseGoogleNews, type NewsItem } from "./gnews.js";
import { withRetry, type FetchText } from "./rollcalls.js";

/*
 * Members' headlines (the News page): Google News RSS, then one Claude call per member that has
 * unread headlines, for tone and stories.
 *
 * - Budgeted: each run asks about the `budget` members checked longest ago (default 100), none more
 *   often than every CHECK_EVERY_HOURS, one request every `delayMs` (1.2 s). Hourly, that walks every
 *   member about every 6 hours, held to 12.
 * - A headline is kept only when its title names the member (their surname) and it is from the last
 *   7 days. A .gov publisher's headline is tone `office`: set here, never by the model, and never
 *   counted in a tone bar.
 * - Stored: title, publisher, publisher's site, date, link. Never article text (gnews.ts).
 * - Tone is how the headline frames the member (favorable / neutral / critical), not whether the
 *   news is good. Stories are groups of >= 2 headlines about one event, titled neutrally by the
 *   model. The reply is checked strictly: an id the call did not send is dropped, a tone outside the
 *   three is null, a story left with fewer than two headlines is dropped.
 */

export const WINDOW_DAYS = 7;
export const KEEP_DAYS = 14;
export const CHECK_EVERY_HOURS = 12;
export const DEFAULT_BUDGET = 100;
export const DEFAULT_DELAY_MS = 1200;
/** Most headlines one model call reads; past this the oldest are left unread (still shown, tone null). */
export const MAX_READ = 60;
/** Session advisory lock held for a run, so two overlapping runs never pay for the same member. */
export const RUN_LOCK_KEY = 4_200_060;

export type Tone = "favorable" | "neutral" | "critical" | "office";

export interface NewsMember {
  bioguide_id: string;
  first_name: string;
  last_name: string;
  chamber: "house" | "senate";
}

export interface NewsRow {
  id: string;
  member_id: string;
  title: string;
  source: string;
  source_url: string | null;
  url: string;
  published_at: string;
  tone: Tone | null;
}

/** A member's feed items as rows: those naming them, from the last WINDOW_DAYS, .gov ones as `office`. */
export function memberHeadlines(items: NewsItem[], m: NewsMember, now: Date): NewsRow[] {
  const from = now.getTime() - WINDOW_DAYS * 86_400_000;
  const seen = new Set<string>();
  const out: NewsRow[] = [];
  for (const it of items) {
    if (!namesMember(it.title, m.last_name) || Date.parse(it.publishedAt) < from) continue;
    const id = `${m.bioguide_id}:${it.guid}`;
    if (seen.has(id)) continue;
    seen.add(id);
    out.push({
      id,
      member_id: m.bioguide_id,
      title: it.title,
      source: it.source,
      source_url: it.sourceUrl,
      url: it.url,
      published_at: it.publishedAt,
      tone: isGov(it.sourceUrl) ? "office" : null,
    });
  }
  return out;
}

/** Upserts headlines. A headline already stored keeps its tone, story and read time. */
export async function storeHeadlines(db: Db, rows: NewsRow[]): Promise<void> {
  if (!rows.length) return;
  await withRetry(() =>
    db.query(
      `insert into member_news (id, member_id, title, source, source_url, url, published_at, tone)
       select distinct on (id) id, member_id, title, source, source_url, url, published_at, tone
         from jsonb_to_recordset($1::jsonb) as x(id text, member_id text, title text, source text, source_url text,
                                                url text, published_at timestamptz, tone text)
        order by id
       on conflict (id) do update set title = excluded.title, source = excluded.source, source_url = excluded.source_url,
         url = excluded.url, published_at = excluded.published_at`,
      [JSON.stringify(rows)],
    ),
  );
}

// ---------------------------------------------------------------------------------------------
// Tone and stories

const SYSTEM = `You read news headlines about one U.S. member of Congress for Floor, a nonpartisan app that tracks Congress. Readers see your labels marked as AI-read, next to the headlines and links.

For each headline, give its tone toward the member, as the headline itself frames them:
- favorable: the headline presents the member positively (praise, a win, support for them, credit).
- critical: the headline presents the member negatively (criticism, a loss, a challenge to them, blame, a scandal).
- neutral: neither, or a plain report of what they did or said.
Judge only how the headline frames the member, not whether the news is good or bad, and not your own view of them or their politics. Use only the headline's words; no outside knowledge.

Then group headlines that report the same specific event or development into stories. Only groups of two or more; a headline belongs to at most one story; most headlines may belong to none. Give each story a short title (at most 8 words) in neutral wording that takes no side, names no tone, and adds nothing the headlines do not say.

Use the headline ids exactly as given.`;

export const SCHEMA = {
  type: "object",
  properties: {
    headlines: {
      type: "array",
      items: {
        type: "object",
        properties: { id: { type: "string" }, tone: { type: "string", enum: ["favorable", "neutral", "critical"] } },
        required: ["id", "tone"],
        additionalProperties: false,
      },
    },
    stories: {
      type: "array",
      items: {
        type: "object",
        properties: { title: { type: "string" }, headlineIds: { type: "array", items: { type: "string" } } },
        required: ["title", "headlineIds"],
        additionalProperties: false,
      },
    },
  },
  required: ["headlines", "stories"],
  additionalProperties: false,
};

const Reply = z.object({
  headlines: z.array(z.object({ id: z.string(), tone: z.string() })),
  stories: z.array(z.object({ title: z.string(), headlineIds: z.array(z.string()) })),
});

export class NewsReadError extends Error {}

export interface ReadResult {
  /** Tone per headline id sent; null when the model gave none or one outside the three. */
  tones: Map<string, "favorable" | "neutral" | "critical" | null>;
  stories: { title: string; headlineIds: string[] }[];
}

const TONES = new Set(["favorable", "neutral", "critical"]);
const MAX_STORY_TITLE = 90;

/**
 * Checks a reply against the ids sent: unknown ids dropped, tones outside the three null, a
 * headline in two stories kept in the first, stories with fewer than two headlines or no title
 * dropped. Throws when the reply is not the schema's shape at all.
 */
export function checkReply(data: unknown, sent: string[]): ReadResult {
  const parsed = Reply.safeParse(data);
  if (!parsed.success) throw new NewsReadError("model output did not match the schema");
  const known = new Set(sent);
  const tones = new Map<string, "favorable" | "neutral" | "critical" | null>(sent.map((id) => [id, null]));
  for (const h of parsed.data.headlines) {
    if (known.has(h.id) && TONES.has(h.tone)) tones.set(h.id, h.tone as "favorable" | "neutral" | "critical");
  }
  const used = new Set<string>();
  const stories: ReadResult["stories"] = [];
  for (const s of parsed.data.stories) {
    const title = s.title.replace(/\s+/g, " ").trim();
    const ids = [...new Set(s.headlineIds)].filter((id) => known.has(id) && !used.has(id));
    if (!title || title.length > MAX_STORY_TITLE || ids.length < 2) continue;
    ids.forEach((id) => used.add(id));
    stories.push({ title, headlineIds: ids });
  }
  return { tones, stories };
}

/** The headlines sent to the model, as the short ids it sees ("h1"…) and the stored ids behind them. */
export function promptFor(name: string, headlines: { id: string; title: string; source: string; published_at: string }[]) {
  const ids = headlines.map((_, i) => `h${i + 1}`);
  const lines = headlines.map((h, i) => `${ids[i]} | ${h.published_at.slice(0, 10)} | ${h.source} | ${h.title}`);
  return { user: `Member: ${name}\n\nHeadlines (id | date | publisher | headline):\n${lines.join("\n")}`, ids };
}

/**
 * Reads one member's window of headlines (newest MAX_READ): tone on each, stories replaced whole.
 * Office headlines are sent for grouping but keep `office`.
 */
export async function readMemberNews(
  db: Db,
  m: NewsMember,
  complete: Complete,
  now: Date,
): Promise<{ read: number; stories: number; costUsd: number | null }> {
  const from = new Date(now.getTime() - WINDOW_DAYS * 86_400_000).toISOString();
  const { rows } = await db.query<{ id: string; title: string; source: string; published_at: Date | string; tone: Tone | null }>(
    `select id, title, source, published_at, tone from member_news
      where member_id = $1 and published_at >= $2::timestamptz order by published_at desc, id limit $3`,
    [m.bioguide_id, from, MAX_READ],
  );
  if (!rows.length) return { read: 0, stories: 0, costUsd: 0 };
  const headlines = rows.map((r) => ({ ...r, published_at: new Date(r.published_at).toISOString() }));
  const { user, ids } = promptFor(`${m.first_name} ${m.last_name}`, headlines);
  const res = await complete({ system: SYSTEM, user, schema: SCHEMA, maxTokens: 6000 });
  const reply = checkReply(res.data, ids);
  const real = new Map(ids.map((short, i) => [short, headlines[i]!.id]));
  const stamp = now.getTime();
  const stories = reply.stories.map((s, i) => ({ id: `${m.bioguide_id}:${i + 1}:${stamp}`, title: s.title, ids: s.headlineIds.map((h) => real.get(h)!) }));
  const storyOf = new Map(stories.flatMap((s) => s.ids.map((id) => [id, s.id] as const)));
  const updates = headlines.map((h, i) => ({
    id: h.id,
    tone: h.tone === "office" ? "office" : reply.tones.get(ids[i]!) ?? null,
    story_id: storyOf.get(h.id) ?? null,
  }));
  await withRetry(() =>
    db.query(
      `with gone as (delete from member_news_stories where member_id = $1 and not (id = any($4::text[]))),
            added as (
              insert into member_news_stories (id, member_id, title, created_at)
              select s->>'id', $1, s->>'title', $3::timestamptz from jsonb_array_elements($2::jsonb) as s
              on conflict (id) do update set title = excluded.title
              returning id)
       select count(*)::int as n from added`,
      [m.bioguide_id, JSON.stringify(stories.map(({ id, title }) => ({ id, title }))), now.toISOString(), stories.map((s) => s.id)],
    ),
  );
  await withRetry(() =>
    db.query(
      `update member_news n set tone = x.tone, story_id = x.story_id, read_at = $2::timestamptz
         from jsonb_to_recordset($1::jsonb) as x(id text, tone text, story_id text)
        where n.id = x.id`,
      [JSON.stringify(updates), now.toISOString()],
    ),
  );
  return { read: headlines.length, stories: stories.length, costUsd: partsCost(res.parts) };
}

// ---------------------------------------------------------------------------------------------
// The job

async function membersDue(db: Db, budget: number, now: Date, only?: string[]): Promise<NewsMember[]> {
  const { rows } = await db.query<NewsMember>(
    `select m.bioguide_id, m.first_name, m.last_name, m.chamber
       from members m left join member_news_checks c on c.member_id = m.bioguide_id
      where m.term_end > $1::date
        and ($3::text[] is null or m.bioguide_id = any($3::text[]))
        and ($3::text[] is not null or c.checked_at is null or c.checked_at < $1::timestamptz - make_interval(hours => $4))
      order by c.checked_at nulls first, m.bioguide_id
      limit $2`,
    [now.toISOString(), budget, only?.length ? only : null, CHECK_EVERY_HOURS],
  );
  return rows;
}

export interface NewsRunResult {
  ran: boolean;
  checked: number;
  headlines: number;
  failed: number;
  read: number;
  stories: number;
  costUsd: number | null;
  stoppedBy: "done" | "rate-limited";
}

const sleepFor = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * One run of the news step. `complete` absent (no ANTHROPIC_API_KEY): headlines are stored and the
 * tone pass is skipped. `db` must be a single connection: the run holds an advisory lock on it.
 * Google News answering 429 or 503 ends the asking early (and is not an error): the next run goes on.
 */
export async function ingestNews(
  db: Db,
  fetchText: FetchText,
  opts: {
    complete?: Complete;
    budget?: number;
    delayMs?: number;
    members?: string[];
    now?: Date;
    sleep?: (ms: number) => Promise<void>;
    log?: (msg: string) => void;
  } = {},
): Promise<NewsRunResult> {
  const result: NewsRunResult = { ran: false, checked: 0, headlines: 0, failed: 0, read: 0, stories: 0, costUsd: 0, stoppedBy: "done" };
  const { rows: lock } = await db.query<{ locked: boolean }>("select pg_try_advisory_lock($1) as locked", [RUN_LOCK_KEY]);
  if (!lock[0]?.locked) {
    opts.log?.("another news run is in progress; exiting");
    return result;
  }
  result.ran = true;
  const now = opts.now ?? new Date();
  const sleep = opts.sleep ?? sleepFor;
  try {
    const finish = await startRun(db, "news");
    try {
      const due = await membersDue(db, opts.budget ?? DEFAULT_BUDGET, now, opts.members);
      const withNew: NewsMember[] = [];
      for (const [i, m] of due.entries()) {
        if (i > 0) await sleep(opts.delayMs ?? DEFAULT_DELAY_MS);
        const url = gnewsUrl(memberNewsQuery(m));
        let status: number;
        let text: string;
        try {
          ({ status, text } = await fetchText(url));
        } catch (err) {
          result.failed++;
          opts.log?.(`${m.bioguide_id}: ${errorText(err)}`);
          continue;
        }
        if (status === 429 || status === 503) {
          opts.log?.(`Google News answered HTTP ${status}; stopping for this run`);
          result.stoppedBy = "rate-limited";
          break;
        }
        if (status !== 200) {
          result.failed++;
          opts.log?.(`${m.bioguide_id}: ${url} returned HTTP ${status}`);
          continue;
        }
        const rows = memberHeadlines(parseGoogleNews(text), m, now);
        await storeHeadlines(db, rows);
        await db.query(
          `insert into member_news_checks (member_id, checked_at) values ($1, $2::timestamptz)
           on conflict (member_id) do update set checked_at = excluded.checked_at`,
          [m.bioguide_id, now.toISOString()],
        );
        result.checked++;
        result.headlines += rows.length;
        withNew.push(m);
      }
      await db.query("delete from member_news where published_at < $1::timestamptz", [
        new Date(now.getTime() - KEEP_DAYS * 86_400_000).toISOString(),
      ]);
      await db.query("delete from member_news_stories s where not exists (select 1 from member_news n where n.story_id = s.id)");

      if (opts.complete) {
        const from = new Date(now.getTime() - WINDOW_DAYS * 86_400_000).toISOString();
        const { rows: unread } = await db.query<{ member_id: string }>(
          `select distinct member_id from member_news
            where member_id = any($1::text[]) and read_at is null and tone is distinct from 'office' and published_at >= $2::timestamptz`,
          [withNew.map((m) => m.bioguide_id), from],
        );
        const toRead = new Set(unread.map((r) => r.member_id));
        for (const m of withNew.filter((x) => toRead.has(x.bioguide_id))) {
          try {
            const r = await readMemberNews(db, m, opts.complete, now);
            result.read += r.read;
            result.stories += r.stories;
            result.costUsd = result.costUsd === null || r.costUsd === null ? null : result.costUsd + r.costUsd;
          } catch (err) {
            if (isFatal(err)) throw err;
            result.failed++;
            opts.log?.(`${m.bioguide_id}: tone read failed: ${errorText(err)}`);
          }
        }
      } else {
        opts.log?.("ANTHROPIC_API_KEY unset: headlines stored, tone and stories skipped");
      }
      await finish(result.headlines, undefined, result.failed);
      return result;
    } catch (err) {
      await finish(result.headlines, errorText(err), result.failed);
      throw err;
    }
  } finally {
    await db.query("select pg_advisory_unlock($1)", [RUN_LOCK_KEY]);
  }
}

/** Parses `news [--budget N] [--member ID ...]`. */
export function parseNewsArgs(args: string[]): { budget: number; members: string[] } {
  const out = { budget: DEFAULT_BUDGET, members: [] as string[] };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--budget") {
      const n = Number(args[++i]);
      if (!Number.isInteger(n) || n <= 0) throw new Error("--budget needs a positive whole number");
      out.budget = n;
    } else if (a === "--member") {
      const id = args[++i] ?? "";
      if (!/^[A-Z]\d{6}$/.test(id)) throw new Error(`--member needs a Bioguide ID like S000148, got "${id}"`);
      out.members.push(id);
    } else throw new Error(`news: unknown argument "${a}"`);
  }
  return out;
}
