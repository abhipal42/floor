/**
 * Every bill of a Congress, not only the ones that reached a recorded vote (Round 10: follow bills
 * and topics).
 *
 * Three phases, each resumable, so a run can stop anywhere (budget spent, rate-limited, killed) and
 * the next one carries on:
 *
 * 1. **List.** `/bill/{congress}` pages of 250, oldest update first, upserting the fields the list
 *    gives: title, type, number, origin chamber, introduced date, latest action and `updateDate`.
 *    Incremental runs start from the stored high-water mark (`max(list_updated_on)`) minus a day,
 *    because `updateDate` is only a date. A full listing (~80 requests) is cheap enough to run daily,
 *    which repairs anything an incremental run's offset paging skipped while the set shifted.
 * 2. **Details.** For each bill whose list `updateDate` is newer than its last detail fetch: the bill
 *    (policy area, sponsor, CBO), its actions (for the stage), its CRS summary only when it has one,
 *    and its titles only when the display title does not already look like a short title. Two to
 *    four requests a bill.
 * 3. **Stage.** Every fetched bill with no stage yet is staged from what is stored (no requests).
 *    A bill known only from the list stays unstaged (null) unless the list says it became law.
 *
 * api.data.gov's standard key allows 5,000 requests an hour (ours reported a limit of 20,000 on
 * 2026-11-13), shared with every other job using it (the per-vote bills and nominations steps, the
 * live worker's linking). `RequestBudget` paces requests (default 4,500 an hour), caps the run's
 * total, counts retries, and stops the run when the key's own `X-RateLimit-Remaining` falls below
 * a reserve (500) — so it yields to the other jobs whatever they spent. Concurrency is at most 4.
 */
import {
  billId,
  fetchActions,
  list,
  toActionRows,
  toBillRow,
  upsertBill,
  type BillType,
  type CongressGet,
  type Json,
  type RequestMeter,
} from "./bills.js";
import { startRun, type Db } from "./db.js";
import { withRetry } from "./rollcalls.js";
import { restage, STAGEABLE } from "./stage.js";

export const LIST_PAGE = 250;
export const DEFAULT_RATE_PER_HOUR = 4_500;
/** Most requests one bill's details can take: bill, actions, summaries, titles. */
const MAX_REQUESTS_PER_BILL = 4;
/**
 * Requests per bill on average, measured on 750 listed 119th-Congress bills on 2026-11-13: every
 * bill takes two, 27% have a CRS summary to fetch (8 of a 30-bill detail sample), and 8% have a
 * display title that reads like an official one (62 of 750). For the log's estimate only.
 */
export const REQUESTS_PER_BILL = 2.35;

export class BudgetExhausted extends Error {
  constructor() {
    super("request budget for this run is spent");
  }
}

/** The key's remaining requests this hour fell below the reserve left for every other job. */
export class KeyReserveReached extends Error {
  constructor(readonly remaining: number) {
    super(`the key has ${remaining} requests left this hour, below the reserve`);
  }
}

/**
 * Requests left on the key that the catalog never spends, for the jobs that share it and cannot
 * wait an hour: the per-vote bills step, nominations, the live worker's linking.
 */
export const DEFAULT_KEY_RESERVE = 500;

/**
 * Paces and counts Congress.gov requests: no more than `ratePerHour` (requests start at least
 * 3600/rate seconds apart) and no more than `limit` in the run. As a `RequestMeter` on the real
 * client it also counts retries, and stops the run once api.data.gov says the key has fewer than
 * `reserve` requests left this hour — a number that counts every caller of the key, not only this one.
 */
export class RequestBudget implements RequestMeter {
  used = 0;
  /** The key's remaining requests at the last response, or null before any said. */
  keyRemaining: number | null = null;
  private nextAt = 0;
  constructor(
    readonly limit: number,
    readonly ratePerHour = DEFAULT_RATE_PER_HOUR,
    private readonly clock: () => number = Date.now,
    private readonly sleep: (ms: number) => Promise<void> = (ms) => new Promise((r) => setTimeout(r, ms)),
    readonly reserve = DEFAULT_KEY_RESERVE,
  ) {}

  get remaining() {
    return Math.max(0, this.limit - this.used);
  }

  /** True once the key is below the reserve: start nothing new. */
  get keyLow() {
    return this.keyRemaining !== null && this.keyRemaining < this.reserve;
  }

  observe(remaining: number): void {
    this.keyRemaining = remaining;
  }

  async take(): Promise<void> {
    if (this.keyLow) throw new KeyReserveReached(this.keyRemaining!);
    if (this.used >= this.limit) throw new BudgetExhausted();
    this.used++;
    const now = this.clock();
    const wait = Math.max(0, this.nextAt - now);
    this.nextAt = Math.max(now, this.nextAt) + 3_600_000 / this.ratePerHour;
    if (wait > 0) await this.sleep(wait);
  }

  /** Wraps a client that has no meter of its own (a test's fake) so every request is paced and counted. */
  wrap(get: CongressGet): CongressGet {
    return async (path) => {
      await this.take();
      return get(path);
    };
  }
}

/** True for a Congress.gov error that retrying in this run will not fix: the hourly key limit. */
const rateLimited = (err: unknown) => err instanceof Error && /HTTP 429\b/.test(err.message);

/** Why an error ends the run quietly (the next run carries on), or null for a real failure. */
function stopReason(err: unknown): "budget" | "rate_limit" | "key_reserve" | null {
  if (err instanceof BudgetExhausted) return "budget";
  if (err instanceof KeyReserveReached) return "key_reserve";
  return rateLimited(err) ? "rate_limit" : null;
}

export interface ListedBill {
  id: string;
  congress: number;
  bill_type: BillType;
  number: number;
  title: string;
  origin_chamber: "house" | "senate" | null;
  introduced_on: string | null;
  latest_action_on: string | null;
  latest_action_text: string | null;
  list_updated_on: string;
}

/**
 * One row of `/bill/{congress}`, or why it is skipped:
 *
 * - `reserved`: the numbers the House holds for its leadership ("Reserved for the Speaker.",
 *   "Reserved for the Minority Leader."), placeholders with no text, sponsor or action. When one is
 *   introduced for real, its title and `updateDate` change and the next listing stores it.
 * - `undated`: no `updateDate`, which is the listing's high-water mark and what says the details
 *   are due. None has been seen; it is counted and logged rather than stored with a made-up date.
 */
export function toListedBill(item: Json): ListedBill | "reserved" | "undated" {
  const title = String(item["title"] ?? "").trim();
  if (!title || /^Reserved for the\b/i.test(title)) return "reserved";
  const updated = String(item["updateDate"] ?? "").slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(updated)) return "undated";
  const type = String(item["type"]).toLowerCase() as BillType;
  const congress = Number(item["congress"]);
  const number = Number(item["number"]);
  const latest = item["latestAction"] as Json | null | undefined;
  const origin = String(item["originChamber"] ?? "").toLowerCase();
  return {
    id: billId(congress, type, number),
    congress,
    bill_type: type,
    number,
    title,
    origin_chamber: origin === "house" || origin === "senate" ? origin : null,
    introduced_on: (item["introducedDate"] as string | undefined) ?? null,
    latest_action_on: (latest?.["actionDate"] as string | undefined) ?? null,
    latest_action_text: (latest?.["text"] as string | undefined) ?? null,
    list_updated_on: updated,
  };
}

/**
 * Upserts listed bills without touching anything only the detail fetch knows. A row the list says
 * nothing new about is left alone (no write, no `updated_at` bump), so the daily full re-list of
 * ~20,000 bills rewrites only the ones that moved. Rows are deduplicated by id first: one statement
 * cannot update the same row twice, and a page can repeat a bill updated while it was being read.
 */
export async function upsertListed(db: Db, rows: ListedBill[]): Promise<void> {
  const unique = [...new Map(rows.map((r) => [r.id, r])).values()];
  if (unique.length === 0) return;
  await db.query(
    `insert into bills (id, congress, bill_type, number, title, origin_chamber, introduced_on,
                        latest_action_on, latest_action_text, list_updated_on, updated_at)
     select id, congress, bill_type, number, title, origin_chamber::chamber, introduced_on,
            latest_action_on, latest_action_text, list_updated_on, now()
       from jsonb_to_recordset($1::jsonb) as x(id text, congress smallint, bill_type text, number integer, title text,
            origin_chamber text, introduced_on date, latest_action_on date, latest_action_text text, list_updated_on date)
     on conflict (id) do update set
       title = excluded.title,
       origin_chamber = coalesce(excluded.origin_chamber, bills.origin_chamber),
       introduced_on = coalesce(excluded.introduced_on, bills.introduced_on),
       latest_action_on = coalesce(excluded.latest_action_on, bills.latest_action_on),
       latest_action_text = coalesce(excluded.latest_action_text, bills.latest_action_text),
       list_updated_on = excluded.list_updated_on,
       updated_at = now()
     where (bills.title, bills.origin_chamber, bills.introduced_on, bills.latest_action_on,
            bills.latest_action_text, bills.list_updated_on)
           is distinct from
           (excluded.title, coalesce(excluded.origin_chamber, bills.origin_chamber),
            coalesce(excluded.introduced_on, bills.introduced_on), coalesce(excluded.latest_action_on, bills.latest_action_on),
            coalesce(excluded.latest_action_text, bills.latest_action_text), excluded.list_updated_on)`,
    [JSON.stringify(unique)],
  );
}

/** Where an incremental listing starts: a day before the newest `updateDate` stored, or null for a full one. */
export async function listingStart(db: Db, congress: number): Promise<string | null> {
  const { rows } = await db.query<{ start: string | null }>(
    `select to_char(max(list_updated_on) - 1, 'YYYY-MM-DD') as start from bills where congress = $1`,
    [congress],
  );
  return rows[0]?.start ? `${rows[0].start}T00:00:00Z` : null;
}

export interface ListingResult {
  listed: number;
  reserved: number;
  undated: number;
  /** Congress.gov's `pagination.count` for the listing. */
  total: number;
  /** After a full listing: listed bills stored for the Congress, to set against `total`. */
  stored?: number;
}

/** Phase 1. Returns how many bills were listed and skipped, and what Congress.gov said the total was. */
export async function listBills(
  db: Db,
  get: CongressGet,
  opts: { congress: number; from: string | null; log?: (msg: string) => void },
): Promise<ListingResult> {
  const result: ListingResult = { listed: 0, reserved: 0, undated: 0, total: 0 };
  for (let offset = 0; ; offset += LIST_PAGE) {
    const from = opts.from ? `&fromDateTime=${opts.from}` : "";
    const page = await get(`/bill/${opts.congress}?limit=${LIST_PAGE}&offset=${offset}&sort=updateDate+asc${from}`);
    result.total = Number((page["pagination"] as Json | undefined)?.["count"] ?? 0);
    const items = list(page["bills"]);
    const keep: ListedBill[] = [];
    for (const item of items) {
      const row = toListedBill(item);
      if (row === "reserved") result.reserved++;
      else if (row === "undated") {
        result.undated++;
        opts.log?.(`skipped a listed ${String(item["type"] ?? "?")} ${String(item["number"] ?? "?")} with no updateDate`);
      } else keep.push(row);
    }
    await withRetry(() => upsertListed(db, keep));
    result.listed += keep.length;
    opts.log?.(`listed ${offset + items.length} of ${result.total}`);
    if (items.length < LIST_PAGE || offset + items.length >= result.total) break;
  }
  if (!opts.from) {
    // A full listing should leave one stored row per listed bill. Offset paging over a list that
    // shifts mid-run can skip one, and a bill can drop off Congress.gov's list; neither is an error
    // here, but a gap that persists across daily runs is worth a look.
    const { rows } = await db.query<{ n: number }>(
      "select count(*)::int as n from bills where congress = $1 and list_updated_on is not null",
      [opts.congress],
    );
    result.stored = rows[0]?.n ?? 0;
    const expected = result.total - result.reserved - result.undated;
    if (result.stored !== expected) {
      opts.log?.(
        `warning: Congress.gov counts ${result.total} bills (${result.reserved} reserved, ${result.undated} undated), ` +
          `so ${expected} should be stored, but ${result.stored} are`,
      );
    }
  }
  return result;
}

/**
 * Bills whose details are due: bills already fetched that have changed first, oldest fetch first,
 * then never-fetched ones newest action first. A bill people may already follow moving on matters
 * more than the next of ~19,000 never-fetched ones, which the backfill would otherwise put ahead of
 * every change for its whole ten hours.
 *
 * `updateDate` is a date, so a bill fetched during the day it changed may change again that day
 * unseen. Hence three cases: never fetched; fetched before the day it last changed; or fetched
 * during that day and the day is now over (with six hours' slack for Congress.gov's time zone) —
 * one more fetch, then it rests until the list moves its date again. A bill that changes daily is
 * fetched at most twice a day.
 */
const DUE = `list_updated_on is not null and (
  details_fetched_at is null
  or details_fetched_at < (list_updated_on::timestamp at time zone 'UTC')
  or (details_fetched_at < ((list_updated_on + 1)::timestamp at time zone 'UTC') + interval '6 hours'
      and $3::timestamptz >= ((list_updated_on + 1)::timestamp at time zone 'UTC') + interval '6 hours'))`;

export async function detailsDue(
  db: Db,
  congress: number,
  limit: number,
  now: Date = new Date(),
): Promise<{ id: string; congress: number; bill_type: BillType; number: number; title: string }[]> {
  const { rows } = await db.query<{ id: string; congress: number; bill_type: BillType; number: number; title: string }>(
    `select id, congress, bill_type, number, title from bills
      where congress = $1 and ${DUE}
      order by (details_fetched_at is null), details_fetched_at, latest_action_on desc nulls last, id
      limit $2`,
    [congress, limit, now.toISOString()],
  );
  return rows;
}

/**
 * Whether the display title already reads as a short title ("Secure America Act", "EARLY Act
 * Reauthorization of 2025"). Congress.gov's display title *is* the short title when the bill has
 * one at introduction (306 of the 326 stored 118th-Congress bills with a short title showed it as
 * their title), so the extra `/titles` request is only worth spending on titles that read like an
 * official one ("To amend title 5 …"), where a short title may have been added later.
 */
export function looksLikeShortTitle(title: string): boolean {
  if (/^(to|a bill|an act|a joint resolution|providing|making|relating)\b/i.test(title.trim())) return false;
  return /\bAct\b/.test(title) && title.length <= 120;
}

/** Phase 2 for one bill: fetch, store and stage it. */
export async function fetchDetails(
  db: Db,
  get: CongressGet,
  b: { congress: number; bill_type: BillType; number: number; title: string },
): Promise<void> {
  const path = `/bill/${b.congress}/${b.bill_type}/${b.number}`;
  const bill = await get(path);
  const detail = (bill["bill"] as Json | undefined) ?? {};
  const hasSummary = Number((detail["summaries"] as Json | undefined)?.["count"] ?? 0) > 0;
  const lawType = ["hr", "s", "hjres", "sjres"].includes(b.bill_type);
  const wantTitles = lawType && !looksLikeShortTitle(String(detail["title"] ?? b.title));
  const [actions, summaries, titles] = await Promise.all([
    fetchActions(get, path),
    hasSummary ? get(`${path}/summaries`) : Promise.resolve({} as Json),
    wantTitles ? get(`${path}/titles?limit=250`) : Promise.resolve(null),
  ]);
  const row = toBillRow(bill, summaries, titles ?? {});
  await withRetry(() => upsertBill(db, row, toActionRows(actions), { keepShortTitle: titles === null }));
  await restage(db, [row.id]);
}

/**
 * Phase 3: stages every bill that has none yet and can be staged (`STAGEABLE`: its details were
 * fetched, or the list says it became law), in batches, walking ids so a bill that stays unstaged
 * is never read twice. No requests. A listed bill whose details are still due keeps a null stage.
 */
export async function stageUnstaged(db: Db, batch = 500): Promise<number> {
  let staged = 0;
  let after = "";
  for (;;) {
    const { rows } = await db.query<{ id: string }>(
      `select b.id from bills b where b.stage is null and ${STAGEABLE} and b.id > $2 order by b.id limit $1`,
      [batch, after],
    );
    if (rows.length === 0) return staged;
    staged += await restage(db, rows.map((r) => r.id));
    after = rows.at(-1)!.id;
  }
}

export interface CatalogOptions {
  congress: number;
  /** Most Congress.gov requests this run may make. */
  budget: number;
  ratePerHour?: number;
  /** Requests left on the key below which the run stops (`DEFAULT_KEY_RESERVE`). */
  keyReserve?: number;
  /** List every bill instead of starting from the high-water mark. */
  full?: boolean;
  /** Parallel detail fetches; capped at 4. */
  concurrency?: number;
  log?: (msg: string) => void;
  now?: () => Date;
  /** Swapped in tests. */
  budgetClock?: { clock: () => number; sleep: (ms: number) => Promise<void> };
}

export interface CatalogResult {
  listed: number;
  reserved: number;
  undated: number;
  fetched: number;
  failed: number;
  stillDue: number;
  staged: number;
  requests: number;
  stoppedBy: "done" | "budget" | "rate_limit" | "key_reserve";
}

/**
 * Runs the three phases under one `ingest_runs` row (source `bill_catalog`). `connect` builds the
 * client around the run's budget: `(budget) => congressClient(key, fetch, budget)` meters every
 * attempt and reads the key's remaining requests; a client with no meter of its own can be
 * `(budget) => budget.wrap(get)`.
 */
export async function ingestCatalog(
  db: Db,
  connect: (budget: RequestBudget) => CongressGet,
  opts: CatalogOptions,
): Promise<CatalogResult> {
  const finish = await startRun(db, "bill_catalog");
  const budget = new RequestBudget(
    opts.budget,
    opts.ratePerHour ?? DEFAULT_RATE_PER_HOUR,
    opts.budgetClock?.clock,
    opts.budgetClock?.sleep,
    opts.keyReserve ?? DEFAULT_KEY_RESERVE,
  );
  const get = connect(budget);
  const log = opts.log ?? (() => {});
  const now = opts.now ?? (() => new Date());
  const result: CatalogResult = {
    listed: 0,
    reserved: 0,
    undated: 0,
    fetched: 0,
    failed: 0,
    stillDue: 0,
    staged: 0,
    requests: 0,
    stoppedBy: "done",
  };
  try {
    const from = opts.full ? null : await listingStart(db, opts.congress);
    try {
      const listing = await listBills(db, get, { congress: opts.congress, from, log });
      result.listed = listing.listed;
      result.reserved = listing.reserved;
      result.undated = listing.undated;
      log(
        `listing ${from ? `since ${from}` : "in full"}: ${listing.listed} bills stored, ${listing.reserved} reserved ` +
          `numbers skipped, ${listing.undated} without an updateDate skipped`,
      );
    } catch (err) {
      const reason = stopReason(err);
      if (!reason) throw err;
      result.stoppedBy = reason;
    }

    if (result.stoppedBy === "done") {
      // Every bill takes at least two requests; the loop below stops before the budget can run out mid-bill.
      const due = await detailsDue(db, opts.congress, Math.floor(budget.remaining / 2), now());
      const { rows: count } = await db.query<{ n: number }>(
        `select count(*)::int as n from bills where congress = $1 and ${DUE.replaceAll("$3", "$2")}`,
        [opts.congress, now().toISOString()],
      );
      const totalDue = count[0]?.n ?? 0;
      const rate = budget.ratePerHour;
      log(
        `details due for ${totalDue} bills; budget ${budget.remaining} requests at ${rate}/h. ` +
          `Estimated to clear all: ~${Math.ceil(totalDue * REQUESTS_PER_BILL)} requests, ` +
          `~${((totalDue * REQUESTS_PER_BILL) / rate).toFixed(1)} h at this rate`,
      );

      let next = 0;
      // Requests each bill in flight may still make, at worst.
      const outstanding = new Set<{ left: number }>();
      const owed = () => [...outstanding].reduce((sum, o) => sum + o.left, 0);
      let stop: CatalogResult["stoppedBy"] = "done";
      const worker = async () => {
        while (stop === "done" && next < due.length) {
          // Start a bill only if it and every bill already in flight could still take their worst
          // case: a bill cut off mid-fetch would have spent requests and stored nothing.
          if (budget.keyLow) {
            stop = "key_reserve";
            return;
          }
          if (budget.remaining - owed() < MAX_REQUESTS_PER_BILL) {
            stop = "budget";
            return;
          }
          const b = due[next++]!;
          const mine = { left: MAX_REQUESTS_PER_BILL };
          outstanding.add(mine);
          try {
            await fetchDetails(db, (path) => {
              mine.left--;
              return get(path);
            }, b);
            result.fetched++;
            if (result.fetched % 100 === 0) log(`details: ${result.fetched} of ${due.length}, ${budget.used} requests`);
          } catch (err) {
            const reason = stopReason(err);
            if (reason) stop = reason;
            else {
              // One bad bill must not stop the rest; it stays due and is retried next run.
              result.failed++;
              log(`${b.id}: ${err instanceof Error ? err.message : String(err)}`);
            }
          } finally {
            outstanding.delete(mine);
          }
        }
      };
      await Promise.all(Array.from({ length: Math.min(4, Math.max(1, opts.concurrency ?? 4)) }, worker));
      result.stillDue = Math.max(0, totalDue - result.fetched);
      // Bills left due that this run never reached were left for want of budget.
      result.stoppedBy = stop === "done" && result.fetched + result.failed < totalDue ? "budget" : stop;
    }

    result.staged = await stageUnstaged(db);
    result.requests = budget.used;
    if (result.stoppedBy === "rate_limit") log("Congress.gov answered 429 after retries: the key's hourly limit is spent; stopping");
    if (result.stoppedBy === "key_reserve") {
      log(`the key has ${budget.keyRemaining} requests left this hour, below the ${budget.reserve} kept for other jobs; stopping`);
    }
    // A run that stopped on its budget or the key's limit did its job; the next run continues.
    await finish(result.listed + result.fetched, undefined, result.failed);
  } catch (err) {
    await finish(result.listed + result.fetched, err instanceof Error ? err.message : String(err), result.failed);
    throw err;
  }
  return result;
}
