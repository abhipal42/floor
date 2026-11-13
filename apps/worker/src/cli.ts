import pg from "pg";
import type { Chamber } from "@floor/shared";
import { startRun, upsertMembers, type Db } from "./db.js";
import { CURRENT_URL, HISTORICAL_URL, toMemberRows, type LegislatorEntry } from "./members.js";
import { ingestRollCalls, sessionsToPoll } from "./rollcalls.js";
import { congressClient, ingestVotedBills } from "./bills.js";
import { ingestVotedNominations } from "./nominations.js";
import { fecClient, ingestFecTotals, ingestPacContributions } from "./fec.js";

const USAGE = `Usage:
  npm run ingest -w @floor/worker -- members
  npm run ingest -w @floor/worker -- rollcalls <house|senate> <congress> <session> [fromRoll]
  npm run ingest -w @floor/worker -- rollcalls <house|senate> current   (the session in progress; what the schedule runs)
  npm run ingest -w @floor/worker -- bills [limit]              (bills that stored votes refer to; needs CONGRESS_API_KEY)
  npm run ingest -w @floor/worker -- bills --refresh [limit]    (re-fetch bills already stored, to pick up changes or mapping fixes)
  npm run ingest -w @floor/worker -- nominations [limit]         (nominations that stored Senate votes refer to; needs CONGRESS_API_KEY)
  npm run ingest -w @floor/worker -- nominations --refresh [limit]
  npm run ingest -w @floor/worker -- fec-totals [limit]           (campaign totals per current member from OpenFEC; needs CONGRESS_API_KEY)
  npm run ingest -w @floor/worker -- fec-pacs [cycle]             (committee-to-candidate totals from the FEC bulk files; default 2026)

Reads DATABASE_URL from the environment (use the Supabase service connection string).`;

async function getJson<T>(url: string): Promise<T> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url} returned HTTP ${res.status}`);
  return (await res.json()) as T;
}

async function main() {
  const [command, ...args] = process.argv.slice(2);
  if (!command || !process.env.DATABASE_URL) {
    console.error(USAGE);
    process.exit(1);
  }
  // One connection: every command issues its queries one after another, and through Supabase's
  // session pooler each connection is one of the 15 slots the API and everyone else share (lesson 37).
  // `pool.end()` below hands it back the moment the command finishes.
  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 1 });
  const db = pool as unknown as Db;
  try {
    if (command === "members") {
      const finish = await startRun(db, "members");
      const [current, historical] = await Promise.all([
        getJson<LegislatorEntry[]>(CURRENT_URL),
        getJson<LegislatorEntry[]>(HISTORICAL_URL),
      ]);
      const count = await upsertMembers(db, toMemberRows([...historical, ...current]));
      await finish(count);
      console.log(`Upserted ${count} members`);
    } else if (command === "rollcalls") {
      const [chamber, congress, session, from] = args;
      if (chamber !== "house" && chamber !== "senate") throw new Error(USAGE);
      // `current` is what the schedule runs: the session in progress, plus the one just ended early in January.
      const sessions =
        congress === "current" ? sessionsToPoll(new Date()) : [{ congress: Number(congress), session: Number(session) }];
      for (const s of sessions) {
        const result = await ingestRollCalls(db, chamber as Chamber, s.congress, s.session, {
          from: congress !== "current" && from ? Number(from) : undefined,
          log: (msg) => console.log(msg),
        });
        console.log(
          `${chamber} ${s.congress}-${s.session}: stored ${result.stored} roll calls (last: ${result.lastRoll}); ${result.skippedPositions} positions for unknown members`,
        );
      }
    } else if (command === "bills") {
      if (!process.env.CONGRESS_API_KEY) throw new Error("Set CONGRESS_API_KEY in .env (free key: https://api.data.gov/signup)");
      const refresh = args.includes("--refresh");
      const limitArg = args.find((a) => a !== "--refresh");
      const result = await ingestVotedBills(db, congressClient(process.env.CONGRESS_API_KEY), {
        limit: limitArg ? Number(limitArg) : undefined,
        refresh,
        log: (msg) => console.log(msg),
      });
      console.log(
        refresh
          ? `Refreshed ${result.bills} bills, ${result.failed} failed`
          : `Loaded ${result.bills} bills, linked ${result.linkedVotes} votes, ${result.failed} failed`,
      );
    } else if (command === "fec-totals") {
      if (!process.env.CONGRESS_API_KEY) throw new Error("Set CONGRESS_API_KEY in .env (the api.data.gov key works for OpenFEC)");
      const result = await ingestFecTotals(db, fecClient(process.env.CONGRESS_API_KEY), {
        limit: args[0] ? Number(args[0]) : undefined,
        log: (msg) => console.log(msg),
      });
      console.log(
        `Loaded totals for ${result.loaded} members; ${result.noTotals} had none filed, ${result.noCandidateId} had no FEC ID, ${result.failed} failed`,
      );
    } else if (command === "fec-pacs") {
      const cycle = Number(args[0] ?? 2026);
      const result = await ingestPacContributions(db, cycle, { log: (msg) => console.log(msg) });
      console.log(`Loaded ${result.rows} committee totals for ${result.members} members (${cycle} cycle)`);
    } else if (command === "nominations") {
      if (!process.env.CONGRESS_API_KEY) throw new Error("Set CONGRESS_API_KEY in .env (free key: https://api.data.gov/signup)");
      const refresh = args.includes("--refresh");
      const limitArg = args.find((a) => a !== "--refresh");
      const result = await ingestVotedNominations(db, congressClient(process.env.CONGRESS_API_KEY), {
        limit: limitArg ? Number(limitArg) : undefined,
        refresh,
        log: (msg) => console.log(msg),
      });
      console.log(
        refresh
          ? `Refreshed ${result.nominations} nominations, ${result.failed} failed`
          : `Loaded ${result.nominations} nominations, linked ${result.linkedVotes} votes, ${result.failed} failed`,
      );
    } else {
      throw new Error(USAGE);
    }
  } finally {
    await pool.end();
  }
}

function describe(err: unknown): string {
  if (!(err instanceof Error)) return String(err);
  const code = (err as { code?: string }).code;
  // Connection failures arrive as an AggregateError with an empty message.
  const inner = err instanceof AggregateError ? err.errors.map((e) => describe(e)).join("; ") : "";
  return [err.message, code && `(${code})`, inner].filter(Boolean).join(" ") || err.name;
}

main().catch((err) => {
  console.error(describe(err));
  process.exit(1);
});
