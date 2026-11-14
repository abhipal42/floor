/**
 * Alerts for the bills a phone follows (round 11, section E: "Bills you follow").
 *
 * A bill's steps are recorded once each in `bill_events` by whatever notices them:
 *
 *   chamber_passed / chamber_failed / to_president / law / vetoed
 *            `restage` (stage.ts), when a bill's stage moves forward: run by the catalog ingest and
 *            by the per-vote bill linking, so a passage roll call alerts within the hour.
 *   committee
 *            `recordCommitteeEvents`, from the catalog's detail fetch: a committee action (hearing,
 *            markup, ordered reported, reported) that was not in the bill's stored actions.
 *   floor_scheduled
 *            `recordScheduledEvents`, from the `floor_schedule` table (the chambers' weekly floor
 *            schedules, written by its own ingest). Guarded: with no such table it does nothing.
 *
 * Only recent steps are recorded (`EVENT_FRESH_DAYS`): a first staging, a backfill or a re-read of
 * an old bill is a correction, not news. The live worker's `BillEventPusher.run` then sends each
 * unsent event to the phones following its bill — or its topic, for phones with "Through topics
 * too" on — whose switch for that step is on, claims every send in `bill_push_log` first (at most
 * once, as push.ts), and stamps the event `pushed_at`. A chamber vote the phone was already told
 * about by the vote's own final alert ("A vote on H.R. 1013, which you follow.") is not sent again.
 * Past three bill alerts in a phone's day, each new one replaces a single "N updates on bills you
 * follow today" notification instead of stacking.
 *
 * Nothing personal is read or sent: an event is public data about a bill, and a phone is its
 * hashed-key row and its APNs token, as for the vote alerts.
 */
import { createHash } from "node:crypto";
import { easternWallClock, type Chamber } from "@floor/shared";
import { list, type Json } from "./bills.js";
import type { Db } from "./db.js";
import {
  BILL_LABEL,
  CHAMBER_NAME,
  DEAD_TOKEN_REASONS,
  DIGEST_AFTER,
  PUSH_CONCURRENCY,
  THREAD_ID,
  fitPayload,
  pool,
  truncate,
  type AlertCopy,
  type PushSender,
  type PushStats,
} from "./push.js";
import { EVENT_FRESH_DAYS, type BillEventKind } from "./stage.js";
import { withRetry } from "./rollcalls.js";

/** An event this old that was never sent (pushes were off, the worker was down) is dropped, not sent. */
export const EVENT_SEND_WINDOW_MS = 48 * 3_600_000;
/** Events sent per run; the rest wait for the next. */
export const EVENTS_PER_RUN = 100;

// MARK: - Recording

/** A committee action worth an alert: Congress.gov's `Committee` type, less the routine referrals. */
export function committeeActions(actionsJson: Json): { actedOn: string; text: string }[] {
  const seen = new Set<string>();
  const out: { actedOn: string; text: string }[] = [];
  for (const a of list(actionsJson["actions"])) {
    if (a["type"] !== "Committee") continue;
    const text = String(a["text"] ?? "").trim();
    const actedOn = String(a["actionDate"] ?? "");
    // "Referred to the Subcommittee on …" happens to nearly every bill the week it is introduced.
    if (!text || !/^\d{4}-\d{2}-\d{2}$/.test(actedOn) || /^referred to\b/i.test(text)) continue;
    const key = `${actedOn}|${text}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({ actedOn, text });
  }
  return out;
}

/** The bill's stored actions as `date|text` keys, and whether it was fetched before; read before an upsert. */
export async function storedActionKeys(db: Db, billId: string): Promise<{ fetched: boolean; keys: Set<string> }> {
  const { rows } = await db.query<{ fetched: boolean; keys: string[] | null }>(
    `select b.details_fetched_at is not null as fetched,
            (select array_agg(to_char(a.acted_on, 'YYYY-MM-DD') || '|' || a.text) from actions a where a.bill_id = b.id) as keys
       from bills b where b.id = $1`,
    [billId],
  );
  return { fetched: rows[0]?.fetched ?? false, keys: new Set(rows[0]?.keys ?? []) };
}

/**
 * Records one `committee` event for the bill when its fetched actions carry committee actions that
 * were not stored before (the latest of them; `count` says how many were new). Nothing for a bill
 * fetched for the first time (the backfill) or for actions older than `EVENT_FRESH_DAYS`.
 */
export async function recordCommitteeEvents(
  db: Db,
  billId: string,
  actionsJson: Json,
  before: { fetched: boolean; keys: Set<string> },
  now: Date,
): Promise<number> {
  if (!before.fetched) return 0;
  const since = now.getTime() - EVENT_FRESH_DAYS * 86_400_000;
  const fresh = committeeActions(actionsJson)
    .filter((a) => !before.keys.has(`${a.actedOn}|${a.text}`) && Date.parse(`${a.actedOn}T23:59:59Z`) >= since)
    .sort((a, b) => a.actedOn.localeCompare(b.actedOn));
  const latest = fresh.at(-1);
  if (!latest) return 0;
  const digest = createHash("sha256").update(latest.text).digest("hex").slice(0, 16);
  const { rows } = await withRetry(() =>
    db.query(
      `insert into bill_events (bill_id, kind, detail, dedupe_key, created_at) values ($1, 'committee', $2::jsonb, $3, $4)
       on conflict (dedupe_key) do nothing returning id`,
      [billId, JSON.stringify({ text: latest.text, actedOn: latest.actedOn, count: fresh.length }), `${billId}:committee:${latest.actedOn}:${digest}`, now.toISOString()],
    ),
  );
  return rows.length;
}

/**
 * Records a `floor_scheduled` event for each bill on a chamber's floor schedule for this week or a
 * later one, added in the last week (or with no add date: listed from the start of the week) and not
 * since removed. One per bill, chamber and week, so a
 * bill carried over to the next week alerts again, and one re-read every run never does.
 *
 * `floor_schedule` (chamber, week_of, category, legis_num, bill_id, title, added_at, removed_at,
 * source_updated_at; 20261117000000_floor_schedule.sql) belongs to the floor schedule ingest. On a
 * database without it this returns 0 and nothing else changes.
 */
export async function recordScheduledEvents(db: Db, now: Date): Promise<number> {
  const { rows: present } = await db.query<{ present: boolean }>(
    "select to_regclass('public.floor_schedule') is not null as present",
  );
  if (!present[0]?.present) return 0;
  const { rows } = await db.query(
    `insert into bill_events (bill_id, kind, chamber, detail, dedupe_key, created_at)
     select distinct on (s.bill_id, s.chamber::text, s.week_of::date)
            s.bill_id, 'floor_scheduled', s.chamber::text::chamber,
            jsonb_build_object('weekOf', to_char(s.week_of::date, 'YYYY-MM-DD'), 'category', s.category),
            s.bill_id || ':floor_scheduled:' || s.chamber::text || ':' || to_char(s.week_of::date, 'YYYY-MM-DD'),
            $1::timestamptz
       from floor_schedule s join bills b on b.id = s.bill_id
      where s.removed_at is null
        and s.week_of::date >= ($1::timestamptz at time zone 'America/New_York')::date - 6
        -- No add date: on the week's list from the start. The week bound above keeps it current.
        and (s.added_at is null or s.added_at >= $1::timestamptz - interval '7 days')
     on conflict (dedupe_key) do nothing
     returning id`,
    [now.toISOString()],
  );
  return rows.length;
}

// MARK: - Copy

export interface BillEvent {
  id: string;
  billId: string;
  kind: BillEventKind;
  chamber: Chamber | null;
  detail: { voteId?: string; yea?: number; nay?: number; weekOf?: string; text?: string; count?: number };
  /** `H.R. 5267`. */
  citation: string;
  /** The short title, else the title, cut to fit. */
  name: string;
  policyArea: string | null;
}

/** "Nov 16", from `2026-11-16`. */
const weekLabel = (date: string) =>
  new Date(`${date}T12:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });

/**
 * The alert for one step. Facts only, in the bill's own terms: what happened, in which chamber, by
 * what score. `viaTopic` (the phone follows its topic, not the bill) says so in the body.
 */
export function billEventAlert(e: BillEvent, viaTopic: string | null = null): AlertCopy {
  const chamber = e.chamber ? CHAMBER_NAME[e.chamber] : null;
  const score = e.detail.yea !== undefined && e.detail.nay !== undefined ? ` ${e.detail.yea}–${e.detail.nay}` : "";
  let title: string;
  let body = `${e.name.replace(/\.$/, "")}.`;
  switch (e.kind) {
    case "floor_scheduled":
      title = e.detail.weekOf
        ? `${e.citation} is up for a ${chamber ?? "floor"} vote the week of ${weekLabel(e.detail.weekOf)}.`
        : `${e.citation} is on the ${chamber ? `${chamber} ` : ""}floor schedule.`;
      break;
    case "chamber_passed":
      title = `${e.citation} passed the ${chamber ?? "chamber"}${score}.`;
      break;
    case "chamber_failed":
      title = `${e.citation} failed in the ${chamber ?? "chamber"}${score}.`;
      break;
    case "to_president":
      title = `${e.citation} was sent to the President.`;
      break;
    case "law":
      title = `${e.citation} became law.`;
      break;
    case "vetoed":
      title = `${e.citation} was vetoed.`;
      break;
    case "committee":
      title = `Committee action on ${e.citation}.`;
      if (e.detail.text) body = `${truncate(e.detail.text)} ${body}`;
      break;
  }
  if (viaTopic) body = `${body} In ${viaTopic}, a topic you follow.`;
  return { title, body };
}

/** Past `DIGEST_AFTER` bill alerts in a day: one notification, replaced as the day goes on. */
export function billDigestAlert(count: number, latest: BillEvent): AlertCopy {
  return { title: `${count} updates on bills you follow today.`, body: `Latest: ${billEventAlert(latest).title} Tap to catch up.` };
}

export function billAlertPayload(copy: AlertCopy, billId: string): Record<string, unknown> {
  const alert: Record<string, string> = { title: copy.title };
  if (copy.body) alert.body = copy.body;
  return { aps: { alert, sound: "default", "thread-id": THREAD_ID }, link: `floor://bill/${billId}` };
}

// MARK: - Sending

const SWITCH: Record<BillEventKind, string> = {
  floor_scheduled: "bill_scheduled",
  chamber_passed: "bill_chamber_vote",
  chamber_failed: "bill_chamber_vote",
  to_president: "bill_to_president",
  law: "bill_law",
  vetoed: "bill_law",
  committee: "bill_committee",
};

export class BillEventPusher {
  constructor(
    private readonly deps: {
      db: Db;
      apns: PushSender;
      environment: "sandbox" | "production";
      now?: () => Date;
      log?: (msg: string) => void;
      concurrency?: number;
    },
  ) {}

  get enabled(): boolean {
    return this.deps.apns.enabled;
  }

  /**
   * Records this week's floor schedule events, then sends every unsent event (oldest first, at most
   * `EVENTS_PER_RUN`). With APNs off it records and sends nothing. Never sends one event twice.
   */
  async run(): Promise<PushStats & { events: number }> {
    const { db } = this.deps;
    const now = (this.deps.now ?? (() => new Date()))();
    const stats = { sent: 0, failed: 0, unregistered: 0, events: 0 };
    if (!this.enabled) return stats;
    await recordScheduledEvents(db, now);
    // Too late to be news: never sent, and never will be.
    await db.query("update bill_events set pushed_at = $1 where pushed_at is null and created_at < $2", [
      now.toISOString(),
      new Date(now.getTime() - EVENT_SEND_WINDOW_MS).toISOString(),
    ]);
    const { rows } = await db.query<{
      id: string;
      bill_id: string;
      kind: BillEventKind;
      chamber: Chamber | null;
      detail: BillEvent["detail"];
      bill_type: string;
      number: number;
      short_title: string | null;
      title: string;
      policy_area: string | null;
    }>(
      `select e.id::text, e.bill_id, e.kind, e.chamber, e.detail, b.bill_type, b.number, b.short_title, b.title, b.policy_area
         from bill_events e join bills b on b.id = e.bill_id
        where e.pushed_at is null order by e.id limit $1`,
      [EVENTS_PER_RUN],
    );
    const day = easternWallClock(now).slice(0, 10);
    for (const r of rows) {
      const event: BillEvent = {
        id: r.id,
        billId: r.bill_id,
        kind: r.kind,
        chamber: r.chamber,
        detail: r.detail ?? {},
        citation: `${BILL_LABEL[r.bill_type] ?? r.bill_type.toUpperCase()} ${r.number}`,
        name: truncate(r.short_title ?? r.title),
        policyArea: r.policy_area,
      };
      const s = await this.send(event, day, now);
      stats.sent += s.sent;
      stats.failed += s.failed;
      stats.unregistered += s.unregistered;
      stats.events++;
    }
    return stats;
  }

  private async send(event: BillEvent, day: string, now: Date): Promise<PushStats> {
    const { db } = this.deps;
    const stats: PushStats = { sent: 0, failed: 0, unregistered: 0 };
    const column = SWITCH[event.kind];
    const { rows: targets } = await db.query<{ device: string; apns_token: string; direct: boolean }>(
      `select d.id::text as device, d.apns_token, bool_or(s.target_kind = 'bill') as direct
         from devices d join device_subscriptions s on s.device_id = d.id
        where d.apns_env = $1 and d.apns_token is not null and d.${column}
          and ((s.target_kind = 'bill' and s.target_id = $2)
               or (s.target_kind = 'topic' and d.bill_through_topics and s.target_id = $3))
          -- The vote's own final alert already told this phone the score.
          and not ($4::text is not null and exists (
                select 1 from push_log p where p.device_id = d.id and p.vote_id = $4 and p.kind = 'final'))
        group by d.id, d.apns_token
        order by d.id`,
      [this.deps.environment, event.billId, event.policyArea ?? "", event.detail.voteId ?? null],
    );
    const { rows: claimed } = targets.length
      ? await db.query<{ device_id: string }>(
          `insert into bill_push_log (device_id, event_id, day, sent_at)
           select x::uuid, $1::bigint, $2::date, $3::timestamptz from unnest($4::text[]) as x
           on conflict (device_id, event_id) do nothing returning device_id::text`,
          [event.id, day, now.toISOString(), targets.map((t) => t.device)],
        )
      : { rows: [] };
    // At most once: stamped before sending, as the vote alerts claim before they send.
    await db.query("update bill_events set pushed_at = $2 where id = $1::bigint", [event.id, now.toISOString()]);
    const mine = new Set(claimed.map((r) => r.device_id));
    const { rows: counts } = mine.size
      ? await db.query<{ device: string; n: number }>(
          `select device_id::text as device, count(*)::int as n from bill_push_log
            where device_id = any($1::uuid[]) and day = $2::date group by device_id`,
          [[...mine], day],
        )
      : { rows: [] };
    const today = new Map(counts.map((r) => [r.device, r.n]));
    const nowS = Math.floor(now.getTime() / 1000);
    const messages = targets
      .filter((t) => mine.has(t.device))
      .flatMap((t) => {
        const n = today.get(t.device) ?? 1;
        const busy = n > DIGEST_AFTER;
        const copy = busy ? billDigestAlert(n, event) : billEventAlert(event, t.direct ? null : event.policyArea);
        const payload = fitPayload(billAlertPayload(copy, event.billId));
        if (!payload) return [];
        return [
          {
            device: t.device,
            msg: {
              deviceToken: t.apns_token,
              pushType: "alert" as const,
              payload,
              collapseId: busy ? `bills-${day}` : `bill-${event.id}`,
              expiration: nowS + 86_400,
            },
          },
        ];
      });
    await pool(messages, this.deps.concurrency ?? PUSH_CONCURRENCY, async ({ device, msg }) => {
      const res = await this.deps.apns.send(msg).catch((err: unknown) => ({ ok: false, reason: String(err) }) as Awaited<ReturnType<PushSender["send"]>>);
      if (res.ok) stats.sent++;
      else if (res.unregistered || (res.reason && DEAD_TOKEN_REASONS.has(res.reason))) {
        stats.unregistered++;
        await db.query("update devices set apns_token = null where id = $1::uuid", [device]);
      } else {
        stats.failed++;
        if (res.reason && !res.skipped) this.deps.log?.(`bill push ${event.billId}: APNs refused (${res.status ?? "?"} ${res.reason})`);
      }
    });
    return stats;
  }
}
