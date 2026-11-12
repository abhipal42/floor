import pg from "pg";
import type { Chamber } from "@floor/shared";
import { startRun, upsertMembers, type Db } from "./db.js";
import { CURRENT_URL, HISTORICAL_URL, toMemberRows, type LegislatorEntry } from "./members.js";
import { ingestRollCalls } from "./rollcalls.js";
import { congressClient, ingestVotedBills } from "./bills.js";

const USAGE = `Usage:
  npm run ingest -w @floor/worker -- members
  npm run ingest -w @floor/worker -- rollcalls <house|senate> <congress> <session> [fromRoll]
  npm run ingest -w @floor/worker -- bills [limit]     (bills that stored votes refer to; needs CONGRESS_API_KEY)

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
  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 2 });
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
      const result = await ingestRollCalls(db, chamber as Chamber, Number(congress), Number(session), {
        from: from ? Number(from) : undefined,
        log: (msg) => console.log(msg),
      });
      console.log(`Stored ${result.stored} roll calls (last: ${result.lastRoll}); ${result.skippedPositions} positions for unknown members`);
    } else if (command === "bills") {
      if (!process.env.CONGRESS_API_KEY) throw new Error("Set CONGRESS_API_KEY in .env (free key: https://api.data.gov/signup)");
      const result = await ingestVotedBills(db, congressClient(process.env.CONGRESS_API_KEY), {
        limit: args[0] ? Number(args[0]) : undefined,
        log: (msg) => console.log(msg),
      });
      console.log(`Loaded ${result.bills} bills, linked ${result.linkedVotes} votes, ${result.failed} failed`);
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
