/** One member as stored in the `members` table. */
export interface MemberRow {
  bioguide_id: string;
  first_name: string;
  last_name: string;
  party: string;
  state: string;
  district: number | null;
  chamber: "house" | "senate";
  term_start: string;
  term_end: string;
  ids: Record<string, unknown>;
}

/** Shape of an entry in congress-legislators' legislators-*.json files (fields we use). */
export interface LegislatorEntry {
  id: { bioguide: string; lis?: string; govtrack?: number; icpsr?: number; thomas?: string; fec?: string[] };
  name: { first: string; last: string; nickname?: string };
  terms: {
    type: "sen" | "rep";
    start: string;
    end: string;
    state: string;
    district?: number;
    party?: string;
    url?: string;
    rss_url?: string;
  }[];
}

export const CURRENT_URL = "https://unitedstates.github.io/congress-legislators/legislators-current.json";
export const HISTORICAL_URL = "https://unitedstates.github.io/congress-legislators/legislators-historical.json";

const PARTY: Record<string, string> = { Democrat: "D", Republican: "R", Independent: "I", Libertarian: "L" };

/**
 * Parties congress-legislators has wrong, corrected on the way in. Keyed by Bioguide ID *and* term
 * start, so an override lapses at the member's next term instead of silently outliving the error.
 *
 * - `K000401|2025-01-03` — Kevin Kiley (CA-3). Upstream lists his 119th-Congress term as
 *   "Independent"; his 118th term says "Republican", and across the 1,879 House roll calls we hold
 *   he sides with the Republican majority on 88% and the Democratic majority on 42%. Left alone he
 *   is the sole member of an "I" bloc, which puts a spurious one-vote third-party row on the party
 *   breakdown of nearly every House vote and makes his party-loyalty figure a trivial 100%.
 *
 * Genuine independents (Sanders, King, and Manchin and Sinema after they left the Democrats) are
 * *not* overridden: their entries are correct.
 */
const PARTY_OVERRIDES: Record<string, string> = {
  "K000401|2025-01-03": "R",
};

/**
 * Converts congress-legislators entries to member rows using each member's latest term.
 * Members whose latest term ended before `servedSince` are dropped, so historical data
 * only adds people who could appear in the roll calls we backfill. The default reaches
 * back before the 118th Congress because the Clerk can list members-elect who died
 * before being sworn in (Rep. McEachin is on the first roll call of 2023).
 */
export function toMemberRows(entries: LegislatorEntry[], servedSince = "2022-11-01"): MemberRow[] {
  const rows: MemberRow[] = [];
  for (const e of entries) {
    const term = e.terms.at(-1);
    if (!term || term.end < servedSince) continue;
    const ids: Record<string, unknown> = {};
    if (e.id.lis) ids.lis = e.id.lis;
    if (e.id.govtrack) ids.govtrack = e.id.govtrack;
    if (e.id.icpsr) ids.icpsr = e.id.icpsr;
    // Every FEC candidate ID the member has held, e.g. a House ID and a later Senate one.
    if (e.id.fec?.length) ids.fec = e.id.fec;
    if (term.url) ids.url = term.url;
    if (term.rss_url) ids.rss_url = term.rss_url;
    rows.push({
      bioguide_id: e.id.bioguide,
      first_name: e.name.nickname ?? e.name.first,
      last_name: e.name.last,
      party:
        PARTY_OVERRIDES[`${e.id.bioguide}|${term.start}`] ??
        PARTY[term.party ?? ""] ??
        (term.party ?? "?").slice(0, 1),
      state: term.state,
      district: term.type === "rep" ? (term.district ?? 0) : null,
      chamber: term.type === "sen" ? "senate" : "house",
      term_start: term.start,
      term_end: term.end,
      ids,
    });
  }
  return rows;
}
