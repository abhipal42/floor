import { z } from "zod";
import { errorText, startRun, type Db } from "./db.js";
import { pickCandidateId, type FecGet } from "./fec.js";
import { electionDay } from "./elect.js";
import { isFatal, partsCost, type Complete } from "./analysis.js";
import { withRetry, type FetchText } from "./rollcalls.js";

/*
 * Campaign promises: what the campaign site that won a member this term said they would do.
 *
 *   1. The site is the FEC's: the `website` the member's own principal campaign committee filed for
 *      that race (OpenFEC /candidate/{id}/committees, designation P, the committee naming this
 *      candidate). No committee website → no_site. Nothing is searched for and no third party's page
 *      is read: a site Floor found by guessing could be someone else's.
 *   2. The page is the Wayback Machine's last capture of that site BEFORE election day (CDX), so it
 *      is what voters could read, not what the site says now → no_snapshot when there is none. From
 *      that capture's links, the issues/priorities page if there is one, else the home page itself.
 *   3. Claude reads the page's text and returns lines from it: quotes only, never a rewrite.
 *   4. The worker keeps a line only when its quote and headline are found verbatim in the page text
 *      (whitespace and quote marks normalised). A heading is kept only when it is on the page too;
 *      a topic only when it is one of the 32 policy areas. Nothing found → no_platform.
 *
 * The Wayback and FEC URLs here: the FEC client carries the key and never logs a URL (lesson 7);
 * Wayback URLs carry no key and are logged.
 */

/** At most this many promises a member. A site with more is cut at the model's first picks. */
export const MAX_PROMISES = 12;

/** Page text past this many characters is cut (an issues page is a few thousand). */
export const MAX_PAGE_CHARS = 60_000;

/** A page with less text than this has no platform on it to read; Claude is not called. */
export const MIN_PAGE_CHARS = 200;

/** A quote shorter than this proves nothing about where it came from. */
export const MIN_QUOTE_CHARS = 20;

/** Session advisory lock held for a run, so two overlapping runs never pay for the same member. */
export const RUN_LOCK_KEY = 4_200_013;

/**
 * The 32 CRS policy areas, as Congress.gov spells them: Floor's topics. A copy of POLICY_AREAS in
 * apps/api/src/bills.ts (the worker cannot import the API); promises.test.ts checks they are equal.
 */
export const TOPICS = [
  "Agriculture and Food", "Animals", "Armed Forces and National Security", "Arts, Culture, Religion",
  "Civil Rights and Liberties, Minority Issues", "Commerce", "Congress", "Crime and Law Enforcement",
  "Economics and Public Finance", "Education", "Emergency Management", "Energy", "Environmental Protection",
  "Families", "Finance and Financial Sector", "Foreign Trade and International Finance",
  "Government Operations and Politics", "Health", "Housing and Community Development", "Immigration",
  "International Affairs", "Labor and Employment", "Law", "Native Americans",
  "Public Lands and Natural Resources", "Science, Technology, Communications", "Social Sciences and History",
  "Social Welfare", "Sports and Recreation", "Taxation", "Transportation and Public Works",
  "Water Resources Development",
] as const;

export type Status = "promises" | "no_platform" | "no_site" | "no_snapshot" | "failed";

export interface CampaignPromise {
  heading: string | null;
  quote: string;
  headline: string;
  topic: string | null;
}

// ---------------------------------------------------------------------------------------------
// Which race, which site

/**
 * The year of the race that won the term starting `termStart`: the year before, for a regular term
 * (January 3); the same year for a special election or appointment's term starting mid-year.
 */
export const electionYear = (termStart: string) => (termStart.slice(5) === "01-03" ? Number(termStart.slice(0, 4)) - 1 : Number(termStart.slice(0, 4)));

/**
 * The day a snapshot must come before: election day for a regular term. A mid-year term has no
 * election day we hold (a special election's date varies by state), so the start of the term stands
 * in: the site as it was before they were sworn in.
 */
export const snapshotCutoff = (termStart: string) =>
  termStart.slice(5) === "01-03" ? electionDay(electionYear(termStart)) : termStart;

/** "WWW.ELISSASLOTKIN.ORG" → "https://www.elissaslotkin.org/". FEC files websites upper-cased, so all of it is lowered. */
export function normalizeSite(website: string): string | null {
  let s = website.trim().toLowerCase();
  if (!s || /\s/.test(s)) return null;
  if (!/^https?:\/\//.test(s)) s = `https://${s}`;
  try {
    const u = new URL(s);
    if (!u.hostname.includes(".")) return null;
    return u.toString();
  } catch {
    return null;
  }
}

/**
 * The website of the member's own principal campaign committee for that race's cycle, or null. A
 * committee counts only when it names this candidate (`candidate_ids`) and is designated P.
 */
export async function committeeSite(get: FecGet, candidateId: string, year: number): Promise<string | null> {
  const res = await get(`/candidate/${candidateId}/committees/?designation=P&cycle=${year}`);
  const committees = (res["results"] as Record<string, unknown>[] | undefined) ?? [];
  for (const c of committees) {
    const ids = (c["candidate_ids"] as string[] | undefined) ?? [];
    if (c["designation"] !== "P" || !ids.includes(candidateId)) continue;
    const site = typeof c["website"] === "string" ? normalizeSite(c["website"]) : null;
    if (site) return site;
  }
  return null;
}

// ---------------------------------------------------------------------------------------------
// The Wayback Machine

export interface Snapshot {
  /** yyyyMMddHHmmss, UTC. */
  timestamp: string;
  original: string;
}

const compactDay = (day: string) => day.replaceAll("-", "");

/** The day before `day` (YYYY-MM-DD). */
const dayBefore = (day: string) => new Date(Date.parse(`${day}T00:00:00Z`) - 86_400_000).toISOString().slice(0, 10);

/**
 * The earliest capture that counts: January 1 of the year before the cutoff, so the page is from
 * this race's campaign. A site last captured years earlier (jasoncrow.org's latest before the 2024
 * election is from December 2021) is an older race's, and reads as no_snapshot.
 */
const earliest = (cutoff: string) => `${Number(cutoff.slice(0, 4)) - 1}0101`;

export const cdxUrl = (url: string, cutoff: string) =>
  `https://web.archive.org/cdx/search/cdx?url=${encodeURIComponent(url)}&from=${earliest(cutoff)}&to=${compactDay(dayBefore(cutoff))}` +
  `&output=json&limit=-5&filter=statuscode:200&fl=timestamp,original,statuscode,mimetype`;

/** The raw capture, without the Wayback toolbar or rewritten links. */
export const rawUrl = (s: Snapshot) => `https://web.archive.org/web/${s.timestamp}id_/${s.original}`;
/** The capture as a person opens it. */
export const humanUrl = (s: Snapshot) => `https://web.archive.org/web/${s.timestamp}/${s.original}`;
export const snapshotTime = (s: Snapshot) =>
  `${s.timestamp.slice(0, 4)}-${s.timestamp.slice(4, 6)}-${s.timestamp.slice(6, 8)}T${s.timestamp.slice(8, 10)}:${s.timestamp.slice(10, 12)}:${s.timestamp.slice(12, 14)}Z`;

/** Parses a CDX JSON answer: the last HTML capture, or null. One on or after the cutoff, or before `earliest`, is refused. */
export function lastCapture(rows: string[][], cutoff: string): Snapshot | null {
  const limit = compactDay(cutoff);
  const from = earliest(cutoff);
  for (const r of rows.slice(1).reverse()) {
    const [timestamp, original, , mimetype] = r;
    if (!timestamp || !original || !/^\d{14}$/.test(timestamp)) continue;
    if (timestamp.slice(0, 8) >= limit || timestamp.slice(0, 8) < from) continue;
    if (mimetype && !mimetype.includes("html")) continue;
    return { timestamp, original };
  }
  return null;
}

/** The last capture of `url` before `cutoff` (YYYY-MM-DD), or null. */
export async function snapshotBefore(fetchText: FetchText, url: string, cutoff: string): Promise<Snapshot | null> {
  const { status, text } = await fetchText(cdxUrl(url, cutoff));
  if (status !== 200) throw new Error(`Wayback CDX for ${url} returned HTTP ${status}`);
  if (!text.trim()) return null;
  return lastCapture(JSON.parse(text) as string[][], cutoff);
}

// ---------------------------------------------------------------------------------------------
// Finding the issues page, and its text

const hostOf = (u: string) => {
  try {
    return new URL(u).hostname.replace(/^www\./, "");
  } catch {
    return null;
  }
};

/** Path words that mark a platform page, and how strongly: "priorities" over "agenda". */
const PLATFORM_WORDS: [RegExp, number][] = [
  [/\b(priorities|platform|issues|positions|where-\w+-stands?)\b/, 10],
  [/\b(agenda|plan|policy|policies|vision|values)\b/, 8],
];

/**
 * The site's issues/priorities page among a home page's links (same site, not a sub-page of one
 * issue), or null. "/priorities/" beats "/issue/making-things-in-america/": an index lists every
 * issue, one issue's page lists one.
 */
export function findPlatformPage(html: string, siteUrl: string): string | null {
  const host = hostOf(siteUrl);
  let best: { url: string; score: number } | null = null;
  for (const [, raw] of html.matchAll(/<a\b[^>]*\bhref\s*=\s*["']([^"'#]+)[^"']*["']/gi)) {
    let u: URL;
    try {
      u = new URL(raw!.replace(/&amp;|&#038;/g, "&"), siteUrl);
    } catch {
      continue;
    }
    if (!/^https?:$/.test(u.protocol) || u.hostname.replace(/^www\./, "") !== host) continue;
    const path = u.pathname.toLowerCase().replace(/\/+$/, "");
    const segments = path.split("/").filter(Boolean);
    if (segments.length === 0 || segments.length > 2) continue;
    if (/privacy|terms|cookie|donat|contribut/.test(path)) continue;
    const word = PLATFORM_WORDS.find(([re]) => re.test(segments[0]!));
    if (!word) continue;
    // An index (one segment) over one issue's page (two).
    const score = word[1] - (segments.length - 1) * 5;
    const url = `${u.origin}${u.pathname}`;
    if (!best || score > best.score) best = { url, score };
  }
  return best?.url ?? null;
}

const BLOCK = /<\/?(?:p|div|section|article|header|footer|li|ul|ol|h[1-6]|br|tr|td|th|blockquote|figcaption|main|aside|nav)\b[^>]*>/gi;

/**
 * A page's readable text: scripts, styles, navigation and forms dropped, block elements as line
 * breaks, entities decoded, runs of spaces folded. What the model reads and what quotes are checked
 * against, so both see exactly the same text.
 */
export function pageText(html: string): string {
  const body = html.match(/<body\b[^>]*>([\s\S]*)<\/body>/i)?.[1] ?? html;
  const text = body
    .replace(/<!--[\s\S]*?-->/g, " ")
    .replace(/<(script|style|noscript|svg|nav|form|iframe|template|select|button)\b[\s\S]*?<\/\1>/gi, " ")
    .replace(BLOCK, "\n")
    .replace(/<[^>]+>/g, " ");
  return decode(text)
    .split("\n")
    .map((l) => l.replace(/[ \t\u00a0]+/g, " ").trim())
    .filter(Boolean)
    .join("\n")
    .slice(0, MAX_PAGE_CHARS);
}

const NAMED: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", rsquo: "’", lsquo: "‘", rdquo: "”", ldquo: "“", ndash: "–", mdash: "—", hellip: "…" };
const decode = (s: string) =>
  s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (m, e: string) => {
    if (e[0] === "#") {
      const code = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return Number.isFinite(code) && code > 0 ? String.fromCodePoint(code) : m;
    }
    return NAMED[e.toLowerCase()] ?? m;
  });

// ---------------------------------------------------------------------------------------------
// The verbatim check

/** Folds whitespace, curly quotes, dashes and ellipses, keeping case: "verbatim" up to typography. */
export function normalizeText(s: string): string {
  return s
    .replace(/[‘’′`]/g, "'")
    .replace(/[“”″]/g, '"')
    .replace(/[‐‑‒–—]/g, "-")
    .replace(/…/g, "...")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * Keeps the model's picks that are on the page: quote and headline verbatim in the page text, the
 * headline inside the quote; a heading kept only if it is a line of the page (else null), a topic only if
 * it is one of the 32 (else null). Duplicates and quotes under MIN_QUOTE_CHARS are dropped. What is
 * stored is the model's text with its spacing folded: equal to the page's up to quote marks and dashes.
 */
export function verifyPromises(text: string, picks: { heading: string; quote: string; headline: string; topic: string }[]): CampaignPromise[] {
  const page = normalizeText(text);
  const lines = new Set(text.split("\n").map(normalizeText));
  const seen = new Set<string>();
  const out: CampaignPromise[] = [];
  const spaced = (s: string) => s.replace(/\s+/g, " ").trim();
  for (const p of picks) {
    const quote = normalizeText(p.quote);
    const headline = normalizeText(p.headline);
    if (quote.length < MIN_QUOTE_CHARS || !headline || !page.includes(quote) || !quote.includes(headline)) continue;
    if (seen.has(quote)) continue;
    seen.add(quote);
    const heading = normalizeText(p.heading);
    const topic = TOPICS.find((t) => t === p.topic.trim()) ?? null;
    out.push({ heading: heading && lines.has(heading) ? spaced(p.heading) : null, quote: spaced(p.quote), headline: spaced(p.headline), topic });
    if (out.length >= MAX_PROMISES) break;
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// The model call

const SYSTEM = `You pick campaign promises from the text of a U.S. member of Congress's campaign website, archived before the election, for Floor, a nonpartisan app that tracks votes in Congress. Readers see each line labelled as picked by AI and quoted exactly, with a link to the archived page.

Return the candidate's stated commitments and priorities: what they say they will do, fight for, support or oppose if elected. One entry per distinct commitment, in the page's order, at most ${MAX_PROMISES}.

For each:
- quote: one to three consecutive sentences copied exactly, character for character, from the page text. Never paraphrase, shorten, fix, join separate passages or add words. If you cannot copy it exactly, leave the entry out.
- headline: a short clause (about 4 to 15 words) copied exactly from inside quote, the line that best says what the commitment is.
- heading: the page's own section heading the quote sits under, copied exactly; an empty string if there is none.
- topic: the one policy area from the list that fits best, spelled exactly as listed; an empty string if none fits.

Leave out: biography, endorsements, attacks on opponents, fundraising and volunteer appeals, navigation, legal notices, and anything that is not a commitment. If the page states no commitments (a donation page, a biography), return an empty list. Do not use outside knowledge.

Policy areas: ${TOPICS.join("; ")}.`;

export const SCHEMA = {
  type: "object",
  properties: {
    promises: {
      type: "array",
      items: {
        type: "object",
        properties: {
          heading: { type: "string" },
          quote: { type: "string" },
          headline: { type: "string" },
          topic: { type: "string" },
        },
        required: ["heading", "quote", "headline", "topic"],
        additionalProperties: false,
      },
    },
  },
  required: ["promises"],
  additionalProperties: false,
};

const Picks = z.object({
  promises: z.array(z.object({ heading: z.string(), quote: z.string(), headline: z.string(), topic: z.string() })),
});

export class PromisesError extends Error {}

/** The model's picks from `text`, verified. */
export async function extractPromises(
  text: string,
  complete: Complete,
  context: { name: string; year: number; pageUrl: string },
): Promise<{ promises: CampaignPromise[]; picked: number; costUsd: number | null }> {
  const res = await complete({
    system: SYSTEM,
    user: `Candidate: ${context.name}\nElection: ${context.year}\nPage: ${context.pageUrl}\n\nPage text:\n\n${text}`,
    schema: SCHEMA,
    maxTokens: 8000,
  });
  const parsed = Picks.safeParse(res.data);
  if (!parsed.success) throw new PromisesError("model output did not match the schema");
  return { promises: verifyPromises(text, parsed.data.promises), picked: parsed.data.promises.length, costUsd: partsCost(res.parts) };
}

// ---------------------------------------------------------------------------------------------
// One member, and the job

export interface SiteResult {
  election_year: number;
  site_url: string | null;
  snapshot_url: string | null;
  snapshot_at: string | null;
  page_url: string | null;
  status: Status;
  promises: CampaignPromise[];
  costUsd: number | null;
}

export interface PromiseMember {
  bioguide_id: string;
  first_name: string;
  last_name: string;
  chamber: "house" | "senate";
  state: string;
  term_start: string;
  term_end: string;
  fec: string[];
}

/** Reads one member's campaign site. Throws on a network or model failure (the caller records `failed`). */
export async function readCampaignSite(
  m: PromiseMember,
  deps: { fec: FecGet; fetchText: FetchText; complete: Complete; log?: (msg: string) => void },
): Promise<SiteResult> {
  const year = electionYear(m.term_start);
  const base: SiteResult = { election_year: year, site_url: null, snapshot_url: null, snapshot_at: null, page_url: null, status: "no_site", promises: [], costUsd: 0 };
  const candidateId = pickCandidateId(m);
  if (!candidateId) return base;
  // The cycle the race was in: an even year, the year itself for a regular term.
  const cycle = year % 2 === 0 ? year : year + 1;
  const site = await committeeSite(deps.fec, candidateId, cycle);
  if (!site) return base;
  const cutoff = snapshotCutoff(m.term_start);
  const home = await snapshotBefore(deps.fetchText, site, cutoff);
  if (!home) return { ...base, site_url: site, status: "no_snapshot" };

  const homeHtml = await fetchCapture(deps.fetchText, home);
  let used = home;
  let html = homeHtml;
  let pageUrl: string | null = null;
  const platform = findPlatformPage(homeHtml, home.original);
  if (platform) {
    const snap = await snapshotBefore(deps.fetchText, platform, cutoff);
    if (snap) {
      used = snap;
      html = await fetchCapture(deps.fetchText, snap);
      pageUrl = platform;
    }
  }
  const found = { ...base, site_url: site, snapshot_url: humanUrl(used), snapshot_at: snapshotTime(used), page_url: pageUrl };
  const text = pageText(html);
  if (text.length < MIN_PAGE_CHARS) return { ...found, status: "no_platform" };
  const r = await extractPromises(text, deps.complete, { name: `${m.first_name} ${m.last_name}`, year, pageUrl: used.original });
  deps.log?.(`${m.bioguide_id}: kept ${r.promises.length} of ${r.picked} picks from ${humanUrl(used)}`);
  return { ...found, status: r.promises.length ? "promises" : "no_platform", promises: r.promises, costUsd: r.costUsd };
}

async function fetchCapture(fetchText: FetchText, s: Snapshot): Promise<string> {
  const { status, text } = await fetchText(rawUrl(s));
  if (status !== 200) throw new Error(`${rawUrl(s)} returned HTTP ${status}`);
  return text;
}

/** Stores a member's site row and replaces their promises, in one statement. */
export async function storeSite(db: Db, memberId: string, r: Omit<SiteResult, "costUsd">): Promise<void> {
  await withRetry(() =>
    db.query(
      `with site as (
         insert into campaign_sites (member_id, election_year, site_url, source, snapshot_url, snapshot_at, page_url, status, checked_at)
         values ($1, $2, $3, 'fec', $4, $5, $6, $7, now())
         on conflict (member_id) do update set election_year = excluded.election_year, site_url = excluded.site_url,
           source = excluded.source, snapshot_url = excluded.snapshot_url, snapshot_at = excluded.snapshot_at,
           page_url = excluded.page_url, status = excluded.status, checked_at = excluded.checked_at
         returning member_id
       ), gone as (
         delete from campaign_promises where member_id = $1
       )
       insert into campaign_promises (member_id, position, heading, quote, headline, topic)
       select $1, p.ord::int, p.e->>'heading', p.e->>'quote', p.e->>'headline', p.e->>'topic'
         from site, jsonb_array_elements($8::jsonb) with ordinality as p(e, ord)`,
      [memberId, r.election_year, r.site_url, r.snapshot_url, r.snapshot_at, r.page_url, r.status, JSON.stringify(r.promises)],
    ),
  );
}

/**
 * Members to read: current members with no campaign_sites row, and those whose last try failed
 * more than a day ago; with `recheck`, every current member; with `members`, just those.
 * Oldest-checked first, so a recheck walks everyone before repeating anyone.
 */
async function pendingMembers(db: Db, opts: { recheck?: boolean; members?: string[] }): Promise<PromiseMember[]> {
  const { rows } = await db.query<Omit<PromiseMember, "term_start" | "term_end" | "fec"> & { term_start: Date | string; term_end: Date | string; fec: string[] | null }>(
    `select m.bioguide_id, m.first_name, m.last_name, m.chamber, m.state, m.term_start, m.term_end, m.ids->'fec' as fec
       from members m left join campaign_sites s on s.member_id = m.bioguide_id
      where m.term_end > current_date
        and ($1::text[] is null or m.bioguide_id = any($1::text[]))
        and ($2 or $1::text[] is not null or s.member_id is null
             or (s.status = 'failed' and s.checked_at < now() - interval '20 hours'))
      order by s.checked_at nulls first, m.bioguide_id`,
    [opts.members?.length ? opts.members : null, opts.recheck === true],
  );
  const day = (d: Date | string) => (typeof d === "string" ? d.slice(0, 10) : d.toISOString().slice(0, 10));
  return rows.map((r) => ({ ...r, term_start: day(r.term_start), term_end: day(r.term_end), fec: r.fec ?? [] }));
}

export interface PromisesRunResult {
  ran: boolean;
  checked: number;
  byStatus: Record<Status, number>;
  costUsd: number | null;
}

/**
 * Reads up to `budget` members' campaign sites. A member that fails is stored as `failed` and tried
 * again after a day; it never stops the others. What would fail every member the same way (bad
 * credentials, a rate limit the SDK did not outlast) ends the run and is rethrown. `db` must be a
 * single connection: the run holds a session advisory lock on it.
 */
export async function runPromises(
  db: Db,
  deps: { fec: FecGet; fetchText: FetchText; complete: Complete; log?: (msg: string) => void },
  opts: { budget?: number; recheck?: boolean; members?: string[] } = {},
): Promise<PromisesRunResult> {
  const byStatus: Record<Status, number> = { promises: 0, no_platform: 0, no_site: 0, no_snapshot: 0, failed: 0 };
  const { rows: lock } = await db.query<{ locked: boolean }>("select pg_try_advisory_lock($1) as locked", [RUN_LOCK_KEY]);
  if (!lock[0]?.locked) {
    deps.log?.("another promises run is in progress; exiting");
    return { ran: false, checked: 0, byStatus, costUsd: 0 };
  }
  try {
    const finish = await startRun(db, "campaign_promises");
    let checked = 0;
    let cost: number | null = 0;
    try {
      for (const m of (await pendingMembers(db, opts)).slice(0, opts.budget ?? 25)) {
        let r: SiteResult;
        try {
          r = await readCampaignSite(m, deps);
        } catch (err) {
          if (isFatal(err)) throw err;
          deps.log?.(`${m.bioguide_id}: ${errorText(err)}`);
          r = { election_year: electionYear(m.term_start), site_url: null, snapshot_url: null, snapshot_at: null, page_url: null, status: "failed", promises: [], costUsd: 0 };
        }
        await storeSite(db, m.bioguide_id, r);
        checked++;
        byStatus[r.status]++;
        cost = cost === null || r.costUsd === null ? null : cost + r.costUsd;
      }
      await finish(byStatus.promises + byStatus.no_platform, undefined, byStatus.failed);
      return { ran: true, checked, byStatus, costUsd: cost };
    } catch (err) {
      await finish(checked, errorText(err), byStatus.failed);
      throw err;
    }
  } finally {
    await db.query("select pg_advisory_unlock($1)", [RUN_LOCK_KEY]);
  }
}

/** Parses `promises [--budget N] [--recheck] [--member ID ...]`. Throws with a usable message. */
export function parsePromisesArgs(args: string[]): { budget: number; recheck: boolean; members: string[] } {
  const out = { budget: 25, recheck: false, members: [] as string[] };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--budget") {
      const n = Number(args[++i]);
      if (!Number.isInteger(n) || n <= 0) throw new Error("--budget needs a positive whole number");
      out.budget = n;
    } else if (a === "--recheck") out.recheck = true;
    else if (a === "--member") {
      const id = args[++i] ?? "";
      if (!/^[A-Z]\d{6}$/.test(id)) throw new Error(`--member needs a Bioguide ID like S001208, got "${id}"`);
      out.members.push(id);
    } else throw new Error(`promises: unknown argument "${a}"`);
  }
  return out;
}
