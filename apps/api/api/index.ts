/**
 * The serverless entry point.
 *
 * Vercel builds every file under `api/` into a function; `vercel.json` rewrites all paths here, so
 * Hono does the routing exactly as it does locally. `src/server.ts` remains the way to run it on a
 * machine you can see.
 */
// `@hono/node-server/vercel`, not `hono/vercel`: the latter returns a fetch-style handler, and on
// Vercel's Node runtime the function is called as (req, res). Nothing ever writes to `res`, so the
// request hangs until the function times out — which is exactly what the first deploy did.
import { handle } from "@hono/node-server/vercel";
import pg from "pg";
import { createApp } from "../src/app.js";
import { locateDistrict } from "../src/district.js";
import { pgRepositories, type Db } from "../src/pg.js";

export const config = { runtime: "nodejs" };

const CONGRESS = Number(process.env.CONGRESS ?? 119);

/**
 * One pool per warm instance, not per request.
 *
 * `max: 1` because a serverless instance handles one request at a time, so a larger pool only
 * holds connections open that Postgres could give to another instance. Point `DATABASE_URL` at
 * Supabase's pooler rather than the direct port: a function that scales out will otherwise exhaust
 * the database's connection limit.
 */
const pool = process.env.DATABASE_URL
  ? new pg.Pool({
      connectionString: process.env.DATABASE_URL,
      max: 1,
      idleTimeoutMillis: 10_000,
      connectionTimeoutMillis: 10_000,
    })
  : null;

/** Browser origins allowed to read a response, comma-separated. Unset means none. */
const allowedOrigins = (process.env.ALLOWED_ORIGINS ?? "")
  .split(",")
  .map((o) => o.trim())
  .filter(Boolean);

const repositories = pool
  ? pgRepositories(pool as unknown as Db)
  : {
      // Answering empty beats crashing on every request: /health still reports, and the misconfigured
      // deployment is visible in /v1/status rather than as a 500 with no explanation.
      votes: {
        getVote: async () => null,
        voteBreakdown: async () => ({ partyTotals: [], candidateTotals: [], positions: [], measure: null }),
      },
      members: {
        membersFor: async () => [],
        recentVotes: async () => [],
        getMember: async () => null,
        partyLoyalty: async () => ({ votes: 0, withParty: 0, againstParty: 0 }),
      },
      bills: { getBill: async () => null },
      nominations: { getNomination: async () => null },
      status: { lastRuns: async () => [] },
    };

if (!pool) console.warn("DATABASE_URL is not set: serving empty data");

const app = createApp({
  ...repositories,
  allowedOrigins,
  locate: (place) => locateDistrict(place, CONGRESS),
});

export default handle(app);
