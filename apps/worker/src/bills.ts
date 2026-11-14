import { startRun, type Db } from "./db.js";
import { withRetry } from "./rollcalls.js";
import { restage } from "./stage.js";

/** What a vote is about, parsed from the chamber's measure reference. */
export type MeasureRef =
  | { kind: "bill"; type: BillType; number: number }
  | { kind: "nomination"; number: number; part: number | null }
  | null;

export type BillType = "hr" | "hres" | "hjres" | "hconres" | "s" | "sres" | "sjres" | "sconres";
const BILL_TYPES = new Set<BillType>(["hr", "hres", "hjres", "hconres", "s", "sres", "sjres", "sconres"]);

/**
 * Parses both chambers' formats: the House writes "H R 2207" or "H CON RES 14",
 * the Senate writes "H.R. 2207", "S.J.Res. 10" or "PN1093-3" for nominations.
 * Returns null for procedural references ("QUORUM", "ADJOURN") and treaties.
 */
export function parseMeasureRef(ref: string | null): MeasureRef {
  if (!ref) return null;
  const nomination = /^PN\s*(\d+)(?:-(\d+))?$/i.exec(ref.trim());
  if (nomination) {
    return { kind: "nomination", number: Number(nomination[1]), part: nomination[2] ? Number(nomination[2]) : null };
  }
  const compact = ref.toLowerCase().replace(/[.\s]/g, "");
  const m = /^([a-z]+)(\d+)$/.exec(compact);
  if (!m || !BILL_TYPES.has(m[1] as BillType)) return null;
  return { kind: "bill", type: m[1] as BillType, number: Number(m[2]) };
}

export const billId = (congress: number, type: BillType, number: number) => `${congress}-${type}-${number}`;

export interface BillRow {
  id: string;
  congress: number;
  bill_type: BillType;
  number: number;
  title: string;
  short_title: string | null;
  sponsor_id: string | null;
  introduced_on: string | null;
  origin_chamber: "house" | "senate" | null;
  policy_area: string | null;
  summary: string | null;
  summary_stage: string | null;
  latest_action_on: string | null;
  latest_action_text: string | null;
  cbo_estimates: { title: string; url: string; pubDate: string }[];
  source_updated_at: string | null;
}

export interface ActionRow {
  acted_on: string;
  chamber: "house" | "senate" | null;
  action_code: string | null;
  text: string;
}

/** Converts CRS summary HTML to plain paragraphs. */
export function htmlToText(html: string): string {
  return html
    .replace(/<\/p>\s*<p>/gi, "\n\n")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<li>/gi, "\n• ")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&rsquo;|&lsquo;/g, "'")
    .replace(/&ldquo;|&rdquo;/g, '"')
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/[ \t]{2,}/g, " ")
    .trim();
}

export type Json = Record<string, unknown>;

/** A list field from a Congress.gov response; sub-resources come back as `{ count, url }` links instead. */
export const list = (value: unknown): Json[] => (Array.isArray(value) ? (value as Json[]) : []);

/**
 * Prefers the most advanced short title: enacted, then passed, then reported, then introduced.
 *
 * Congress.gov also lists short titles for *portions* of a bill — the divisions and titles inside it. Those
 * name a component, not the measure, and they tie with the real short title on stage, so whichever the API
 * happened to list first used to win: H.R. 1 (119th) came back as "FEHB Protection Act of 2025" instead of
 * "One Big Beautiful Bill Act", and H.R. 3746 (118th) as "Administrative Pay-As-You-Go Act of 2023" instead
 * of "Fiscal Responsibility Act of 2023". They always carry "for portions of this bill" in the title type.
 */
export function pickShortTitle(titlesJson: Json): string | null {
  const shorts = list(titlesJson["titles"]).filter((t) => {
    const type = String(t["titleType"] ?? "");
    return /^short title/i.test(type) && !/portions of this bill/i.test(type);
  });
  const rank = (t: Json) => {
    const type = String(t["titleType"]).toLowerCase();
    return type.includes("enacted") ? 0 : type.includes("passed") ? 1 : type.includes("reported") ? 2 : 3;
  };
  shorts.sort((a, z) => rank(a) - rank(z));
  return shorts[0] ? String(shorts[0]["title"]) : null;
}

export function toBillRow(billJson: Json, summariesJson: Json, titlesJson: Json = {}): BillRow {
  const b = billJson["bill"] as Json;
  const type = String(b["type"]).toLowerCase() as BillType;
  const congress = Number(b["congress"]);
  const number = Number(b["number"]);
  const sponsor = list(b["sponsors"])[0];
  const latest = b["latestAction"] as Json | undefined;
  const origin = String(b["originChamber"] ?? "").toLowerCase();

  // Ordered by actionDate (the legislative stage), not updateDate: Congress.gov reindexes summaries in
  // arbitrary order, so H.R. 3746 (118th) carries its Public Law summary stamped three minutes *before*
  // its Passed Senate one. Sorting on updateDate therefore stored the stale summary. Sort is stable, so
  // summaries sharing an actionDate keep the order the API returned them in.
  const summaries = list(summariesJson["summaries"]).slice();
  summaries.sort((a, z) => String(a["actionDate"] ?? "").localeCompare(String(z["actionDate"] ?? "")));
  const summary = summaries.at(-1);

  const cbo = list(b["cboCostEstimates"]).map((c) => ({
    title: String(c["title"] ?? ""),
    url: String(c["url"] ?? ""),
    pubDate: String(c["pubDate"] ?? ""),
  }));

  return {
    id: billId(congress, type, number),
    congress,
    bill_type: type,
    number,
    title: String(b["title"] ?? ""),
    short_title: pickShortTitle(titlesJson),
    sponsor_id: sponsor ? String(sponsor["bioguideId"]) : null,
    introduced_on: (b["introducedDate"] as string | undefined) ?? null,
    origin_chamber: origin === "house" || origin === "senate" ? origin : null,
    policy_area: ((b["policyArea"] as Json | undefined)?.["name"] as string | undefined) ?? null,
    summary: summary ? htmlToText(String(summary["text"] ?? "")) : null,
    summary_stage: summary ? String(summary["actionDesc"] ?? "") || null : null,
    latest_action_on: (latest?.["actionDate"] as string | undefined) ?? null,
    latest_action_text: (latest?.["text"] as string | undefined) ?? null,
    cbo_estimates: cbo,
    source_updated_at: (b["updateDateIncludingText"] as string | undefined) ?? (b["updateDate"] as string | undefined) ?? null,
  };
}

/** Actions newest first, with the Library of Congress duplicates of chamber actions removed. */
export function toActionRows(actionsJson: Json): ActionRow[] {
  const seen = new Set<string>();
  const rows: ActionRow[] = [];
  for (const a of list(actionsJson["actions"])) {
    const text = String(a["text"] ?? "").trim();
    const date = String(a["actionDate"] ?? "");
    if (!text || !date) continue;
    const key = `${date}|${text}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const source = String((a["sourceSystem"] as Json | undefined)?.["name"] ?? "").toLowerCase();
    rows.push({
      acted_on: date,
      chamber: source.startsWith("house") ? "house" : source.startsWith("senate") ? "senate" : null,
      action_code: (a["actionCode"] as string | undefined) ?? null,
      text,
    });
  }
  return rows;
}

/**
 * Stores a bill with its actions in one statement, and stamps it as fetched (`details_fetched_at`).
 * Unknown sponsors are stored as null. With `keepShortTitle`, the stored short title stays: the
 * catalog skips the `/titles` request for bills whose display title already is one.
 */
export async function upsertBill(
  db: Db,
  bill: BillRow,
  actions: ActionRow[],
  opts: { keepShortTitle?: boolean } = {},
): Promise<void> {
  await db.query(
    `with b as (
       insert into bills (id, congress, bill_type, number, title, short_title, sponsor_id, introduced_on,
                          origin_chamber, policy_area, summary, summary_stage, latest_action_on, latest_action_text,
                          cbo_estimates, source_updated_at, updated_at, details_fetched_at)
       values ($1, $2, $3, $4, $5, $6, (select bioguide_id from members where bioguide_id = $7), $8,
               $9::chamber, $10, $11, $12, $13, $14, $15::jsonb, $16, now(), now())
       on conflict (id) do update set
         title = excluded.title,
         short_title = case when $18 then coalesce(bills.short_title, excluded.short_title) else excluded.short_title end,
         sponsor_id = excluded.sponsor_id,
         introduced_on = excluded.introduced_on, origin_chamber = excluded.origin_chamber,
         policy_area = excluded.policy_area, summary = excluded.summary, summary_stage = excluded.summary_stage,
         latest_action_on = excluded.latest_action_on, latest_action_text = excluded.latest_action_text,
         cbo_estimates = excluded.cbo_estimates, source_updated_at = excluded.source_updated_at, updated_at = now(),
         details_fetched_at = now()
       returning id
     ), cleared as (
       delete from actions where bill_id = $1
     )
     insert into actions (bill_id, acted_on, chamber, action_code, text)
     select b.id, a.acted_on, a.chamber::chamber, a.action_code, a.text
       from b cross join jsonb_to_recordset($17::jsonb) as a(acted_on date, chamber text, action_code text, text text)`,
    [
      bill.id, bill.congress, bill.bill_type, bill.number, bill.title, bill.short_title, bill.sponsor_id,
      bill.introduced_on, bill.origin_chamber, bill.policy_area, bill.summary, bill.summary_stage,
      bill.latest_action_on, bill.latest_action_text, JSON.stringify(bill.cbo_estimates), bill.source_updated_at,
      JSON.stringify(actions), opts.keepShortTitle ?? false,
    ],
  );
}

export type CongressGet = (path: string) => Promise<Json>;

/**
 * What a caller can learn from, and impose on, every request a client sends: the catalog's
 * `RequestBudget` implements it.
 */
export interface RequestMeter {
  /** Awaited before every attempt, retries included, so a retried request is paced and counted. */
  take(): Promise<void>;
  /**
   * api.data.gov's `X-RateLimit-Remaining` for the key, from every response that carries it. The
   * key is shared by every job that uses it, so this is the one number that counts them all.
   */
  observe?(remaining: number): void;
}

/**
 * Congress.gov API client. Retries rate limits and server errors with backoff. With a `meter`,
 * every attempt waits on it and every response reports the key's remaining requests to it.
 */
export function congressClient(apiKey: string, fetchImpl: typeof fetch = fetch, meter?: RequestMeter): CongressGet {
  return async (path) => {
    const sep = path.includes("?") ? "&" : "?";
    const url = `https://api.congress.gov/v3${path}${sep}format=json&api_key=${apiKey}`;
    for (let attempt = 1; ; attempt++) {
      await meter?.take();
      const res = await fetchImpl(url, { headers: { "user-agent": "floor-ingest/0.1" } });
      const remaining = Number(res.headers.get("x-ratelimit-remaining") ?? Number.NaN);
      if (Number.isFinite(remaining)) meter?.observe?.(remaining);
      if (res.ok) return (await res.json()) as Json;
      if ((res.status === 429 || res.status >= 500) && attempt < 5) {
        await new Promise((r) => setTimeout(r, 1000 * 2 ** attempt));
        continue;
      }
      // Never include the URL: it carries the API key.
      throw new Error(`Congress.gov ${path} returned HTTP ${res.status}`);
    }
  };
}

/**
 * A bill's actions, every page: `/actions` stops at 250 a page, and the largest bills (an NDAA, an
 * omnibus) have more. Merged into one response so `toActionRows` reads it as one.
 */
export async function fetchActions(get: CongressGet, billPath: string): Promise<Json> {
  const first = await get(`${billPath}/actions?limit=250`);
  const all = [...list(first["actions"])];
  const count = Number((first["pagination"] as Json | undefined)?.["count"] ?? all.length);
  for (let offset = 250; offset < count && all.length >= offset; offset += 250) {
    const page = await get(`${billPath}/actions?limit=250&offset=${offset}`);
    const items = list(page["actions"]);
    if (items.length === 0) break;
    all.push(...items);
  }
  return { ...first, actions: all };
}

/**
 * Loads every bill that a stored vote refers to but that isn't linked yet, then links those votes to it.
 *
 * With `refresh`, re-fetches bills already stored instead, leaving the vote links alone. Use it when a bill
 * has moved on since it was loaded, or when a mapping fix means the stored rows need rebuilding.
 */
export async function ingestVotedBills(
  db: Db,
  get: CongressGet,
  opts: { limit?: number; refresh?: boolean; log?: (msg: string) => void } = {},
): Promise<{ bills: number; linkedVotes: number; failed: number }> {
  const finish = await startRun(db, "bills");
  let bills = 0;
  let linkedVotes = 0;
  let failed = 0;
  try {
    // Group the chambers' different spellings of the same bill.
    const byBill = new Map<string, { congress: number; type: BillType; number: number; refs: string[] }>();
    if (opts.refresh) {
      const { rows } = await db.query<{ id: string; congress: number; bill_type: BillType; number: number }>(
        "select id, congress, bill_type, number from bills order by id",
      );
      for (const r of rows) byBill.set(r.id, { congress: r.congress, type: r.bill_type, number: r.number, refs: [] });
    } else {
      const { rows } = await db.query<{ congress: number; bill_ref: string }>(
        "select distinct congress, bill_ref from votes where bill_id is null and bill_ref is not null order by congress, bill_ref",
      );
      for (const r of rows) {
        const ref = parseMeasureRef(r.bill_ref);
        if (ref?.kind !== "bill") continue;
        const id = billId(r.congress, ref.type, ref.number);
        const entry = byBill.get(id) ?? { congress: r.congress, type: ref.type, number: ref.number, refs: [] };
        entry.refs.push(r.bill_ref);
        byBill.set(id, entry);
      }
    }

    for (const [id, b] of byBill) {
      if (opts.limit !== undefined && bills >= opts.limit) break;
      const path = `/bill/${b.congress}/${b.type}/${b.number}`;
      try {
        const [bill, actions, summaries, titles] = await Promise.all([
          get(path),
          fetchActions(get, path),
          get(`${path}/summaries`),
          get(`${path}/titles?limit=250`),
        ]);
        await withRetry(() => upsertBill(db, toBillRow(bill, summaries, titles), toActionRows(actions)));
        // A refresh has no refs to match: the votes are already linked, only the bill row is being rebuilt.
        if (b.refs.length > 0) {
          const { rows: linked } = await db.query<{ n: number }>(
            `with u as (update votes set bill_id = $1 where congress = $2 and bill_ref = any($3::text[]) returning 1)
             select count(*)::int as n from u`,
            [id, b.congress, b.refs],
          );
          linkedVotes += linked[0]?.n ?? 0;
          // A passage vote can settle a chamber before the bill's actions say so (stage.ts).
          await restage(db, [id]);
          opts.log?.(`${id}: linked ${linked[0]?.n ?? 0} votes`);
        } else {
          await restage(db, [id]);
          opts.log?.(`${id}: refreshed`);
        }
        bills++;
      } catch (err) {
        // One missing or malformed bill shouldn't stop the rest; it stays unlinked and is retried next run.
        failed++;
        opts.log?.(`${id}: ${err instanceof Error ? err.message : String(err)}`);
      }
    }
    // Per-bill failures are counted, not reported as the run's error (lesson 38).
    await finish(bills, undefined, failed);
  } catch (err) {
    await finish(bills, err instanceof Error ? err.message : String(err), failed);
    throw err;
  }
  return { bills, linkedVotes, failed };
}
