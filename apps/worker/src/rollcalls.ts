import { parseHouseRollCall, parseSenateRollCall, type Chamber, type RollCall } from "@floor/shared";
import { lastRollNumber, rollsMissingPositions, startRun, upsertRollCall, type Db } from "./db.js";

export type FetchText = (url: string) => Promise<{ status: number; text: string }>;

export const defaultFetch: FetchText = async (url) => {
  const res = await fetch(url, { headers: { "user-agent": "floor-ingest/0.1" } });
  return { status: res.status, text: res.status === 200 ? await res.text() : "" };
};

/** Calendar year of a congress session (119th, session 1 → 2025). */
export const yearOf = (congress: number, session: number) => 1789 + 2 * (congress - 1) + (session - 1);

export const houseRollUrl = (congress: number, session: number, roll: number) =>
  `https://clerk.house.gov/evs/${yearOf(congress, session)}/roll${String(roll).padStart(3, "0")}.xml`;

export const senateRollUrl = (congress: number, session: number, roll: number) =>
  `https://www.senate.gov/legislative/LIS/roll_call_votes/vote${congress}${session}/vote_${congress}_${session}_${String(roll).padStart(5, "0")}.xml`;

/** Fetches and parses one roll call. Returns null when it hasn't been published yet. */
export async function fetchRollCall(
  chamber: Chamber,
  congress: number,
  session: number,
  roll: number,
  fetchText: FetchText = defaultFetch,
): Promise<RollCall | null> {
  const url = chamber === "house" ? houseRollUrl(congress, session, roll) : senateRollUrl(congress, session, roll);
  const { status, text } = await fetchText(url);
  if (status === 404) return null;
  if (status !== 200) throw new Error(`${url} returned HTTP ${status}`);
  // Both sites can answer a missing vote with an HTML page instead of a 404.
  const marker = chamber === "house" ? "<rollcall-vote" : "<roll_call_vote";
  if (!text.includes(marker)) return null;
  return chamber === "house" ? parseHouseRollCall(text) : parseSenateRollCall(text);
}

/** Postgres errors that succeed when the statement is simply run again. */
const TRANSIENT = new Set(["40P01", "40001"]); // deadlock_detected, serialization_failure

export async function withRetry<T>(fn: () => Promise<T>, attempts = 4, baseDelayMs = 200): Promise<T> {
  for (let i = 1; ; i++) {
    try {
      return await fn();
    } catch (err) {
      const code = (err as { code?: string }).code;
      if (!code || !TRANSIENT.has(code) || i >= attempts) throw err;
      await new Promise((r) => setTimeout(r, baseDelayMs * i));
    }
  }
}

/**
 * Ingests roll calls for one chamber session, starting after the last stored roll
 * (or at `from`) and stopping at the first one that isn't published.
 */
export async function ingestRollCalls(
  db: Db,
  chamber: Chamber,
  congress: number,
  session: number,
  opts: { from?: number; limit?: number; fetchText?: FetchText; log?: (msg: string) => void } = {},
): Promise<{ stored: number; lastRoll: number; skippedPositions: number }> {
  const finish = await startRun(db, `${chamber}_rollcalls`);
  let roll = opts.from ?? (await lastRollNumber(db, chamber, congress, session)) + 1;
  let stored = 0;
  let skippedPositions = 0;
  try {
    // Repair votes saved without positions (for example, by an interrupted older run).
    for (const missing of await rollsMissingPositions(db, chamber, congress, session)) {
      const rc = await fetchRollCall(chamber, congress, session, missing, opts.fetchText);
      if (!rc) continue;
      const result = await withRetry(() => upsertRollCall(db, rc));
      opts.log?.(`repaired ${result.id}: ${result.stored} positions`);
    }

    while (opts.limit === undefined || stored < opts.limit) {
      const rc = await fetchRollCall(chamber, congress, session, roll, opts.fetchText);
      if (!rc) break;
      const result = await withRetry(() => upsertRollCall(db, rc));
      skippedPositions += result.skipped;
      stored++;
      opts.log?.(`${result.id}: ${rc.totals.yea}-${rc.totals.nay}, ${result.stored} positions`);
      roll++;
    }
    await finish(stored);
  } catch (err) {
    await finish(stored, err instanceof Error ? err.message : String(err));
    throw err;
  }
  return { stored, lastRoll: roll - 1, skippedPositions };
}
