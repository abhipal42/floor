import { strFromU8, unzipSync } from "fflate";
import { errorText, startRun, type Db } from "./db.js";
import { withRetry } from "./rollcalls.js";

// Campaign finance from the FEC. Two sources, each labelled where it is shown:
// - OpenFEC candidate totals: what the member's campaign reported *receiving* (one call each).
// - The bulk file of committee-to-candidate contributions (pas2): what each committee reported
//   *giving*. Individuals' money passed through a committee ("earmarked") is kept apart from the
//   committee's own direct contributions, and memo text — which names individual donors — is
//   read for the word EARMARK and then discarded. Product rule: no individual donors' names.

type Json = Record<string, unknown>;

export interface FecMember {
  bioguide_id: string;
  chamber: "house" | "senate";
  state: string;
  term_end: string;
  fec: string[];
}

/** The FEC candidate ID for the seat held now: `S…` for a senator, `H…` for a House member, in their state. */
export function pickCandidateId(m: Pick<FecMember, "chamber" | "state" | "fec">): string | null {
  const prefix = m.chamber === "senate" ? "S" : "H";
  return m.fec.filter((id) => id.startsWith(prefix) && id.slice(2, 4) === m.state).at(-1) ?? null;
}

/** The election the member's current campaign is for: the year before their term ends. */
export const campaignCycle = (termEnd: string) => Number(termEnd.slice(0, 4)) - 1;

export interface FinanceRow {
  member_id: string;
  fec_candidate_id: string;
  cycle: number;
  coverage_start: string | null;
  coverage_end: string | null;
  receipts: number;
  individual_unitemized: number;
  individual_itemized: number;
  pac: number;
  party: number;
  other: number;
  cash_on_hand: number | null;
}

const num = (v: unknown) => (typeof v === "number" ? v : Number(v ?? 0)) || 0;
const day = (v: unknown) => (typeof v === "string" ? v.slice(0, 10) : null);
const cents = (n: number) => Math.round(n * 100) / 100;

/** Maps an OpenFEC `/candidate/{id}/totals` response. Null when the FEC has no totals yet. */
export function toFinanceRow(memberId: string, candidateId: string, cycle: number, totals: Json): FinanceRow | null {
  const t = (totals["results"] as Json[] | undefined)?.[0];
  if (!t) return null;
  const receipts = num(t["receipts"]);
  const unitemized = num(t["individual_unitemized_contributions"]);
  const itemized = num(t["individual_itemized_contributions"]);
  const pac = num(t["other_political_committee_contributions"]);
  const party = num(t["political_party_committee_contributions"]);
  return {
    member_id: memberId,
    fec_candidate_id: candidateId,
    cycle,
    coverage_start: day(t["coverage_start_date"]),
    coverage_end: day(t["coverage_end_date"]),
    receipts,
    individual_unitemized: unitemized,
    individual_itemized: itemized,
    pac,
    party,
    // Transfers from joint fundraising committees, the candidate's own money, refunds and the rest.
    other: cents(receipts - unitemized - itemized - pac - party),
    cash_on_hand: t["last_cash_on_hand_end_period"] == null ? null : num(t["last_cash_on_hand_end_period"]),
  };
}

export type FecGet = (path: string) => Promise<Json>;

/**
 * OpenFEC client. The api.data.gov key allows 60 requests a minute here; on a 429 it waits and
 * retries. Errors carry the path only, never the URL, which holds the key.
 */
export function fecClient(apiKey: string, fetchImpl: typeof fetch = fetch, waitMs = 61_000): FecGet {
  return async (path) => {
    const sep = path.includes("?") ? "&" : "?";
    const url = `https://api.open.fec.gov/v1${path}${sep}api_key=${apiKey}`;
    for (let attempt = 1; ; attempt++) {
      const res = await fetchImpl(url, { headers: { "user-agent": "floor-ingest/0.1" } });
      if (res.ok) {
        if (res.headers.get("x-ratelimit-remaining") === "0") await new Promise((r) => setTimeout(r, waitMs));
        return (await res.json()) as Json;
      }
      if ((res.status === 429 || res.status >= 500) && attempt < 6) {
        await new Promise((r) => setTimeout(r, res.status === 429 ? waitMs : 2000 * attempt));
        continue;
      }
      throw new Error(`OpenFEC ${path} returned HTTP ${res.status}`);
    }
  };
}

async function currentMembers(db: Db): Promise<FecMember[]> {
  const { rows } = await db.query<{ bioguide_id: string; chamber: "house" | "senate"; state: string; term_end: Date | string; fec: string[] | null }>(
    `select bioguide_id, chamber, state, term_end, ids->'fec' as fec from members where term_end > current_date order by bioguide_id`,
  );
  return rows.map((r) => ({
    ...r,
    term_end: typeof r.term_end === "string" ? r.term_end.slice(0, 10) : r.term_end.toISOString().slice(0, 10),
    fec: r.fec ?? [],
  }));
}

/** Loads campaign totals for every current member not refreshed in the last `staleHours`. */
export async function ingestFecTotals(
  db: Db,
  get: FecGet,
  opts: { staleHours?: number; limit?: number; log?: (msg: string) => void } = {},
): Promise<{ loaded: number; noTotals: number; noCandidateId: number; failed: number }> {
  const finish = await startRun(db, "fec_totals");
  const result = { loaded: 0, noTotals: 0, noCandidateId: 0, failed: 0 };
  try {
    const { rows: fresh } = await db.query<{ member_id: string }>(
      "select member_id from campaign_finance where updated_at > now() - make_interval(hours => $1)",
      [opts.staleHours ?? 20],
    );
    const skip = new Set(fresh.map((r) => r.member_id));
    for (const m of await currentMembers(db)) {
      if (skip.has(m.bioguide_id)) continue;
      if (opts.limit !== undefined && result.loaded >= opts.limit) break;
      const candidateId = pickCandidateId(m);
      if (!candidateId) {
        result.noCandidateId++;
        opts.log?.(`${m.bioguide_id}: no FEC candidate ID for a ${m.chamber} seat in ${m.state}`);
        continue;
      }
      const cycle = campaignCycle(m.term_end);
      try {
        const row = toFinanceRow(m.bioguide_id, candidateId, cycle, await get(`/candidate/${candidateId}/totals/?cycle=${cycle}&election_full=true`));
        if (!row) {
          result.noTotals++;
          continue;
        }
        await withRetry(() =>
          db.query(
            `insert into campaign_finance (member_id, fec_candidate_id, cycle, coverage_start, coverage_end, receipts,
               individual_unitemized, individual_itemized, pac, party, other, cash_on_hand, updated_at)
             values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, now())
             on conflict (member_id) do update set fec_candidate_id = excluded.fec_candidate_id, cycle = excluded.cycle,
               coverage_start = excluded.coverage_start, coverage_end = excluded.coverage_end, receipts = excluded.receipts,
               individual_unitemized = excluded.individual_unitemized, individual_itemized = excluded.individual_itemized,
               pac = excluded.pac, party = excluded.party, other = excluded.other, cash_on_hand = excluded.cash_on_hand,
               updated_at = now()`,
            [row.member_id, row.fec_candidate_id, row.cycle, row.coverage_start, row.coverage_end, row.receipts,
              row.individual_unitemized, row.individual_itemized, row.pac, row.party, row.other, row.cash_on_hand],
          ),
        );
        result.loaded++;
      } catch (err) {
        result.failed++;
        opts.log?.(`${m.bioguide_id}: ${err instanceof Error ? err.message : String(err)}`);
      }
    }
    // Per-member failures are counted, not reported as the run's error (lesson 38).
    await finish(result.loaded, undefined, result.failed);
  } catch (err) {
    await finish(result.loaded, errorText(err), result.failed);
    throw err;
  }
  return result;
}

export interface Committee {
  name: string;
  /** CMTE_DSGN. `J` marks a joint fundraising committee, whose transfers are not contributions. */
  designation: string | null;
  type: string | null;
  orgType: string | null;
  connectedOrg: string | null;
}

/**
 * Party committees (CMTE_TP X, Y, Z) and joint fundraising committees (CMTE_DSGN J) are not PACs:
 * a party can give far more than $10,000, and a joint fundraiser transfers money it raised for the
 * candidate. Lists of PAC checks leave both out.
 */
export const isPac = (c: Pick<Committee, "designation" | "type">) =>
  c.designation !== "J" && !(c.type === "X" || c.type === "Y" || c.type === "Z");

/** Parses the FEC committee master file (cm.txt): pipe-delimited, no header. */
export function parseCommitteeMaster(text: string): Map<string, Committee> {
  const out = new Map<string, Committee>();
  for (const line of text.split("\n")) {
    const c = line.split("|");
    if (!c[0] || !c[1]) continue;
    out.set(c[0], { name: c[1], designation: c[8] || null, type: c[9] || null, orgType: c[12] || null, connectedOrg: c[13] || null });
  }
  return out;
}

export interface PacTotal {
  direct: number;
  earmarked: number;
}

/**
 * Aggregates the committee-to-candidate file (itpas2.txt) into totals per member and giving
 * committee. Only contributions to the candidate (type 24K) count. A transaction filed again on
 * an amended report keeps only its latest filing; voided checks are negative rows and net out.
 */
export function aggregatePacContributions(text: string, candidateToMember: Map<string, string>): Map<string, Map<string, PacTotal>> {
  const latest = new Map<string, string[]>();
  for (const line of text.split("\n")) {
    const c = line.split("|");
    if (c[5] !== "24K" || !candidateToMember.has(c[16] ?? "")) continue;
    const key = `${c[0]}|${c[17]}`;
    const prev = latest.get(key);
    if (!prev || Number(c[18]) > Number(prev[18])) latest.set(key, c);
  }
  const out = new Map<string, Map<string, PacTotal>>();
  for (const c of latest.values()) {
    const member = candidateToMember.get(c[16]!)!;
    const byCommittee = out.get(member) ?? new Map<string, PacTotal>();
    const total = byCommittee.get(c[0]!) ?? { direct: 0, earmarked: 0 };
    const amount = Number(c[14]) || 0;
    if (/EARMARK/i.test(c[20] ?? "")) total.earmarked = cents(total.earmarked + amount);
    else total.direct = cents(total.direct + amount);
    byCommittee.set(c[0]!, total);
    out.set(member, byCommittee);
  }
  return out;
}

export type FetchBytes = (url: string) => Promise<Uint8Array>;

const defaultFetchBytes: FetchBytes = async (url) => {
  const res = await fetch(url, { headers: { "user-agent": "floor-ingest/0.1" } });
  if (!res.ok) throw new Error(`${url} returned HTTP ${res.status}`);
  return new Uint8Array(await res.arrayBuffer());
};

/** The one text file inside an FEC bulk zip. */
export function unzipText(bytes: Uint8Array): string {
  const files = Object.values(unzipSync(bytes));
  if (files.length !== 1) throw new Error(`Expected one file in the FEC zip, found ${files.length}`);
  return strFromU8(files[0]!);
}

export const bulkUrl = (cycle: number, file: "pas2" | "cm") =>
  `https://www.fec.gov/files/bulk-downloads/${cycle}/${file}${String(cycle).slice(2)}.zip`;

/** Loads committee-to-candidate totals for every current member from one cycle's bulk files. */
export async function ingestPacContributions(
  db: Db,
  cycle: number,
  opts: { fetchBytes?: FetchBytes; log?: (msg: string) => void } = {},
): Promise<{ members: number; rows: number }> {
  const finish = await startRun(db, "fec_pacs");
  try {
    const fetchBytes = opts.fetchBytes ?? defaultFetchBytes;
    const [pas2, cm] = await Promise.all([fetchBytes(bulkUrl(cycle, "pas2")), fetchBytes(bulkUrl(cycle, "cm"))]);
    const committees = parseCommitteeMaster(unzipText(cm));
    const candidateToMember = new Map<string, string>();
    for (const m of await currentMembers(db)) for (const id of m.fec) candidateToMember.set(id, m.bioguide_id);
    const totals = aggregatePacContributions(unzipText(pas2), candidateToMember);

    let rows = 0;
    for (const [member, byCommittee] of totals) {
      const payload = [...byCommittee].map(([id, t]) => {
        const c = committees.get(id);
        return {
          committee_id: id,
          committee_name: c?.name ?? id,
          committee_designation: c?.designation ?? null,
          committee_type: c?.type ?? null,
          org_type: c?.orgType ?? null,
          connected_org: c?.connectedOrg ?? null,
          direct_amount: t.direct,
          earmarked_amount: t.earmarked,
        };
      });
      // One statement per member, so their rows for this cycle change together or not at all. It
      // upserts the committees in the file and deletes any that dropped out; a plain delete-then-
      // insert can't work in one statement, because the insert doesn't see the delete.
      await withRetry(() =>
        db.query(
          `with input as (
             select * from jsonb_to_recordset($3::jsonb) as p(committee_id text, committee_name text, committee_designation text, committee_type text,
               org_type text, connected_org text, direct_amount numeric, earmarked_amount numeric)
           ), upserted as (
             insert into pac_contributions (member_id, cycle, committee_id, committee_name, committee_designation, committee_type, org_type,
               connected_org, direct_amount, earmarked_amount)
             select $1, $2, committee_id, committee_name, committee_designation, committee_type, org_type, connected_org, direct_amount, earmarked_amount
               from input
             on conflict (member_id, cycle, committee_id) do update set committee_name = excluded.committee_name, committee_designation = excluded.committee_designation,
               committee_type = excluded.committee_type, org_type = excluded.org_type, connected_org = excluded.connected_org,
               direct_amount = excluded.direct_amount, earmarked_amount = excluded.earmarked_amount
             returning 1
           )
           delete from pac_contributions
            where member_id = $1 and cycle = $2 and committee_id not in (select committee_id from input)`,
          [member, cycle, JSON.stringify(payload)],
        ),
      );
      rows += payload.length;
    }
    opts.log?.(`${totals.size} members, ${rows} giving committees`);
    await finish(rows);
    return { members: totals.size, rows };
  } catch (err) {
    await finish(0, err instanceof Error ? err.message : String(err));
    throw err;
  }
}
