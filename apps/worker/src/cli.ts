import pg from "pg";
import type { Chamber } from "@floor/shared";
import { type Db } from "./db.js";
import { ingestMembers } from "./members.js";
import { ingestSessions, sessionsToPoll } from "./rollcalls.js";
import { congressClient, ingestVotedBills } from "./bills.js";
import { DEFAULT_KEY_RESERVE, DEFAULT_RATE_PER_HOUR, ingestCatalog } from "./catalog.js";
import { ingestVotedNominations } from "./nominations.js";
import { fecClient, ingestFecTotals, ingestPacContributions } from "./fec.js";
import Anthropic from "@anthropic-ai/sdk";
import { analyzeOptions, anthropicComplete, runAnalyses } from "./analysis.js";
import { LiveWorker, parseLatencyDays, postingLatency, revalidatingFetch, runLive, summarize } from "./live.js";
import { supabaseBroadcaster } from "./realtime.js";
import { StatusAlerter } from "./alert.js";

const USAGE = `Usage:
  npm run ingest -w @floor/worker -- members
  npm run ingest -w @floor/worker -- rollcalls <house|senate> <congress> <session> [fromRoll]
  npm run ingest -w @floor/worker -- rollcalls <house|senate> current   (the session in progress; what the schedule runs)
  npm run ingest -w @floor/worker -- bills [limit]              (bills that stored votes refer to; needs CONGRESS_API_KEY)
  npm run ingest -w @floor/worker -- bills --refresh [limit]    (re-fetch bills already stored, to pick up changes or mapping fixes)
  npm run ingest -w @floor/worker -- bill-catalog [--full] [--budget N] [--rate N] [--reserve N] [--congress N]
                                         (every bill of the Congress: list, details, stage; default budget 1200 requests at
                                          4500/h, stopping when the key has fewer than 500 left this hour; incremental
                                          from the last listing; needs CONGRESS_API_KEY)
  npm run ingest -w @floor/worker -- nominations [limit]         (nominations that stored Senate votes refer to; needs CONGRESS_API_KEY)
  npm run ingest -w @floor/worker -- nominations --refresh [limit]
  npm run ingest -w @floor/worker -- fec-totals [limit]           (campaign totals per current member from OpenFEC; needs CONGRESS_API_KEY)
  npm run ingest -w @floor/worker -- fec-pacs [cycle]             (committee-to-candidate totals from the FEC bulk files; default 2026)
  npm run ingest -w @floor/worker -- analyze [limit]              (AI analysis of bills whose CRS summary has none or changed; default 25; needs ANTHROPIC_API_KEY)
  npm run ingest -w @floor/worker -- live                         (always-on: floor events, vote state, roll calls; until SIGTERM)
  npm run ingest -w @floor/worker -- latency [days]               (posting latency the live worker measured; default 30 days)

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
  // An idle connection the pooler drops emits "error" on the pool; with no listener Node turns that
  // into an uncaught exception and the always-on worker dies. Log it: the pool opens a new connection
  // on the next query.
  pool.on("error", (err) => console.error(`${new Date().toISOString()} database connection error: ${describe(err)}`));
  const db = pool as unknown as Db;
  try {
    if (command === "live") {
      await live(db);
    } else if (command === "latency") {
      const rows = await postingLatency(db, parseLatencyDays(args[0]));
      for (const r of rows) {
        console.log(
          `${r.id}  posted ${r.postedAt}  from floor time ${r.fromOpenSeconds ?? "-"} s  from first sighting ${r.fromAnnouncedSeconds ?? "-"} s`,
        );
      }
      for (const chamber of ["house", "senate"] as const) {
        const mine = rows.filter((r) => r.chamber === chamber);
        const open = summarize(mine.map((r) => r.fromOpenSeconds));
        const seen = summarize(mine.map((r) => r.fromAnnouncedSeconds));
        console.log(
          `${chamber}: ${mine.length} votes measured; floor time -> XML median ${open.median ?? "-"} s, p90 ${open.p90 ?? "-"} s; ` +
            `first sighting -> XML median ${seen.median ?? "-"} s, p90 ${seen.p90 ?? "-"} s`,
        );
      }
    } else if (command === "members") {
      const count = await ingestMembers(db, getJson);
      console.log(`Upserted ${count} members`);
    } else if (command === "rollcalls") {
      const [chamber, congress, session, from] = args;
      if (chamber !== "house" && chamber !== "senate") throw new Error(USAGE);
      // `current` is what the schedule runs: the session in progress, plus the one just ended early in January.
      const sessions =
        congress === "current" ? sessionsToPoll(new Date()) : [{ congress: Number(congress), session: Number(session) }];
      await ingestSessions(db, chamber as Chamber, sessions, {
        from: congress !== "current" && from ? Number(from) : undefined,
        log: (msg) => console.log(msg),
      });
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
    } else if (command === "bill-catalog") {
      if (!process.env.CONGRESS_API_KEY) throw new Error("Set CONGRESS_API_KEY in .env (free key: https://api.data.gov/signup)");
      const flag = (name: string) => {
        const i = args.indexOf(name);
        if (i < 0) return undefined;
        const value = Number(args[i + 1]);
        if (!Number.isInteger(value) || value <= 0) throw new Error(`${name} needs a positive whole number`);
        return value;
      };
      const congress = flag("--congress") ?? sessionsToPoll(new Date())[0]!.congress;
      const key = process.env.CONGRESS_API_KEY;
      const result = await ingestCatalog(db, (budget) => congressClient(key, fetch, budget), {
        congress,
        full: args.includes("--full"),
        budget: flag("--budget") ?? 1200,
        ratePerHour: flag("--rate") ?? DEFAULT_RATE_PER_HOUR,
        keyReserve: flag("--reserve") ?? DEFAULT_KEY_RESERVE,
        log: (msg) => console.log(`${new Date().toISOString()} ${msg}`),
      });
      console.log(
        `Congress ${congress}: listed ${result.listed} (${result.reserved} reserved, ${result.undated} undated skipped), details for ${result.fetched}, ` +
          `${result.failed} failed, ${result.stillDue} still due, staged ${result.staged}; ` +
          `${result.requests} requests; stopped: ${result.stoppedBy}`,
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
    } else if (command === "analyze") {
      // Checked before anything is spent: a typo in the effort or the limit fails here, not mid-run.
      const options = analyzeOptions(process.env, args[0]);
      // Credentials come from the SDK's usual chain (ANTHROPIC_API_KEY first). Never log them.
      const client = new Anthropic();
      // One connection for the whole run: the run's advisory lock is held on it.
      const conn = await pool.connect();
      try {
        const result = await runAnalyses(conn as unknown as Db, anthropicComplete(client, options.model, options), {
          verifyWith: anthropicComplete(client, options.verifierModel, options),
          limit: options.limit,
          log: (msg) => console.log(msg),
        });
        if (result.ran) {
          console.log(
            `Analysed ${result.analysed} bills, ${result.failed} failed; ` +
              `est. ${result.costUsd === null ? "unknown (a model with no known price ran)" : `$${result.costUsd.toFixed(2)}`}`,
          );
        }
      } finally {
        conn.release();
      }
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

/** The always-on loop. Stops cleanly on SIGTERM (what Fly and Railway send) or SIGINT. */
async function live(db: Db) {
  const log = (msg: string) => console.log(`${new Date().toISOString()} ${msg}`);
  const broadcaster = supabaseBroadcaster(process.env);
  const alerter = new StatusAlerter({
    webhookUrl: process.env.ALERT_WEBHOOK_URL || undefined,
    statusUrl: process.env.FLOOR_STATUS_URL || undefined,
    log,
  });
  const key = process.env.CONGRESS_API_KEY;
  const worker = new LiveWorker({
    db,
    fetchFloor: revalidatingFetch(),
    broadcaster,
    alerter,
    log,
    // congressClient keeps its URL (which carries the key) out of errors and logs (lesson 7).
    linkMeasures: key
      ? async () => {
          const client = congressClient(key);
          const bills = await ingestVotedBills(db, client, { log });
          const noms = await ingestVotedNominations(db, client, { log });
          log(`linked ${bills.linkedVotes} votes to bills and ${noms.linkedVotes} to nominations`);
        }
      : undefined,
  });
  // By Node's default a rejected promise nobody awaited kills the process. Every step of a poll is
  // already caught, so one that slips through is a bug to log, not a reason to stop polling.
  process.on("unhandledRejection", (reason) => log(`unhandled rejection (still running): ${describe(reason)}`));
  const stop = new AbortController();
  for (const signal of ["SIGTERM", "SIGINT"] as const) {
    process.once(signal, () => {
      log(`${signal}: finishing the current poll, then stopping`);
      stop.abort();
    });
  }
  log(
    `live worker starting: realtime ${broadcaster.enabled ? "on" : "off (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY unset)"}, ` +
      `alerts ${alerter.enabled ? "on" : "off (ALERT_WEBHOOK_URL unset)"}, ` +
      `bill linking ${key ? "on" : "off (CONGRESS_API_KEY unset)"}`,
  );
  const ticks = await runLive(worker, stop.signal, { log });
  log(`stopped after ${ticks} polls`);
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
