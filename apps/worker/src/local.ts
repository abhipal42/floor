import { errorText, startRun, type Db } from "./db.js";
import { gnewsUrl, parseGoogleNews } from "./gnews.js";
import { JURISDICTIONS, localNewsQuery, type JurisdictionEntry } from "./jurisdictions.js";
import { withRetry, type FetchText } from "./rollcalls.js";

/*
 * The Local tab's records and headlines, once a day (the 06 UTC run) and on manual runs.
 *
 * - States, from Open States v3 (`OPENSTATES_API_KEY`, sent as the X-API-KEY header, never in a
 *   URL): each state's bills with an action in the last RECORD_DAYS days. Signed or became law in
 *   that window → enacted (`signed` / `became_law`). Passed both chambers (or a unicameral
 *   legislature) with no executive action yet → waiting (`awaiting_governor`). A bill that passed
 *   both chambers months ago with no action since is not seen: Open States filters on actions.
 * - Cities, from Legistar's web API: matters the council passed in the last RECORD_DAYS days,
 *   with the yes/no tally from the council vote when Legistar has the roll call. NYC needs a token
 *   (`NYC_LEGISTAR_TOKEN`, a query parameter, so its URLs are never logged).
 * - Headlines for every jurisdiction from Google News (7 days), title/source/date/link only.
 *
 * A source without its key skips with a log line. Requests are paced (`delayMs`) and budgeted.
 */

export const OPENSTATES = "https://v3.openstates.org";
export const LEGISTAR = "https://webapi.legistar.com/v1";
export const RECORD_DAYS = 30;
export const KEEP_ITEM_DAYS = 90;
export const KEEP_NEWS_DAYS = 14;
export const NEWS_DAYS = 7;
/** Open States pages read per state (20 bills a page). */
export const OPENSTATES_PAGES = 2;
/**
 * Open States' free tier is limited per day and per minute; the published numbers are on the
 * account page, not in the docs (HANDOFF). These keep a daily run well inside any tier we have
 * seen: at most 150 requests a run, one every 7 s (under 10 a minute). A 429 ends the state pass.
 */
export const OPENSTATES_BUDGET = 150;
export const OPENSTATES_DELAY_MS = 7_000;
export const LEGISTAR_BUDGET = 300;
export const DEFAULT_DELAY_MS = 1_200;

export type LocalStatus = "signed" | "became_law" | "passed" | "awaiting_governor";

export interface LocalItemRow {
  id: string;
  jurisdiction_id: string;
  identifier: string;
  title: string;
  summary: string | null;
  body: string;
  date: string;
  status: LocalStatus;
  yes: number | null;
  no: number | null;
  url: string | null;
}

const day = (d: Date) => d.toISOString().slice(0, 10);
const daysAgo = (now: Date, n: number) => new Date(now.getTime() - n * 86_400_000);

// ---------------------------------------------------------------------------------------------
// Open States

interface OsOrg {
  name?: string;
  classification?: string;
}
interface OsAction {
  organization?: OsOrg;
  description?: string;
  date?: string;
  classification?: string[];
  order?: number;
}
export interface OsBill {
  id: string;
  identifier: string;
  title: string;
  from_organization?: OsOrg;
  openstates_url?: string;
  abstracts?: { abstract: string; note?: string }[];
  actions?: OsAction[];
}

/** The chamber a bill came from, as the hub names it: "State Senate", "Assembly", "State House". */
export function chamberBody(org: OsOrg | undefined): string {
  if (org?.classification === "upper") return "State Senate";
  if (org?.classification === "lower") return /assembly|delegates/i.test(org.name ?? "") ? (org.name as string) : "State House";
  return "Legislature";
}

/**
 * Where a bill stands, from its actions: enacted (signed / became law, on that action's date) when
 * that is on or after `since`; waiting when both chambers (or a unicameral legislature) recorded
 * passage and there is no executive action (receipt by the governor does not count as one); else null.
 */
export function classifyBill(bill: OsBill, jurisdictionId: string, since: string): LocalItemRow | null {
  const actions = [...(bill.actions ?? [])].sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
  const has = (a: OsAction, c: string) => (a.classification ?? []).includes(c);
  const enacted = [...actions].reverse().find((a) => has(a, "executive-signature") || has(a, "became-law"));
  const vetoed = actions.some((a) => has(a, "executive-veto"));
  const passed = actions.filter((a) => has(a, "passage"));
  const chambers = new Set(passed.map((a) => a.organization?.classification));
  const base = {
    id: `openstates:${bill.id}`,
    jurisdiction_id: jurisdictionId,
    identifier: bill.identifier,
    title: bill.title,
    summary: bill.abstracts?.find((a) => a.abstract?.trim())?.abstract.trim() ?? null,
    body: chamberBody(bill.from_organization),
    yes: null,
    no: null,
    url: bill.openstates_url ?? null,
  };
  if (enacted?.date) {
    if (enacted.date.slice(0, 10) < since) return null;
    return { ...base, date: enacted.date.slice(0, 10), status: has(enacted, "became-law") && !has(enacted, "executive-signature") ? "became_law" : "signed" };
  }
  if (vetoed) return null;
  const bothPassed = (chambers.has("upper") && chambers.has("lower")) || chambers.has("legislature");
  if (!bothPassed) return null;
  const last = passed.at(-1)!;
  return { ...base, date: (last.date ?? "").slice(0, 10), status: "awaiting_governor" };
}

export const openStatesBillsUrl = (j: JurisdictionEntry & { records: { source: "openstates" } }, since: string, page: number) =>
  `${OPENSTATES}/bills?jurisdiction=${encodeURIComponent(j.records.jurisdiction)}&action_since=${since}` +
  `&sort=latest_action_desc&include=actions&include=abstracts&per_page=20&page=${page}`;

/** GETs with the key in a header. Errors name the path only. */
export type KeyedGet = (url: string) => Promise<{ status: number; text: string }>;

export const openStatesGet =
  (key: string, base: typeof fetch = fetch): KeyedGet =>
  async (url) => {
    const res = await base(url, { headers: { "x-api-key": key, "user-agent": "floor-ingest/0.1" }, signal: AbortSignal.timeout(60_000) });
    return { status: res.status, text: res.status === 200 ? await res.text() : "" };
  };

// ---------------------------------------------------------------------------------------------
// Legistar

export interface LegistarMatter {
  MatterId: number;
  MatterGuid?: string;
  MatterFile: string | null;
  MatterName: string | null;
  MatterTitle: string | null;
  MatterTypeName: string | null;
  MatterStatusName: string | null;
  MatterPassedDate: string | null;
}
export interface LegistarHistory {
  MatterHistoryId: number;
  MatterHistoryActionDate: string | null;
  MatterHistoryActionName: string | null;
  MatterHistoryActionBodyName: string | null;
  MatterHistoryPassedFlag: number | null;
  MatterHistoryTally: string | null;
}
export interface LegistarVote {
  VoteValueName: string | null;
}

/**
 * Matter types that are never legislation the council passed: minutes, calendars, communications,
 * reports, presentations, proclamations, personnel and appointment items, Denver's test records
 * ("Historical"). Statuses that mean it did not pass, or has not yet.
 */
const SKIP_TYPES = /minutes|calendar|agenda|communication|report|presentation|historical|proclamation|personnel|appointment|petition/i;
const SKIP_STATUS = /not pass|fail|veto|withdraw|filed|referred|introduc|agenda ready|in committee|laid over|tabled/i;

/** Whether a listed matter can be one the council passed (the history decides). */
export function keepMatter(m: LegistarMatter, since: string, today: string): boolean {
  const passed = m.MatterPassedDate?.slice(0, 10);
  if (!passed || passed < since || passed > today) return false;
  if (SKIP_TYPES.test(m.MatterTypeName ?? "") || SKIP_STATUS.test(m.MatterStatusName ?? "")) return false;
  return Boolean(m.MatterFile?.trim() && (m.MatterTitle?.trim() || m.MatterName?.trim()));
}

const COUNCIL = /council|board of supervisors/i;
const PASSING = /pass|adopt|approv|enact|sustain/i;

/** The council's own passing action in a matter's history (the last one), or null. */
export function councilPassage(histories: LegistarHistory[]): LegistarHistory | null {
  const rows = histories.filter(
    (h) => h.MatterHistoryPassedFlag === 1 && COUNCIL.test(h.MatterHistoryActionBodyName ?? "") && PASSING.test(h.MatterHistoryActionName ?? ""),
  );
  return rows.at(-1) ?? null;
}

/** "44-5", "9:0", "44 - 5" → {yes, no}; null when the tally is not two numbers. */
export function parseTally(tally: string | null): { yes: number; no: number } | null {
  const m = tally?.match(/^\s*(\d+)\s*[-:–]\s*(\d+)\s*$/);
  return m ? { yes: Number(m[1]), no: Number(m[2]) } : null;
}

const YES = /^(in favor|aye|yes|yea|affirmative|approve)$/i;
const NO = /^(opposed|nay|no|negative|against)$/i;

/** Counts a roll call's yes and no votes; null with no votes recorded. Absent, excused, recused: neither. */
export function countVotes(votes: LegistarVote[]): { yes: number; no: number } | null {
  if (!votes.length) return null;
  let yes = 0;
  let no = 0;
  for (const v of votes) {
    const name = (v.VoteValueName ?? "").trim();
    if (YES.test(name)) yes++;
    else if (NO.test(name)) no++;
  }
  return yes + no ? { yes, no } : null;
}

export function matterRow(j: JurisdictionEntry, web: string, m: LegistarMatter, tally: { yes: number; no: number } | null): LocalItemRow {
  const name = m.MatterName?.trim();
  const longTitle = m.MatterTitle?.trim() || null;
  const short = name && name !== m.MatterFile?.trim() ? name : null;
  return {
    id: `legistar:${j.id}:${m.MatterId}`,
    jurisdiction_id: j.id,
    identifier: m.MatterFile!.trim(),
    title: short ?? longTitle ?? m.MatterFile!.trim(),
    summary: short && longTitle && longTitle !== short ? longTitle : null,
    body: j.council ?? "City Council",
    date: m.MatterPassedDate!.slice(0, 10),
    status: "passed",
    yes: tally?.yes ?? null,
    no: tally?.no ?? null,
    url: m.MatterGuid ? `https://${web}/LegislationDetail.aspx?ID=${m.MatterId}&GUID=${m.MatterGuid}` : null,
  };
}

export const legistarMattersPath = (client: string, since: string, today: string) =>
  `${LEGISTAR}/${client}/matters?$filter=${encodeURIComponent(`MatterPassedDate ge datetime'${since}' and MatterPassedDate le datetime'${today}'`)}` +
  `&$orderby=${encodeURIComponent("MatterPassedDate desc")}&$top=100`;

// ---------------------------------------------------------------------------------------------
// Storing

export async function storeItems(db: Db, rows: LocalItemRow[]): Promise<void> {
  if (!rows.length) return;
  await withRetry(() =>
    db.query(
      `insert into local_items (id, jurisdiction_id, identifier, title, summary, body, date, status, yes, no, url, updated_at)
       select distinct on (id) id, jurisdiction_id, identifier, title, summary, body, date, status, yes, no, url, now()
         from jsonb_to_recordset($1::jsonb) as x(id text, jurisdiction_id text, identifier text, title text, summary text,
              body text, date date, status text, yes int, no int, url text)
        order by id
       on conflict (id) do update set identifier = excluded.identifier, title = excluded.title, summary = excluded.summary,
         body = excluded.body, date = excluded.date, status = excluded.status,
         yes = coalesce(excluded.yes, local_items.yes), no = coalesce(excluded.no, local_items.no),
         url = excluded.url, updated_at = now()`,
      [JSON.stringify(rows)],
    ),
  );
}

const checked = (db: Db, jurisdictionId: string, source: "records" | "news", now: Date) =>
  db.query(
    `insert into local_checks (jurisdiction_id, source, checked_at) values ($1, $2, $3::timestamptz)
     on conflict (jurisdiction_id, source) do update set checked_at = excluded.checked_at`,
    [jurisdictionId, source, now.toISOString()],
  );

// ---------------------------------------------------------------------------------------------
// The job

export interface LocalDeps {
  /** Open States, keyed (openStatesGet). Absent: states skip. */
  openStates?: KeyedGet;
  /** Legistar and Google News (no keys, but see `tokens`). */
  fetchText: FetchText;
  /** Legistar tokens by environment-variable name (NYC_LEGISTAR_TOKEN). A client missing its token skips. */
  tokens?: Record<string, string | undefined>;
  sleep?: (ms: number) => Promise<void>;
  log?: (msg: string) => void;
}

export interface LocalRunResult {
  states: number;
  cities: number;
  enacted: number;
  waiting: number;
  passed: number;
  headlines: number;
  failed: number;
  skipped: string[];
  requests: { openstates: number; legistar: number; news: number };
}

class BudgetSpent extends Error {}

const sleepFor = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function ingestLocal(
  db: Db,
  deps: LocalDeps,
  opts: { now?: Date; only?: string[]; delayMs?: number; openStatesDelayMs?: number; news?: boolean } = {},
): Promise<LocalRunResult> {
  const now = opts.now ?? new Date();
  const since = day(daysAgo(now, RECORD_DAYS));
  const today = day(now);
  const sleep = deps.sleep ?? sleepFor;
  const log = deps.log ?? (() => {});
  const delay = opts.delayMs ?? DEFAULT_DELAY_MS;
  const r: LocalRunResult = {
    states: 0, cities: 0, enacted: 0, waiting: 0, passed: 0, headlines: 0, failed: 0, skipped: [],
    requests: { openstates: 0, legistar: 0, news: 0 },
  };
  const list = JURISDICTIONS.filter((j) => !opts.only?.length || opts.only.includes(j.id));
  const finish = await startRun(db, "local");
  try {
    // States.
    if (!deps.openStates) {
      log("OPENSTATES_API_KEY unset: state records skipped");
      r.skipped.push("openstates");
    } else {
      let stop = false;
      for (const j of list) {
        if (stop || j.records?.source !== "openstates") continue;
        const rows: LocalItemRow[] = [];
        let ok = true;
        for (let page = 1; page <= OPENSTATES_PAGES; page++) {
          if (r.requests.openstates >= OPENSTATES_BUDGET) {
            log(`Open States budget of ${OPENSTATES_BUDGET} requests spent; the rest wait for tomorrow`);
            stop = true;
            ok = false;
            break;
          }
          if (r.requests.openstates > 0) await sleep(opts.openStatesDelayMs ?? OPENSTATES_DELAY_MS);
          r.requests.openstates++;
          const url = openStatesBillsUrl(j as JurisdictionEntry & { records: { source: "openstates" } }, since, page);
          let res: { status: number; text: string };
          try {
            res = await deps.openStates(url);
          } catch (err) {
            log(`${j.id}: Open States failed: ${errorText(err)}`);
            ok = false;
            break;
          }
          if (res.status === 429) {
            log("Open States answered 429 (rate limit); the state pass stops for this run");
            stop = true;
            ok = false;
            break;
          }
          if (res.status !== 200) {
            log(`${j.id}: ${url} returned HTTP ${res.status}`);
            ok = false;
            break;
          }
          const body = JSON.parse(res.text) as { results?: OsBill[]; pagination?: { max_page?: number } };
          for (const bill of body.results ?? []) {
            const row = classifyBill(bill, j.id, since);
            if (row) rows.push(row);
          }
          if ((body.pagination?.max_page ?? 1) <= page) break;
        }
        if (!ok) {
          r.failed++;
          continue;
        }
        // The waiting list is what this pass saw: a bill since signed, vetoed or gone quiet leaves it.
        await db.query(
          "delete from local_items where jurisdiction_id = $1 and status = 'awaiting_governor' and not (id = any($2::text[]))",
          [j.id, rows.filter((x) => x.status === "awaiting_governor").map((x) => x.id)],
        );
        await storeItems(db, rows);
        await checked(db, j.id, "records", now);
        r.states++;
        r.enacted += rows.filter((x) => x.status !== "awaiting_governor").length;
        r.waiting += rows.filter((x) => x.status === "awaiting_governor").length;
      }
    }

    // Cities.
    for (const j of list) {
      if (j.records?.source !== "legistar") continue;
      const rec = j.records;
      const token = rec.token ? deps.tokens?.[rec.token] : undefined;
      if (rec.token && !token) {
        log(`${j.id}: ${rec.token} unset: council records skipped`);
        r.skipped.push(j.id);
        continue;
      }
      // The token is a query parameter: `shown` is the URL without it, the only form ever logged.
      const get = async (path: string) => {
        if (r.requests.legistar >= LEGISTAR_BUDGET) throw new BudgetSpent(`Legistar budget of ${LEGISTAR_BUDGET} requests spent`);
        if (r.requests.legistar > 0) await sleep(delay);
        r.requests.legistar++;
        const url = token ? `${path}${path.includes("?") ? "&" : "?"}token=${encodeURIComponent(token)}` : path;
        const res = await deps.fetchText(url);
        if (res.status !== 200) throw new Error(`${path} returned HTTP ${res.status}`);
        return JSON.parse(res.text) as unknown;
      };
      try {
        const matters = ((await get(legistarMattersPath(rec.client, since, today))) as LegistarMatter[]).filter((m) => keepMatter(m, since, today));
        const { rows: stored } = await db.query<{ id: string }>("select id from local_items where jurisdiction_id = $1", [j.id]);
        const have = new Set(stored.map((x) => x.id));
        const rows: LocalItemRow[] = [];
        for (const m of matters) {
          if (have.has(`legistar:${j.id}:${m.MatterId}`)) continue;
          // One matter failing (a history Legistar will not serve) skips that matter, not the city.
          try {
            const histories = (await get(`${LEGISTAR}/${rec.client}/matters/${m.MatterId}/histories`)) as LegistarHistory[];
            const passage = councilPassage(histories);
            if (!passage) continue;
            let tally = parseTally(passage.MatterHistoryTally);
            if (!tally) tally = countVotes((await get(`${LEGISTAR}/${rec.client}/eventitems/${passage.MatterHistoryId}/votes`)) as LegistarVote[]);
            rows.push(matterRow(j, rec.web, m, tally));
          } catch (err) {
            if (err instanceof BudgetSpent) throw err;
            r.failed++;
            log(`${j.id} matter ${m.MatterId}: ${errorText(err)}`);
          }
        }
        await storeItems(db, rows);
        await checked(db, j.id, "records", now);
        r.cities++;
        r.passed += rows.length;
      } catch (err) {
        r.failed++;
        log(`${j.id}: Legistar failed: ${errorText(err)}`);
      }
    }

    // Headlines.
    if (opts.news !== false) {
      for (const j of list) {
        if (r.requests.news > 0) await sleep(delay);
        r.requests.news++;
        const url = gnewsUrl(localNewsQuery(j));
        try {
          const res = await deps.fetchText(url);
          if (res.status === 429 || res.status === 503) {
            log(`Google News answered HTTP ${res.status}; local headlines stop for this run`);
            break;
          }
          if (res.status !== 200) throw new Error(`${url} returned HTTP ${res.status}`);
          const from = daysAgo(now, NEWS_DAYS).getTime();
          const items = parseGoogleNews(res.text).filter((it) => Date.parse(it.publishedAt) >= from);
          const rows = items.map((it) => ({
            id: `${j.id}:${it.guid}`,
            jurisdiction_id: j.id,
            title: it.title,
            source: it.source,
            source_url: it.sourceUrl,
            url: it.url,
            published_at: it.publishedAt,
          }));
          if (rows.length) {
            await withRetry(() =>
              db.query(
                `insert into local_news (id, jurisdiction_id, title, source, source_url, url, published_at)
                 select distinct on (id) id, jurisdiction_id, title, source, source_url, url, published_at
                   from jsonb_to_recordset($1::jsonb) as x(id text, jurisdiction_id text, title text, source text,
                        source_url text, url text, published_at timestamptz)
                  order by id
                 on conflict (id) do update set title = excluded.title, source = excluded.source,
                   source_url = excluded.source_url, url = excluded.url, published_at = excluded.published_at`,
                [JSON.stringify(rows)],
              ),
            );
          }
          await checked(db, j.id, "news", now);
          r.headlines += rows.length;
        } catch (err) {
          r.failed++;
          log(`${j.id}: headlines failed: ${errorText(err)}`);
        }
      }
    }

    await db.query("delete from local_news where published_at < $1::timestamptz", [daysAgo(now, KEEP_NEWS_DAYS).toISOString()]);
    await db.query("delete from local_items where date < $1::date", [day(daysAgo(now, KEEP_ITEM_DAYS))]);
    await finish(r.enacted + r.waiting + r.passed + r.headlines, undefined, r.failed);
    return r;
  } catch (err) {
    await finish(r.enacted + r.waiting + r.passed + r.headlines, errorText(err), r.failed);
    throw err;
  }
}

/** Parses `local [--only ID ...] [--no-news]`. */
export function parseLocalArgs(args: string[]): { only: string[]; news: boolean } {
  const out = { only: [] as string[], news: true };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--only") {
      const id = args[++i] ?? "";
      if (!JURISDICTIONS.some((j) => j.id === id)) throw new Error(`--only needs a jurisdiction id like ny or seattle, got "${id}"`);
      out.only.push(id);
    } else if (a === "--no-news") out.news = false;
    else throw new Error(`local: unknown argument "${a}"`);
  }
  return out;
}
