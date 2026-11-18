import pg from "pg";
import type { Chamber } from "@floor/shared";
import { type Db } from "./db.js";
import { ingestMembers } from "./members.js";
import { defaultFetch, fetchWithTimeout, ingestSessions, sessionsToPoll } from "./rollcalls.js";
import { ingestPosts, ingestSocial } from "./social.js";
import { parsePromisesArgs, runPromises } from "./promises.js";
import { ingestSchedule } from "./schedule.js";
import { congressClient, ingestVotedBills } from "./bills.js";
import { DEFAULT_KEY_RESERVE, DEFAULT_RATE_PER_HOUR, ingestCatalog } from "./catalog.js";
import { ingestVotedNominations } from "./nominations.js";
import { fecClient, ingestFecElect, ingestFecTotals, ingestPacContributions } from "./fec.js";
import Anthropic from "@anthropic-ai/sdk";
import { analyzeOptions, anthropicComplete, runAnalyses } from "./analysis.js";
import { LiveWorker, parseLatencyDays, postingLatency, revalidatingFetch, runLive, summarize } from "./live.js";
import { supabaseBroadcaster } from "./realtime.js";
import { StatusAlerter } from "./alert.js";
import { ApnsSender, apnsConfigFromEnv } from "./apns.js";
import { PushBroadcaster, composeBroadcasters, pruneDevices } from "./push.js";
import { disclosureSource, ingestDisclosures, parseDisclosureArgs } from "./disclosures.js";
import { loadTranscription, readTranscriptions } from "./transcriptions.js";
import { BillEventPusher } from "./billevents.js";
import { ingestElectDisclosures, ingestHouseMembersElect, loadElections, readElections } from "./elect.js";
import { ingestNews, parseNewsArgs } from "./news.js";
import { loadPolls, readPolls } from "./polls.js";
import { ingestLocal, openStatesGet, parseLocalArgs } from "./local.js";

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
  npm run ingest -w @floor/worker -- schedule                     (the week ahead: the House's weekly list for this week and next, the
                                         Senate's next convening, and with CONGRESS_API_KEY its Daily Digest program)
  npm run ingest -w @floor/worker -- transcriptions
                                         (load apps/worker/transcriptions/*.json into the paper filings they transcribe)
  npm run ingest -w @floor/worker -- disclosures <house|senate> [--year N] [--budget N]
                                         (financial disclosures: annual reports' assets and PTR trades; default the last
                                          three years' indexes and 150 requests, one every 1.5 s; documents cached under
                                          apps/worker/.cache/. Served only when the API has DISCLOSURES_ENABLED=true)
  npm run ingest -w @floor/worker -- elections                    (load apps/worker/elections/*.json: Senate races as the AP called them,
                                          into members_elect and seats_pending)
  npm run ingest -w @floor/worker -- members-elect-house [congress]
                                         (the House Clerk's unofficial member-elect list; default the 120th; nothing
                                          until the Clerk publishes it in late December)
  npm run ingest -w @floor/worker -- fec-elect                    (OpenFEC totals for members-elect with an FEC ID; needs CONGRESS_API_KEY)
  npm run ingest -w @floor/worker -- elect-disclosures [--budget N]
                                         (House members-elect's candidate reports from the Clerk's index; default 50 requests)
  npm run ingest -w @floor/worker -- social                       (official accounts from congress-legislators, plus a Bluesky account only
                                          when Bluesky verified it or it is a .senate.gov/.house.gov handle)
  npm run ingest -w @floor/worker -- posts                        (recent posts from YouTube, Bluesky and Mastodon; free, no keys)
  npm run ingest -w @floor/worker -- promises [--budget N] [--recheck] [--member ID]
                                         (campaign promises from the FEC committee's site as the Wayback Machine held
                                          it before election day; default 25 members not yet checked; needs
                                          CONGRESS_API_KEY and ANTHROPIC_API_KEY)
  npm run ingest -w @floor/worker -- news [--budget N] [--member ID]
                                         (members' headlines from Google News RSS, the 100 checked longest ago, each at
                                          most every 12 h, 1.2 s apart; with ANTHROPIC_API_KEY, tone and stories)
  npm run ingest -w @floor/worker -- polls                        (load apps/worker/polls/*.json: polls naming members, reviewed in PRs)
  npm run ingest -w @floor/worker -- local [--only ID] [--no-news]
                                         (state bills from Open States with OPENSTATES_API_KEY, city council matters
                                          from Legistar (NYC needs NYC_LEGISTAR_TOKEN), and each jurisdiction's headlines)
  npm run ingest -w @floor/worker -- live                     (always-on: floor events, vote state, roll calls; until SIGTERM)
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
    } else if (command === "schedule") {
      const key = process.env.CONGRESS_API_KEY;
      const result = await ingestSchedule(db, defaultFetch, {
        // congressClient keeps its URL (which carries the key) out of errors and logs (lesson 7).
        congress: key ? congressClient(key) : undefined,
        log: (msg) => console.log(msg),
      });
      console.log(
        `Schedule: ${result.weeks} House weeks, ${result.items} items stored, ${result.removed} newly removed; ` +
          `Senate next meets ${result.senateMeeting ?? "(none published)"}, program ${result.senateProgram ?? (key ? "(none in the latest Record)" : "(skipped: no CONGRESS_API_KEY)")}`,
      );
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
    } else if (command === "transcriptions") {
      const dir = new URL("../transcriptions/", import.meta.url).pathname;
      for (const t of readTranscriptions(dir)) {
        console.log(`${t.filingId}: ${await loadTranscription(db, t)} (${t.assets.length} assets)`);
      }
    } else if (command === "elections") {
      const dir = new URL("../elections/", import.meta.url).pathname;
      for (const e of readElections(dir)) {
        const r = await loadElections(db, e, (msg) => console.log(msg));
        console.log(`${e.cycle} senate: ${r.elect} members-elect, ${r.pending} seats pending, ${r.unmatched.length} incumbents unmatched`);
      }
    } else if (command === "members-elect-house") {
      const congress = Number(args[0] ?? 120);
      if (!Number.isInteger(congress) || congress <= 0) throw new Error("members-elect-house takes a Congress number, e.g. 120");
      const r = await ingestHouseMembersElect(db, congress, { log: (msg) => console.log(msg) });
      if (r.published) console.log(`${congress}th Congress: ${r.listed} listed, ${r.reElected} re-elected to their seat, ${r.elect} members-elect`);
    } else if (command === "fec-elect") {
      if (!process.env.CONGRESS_API_KEY) throw new Error("Set CONGRESS_API_KEY in .env (the api.data.gov key works for OpenFEC)");
      const r = await ingestFecElect(db, fecClient(process.env.CONGRESS_API_KEY), { log: (msg) => console.log(msg) });
      console.log(`Loaded totals for ${r.loaded} members-elect; ${r.noTotals} had none filed, ${r.failed} failed`);
    } else if (command === "elect-disclosures") {
      const i = args.indexOf("--budget");
      const budget = i < 0 ? 50 : Number(args[i + 1]);
      if (!Number.isInteger(budget) || budget <= 0) throw new Error("--budget needs a positive whole number");
      const year = new Date().getUTCFullYear();
      const r = await ingestElectDisclosures(db, {
        years: [year, year - 1],
        budget,
        log: (msg) => console.log(`${new Date().toISOString()} ${msg}`),
      });
      console.log(
        `${r.elects} House members-elect: ${r.matched} with a candidate report, ${r.parsed} parsed, ${r.paper} paper, ` +
          `${r.failed} failed; ${r.requests} requests`,
      );
    } else if (command === "disclosures") {
      const opts = parseDisclosureArgs(args, new Date());
      const result = await ingestDisclosures(db, await disclosureSource(opts), {
        log: (msg) => console.log(`${new Date().toISOString()} ${msg}`),
      });
      if (result.unmatched.length) console.log(`Unmatched filers (stored with no member): ${result.unmatched.join("; ")}`);
      console.log(
        `${opts.chamber}: listed ${result.listed} filings (${result.matched} matched to a member); parsed ${result.parsed} ` +
          `(${result.assets} assets, ${result.trades} trades), ${result.paper} paper, ${result.failed} failed, ` +
          `${result.stillDue} still due; ${result.requests} requests`,
      );
    } else if (command === "social") {
      const r = await ingestSocial(db, fetchWithTimeout(fetch, 30_000), { log: (msg) => console.log(msg) });
      console.log(`Social accounts for ${r.members} members, ${r.bluesky} with a Bluesky account; ${r.failed} Bluesky searches failed`);
    } else if (command === "posts") {
      const r = await ingestPosts(db, fetchWithTimeout(fetch, 30_000), { log: (msg) => console.log(msg) });
      console.log(`${r.posts} posts from ${r.members} members; ${r.failed} feeds failed`);
    } else if (command === "promises") {
      const opts = parsePromisesArgs(args);
      if (!process.env.CONGRESS_API_KEY) throw new Error("Set CONGRESS_API_KEY in .env (the api.data.gov key works for OpenFEC)");
      const ai = analyzeOptions(process.env, undefined);
      // Credentials come from the SDK's usual chain (ANTHROPIC_API_KEY first). Never log them.
      const complete = anthropicComplete(new Anthropic(), ai.model, ai);
      // One connection for the whole run: the run's advisory lock is held on it.
      const conn = await pool.connect();
      try {
        const r = await runPromises(
          conn as unknown as Db,
          // fecClient never puts its URL, which carries the key, in an error (lesson 7).
          { fec: fecClient(process.env.CONGRESS_API_KEY), fetchText: fetchWithTimeout(fetch, 60_000), complete, log: (msg) => console.log(msg) },
          opts,
        );
        if (r.ran) {
          const s = r.byStatus;
          console.log(
            `Checked ${r.checked} members: ${s.promises} with promises, ${s.no_platform} no platform, ${s.no_site} no site, ` +
              `${s.no_snapshot} no snapshot, ${s.failed} failed; est. ${r.costUsd === null ? "unknown" : `$${r.costUsd.toFixed(2)}`}`,
          );
        }
      } finally {
        conn.release();
      }
    } else if (command === "news") {
      const opts = parseNewsArgs(args);
      const ai = analyzeOptions(process.env, undefined);
      // Credentials come from the SDK's usual chain (ANTHROPIC_API_KEY first). Never log them.
      const complete = process.env.ANTHROPIC_API_KEY ? anthropicComplete(new Anthropic(), ai.model, ai) : undefined;
      // One connection for the whole run: the run's advisory lock is held on it.
      const conn = await pool.connect();
      try {
        const r = await ingestNews(conn as unknown as Db, fetchWithTimeout(fetch, 30_000), {
          complete,
          budget: opts.budget,
          members: opts.members,
          log: (msg) => console.log(`${new Date().toISOString()} ${msg}`),
        });
        if (r.ran) {
          console.log(
            `Checked ${r.checked} members: ${r.headlines} headlines, ${r.failed} failed${r.stoppedBy === "rate-limited" ? " (stopped: rate-limited)" : ""}; ` +
              `read ${r.read} for tone, ${r.stories} stories; est. ${r.costUsd === null ? "unknown" : `$${r.costUsd.toFixed(2)}`}`,
          );
        }
      } finally {
        conn.release();
      }
    } else if (command === "polls") {
      const dir = new URL("../polls/", import.meta.url).pathname;
      const r = await loadPolls(db, readPolls(dir));
      console.log(`Loaded ${r.polls} polls${r.unknownMembers.length ? `; unknown member ids skipped: ${r.unknownMembers.join(", ")}` : ""}`);
    } else if (command === "local") {
      const opts = parseLocalArgs(args);
      const key = process.env.OPENSTATES_API_KEY;
      const r = await ingestLocal(
        db,
        {
          // The key goes in a header (openStatesGet), so Open States URLs are safe to log.
          openStates: key ? openStatesGet(key) : undefined,
          fetchText: fetchWithTimeout(fetch, 60_000),
          // Legistar's NYC token is a query parameter: local.ts never logs a URL carrying it.
          tokens: { NYC_LEGISTAR_TOKEN: process.env.NYC_LEGISTAR_TOKEN || undefined },
          log: (msg) => console.log(`${new Date().toISOString()} ${msg}`),
        },
        { only: opts.only, news: opts.news },
      );
      console.log(
        `Local: ${r.states} states (${r.enacted} enacted, ${r.waiting} waiting), ${r.cities} cities (${r.passed} new passed), ` +
          `${r.headlines} headlines, ${r.failed} failed; skipped: ${r.skipped.join(", ") || "none"}; ` +
          `requests: Open States ${r.requests.openstates}, Legistar ${r.requests.legistar}, Google News ${r.requests.news}`,
      );
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
  const realtime = supabaseBroadcaster(process.env);
  // Alerts and Live Activities (push.ts). Without every APNS_* variable this sends nothing.
  const apnsConfig = apnsConfigFromEnv(process.env);
  const apns = new ApnsSender(apnsConfig);
  const push = new PushBroadcaster({ db, apns, environment: apnsConfig?.production ? "production" : "sandbox", log });
  // Bill alerts (billevents.ts): the steps the catalog and bill linking recorded, sent from here
  // because this is the process that holds the APNs session.
  const billPush = new BillEventPusher({ db, apns, environment: apnsConfig?.production ? "production" : "sandbox", log });
  // Realtime first, pushes queued after it in a finally: APNs never delays the loop, and a failed
  // Realtime broadcast (retried next poll) cannot skip the pushes (their dedupe makes the retry safe).
  const broadcaster = composeBroadcasters(realtime, push);
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
    maintenance: push.enabled ? async (now) => log(`pruned push tables: ${JSON.stringify(await pruneDevices(db, now))}`) : undefined,
    billAlerts: billPush.enabled
      ? async () => {
          const s = await billPush.run();
          if (s.events) log(`bill alerts: ${s.events} events, ${s.sent} sent, ${s.failed} failed, ${s.unregistered} tokens gone`);
        }
      : undefined,
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
    `live worker starting: realtime ${realtime.enabled ? "on" : "off (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY unset)"}, ` +
      `pushes ${push.enabled ? `on (${apnsConfig?.production ? "production" : "sandbox"})` : "off (APNS_KEY_ID / APNS_TEAM_ID / APNS_PRIVATE_KEY / APNS_TOPIC unset)"}, ` +
      `alerts ${alerter.enabled ? "on" : "off (ALERT_WEBHOOK_URL unset)"}, ` +
      `bill linking ${key ? "on" : "off (CONGRESS_API_KEY unset)"}`,
  );
  const ticks = await runLive(worker, stop.signal, { log });
  // Send what is queued, then close the APNs HTTP/2 session, which would keep the process alive.
  await push.idle();
  apns.close();
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
