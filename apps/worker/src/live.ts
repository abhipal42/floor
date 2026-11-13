/**
 * The always-on worker (M3 live layer): polls the floor and the roll call files, moves votes from
 * `open` to `final`, publishes each change, and records how long the chambers take to post.
 *
 *   npm run ingest -w @floor/worker -- live      (runs until SIGTERM/SIGINT)
 *   npm run ingest -w @floor/worker -- latency 30
 *
 * Each chamber has its own cadence: every 10 s while it sits, every 5 minutes otherwise, so
 * senate.gov is not polled every 10 s just because the House is in. A host that answers 403 or 429
 * is left alone for 30 s, doubling to 5 minutes while it keeps refusing. Every step is wrapped so one
 * upstream failing (senate.gov is down, the Clerk serves HTML) never stops the loop.
 */
import {
  congressSessionOn,
  easternToDate,
  easternWallClock,
  parseHouseFloor,
  parseSenateFloorActivity,
  parseSenateSchedule,
  parseSenateVoteMenu,
  type Chamber,
  type HouseFloorDay,
  type SenateMeeting,
  type SenateSchedule,
  type SenateVoteMenu,
} from "@floor/shared";
import { lastRollNumber, voteId, type Db } from "./db.js";
import { defaultFetch, ingestRollCalls, type FetchText } from "./rollcalls.js";
import type { Broadcaster, VoteStateChange } from "./realtime.js";
import type { StatusAlerter } from "./alert.js";

export const POLL_IN_SESSION_MS = 10_000;
export const POLL_IDLE_MS = 5 * 60_000;
/** Treat a chamber as sitting from this long before its scheduled convening. */
export const PRE_CONVENE_MS = 15 * 60_000;
/** A posted_at is only a measurement, and a vote only news, if the chamber's poll before was this recent. */
export const LIVE_GAP_MS = 60_000;
/** How long a cached Senate schedule or floor page stands in for one senate.gov failed to serve. */
export const SENATE_STALE_MS = 30 * 60_000;
/** Votes saved without positions are re-fetched this often, not every poll. */
export const REPAIR_EVERY_MS = 3_600_000;
/** How often to look for votes stuck `open`, and how old one has to be to count. */
export const SWEEP_EVERY_MS = 3_600_000;
export const STUCK_OPEN_MS = 6 * 3_600_000;
/** When no recent House floor file exists, look back a week at most this often. */
export const LOOKBACK_EVERY_MS = 3_600_000;
/** Backoff for a host that refuses us (403/429): 30 s, doubling to 5 minutes. */
export const BACKOFF_START_MS = 30_000;
export const BACKOFF_MAX_MS = 5 * 60_000;
/** A final vote older than this is history: marked broadcast without being published. */
export const NEWS_WINDOW_MS = 86_400_000;
/** A chamber is due again this much before its interval is up, so a 10 s loop never skips a beat. */
const DUE_SLACK_MS = 1_000;

export const houseFloorUrl = (day: string) => `https://clerk.house.gov/floor/${day.replaceAll("-", "")}.xml`;
export const SENATE_SCHEDULE_URL = "https://www.senate.gov/legislative/schedule/floor_schedule.json";
export const SENATE_FLOOR_URL = "https://www.senate.gov/legislative/floor_activity_pail.htm";
export const senateVoteMenuUrl = (congress: number, session: number) =>
  `https://www.senate.gov/legislative/LIS/roll_call_lists/vote_menu_${congress}_${session}.xml`;

export interface ChamberSession {
  chamber: Chamber;
  inSession: boolean;
  convenesAt: Date | null;
  legislativeDay: string | null;
  source: string;
}

/**
 * Is the House sitting? An unfinished legislative day means yes (a recess included: it comes back).
 * A finished one names the next convening; from 15 minutes before it we poll fast, for up to two
 * hours, while waiting for the new day's file to appear.
 */
export function houseSession(day: HouseFloorDay | null, now: Date): ChamberSession {
  const base = { chamber: "house" as const, source: "house_floor" };
  if (!day) return { ...base, inSession: false, convenesAt: null, legislativeDay: null };
  if (!day.finished) {
    // A day the Clerk never closed shouldn't hold the worker at 10 s forever.
    const ageMs = now.getTime() - easternToDate(day.legislativeDay).getTime();
    return { ...base, inSession: ageMs < 2 * 86_400_000, convenesAt: null, legislativeDay: day.legislativeDay };
  }
  const next = day.nextConvenesEastern ? easternToDate(day.nextConvenesEastern) : null;
  const t = now.getTime();
  const inSession = next !== null && t >= next.getTime() - PRE_CONVENE_MS && t < next.getTime() + 2 * 3_600_000;
  return { ...base, inSession, convenesAt: next, legislativeDay: day.legislativeDay };
}

/**
 * Is the Senate sitting? senate.gov's schedule names the convening and keeps it until after the
 * Senate adjourns (the 2026-11-12 file was rewritten two minutes after a 4:52 p.m. adjournment), and
 * the floor activity page says when a meeting adjourned. Sitting = past the convening time, that
 * meeting not yet adjourned, and less than 16 hours in (a stale schedule must not pin us at 10 s).
 */
export function senateSession(schedule: SenateSchedule | null, meetings: SenateMeeting[], now: Date): ChamberSession {
  const base = { chamber: "senate" as const, source: "senate_schedule" };
  if (!schedule) return { ...base, inSession: false, convenesAt: null, legislativeDay: null };
  const convenes = easternToDate(schedule.convenesEastern);
  const date = schedule.convenesEastern.slice(0, 10);
  const adjourned = meetings.some((m) => m.date === date && m.adjournedAt !== null);
  const t = now.getTime();
  const lead = Math.max(schedule.offsetMinutes * 60_000, PRE_CONVENE_MS);
  const inSession = !adjourned && t >= convenes.getTime() - lead && t < convenes.getTime() + 16 * 3_600_000;
  return { ...base, inSession, convenesAt: convenes, legislativeDay: date };
}

export async function saveChamberStatus(db: Db, s: ChamberSession, now: Date): Promise<void> {
  await db.query(
    `insert into chamber_status (chamber, in_session, convenes_at, legislative_day, source, checked_at)
     values ($1, $2, $3, $4, $5, $6)
     on conflict (chamber) do update set in_session = excluded.in_session, convenes_at = excluded.convenes_at,
       legislative_day = excluded.legislative_day, source = excluded.source, checked_at = excluded.checked_at`,
    [s.chamber, s.inSession, s.convenesAt?.toISOString() ?? null, s.legislativeDay, s.source, now.toISOString()],
  );
}

interface ChangeRow {
  id: string;
  chamber: Chamber;
  congress: number;
  session: number;
  roll_number: number | null;
  state: "open" | "final";
  question: string;
  result: string | null;
  opened_at: Date | null;
  announced_at: Date | null;
  posted_at: Date | null;
}

const iso = (d: Date | null) => (d ? new Date(d).toISOString() : null);

const toChange = (r: ChangeRow): VoteStateChange => ({
  id: r.id,
  chamber: r.chamber,
  congress: r.congress,
  session: r.session,
  rollNumber: r.roll_number,
  state: r.state,
  question: r.question,
  result: r.result,
  openedAt: iso(r.opened_at),
  announcedAt: iso(r.announced_at),
  postedAt: iso(r.posted_at),
});

const CHANGE_COLUMNS = "id, chamber, congress, session, roll_number, state, question, result, opened_at, announced_at, posted_at";

interface OpenVoteInput {
  id: string;
  chamber: Chamber;
  congress: number;
  session: number;
  roll_number: number;
  question: string;
  result: string | null;
  yea: number;
  nay: number;
  opened_at: string | null;
  bill_ref: string | null;
  /** False for a vote found after the fact (downtime, a first run): stored, but not announced. */
  news: boolean;
}

/**
 * Stores votes a floor source has named. A vote not yet in the table goes in as `open`; one already
 * there only gains the floor's time and the first-seen time, so a final vote is never reopened and an
 * earlier sighting is never overwritten. Returns the votes that just became open and are news; a vote
 * that is not news goes in without `announced_at` (it would measure our downtime) and is not returned.
 */
async function upsertOpenVotes(db: Db, votes: OpenVoteInput[], now: Date): Promise<VoteStateChange[]> {
  if (votes.length === 0) return [];
  const { rows } = await db.query<ChangeRow & { inserted: boolean }>(
    `insert into votes (id, chamber, congress, session, roll_number, question, state, yea, nay, result,
                        opened_at, occurred_at, announced_at, bill_ref)
     select id, chamber, congress, session, roll_number, question, 'open', yea, nay, result,
            opened_at, opened_at, case when news then $2::timestamptz end, bill_ref
       from jsonb_to_recordset($1::jsonb) as x(id text, chamber chamber, congress smallint, session smallint,
            roll_number integer, question text, yea integer, nay integer, result text, opened_at timestamptz,
            bill_ref text, news boolean)
     on conflict (id) do update set
       opened_at = coalesce(votes.opened_at, excluded.opened_at),
       announced_at = coalesce(votes.announced_at, excluded.announced_at)
     returning ${CHANGE_COLUMNS}, (xmax = 0) as inserted`,
    [JSON.stringify(votes), now.toISOString()],
  );
  return rows.filter((r) => r.inserted && r.announced_at !== null).map(toChange);
}

interface FloorEventInput {
  chamber: Chamber;
  occurred_at: string;
  kind: string;
  text: string;
  vote_id: string | null;
  source_ref: string;
  roll_number: number | null;
}

async function insertFloorEvents(db: Db, events: FloorEventInput[], now: Date): Promise<number> {
  if (events.length === 0) return 0;
  // A vote menu entry has no time of its own; its occurred_at is when we first saw it, so a later
  // sighting keeps it. A House action carries the floor's time, which the Clerk can correct.
  const { rows } = await db.query<{ inserted: boolean }>(
    `insert into floor_events (chamber, occurred_at, kind, text, vote_id, source_ref, roll_number, observed_at)
     select chamber, occurred_at, kind, text, vote_id, source_ref, roll_number, $2::timestamptz
       from jsonb_to_recordset($1::jsonb) as x(chamber chamber, occurred_at timestamptz, kind text, text text,
            vote_id text, source_ref text, roll_number integer)
     on conflict (chamber, source_ref) do update set
       kind = excluded.kind, text = excluded.text,
       occurred_at = case when floor_events.source_ref like 'vote_menu:%'
                          then coalesce(floor_events.occurred_at, excluded.occurred_at)
                          else excluded.occurred_at end,
       vote_id = coalesce(excluded.vote_id, floor_events.vote_id), roll_number = excluded.roll_number
     returning (xmax = 0) as inserted`,
    [JSON.stringify(events), now.toISOString()],
  );
  return rows.filter((r) => r.inserted).length;
}

/** Says whether a vote dated `day` (Eastern "YYYY-MM-DD") is news; the default treats everything as news. */
export type IsNews = (day: string) => boolean;

/** Stores a House floor summary day: every action as a floor event, and each roll call it names as a vote. */
export async function recordHouseFloor(
  db: Db,
  day: HouseFloorDay,
  now: Date,
  isNews: IsNews = () => true,
): Promise<{ events: number; opened: VoteStateChange[] }> {
  const actions = [...day.actions].reverse(); // oldest first
  const votes: OpenVoteInput[] = [];
  const events: FloorEventInput[] = [];
  for (const a of actions) {
    if (!a.uniqueId || !a.occurredAtEastern) continue;
    const occurred = easternToDate(a.occurredAtEastern).toISOString();
    let id: string | null = null;
    if (a.roll) {
      id = voteId({ chamber: "house", congress: day.congress, session: day.session, rollNumber: a.roll.rollNumber });
      votes.push({
        id,
        chamber: "house",
        congress: day.congress,
        session: day.session,
        roll_number: a.roll.rollNumber,
        question: a.roll.question ?? a.text,
        result: a.roll.result,
        yea: a.roll.yea ?? 0,
        nay: a.roll.nay ?? 0,
        opened_at: occurred,
        bill_ref: a.item,
        news: isNews(a.occurredAtEastern.slice(0, 10)),
      });
    }
    events.push({
      chamber: "house",
      occurred_at: occurred,
      kind: a.kind,
      text: a.text,
      vote_id: id,
      source_ref: a.uniqueId,
      roll_number: a.roll?.rollNumber ?? null,
    });
  }
  const opened = await upsertOpenVotes(db, votes, now);
  return { events: await insertFloorEvents(db, events, now), opened };
}

/**
 * Stores Senate votes the vote menu lists before their roll call XML is stored. The menu has no time
 * of day, so a Senate vote has no `opened_at` and its floor event is stamped with when we saw it.
 */
export async function recordSenateMenu(
  db: Db,
  menu: SenateVoteMenu,
  now: Date,
  isNews: IsNews = () => true,
): Promise<{ events: number; opened: VoteStateChange[] }> {
  // Only votes past the newest one stored. The menu lists the whole session, and a gap further back
  // is the roll call ingest's to repair, not news (lesson 44).
  const after = await lastRollNumber(db, "senate", menu.congress, menu.session);
  const pending = menu.votes.filter((v) => v.rollNumber > after).reverse();
  const votes: OpenVoteInput[] = pending.map((v) => ({
    id: voteId({ chamber: "senate", congress: menu.congress, session: menu.session, rollNumber: v.rollNumber }),
    chamber: "senate",
    congress: menu.congress,
    session: menu.session,
    roll_number: v.rollNumber,
    question: v.question,
    result: v.result || null,
    yea: v.yeas,
    nay: v.nays,
    opened_at: null,
    bill_ref: v.issue,
    news: isNews(v.date),
  }));
  const opened = await upsertOpenVotes(db, votes, now);
  const events = await insertFloorEvents(
    db,
    pending.map((v, i) => ({
      chamber: "senate",
      occurred_at: now.toISOString(),
      kind: "vote",
      text: [v.question, v.title, v.result && `${v.result} ${v.yeas}-${v.nays}`].filter(Boolean).join(" — "),
      vote_id: votes[i]!.id,
      source_ref: `vote_menu:${menu.congress}-${menu.session}-${v.rollNumber}`,
      roll_number: v.rollNumber,
    })),
    now,
  );
  return { events, opened };
}

/**
 * Stamps `posted_at` — the measurement M3 needs — on a chamber's final votes nobody has been told
 * about yet. Called only when the chamber's previous roll call poll was recent, so a backfill after
 * downtime records nothing rather than a delay that is really our own. Returns the votes stamped.
 */
export async function stampPosted(db: Db, chamber: Chamber, now: Date): Promise<VoteStateChange[]> {
  const { rows } = await db.query<ChangeRow>(
    `update votes set posted_at = $2
      where chamber = $1 and state = 'final' and broadcast_at is null and posted_at is null
      returning ${CHANGE_COLUMNS}`,
    [chamber, now.toISOString()],
  );
  return rows.sort((a, b) => (a.roll_number ?? 0) - (b.roll_number ?? 0)).map(toChange);
}

/**
 * Publishes every final vote not yet broadcast and marks it broadcast — however it became final: this
 * worker's poll, a poll that threw halfway through, the hourly ingest workflow, or a run before a
 * restart. Nothing is derived from "what this poll stored", so nothing is lost when a poll fails.
 *
 * A vote older than a day is marked without being published (a backfill of an old session is not
 * news). When the broadcast fails nothing is marked, and the next poll tries again.
 */
export async function publishFinals(db: Db, broadcaster: Broadcaster, now: Date): Promise<VoteStateChange[]> {
  const { rows } = await db.query<ChangeRow & { occurred_at: Date | null }>(
    `select ${CHANGE_COLUMNS}, occurred_at from votes
      where state = 'final' and broadcast_at is null
      order by chamber, roll_number
      limit 500`,
  );
  if (rows.length === 0) return [];
  const cutoff = now.getTime() - NEWS_WINDOW_MS;
  const news = rows.filter((r) => (r.occurred_at ? new Date(r.occurred_at).getTime() : now.getTime()) > cutoff).map(toChange);
  if (news.length) await broadcaster.publish(news);
  await db.query(`update votes set broadcast_at = $2 where id = any($1::text[]) and broadcast_at is null`, [
    rows.map((r) => r.id),
    now.toISOString(),
  ]);
  return news;
}

/** Votes still `open` whose first sighting is older than `olderThanMs`: XML that never posted or never parsed. */
export async function stuckOpenVotes(db: Db, now: Date, olderThanMs: number): Promise<{ id: string; since: string }[]> {
  const { rows } = await db.query<{ id: string; since: Date }>(
    `select v.id, min(e.observed_at) as since
       from votes v join floor_events e on e.vote_id = v.id
      where v.state = 'open'
      group by v.id
     having min(e.observed_at) < $1::timestamptz
      order by v.id`,
    [new Date(now.getTime() - olderThanMs).toISOString()],
  );
  return rows.map((r) => ({ id: r.id, since: new Date(r.since).toISOString() }));
}

export interface LatencyRow {
  id: string;
  chamber: Chamber;
  openedAt: string | null;
  announcedAt: string | null;
  postedAt: string;
  /** Floor's time for the vote → XML seen. House only. */
  fromOpenSeconds: number | null;
  /** Floor source first named it → XML seen. Negative when the XML came first. */
  fromAnnouncedSeconds: number | null;
}

/** Every live-measured vote in the last `days` days, newest first. */
export async function postingLatency(db: Db, days: number): Promise<LatencyRow[]> {
  const { rows } = await db.query<{
    id: string;
    chamber: Chamber;
    opened_at: Date | null;
    announced_at: Date | null;
    posted_at: Date;
    from_open: number | null;
    from_announced: number | null;
  }>(
    `select id, chamber, opened_at, announced_at, posted_at,
            extract(epoch from posted_at - opened_at)::float8 as from_open,
            extract(epoch from posted_at - announced_at)::float8 as from_announced
       from votes
      where posted_at is not null and posted_at > now() - make_interval(days => $1)
      order by posted_at desc`,
    [days],
  );
  return rows.map((r) => ({
    id: r.id,
    chamber: r.chamber,
    openedAt: iso(r.opened_at),
    announcedAt: iso(r.announced_at),
    postedAt: iso(r.posted_at)!,
    fromOpenSeconds: r.from_open === null ? null : Math.round(r.from_open),
    fromAnnouncedSeconds: r.from_announced === null ? null : Math.round(r.from_announced),
  }));
}

/** The `latency [days]` argument: a whole number of days from 1 to 3650; anything else is refused. */
export function parseLatencyDays(arg: string | undefined): number {
  if (arg === undefined) return 30;
  if (!/^\d+$/.test(arg) || Number(arg) < 1 || Number(arg) > 3650) {
    throw new Error(`latency takes a whole number of days from 1 to 3650, not "${arg}"`);
  }
  return Number(arg);
}

/** Median and 90th percentile of the non-null values, in seconds. */
export function summarize(values: (number | null)[]): { n: number; median: number | null; p90: number | null } {
  const xs = values.filter((v): v is number => v !== null).sort((a, b) => a - b);
  const at = (q: number) => (xs.length ? xs[Math.min(xs.length - 1, Math.ceil(q * xs.length) - 1)]! : null);
  return { n: xs.length, median: at(0.5), p90: at(0.9) };
}

export interface Revalidated {
  status: number;
  text: string;
  /** The body is the one last committed for this URL (a 304, or the same bytes again). */
  unchanged: boolean;
  /**
   * Remembers this body (and its ETag) as handled. Call it only once what it says is stored: an
   * uncommitted body is fetched in full and reported as changed again on the next poll.
   */
  commit(): void;
}

/** URLs a revalidating fetcher remembers; the worker uses a handful, so this only bounds a mistake. */
export const REVALIDATION_CACHE_MAX = 64;

/**
 * Wraps a fetcher with ETag / Last-Modified revalidation, so polling a big file every 10 s (the
 * Senate's vote menu is ~170 KB) costs a 304 when nothing changed. A 304 comes back as the cached
 * 200, with `unchanged` set.
 */
export function revalidatingFetch(base: typeof fetch = fetch): (url: string) => Promise<Revalidated> {
  const cache = new Map<string, { etag: string | null; modified: string | null; text: string }>();
  return async (url) => {
    const hit = cache.get(url);
    const headers: Record<string, string> = { "user-agent": "floor-ingest/0.1" };
    if (hit?.etag) headers["if-none-match"] = hit.etag;
    if (hit?.modified) headers["if-modified-since"] = hit.modified;
    const res = await base(url, { headers, signal: AbortSignal.timeout(15_000) });
    if (res.status === 304 && hit) return { status: 200, text: hit.text, unchanged: true, commit: () => {} };
    const text = res.status === 200 ? await res.text() : "";
    const entry = { etag: res.headers.get("etag"), modified: res.headers.get("last-modified"), text };
    return {
      status: res.status,
      text,
      unchanged: res.status === 200 && hit?.text === text,
      commit: () => {
        if (res.status !== 200) return;
        cache.delete(url); // re-insert at the end: the Map's order is the eviction order
        cache.set(url, entry);
        while (cache.size > REVALIDATION_CACHE_MAX) cache.delete(cache.keys().next().value!);
      },
    };
  };
}

export type RevalidatingFetch = ReturnType<typeof revalidatingFetch>;

/**
 * Per-host backoff: after a 403 or 429 a host is not asked again for 30 s, then 1, 2, 4 minutes and
 * at most 5 while it keeps refusing (senate.gov refuses bursts, lesson 43). Any other answer resets it.
 */
export class HostBackoff {
  /** `seq` orders refusals against requests: a success resets only refusals older than its own request. */
  private readonly hosts = new Map<string, { until: number; delay: number; seq: number }>();
  private seq = 0;
  constructor(private readonly now: () => number) {}

  async run<T extends { status: number }>(url: string, fn: () => Promise<T>): Promise<T> {
    const host = new URL(url).host;
    const before = this.hosts.get(host);
    if (before && this.now() < before.until) {
      throw new Error(`${host} refused us (403/429); backing off for ${Math.ceil((before.until - this.now()) / 1000)} s more`);
    }
    const started = ++this.seq;
    const res = await fn();
    const s = this.hosts.get(host);
    if (res.status === 403 || res.status === 429) {
      // Requests that were already in flight together (the schedule and the floor page) count once.
      if (s && s.seq > started) return res;
      const delay = s ? Math.min(s.delay * 2, BACKOFF_MAX_MS) : BACKOFF_START_MS;
      this.hosts.set(host, { until: this.now() + delay, delay, seq: ++this.seq });
    } else if (s && s.seq < started) {
      this.hosts.delete(host);
    }
    return res;
  }
}

export interface LiveDeps {
  db: Db;
  /** Floor sources (revalidated). */
  fetchFloor: RevalidatingFetch;
  /** Roll call XML. */
  fetchRoll?: FetchText;
  broadcaster: Broadcaster;
  alerter?: Pick<StatusAlerter, "check"> & Partial<Pick<StatusAlerter, "notify">>;
  now?: () => Date;
  log?: (msg: string) => void;
  /** Links bills and nominations for newly final votes; called at most every 5 minutes, only after new votes. */
  linkMeasures?: () => Promise<void>;
}

export interface TickResult {
  /** Each chamber as last known (a chamber not polled this tick keeps its previous state). */
  sessions: ChamberSession[];
  inSession: boolean;
  /** The chambers whose sources were polled this tick. */
  polled: Chamber[];
  changes: VoteStateChange[];
  errors: string[];
}

const describe = (err: unknown) => (err instanceof Error ? err.message : String(err));

type Step = <T>(name: string, fn: () => Promise<T>) => Promise<T | null>;

export class LiveWorker {
  private houseDay: HouseFloorDay | null = null;
  private lastLookback = -Infinity;
  private senateSchedule: { value: SenateSchedule; at: number } | null = null;
  private senateMeetings: { value: SenateMeeting[]; at: number } | null = null;
  private readonly sessions: Record<Chamber, ChamberSession> = {
    house: houseSession(null, new Date(0)),
    senate: senateSession(null, [], new Date(0)),
  };
  private readonly nextDue: Record<Chamber, number> = { house: -Infinity, senate: -Infinity };
  /** When each chamber's floor sources last answered, and its roll calls were last ingested without error. */
  private readonly lastFloorPoll: Record<Chamber, number | null> = { house: null, senate: null };
  private readonly lastRollPoll: Record<Chamber, number | null> = { house: null, senate: null };
  private readonly lastRepair: Record<Chamber, number> = { house: -Infinity, senate: -Infinity };
  private lastPrune = -Infinity;
  private lastSweep = -Infinity;
  private readonly reportedStuck = new Set<string>();
  private lastLink = -Infinity;
  private pendingLink = false;
  private readonly now: () => Date;
  private readonly log: (msg: string) => void;
  private readonly fetchFloor: RevalidatingFetch;
  private readonly fetchRoll: FetchText;

  constructor(private readonly deps: LiveDeps) {
    this.now = deps.now ?? (() => new Date());
    this.log = deps.log ?? (() => {});
    const backoff = new HostBackoff(() => this.now().getTime());
    this.fetchFloor = (url) => backoff.run(url, () => deps.fetchFloor(url));
    const roll = deps.fetchRoll ?? defaultFetch;
    this.fetchRoll = (url) => backoff.run(url, () => roll(url));
  }

  private isLive(last: number | null, now: Date): boolean {
    return last !== null && now.getTime() - last <= LIVE_GAP_MS;
  }

  private async fetchHouseDay(day: string): Promise<{ day: HouseFloorDay; res: Revalidated } | null> {
    const res = await this.fetchFloor(houseFloorUrl(day));
    if (res.status === 404) return null;
    if (res.status !== 200) throw new Error(`House floor summary for ${day} returned HTTP ${res.status}`);
    if (!res.text.includes("<legislative_activity")) return null; // an HTML error page with a 200
    return { day: parseHouseFloor(res.text), res };
  }

  /** The House's current legislative day: the open one, else today's, else the latest within a week. */
  private async pollHouseFloor(now: Date): Promise<{ day: HouseFloorDay; res: Revalidated } | null> {
    const today = easternWallClock(now).slice(0, 10);
    const open = this.houseDay && !this.houseDay.finished ? this.houseDay.legislativeDay : null;
    let got = await this.fetchHouseDay(open ?? today);
    if (!got && open && open !== today) got = await this.fetchHouseDay(today);
    if (!got && !this.houseDay && now.getTime() - this.lastLookback >= LOOKBACK_EVERY_MS) {
      // First poll on a day the House isn't sitting: find the last day it did, for its next convening.
      // Seven requests, so a week with no file at all is remembered for an hour rather than retried every poll.
      this.lastLookback = now.getTime();
      for (let back = 1; back <= 7 && !got; back++) {
        got = await this.fetchHouseDay(easternWallClock(new Date(now.getTime() - back * 86_400_000)).slice(0, 10));
      }
    }
    if (got) this.houseDay = got.day;
    return got;
  }

  /**
   * The Senate's session from its schedule and floor page. A source that fails (an HTTP error, a 403,
   * an error page served as 200) is replaced by its last good copy for up to 30 minutes; after that it
   * counts as unknown, and unknown means not in session. Returns the failures alongside.
   */
  private async pollSenateSession(now: Date): Promise<{ session: ChamberSession; failures: string[] }> {
    const t = now.getTime();
    const failures: string[] = [];
    const [sched, floor] = await Promise.allSettled([this.fetchFloor(SENATE_SCHEDULE_URL), this.fetchFloor(SENATE_FLOOR_URL)]);
    const read = <T>(name: string, got: PromiseSettledResult<Revalidated>, parse: (text: string) => T): T | null => {
      try {
        if (got.status === "rejected") throw got.reason;
        if (got.value.status !== 200) throw new Error(`HTTP ${got.value.status}`);
        const value = parse(got.value.text);
        got.value.commit();
        return value;
      } catch (err) {
        failures.push(`${name}: ${describe(err)}`);
        return null;
      }
    };
    const schedule = read("senate schedule", sched, parseSenateSchedule);
    if (schedule) this.senateSchedule = { value: schedule, at: t };
    const meetings = read("senate floor page", floor, parseSenateFloorActivity);
    if (meetings) this.senateMeetings = { value: meetings, at: t };
    const fresh = <T>(c: { value: T; at: number } | null) => (c && t - c.at <= SENATE_STALE_MS ? c.value : null);
    return { session: senateSession(fresh(this.senateSchedule), fresh(this.senateMeetings) ?? [], now), failures };
  }

  /**
   * Ingests new roll calls for a chamber. Whether or not the ingest throws partway, a chamber that was
   * polled recently gets `posted_at` stamped on what became final (the latency measurement); the
   * broadcast itself happens in `publishFinals`, from the table.
   */
  private async pollRollCalls(chamber: Chamber, congress: number, session: number, now: Date): Promise<void> {
    const { db } = this.deps;
    const live = this.isLive(this.lastRollPoll[chamber], now);
    const repair = now.getTime() - this.lastRepair[chamber] >= REPAIR_EVERY_MS;
    if (repair) this.lastRepair[chamber] = now.getTime();
    try {
      await ingestRollCalls(db, chamber, congress, session, { fetchText: this.fetchRoll, log: (msg) => this.log(msg), repair });
      this.lastRollPoll[chamber] = now.getTime();
    } finally {
      if (live) {
        for (const f of await stampPosted(db, chamber, now)) {
          const fromOpen = f.openedAt ? Math.round((Date.parse(f.postedAt!) - Date.parse(f.openedAt)) / 1000) : null;
          const fromSeen = f.announcedAt ? Math.round((Date.parse(f.postedAt!) - Date.parse(f.announcedAt)) / 1000) : null;
          this.log(`latency ${f.id}: XML seen ${fromOpen ?? "?"} s after the floor's vote time, ${fromSeen ?? "?"} s after a floor source named it`);
        }
      }
    }
  }

  private async pollHouse(now: Date, step: Step, changes: VoteStateChange[]): Promise<void> {
    const { db } = this.deps;
    const today = easternWallClock(now).slice(0, 10);
    const live = this.isLive(this.lastFloorPoll.house, now);
    const polled = await step("house floor", async () => ({ got: await this.pollHouseFloor(now) }));
    const got = polled?.got ?? null;
    // The last good day stands in for a failed poll; the stored status is only written from a good one.
    this.sessions.house = houseSession(this.houseDay, now);
    if (got && !got.res.unchanged) {
      const rec = await step("house floor store", () => recordHouseFloor(db, got.day, now, (d) => live || d === today));
      if (rec) {
        changes.push(...rec.opened);
        got.res.commit();
      }
    }
    if (polled) {
      this.lastFloorPoll.house = now.getTime();
      await step("house status store", () => saveChamberStatus(db, this.sessions.house, now));
    }
    // The House's Congress and session come from its own file when it is this year's.
    const cs =
      this.houseDay && this.houseDay.legislativeDay.slice(0, 4) === today.slice(0, 4)
        ? { congress: this.houseDay.congress, session: this.houseDay.session }
        : congressSessionOn(now);
    await step("house roll calls", () => this.pollRollCalls("house", cs.congress, cs.session, now));
  }

  private async pollSenate(now: Date, step: Step, errors: string[], changes: VoteStateChange[]): Promise<void> {
    const { db } = this.deps;
    const today = easternWallClock(now).slice(0, 10);
    const live = this.isLive(this.lastFloorPoll.senate, now);
    const polled = await this.pollSenateSession(now);
    this.sessions.senate = polled.session;
    for (const f of polled.failures) {
      errors.push(f);
      this.log(`${f}`);
    }
    if (polled.failures.length === 0) {
      this.lastFloorPoll.senate = now.getTime();
      await step("senate status store", () => saveChamberStatus(db, polled.session, now));
    }

    const cs = congressSessionOn(now);
    const menu = await step("senate vote menu", async () => {
      const r = await this.fetchFloor(senateVoteMenuUrl(cs.congress, cs.session));
      if (r.status !== 200) throw new Error(`Senate vote menu returned HTTP ${r.status}`);
      return r.unchanged ? null : { menu: parseSenateVoteMenu(r.text), res: r };
    });
    if (menu) {
      const rec = await step("senate menu store", () => recordSenateMenu(db, menu.menu, now, (d) => live || d === today));
      if (rec) {
        changes.push(...rec.opened);
        menu.res.commit();
      }
    }
    await step("senate roll calls", () => this.pollRollCalls("senate", cs.congress, cs.session, now));
  }

  async tick(): Promise<TickResult> {
    const { db, broadcaster } = this.deps;
    const now = this.now();
    const t = now.getTime();
    const errors: string[] = [];
    const changes: VoteStateChange[] = [];
    const polled: Chamber[] = [];
    const step: Step = async (name, fn) => {
      try {
        return await fn();
      } catch (err) {
        errors.push(`${name}: ${describe(err)}`);
        this.log(`${name} failed: ${describe(err)}`);
        return null;
      }
    };

    try {
      if (t >= this.nextDue.house) {
        polled.push("house");
        await this.pollHouse(now, step, changes);
      }
      if (t >= this.nextDue.senate) {
        polled.push("senate");
        await this.pollSenate(now, step, errors, changes);
      }
    } finally {
      // Runs whatever happened above: opens first (they are already in `changes`), then every final
      // vote in the table that nobody has been told about.
      if (changes.length) await step("broadcast", () => broadcaster.publish([...changes]));
      const finals = await step("broadcast finals", () => publishFinals(db, broadcaster, now));
      if (finals?.length) {
        changes.push(...finals);
        this.pendingLink = true;
      }
      for (const c of polled) this.nextDue[c] = t + pollInterval(this.sessions[c].inSession) - DUE_SLACK_MS;
    }

    if (this.pendingLink && this.deps.linkMeasures && t - this.lastLink >= 5 * 60_000) {
      this.lastLink = t;
      this.pendingLink = false;
      await step("link bills and nominations", () => this.deps.linkMeasures!());
    }

    const inSession = this.sessions.house.inSession || this.sessions.senate.inSession;
    if (this.deps.alerter) await step("status alert", () => this.deps.alerter!.check(inSession));

    if (t - this.lastPrune >= 3_600_000) {
      this.lastPrune = t;
      await step("prune ingest runs", () => pruneIngestRuns(db));
    }

    if (t - this.lastSweep >= SWEEP_EVERY_MS) {
      this.lastSweep = t;
      const stuck = await step("stuck open sweep", () => stuckOpenVotes(db, now, STUCK_OPEN_MS));
      if (stuck?.length) {
        const list = stuck.map((s) => `${s.id} (since ${s.since})`).join(", ");
        this.log(`stuck open: ${stuck.length} vote(s) open for over ${STUCK_OPEN_MS / 3_600_000} h: ${list}`);
        // Post once per vote, not every hour it stays stuck.
        const fresh = stuck.filter((s) => !this.reportedStuck.has(s.id));
        if (fresh.length && this.deps.alerter?.notify) {
          for (const s of fresh) this.reportedStuck.add(s.id);
          await step("stuck open alert", () =>
            this.deps.alerter!.notify!(
              `Floor: ${fresh.length} vote(s) open for over ${STUCK_OPEN_MS / 3_600_000} h with no roll call stored: ` +
                fresh.map((s) => s.id).join(", "),
            ),
          );
        }
      }
    }

    return { sessions: [this.sessions.house, this.sessions.senate], inSession, polled, changes, errors };
  }
}

/**
 * Polling every 10 s writes an `ingest_runs` row per chamber per poll. Finished runs that stored
 * nothing and failed nothing say no more than the newest one, so after two days they go; the newest
 * run per source is always kept, and so is every error, every unfinished run and every run that
 * stored something.
 */
export async function pruneIngestRuns(db: Db): Promise<number> {
  const { rows } = await db.query<{ id: number }>(
    `delete from ingest_runs r
      where r.started_at < now() - interval '2 days' and r.items = 0 and r.error is null and r.failed = 0
        -- an unfinished run is reported as "abandoned" by /v1/status (lesson 38): never hide one
        and r.finished_at is not null
        and r.id <> (select max(x.id) from ingest_runs x where x.source = r.source)
      returning r.id`,
  );
  return rows.length;
}

export const pollInterval = (inSession: boolean) => (inSession ? POLL_IN_SESSION_MS : POLL_IDLE_MS);

/** Resolves after `ms`, or at once when `signal` aborts. */
export function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal.aborted) return resolve();
    const timer = setTimeout(done, ms);
    function done() {
      clearTimeout(timer);
      signal.removeEventListener("abort", done);
      resolve();
    }
    signal.addEventListener("abort", done, { once: true });
  });
}

/** Polls until `signal` aborts; the poll in progress always finishes, so no write is cut off. */
export async function runLive(
  worker: Pick<LiveWorker, "tick">,
  signal: AbortSignal,
  opts: { log?: (msg: string) => void; wait?: (ms: number, signal: AbortSignal) => Promise<void> } = {},
): Promise<number> {
  const wait = opts.wait ?? sleep;
  let ticks = 0;
  let wasInSession: boolean | null = null;
  while (!signal.aborted) {
    const result = await worker.tick();
    ticks++;
    if (result.inSession !== wasInSession) {
      const sitting = result.sessions.filter((s) => s.inSession).map((s) => s.chamber);
      opts.log?.(
        result.inSession
          ? `in session (${sitting.join(", ")}): polling it every ${POLL_IN_SESSION_MS / 1000} s, the other every ${POLL_IDLE_MS / 60_000} min`
          : `no chamber in session: polling every ${POLL_IDLE_MS / 60_000} min`,
      );
      wasInSession = result.inSession;
    }
    if (signal.aborted) break;
    await wait(pollInterval(result.inSession), signal);
  }
  return ticks;
}
