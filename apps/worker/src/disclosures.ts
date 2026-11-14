import { mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { errorText, startRun, type Db } from "./db.js";

// Financial disclosures of members of both chambers: the latest annual report's assets, and the
// trades in periodic transaction reports (PTRs). Imported, stored and served, but OFF in the
// product until the team answers the 5 U.S.C. §13107(c) commercial-use question — see
// docs/HANDOFF.md, "Financial disclosures". The two sources live in disclosures-house.ts and
// disclosures-senate.ts; this file is what they share: the parsed shapes, matching a filer to a
// member, storage, and the run loop.
//
// Values are kept exactly as filed (range text). Nothing here turns a range into a number, so
// nothing can add them into a net worth (product rule: ranges, never net worth). A filing whose
// document is an image is stored with its link as a paper filing and never OCR'd: a misread digit
// in a value band is an invented number.

export type Owner = "self" | "spouse" | "joint" | "dependent";
export type TxType = "buy" | "sell" | "exchange";
export type Chamber = "house" | "senate";

export interface ParsedAsset {
  name: string;
  assetType: string | null;
  assetTypeCode: string | null;
  account: string | null;
  owner: Owner | null;
  valueRange: string | null;
  incomeType: string | null;
  incomeRange: string | null;
  description: string | null;
}

export interface ParsedTrade {
  owner: Owner | null;
  assetName: string;
  ticker: string | null;
  assetType: string | null;
  assetTypeCode: string | null;
  txType: TxType;
  txTypeFiled: string;
  amountRange: string;
  transactedOn: string; // YYYY-MM-DD
  notifiedOn: string | null;
  capGainsOver200: boolean | null;
  comment: string | null;
}

/** What reading one document gave: its rows, or that it is an image with nothing to read. */
export type ParseResult = { format: "electronic"; assets: ParsedAsset[]; trades: ParsedTrade[] } | { format: "paper" };

/** One filing as a source's index lists it, before it is matched to a member. */
export interface ListedFiling {
  id: string;
  chamber: Chamber;
  filerName: string;
  /** The parts matching uses. */
  first: string;
  last: string;
  /** House only: the index's StateDst, e.g. "AL04". */
  stateDistrict: string | null;
  kind: "annual" | "ptr";
  amendment: boolean;
  reportYear: number | null;
  filedOn: string | null;
  sourceUrl: string;
  /** Known from the index alone (the Senate marks paper reports in the link); null means look. */
  format: "electronic" | "paper" | null;
}

// ---------------------------------------------------------------------------------------------
// Matching filers to members

export interface MatchMember {
  bioguide_id: string;
  first_name: string;
  last_name: string;
  state: string;
  district: number | null;
  chamber: Chamber;
}

const SUFFIXES = new Set(["jr", "sr", "ii", "iii", "iv", "v"]);

/** A name reduced for comparison: no accents, case, punctuation, spaces or generational suffix. */
export function normName(name: string): string {
  return name
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .split(/[\s,.]+/)
    .filter((t) => t && !SUFFIXES.has(t))
    .join("")
    .replace(/[^a-z]/g, "");
}

const firstToken = (first: string) => normName(first.trim().split(/\s+/)[0] ?? "");

/** First names that could be the same person: one is a prefix of the other ("Tim" / "Timothy"). */
function firstCompatible(a: string, b: string): boolean {
  const x = firstToken(a);
  const y = firstToken(b);
  return x.length > 0 && y.length > 0 && (x.startsWith(y) || y.startsWith(x));
}

/**
 * The member a House filing belongs to, or null. A seat (state and district) plus the surname must
 * agree; failing that, surname and first name must pick out one House member of the state (a member
 * whose district was renumbered). Anything looser is left unmatched and reported, never guessed.
 */
export function matchHouseFiler(members: MatchMember[], f: Pick<ListedFiling, "last" | "first" | "stateDistrict">): string | null {
  const sd = f.stateDistrict ?? "";
  const state = sd.slice(0, 2).toUpperCase();
  const district = Number(sd.slice(2));
  if (!/^[A-Z]{2}$/.test(state)) return null;
  const last = normName(f.last);
  const sameName = (m: MatchMember) => normName(m.last_name) === last;
  // At the member's own seat the index may split a compound or married surname differently from
  // congress-legislators ("Delaney, April McClain" for McClain Delaney; "Arenholz, Ashley Hinson" for
  // Hinson; "Amata, Aumua" for Aumua Amata Radewagen), so there it is enough that one side's surname
  // is among the other's name *words*. Words, not substrings: "Arias" is inside "MariaSalazar", and a
  // substring test matched a candidate for FL-27 to the member who holds it.
  const words = (name: string) => new Set(name.split(/\s+/).map(normName).filter(Boolean));
  const within = (part: string, whole: string) => {
    const w = words(whole);
    const p = [...words(part)];
    return p.length > 0 && p.every((x) => w.has(x));
  };
  const seatName = (m: MatchMember) =>
    sameName(m) || within(m.last_name, `${f.first} ${f.last}`) || within(f.last, `${m.first_name} ${m.last_name}`);
  const seat = members.filter(
    (m) => m.chamber === "house" && m.state === state && Number.isInteger(district) && m.district === district && seatName(m),
  );
  if (seat.length === 1) return seat[0]!.bioguide_id;
  // Off the seat, surname and first name must both agree, and only House members count: the index
  // also lists candidates' amendments, and a candidate who shares a senator's surname is not them.
  const inState = members.filter(
    (m) => m.chamber === "house" && m.state === state && sameName(m) && firstCompatible(m.first_name, f.first),
  );
  return inState.length === 1 ? inState[0]!.bioguide_id : null;
}

/**
 * The senator a Senate filing belongs to, or null. eFD lists no state, so the surname must match
 * exactly one senator, or exactly one whose first name is compatible (the two Scotts).
 */
export function matchSenateFiler(members: MatchMember[], f: Pick<ListedFiling, "last" | "first">): string | null {
  const last = normName(f.last);
  const named = members.filter((m) => m.chamber === "senate" && normName(m.last_name) === last);
  // A unique surname is enough: first names differ too often between eFD and congress-legislators
  // ("James Conley" for Jim Justice) to require them when nothing else could be meant.
  if (named.length === 1) return named[0]!.bioguide_id;
  const byFirst = named.filter((m) => firstCompatible(m.first_name, f.first));
  return byFirst.length === 1 ? byFirst[0]!.bioguide_id : null;
}

// ---------------------------------------------------------------------------------------------
// Shared parsing helpers

const OWNERS: Record<string, Owner> = {
  "": "self",
  self: "self",
  sp: "spouse",
  spouse: "spouse",
  jt: "joint",
  joint: "joint",
  dc: "dependent",
  "dependent child": "dependent",
  child: "dependent", // eFD PTRs write "Child"
  dependent: "dependent",
};

/** An owner code or word as filed, or undefined when it is something we do not know. */
export function ownerOf(filed: string): Owner | undefined {
  return OWNERS[filed.trim().toLowerCase()];
}

/** M/D/YYYY or MM/DD/YYYY to YYYY-MM-DD; null when it is not a real date. */
export function isoDate(us: string): string | null {
  const m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(us.trim());
  if (!m) return null;
  const [, mo, d, y] = m;
  const iso = `${y}-${mo!.padStart(2, "0")}-${d!.padStart(2, "0")}`;
  const t = new Date(`${iso}T00:00:00Z`);
  return Number.isNaN(t.getTime()) || t.toISOString().slice(0, 10) !== iso ? null : iso;
}

/** Whitespace collapsed; a range split over two lines ("$100,001 -", "$250,000") reads as one. */
export const tidy = (s: string) => s.replace(/\s+/g, " ").trim();

// ---------------------------------------------------------------------------------------------
// Polite fetching and the download cache

/** A generic client name: no person, no contact detail. */
export const USER_AGENT = "Mozilla/5.0 (compatible; floor-ingest/0.1)";

/** Downloaded documents, kept so a re-run or a parser fix costs no request. Gitignored (`.cache/`). */
export const DEFAULT_CACHE_DIR =
  process.env.DISCLOSURES_CACHE_DIR ?? join(dirname(fileURLToPath(import.meta.url)), "../.cache/disclosures");

export interface Cache {
  get(key: string, maxAgeMs?: number): Uint8Array | null;
  put(key: string, body: Uint8Array): void;
}

export function fileCache(dir = DEFAULT_CACHE_DIR, now = () => Date.now()): Cache {
  return {
    get(key, maxAgeMs) {
      const path = join(dir, key);
      try {
        if (maxAgeMs !== undefined && now() - statSync(path).mtimeMs > maxAgeMs) return null;
        return new Uint8Array(readFileSync(path));
      } catch {
        return null;
      }
    },
    put(key, body) {
      const path = join(dir, key);
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, body);
    },
  };
}

export const memoryCache = (): Cache => {
  const m = new Map<string, Uint8Array>();
  return { get: (k) => m.get(k) ?? null, put: (k, b) => void m.set(k, b) };
};

/**
 * Spaces requests to one source at least `gapMs` apart and counts them against a budget. The
 * sources are small government servers: a run never has more than one request in flight.
 */
export class Throttle {
  requests = 0;
  private last = 0;
  constructor(
    private readonly gapMs: number,
    readonly budget: number,
    private readonly sleep: (ms: number) => Promise<void> = (ms) => new Promise((r) => setTimeout(r, ms)),
    private readonly now: () => number = () => Date.now(),
  ) {}
  get exhausted() {
    return this.requests >= this.budget;
  }
  async wait() {
    const due = this.last + this.gapMs - this.now();
    if (this.requests > 0 && due > 0) await this.sleep(due);
    this.last = this.now();
    this.requests++;
  }
}

// ---------------------------------------------------------------------------------------------
// Storage

export async function loadMatchMembers(db: Db): Promise<MatchMember[]> {
  const { rows } = await db.query<MatchMember>(
    "select bioguide_id, first_name, last_name, state, district, chamber from members order by bioguide_id",
  );
  return rows;
}

/** Upserts listed filings with their member match. A filing's parse state is kept across runs. */
export async function upsertFilings(db: Db, filings: (ListedFiling & { memberId: string | null })[]): Promise<void> {
  if (filings.length === 0) return;
  const rows = filings.map((f) => ({
    id: f.id,
    chamber: f.chamber,
    member_id: f.memberId,
    filer_name: f.filerName,
    filer_state_district: f.stateDistrict,
    kind: f.kind,
    amendment: f.amendment,
    report_year: f.reportYear,
    filed_on: f.filedOn,
    source_url: f.sourceUrl,
    format: f.format,
  }));
  await db.query(
    `insert into disclosure_filings (id, chamber, member_id, filer_name, filer_state_district, kind, amendment,
                                     report_year, filed_on, source_url, format, parse_status)
     select id, chamber, member_id, filer_name, filer_state_district, kind, amendment, report_year, filed_on,
            source_url, format, case when format = 'paper' then 'paper' else 'pending' end
       from jsonb_to_recordset($1::jsonb) as x(id text, chamber chamber, member_id text, filer_name text,
            filer_state_district text, kind text, amendment boolean, report_year smallint, filed_on date,
            source_url text, format text)
      where member_id is null or exists (select 1 from members m where m.bioguide_id = x.member_id)
     on conflict (id) do update set
       member_id = excluded.member_id, filer_name = excluded.filer_name,
       filer_state_district = excluded.filer_state_district, kind = excluded.kind, amendment = excluded.amendment,
       report_year = excluded.report_year, filed_on = excluded.filed_on, source_url = excluded.source_url,
       listed_at = now()`,
    [JSON.stringify(rows)],
  );
}

/** Replaces a filing's parsed rows and records how it went, in one statement. */
export async function storeParse(db: Db, filingId: string, result: ParseResult | { error: string }): Promise<void> {
  if ("error" in result) {
    await db.query(
      "update disclosure_filings set parse_status = 'failed', parse_error = $2, parsed_at = now() where id = $1",
      [filingId, result.error.slice(0, 500)],
    );
    return;
  }
  const assets = result.format === "electronic" ? result.assets : [];
  const trades = result.format === "electronic" ? result.trades : [];
  await db.query(
    `with f as (
       update disclosure_filings set format = $2, parse_status = case when $2 = 'paper' then 'paper' else 'parsed' end,
              parse_error = null, parsed_at = now()
        where id = $1 returning id
     ), da as (
       delete from disclosure_assets where filing_id = $1
     ), dt as (
       delete from disclosure_transactions where filing_id = $1
     ), ia as (
       insert into disclosure_assets (filing_id, position, name, asset_type, asset_type_code, account, owner,
                                      value_range, income_type, income_range, description)
       select f.id, x.position, x.name, x.asset_type, x.asset_type_code, x.account, x.owner, x.value_range,
              x.income_type, x.income_range, x.description
         from f cross join jsonb_to_recordset($3::jsonb) as x(position int, name text, asset_type text,
              asset_type_code text, account text, owner text, value_range text, income_type text,
              income_range text, description text)
     ), it as (
       insert into disclosure_transactions (filing_id, position, owner, asset_name, ticker, asset_type, asset_type_code,
                                            tx_type, tx_type_filed, amount_range, transacted_on, notified_on,
                                            cap_gains_over_200, comment)
       select f.id, x.position, x.owner, x.asset_name, x.ticker, x.asset_type, x.asset_type_code, x.tx_type,
              x.tx_type_filed, x.amount_range, x.transacted_on, x.notified_on, x.cap_gains_over_200, x.comment
         from f cross join jsonb_to_recordset($4::jsonb) as x(position int, owner text, asset_name text, ticker text,
              asset_type text, asset_type_code text, tx_type text, tx_type_filed text, amount_range text,
              transacted_on date, notified_on date, cap_gains_over_200 boolean, comment text)
     )
     select 1`,
    [
      filingId,
      result.format,
      JSON.stringify(
        assets.map((a, i) => ({
          position: i + 1,
          name: a.name,
          asset_type: a.assetType,
          asset_type_code: a.assetTypeCode,
          account: a.account,
          owner: a.owner,
          value_range: a.valueRange,
          income_type: a.incomeType,
          income_range: a.incomeRange,
          description: a.description,
        })),
      ),
      JSON.stringify(
        trades.map((t, i) => ({
          position: i + 1,
          owner: t.owner,
          asset_name: t.assetName,
          ticker: t.ticker,
          asset_type: t.assetType,
          asset_type_code: t.assetTypeCode,
          tx_type: t.txType,
          tx_type_filed: t.txTypeFiled,
          amount_range: t.amountRange,
          transacted_on: t.transactedOn,
          notified_on: t.notifiedOn,
          cap_gains_over_200: t.capGainsOver200,
          comment: t.comment,
        })),
      ),
    ],
  );
}

// ---------------------------------------------------------------------------------------------
// The run

/** One chamber's source: what its index lists, and how to read one filing's document. */
export interface DisclosureSource {
  chamber: Chamber;
  list(): Promise<ListedFiling[]>;
  /** Throws on a document it cannot read; that filing is stored as failed and retried next run. */
  parse(filing: { id: string; kind: "annual" | "ptr"; sourceUrl: string }): Promise<ParseResult>;
  /** Requests made so far, and whether the run's budget is spent. */
  throttle: Throttle;
}

export interface DisclosureRunResult {
  listed: number;
  matched: number;
  unmatched: string[];
  parsed: number;
  paper: number;
  failed: number;
  assets: number;
  trades: number;
  stillDue: number;
  requests: number;
}

/**
 * Lists a chamber's filings, matches each to a member, and reads the documents still due —
 * newest first — until the request budget is spent. Filings of unmatched filers are stored (with
 * no member) but not downloaded; their names are returned so they can be checked by hand.
 */
export async function ingestDisclosures(
  db: Db,
  source: DisclosureSource,
  opts: { log?: (msg: string) => void } = {},
): Promise<DisclosureRunResult> {
  const log = opts.log ?? (() => {});
  const finish = await startRun(db, `${source.chamber}_disclosures`);
  const result: DisclosureRunResult = {
    listed: 0, matched: 0, unmatched: [], parsed: 0, paper: 0, failed: 0, assets: 0, trades: 0, stillDue: 0, requests: 0,
  };
  try {
    const members = await loadMatchMembers(db);
    // One row per filing: an index can list a document twice, and one statement cannot upsert a row twice.
    const listed = [...new Map((await source.list()).map((f) => [f.id, f])).values()];
    const match = source.chamber === "house" ? matchHouseFiler : matchSenateFiler;
    const withMembers = listed.map((f) => ({ ...f, memberId: match(members, f) }));
    result.listed = withMembers.length;
    result.matched = withMembers.filter((f) => f.memberId).length;
    result.unmatched = [
      ...new Set(withMembers.filter((f) => !f.memberId).map((f) => `${f.filerName}${f.stateDistrict ? ` (${f.stateDistrict})` : ""}`)),
    ].sort();
    for (let i = 0; i < withMembers.length; i += 500) await upsertFilings(db, withMembers.slice(i, i + 500));

    const { rows: due } = await db.query<{ id: string; kind: "annual" | "ptr"; source_url: string }>(
      `select id, kind, source_url from disclosure_filings
        where chamber = $1 and member_id is not null and parse_status in ('pending', 'failed') and id = any($2)
        order by filed_on desc nulls last, id`,
      [source.chamber, withMembers.map((f) => f.id)],
    );
    for (const [i, f] of due.entries()) {
      if (source.throttle.exhausted) {
        result.stillDue = due.length - i;
        break;
      }
      try {
        const parsed = await source.parse({ id: f.id, kind: f.kind, sourceUrl: f.source_url });
        await storeParse(db, f.id, parsed);
        if (parsed.format === "paper") result.paper++;
        else {
          result.parsed++;
          result.assets += parsed.assets.length;
          result.trades += parsed.trades.length;
        }
      } catch (err) {
        result.failed++;
        log(`${f.id}: ${errorText(err)}`);
        await storeParse(db, f.id, { error: errorText(err) });
      }
    }
    result.requests = source.throttle.requests;
    await finish(result.parsed + result.paper, undefined, result.failed);
    return result;
  } catch (err) {
    result.requests = source.throttle.requests;
    await finish(result.parsed + result.paper, errorText(err), result.failed);
    throw err;
  }
}

// ---------------------------------------------------------------------------------------------
// The CLI's options

export interface DisclosureArgs {
  chamber: Chamber;
  /** House: the yearly indexes to read. */
  years: number[];
  /** Annual reports received on or after this date (Senate). */
  annualSince: string;
  /** PTRs filed on or after this date: 13 months back, a month more than the product shows. */
  ptrSince: string;
  budget: number;
}

/** `disclosures <house|senate> [--year N] [--budget N]`. */
export function parseDisclosureArgs(args: string[], now: Date): DisclosureArgs {
  const [chamber] = args;
  if (chamber !== "house" && chamber !== "senate") throw new Error("disclosures needs a chamber: house or senate");
  const flag = (name: string) => {
    const i = args.indexOf(name);
    if (i < 0) return undefined;
    const value = Number(args[i + 1]);
    if (!Number.isInteger(value) || value <= 0) throw new Error(`${name} needs a positive whole number`);
    return value;
  };
  const thisYear = now.getUTCFullYear();
  const year = flag("--year");
  // The latest annual report can be two indexes back: in March 2027 the newest filed is CY2025's,
  // listed in 2025FD.
  const years = year ? [year] : [thisYear, thisYear - 1, thisYear - 2];
  const since = new Date(now);
  since.setUTCMonth(since.getUTCMonth() - 13);
  return {
    chamber,
    years,
    annualSince: `${Math.min(...years)}-01-01`,
    ptrSince: year ? `${year}-01-01` : since.toISOString().slice(0, 10),
    budget: flag("--budget") ?? 150,
  };
}

/** The source for a chamber with the run's cache and politeness settings. */
export async function disclosureSource(opts: DisclosureArgs, cache: Cache = fileCache()): Promise<DisclosureSource> {
  const throttle = new Throttle(1500, opts.budget);
  if (opts.chamber === "house") {
    const { houseSource } = await import("./disclosures-house.js");
    return houseSource({ years: opts.years, ptrSince: opts.ptrSince, cache, throttle });
  }
  const { senateSource } = await import("./disclosures-senate.js");
  return senateSource({ annualSince: opts.annualSince, ptrSince: opts.ptrSince, cache, throttle });
}
