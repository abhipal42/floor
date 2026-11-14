/**
 * Alerts and Live Activities, from the live loop's vote changes (round 8 sections A-C, generalized to
 * everything a phone follows by the round 9/10 "Alerts" screen).
 *
 * The live worker hands every change it publishes (`LiveWorker.tick`: opens from the poll that
 * stored them, finals from `publishFinals`, i.e. the `broadcast_at` path) to `PushBroadcaster`, beside
 * the Realtime broadcast. For each change it finds the phones that asked (`devices`,
 * `device_subscriptions`, written by `PUT /v1/devices`) and sends:
 *
 *   open   "A House vote opened: H.R. 1013, On Passage." to phones with "A vote opened" on whose
 *          members sit in that chamber or who follow the bill; a phone with a push-to-start token
 *          gets a Live Activity started instead, whose alert is that same line (one buzz, not two).
 *   final  "Doggett voted nay on H.R. 1013." / "It passed the House 295–128." to phones whose
 *          "How they voted" switch is on for a member with a position on it, or for the bill
 *          ("A vote on H.R. 1013, which you follow."). The fourth final of a phone's day and every
 *          one after it replace one digest notification instead ("Your members cast 6 votes today."),
 *          so a busy night is one notification, not twelve. Every Live Activity a phone registered
 *          for the vote gets the final and ends 15 minutes later.
 *
 * Every send is claimed in `push_log` first (insert … on conflict do nothing), so a poll that is
 * retried (a failed Realtime broadcast leaves `broadcast_at` unset and the next poll publishes the
 * vote again) never alerts twice. That makes delivery at most once: a push APNs refuses for a reason
 * other than a dead token is logged, not retried. A 410 clears the token (`apns_token`,
 * `push_to_start_token`) or deletes the activity token, as Apple asks.
 *
 * Topics are not alerted on: a topic is up to thousands of bills, so "a vote in Health" is a feed
 * (Finals' "Following" shows it), not a push. See docs/HANDOFF.md, M3.
 *
 * With APNs unconfigured (`apnsFromEnv` with any APNS_* unset) `enabled` is false and nothing is
 * read or sent; the live worker runs exactly as before.
 */
import { easternWallClock, type Chamber, type Threshold, type VotePosition } from "@floor/shared";
import type { ApnsMessage, ApnsResult } from "./apns.js";
import { billId, parseMeasureRef } from "./bills.js";
import type { Db } from "./db.js";
import type { Broadcaster, VoteStateChange } from "./realtime.js";

/** From this many finals in a phone's day, each new one updates the day's digest instead. */
export const DIGEST_AFTER = 3;
/** Same for opens: past this many, each new "vote opened" replaces the last rather than stacking. */
export const OPENED_STACK_MAX = 3;
/** The final stays on the lock screen this long, then the activity ends itself (round 8, section A). */
export const ACTIVITY_LINGER_S = 15 * 60;
/** An open vote's activity reads as stale if no final has reached it in this long. */
export const ACTIVITY_STALE_S = 2 * 3600;
/** The lock screen lists this many of your members; the rest are counted. */
export const ACTIVITY_MEMBERS_MAX = 3;
/** Concurrent APNs streams: one HTTP/2 session, as Apple asks, with a bounded number in flight. */
export const PUSH_CONCURRENCY = 20;
/** Notifications are grouped under one thread on the lock screen ("Grouped under Floor"). */
export const THREAD_ID = "floor";
/** The ActivityKit type the app registers (`VoteActivityAttributes` in FloorKit's LiveActivity). */
export const ACTIVITY_TYPE = "VoteActivityAttributes";

const CHAMBER_NAME: Record<Chamber, string> = { house: "House", senate: "Senate" };

const BILL_LABEL: Record<string, string> = {
  hr: "H.R.",
  s: "S.",
  hres: "H.Res.",
  sres: "S.Res.",
  hjres: "H.J.Res.",
  sjres: "S.J.Res.",
  hconres: "H.Con.Res.",
  sconres: "S.Con.Res.",
};

/** The vote as an alert needs it: the row, what it is on, and how it ended. */
export interface PushVote {
  id: string;
  chamber: Chamber;
  kind: "question" | "election";
  rollNumber: number | null;
  question: string;
  result: string | null;
  threshold: Threshold;
  state: "open" | "final" | "scheduled";
  totals: { yea: number; nay: number; present: number; notVoting: number };
  candidates: { name: string; total: number }[];
  openedAt: string | null;
  announcedAt: string | null;
  /** The bill this vote is on, linked or read from the roll call's reference; null otherwise. */
  billId: string | null;
  /** `H.R. 1013`, a nomination's `PN1093-3`, or null for a procedural vote. */
  citation: string | null;
  /** The bill's short title (else its title), or the nominee. */
  title: string | null;
}

/** One of your members on the vote; `position` null while the roll call has not posted. */
export interface ActivityMember {
  id: string;
  name: string;
  position: VotePosition | null;
  choice: string | null;
}

/**
 * ActivityKit's static half, `VoteActivityAttributes` in Swift. The key names and shapes are a
 * contract with `ios/FloorKit/Sources/LiveActivity/VoteActivity.swift`: both sides are tested on
 * `ios/FloorKit/Tests/ModelsTests/Fixtures/live-activity-*.json`.
 */
export interface ActivityAttributes {
  voteId: string;
  chamber: Chamber;
  kind: "question" | "election";
  rollNumber: number | null;
  threshold: Threshold;
  question: string;
  citation: string | null;
  title: string | null;
}

/** ActivityKit's changing half, `VoteActivityAttributes.ContentState` in Swift. */
export interface ActivityContent {
  state: "open" | "final";
  result: string | null;
  /** Null while open: the House posts no running count (round 8, "no running House tally"). */
  totals: { yea: number; nay: number; present: number; notVoting: number } | null;
  /** The floor's own time for the vote (House). */
  openedAt: string | null;
  /** When a floor source first named it: the only time the Senate's sources give. */
  calledAt: string | null;
  members: ActivityMember[];
  /** Members of yours on the vote beyond those listed. */
  moreMembers: number;
}

export const activityAttributes = (v: PushVote): ActivityAttributes => ({
  voteId: v.id,
  chamber: v.chamber,
  kind: v.kind,
  rollNumber: v.rollNumber,
  threshold: v.threshold,
  question: v.question,
  citation: v.citation,
  title: v.title,
});

/** The content for one phone: its members on this vote, positions once final. */
export function activityContent(v: PushVote, members: ActivityMember[]): ActivityContent {
  const final = v.state === "final";
  const sorted = [...members].sort((a, b) => a.name.localeCompare(b.name) || a.id.localeCompare(b.id));
  return {
    state: final ? "final" : "open",
    result: final ? v.result : null,
    totals: final ? v.totals : null,
    openedAt: v.openedAt,
    calledAt: v.announcedAt,
    members: sorted.slice(0, ACTIVITY_MEMBERS_MAX).map((m) => (final ? m : { ...m, position: null, choice: null })),
    moreMembers: Math.max(0, sorted.length - ACTIVITY_MEMBERS_MAX),
  };
}

// MARK: - Copy

type Outcome = "carried" | "failed";

/**
 * Whether the question carried, from the chamber's own result first (as the app's
 * `Vote.recordedOutcome`: rejection words before acceptance, because "Not Agreed to" contains
 * "Agreed"), else the threshold arithmetic. Null for a Speaker ballot.
 */
export function outcomeOf(v: Pick<PushVote, "kind" | "result" | "totals" | "threshold">): Outcome | null {
  if (v.kind === "election") return null;
  const r = (v.result ?? "").toLowerCase();
  if (["rejected", "failed", "not agreed", "not sustained", "not invoked", "defeated", "veto sustained"].some((w) => r.includes(w))) {
    return "failed";
  }
  if (["passed", "agreed", "confirmed", "sustained", "adopted", "invoked", "concurred", "overridden"].some((w) => r.includes(w))) {
    return "carried";
  }
  const voting = v.totals.yea + v.totals.nay + v.totals.present;
  const needed =
    v.threshold === "two_thirds" ? Math.ceil((voting * 2) / 3) : v.threshold === "three_fifths_sworn" ? 60 : Math.floor(voting / 2) + 1;
  return v.totals.yea >= needed ? "carried" : "failed";
}

/** "passed the House 295–128", "was agreed to in the Senate 62–21", "failed in the House 200–220". */
export function outcomeClause(v: PushVote): string {
  const chamber = CHAMBER_NAME[v.chamber];
  const score = `${v.totals.yea}–${v.totals.nay}`;
  if (v.kind === "election") {
    const cast = v.candidates.reduce((n, c) => n + c.total, 0);
    const leader = [...v.candidates].sort((a, b) => b.total - a.total)[0];
    if (!leader) return `was a Speaker ballot`;
    // Leading a ballot is not winning it (lesson 16): elected needs more than half cast for a person.
    return leader.total * 2 > cast ? `elected ${leader.name} Speaker with ${leader.total}` : `elected no one; ${leader.name} led with ${leader.total}`;
  }
  const r = (v.result ?? "").toLowerCase();
  switch (outcomeOf(v)) {
    case "carried":
      if (r.includes("overridden")) return `overrode the veto ${score}`;
      if (r.includes("confirmed")) return `confirmed the nomination ${score}`;
      if (r.includes("passed")) return `passed the ${chamber} ${score}`;
      if (r.includes("agreed")) return `was agreed to in the ${chamber} ${score}`;
      return `carried in the ${chamber} ${score}`;
    case "failed":
      if (r.includes("rejected") || r.includes("not agreed")) return `was rejected in the ${chamber} ${score}`;
      return `failed in the ${chamber} ${score}`;
    default:
      return `was voted on in the ${chamber} ${score}`;
  }
}

const VERB: Record<VotePosition, string> = {
  yea: "voted yea",
  nay: "voted nay",
  present: "voted present",
  not_voting: "did not vote",
  candidate: "voted",
};

const verbOf = (m: Pick<ActivityMember, "position" | "choice">) =>
  m.position === "candidate" ? `voted for ${m.choice ?? "a candidate"}` : VERB[m.position ?? "not_voting"];

/** `Doggett`, `Cornyn and Cruz`, `Cornyn, Cruz and Paxton`. */
export const joinNames = (names: string[]) =>
  names.length <= 1 ? (names[0] ?? "") : `${names.slice(0, -1).join(", ")} and ${names.at(-1)}`;

/** What a vote was on, mid-sentence: `H.R. 1013`, `PN1093-3`, `a procedural vote`. */
const subjectOf = (v: PushVote) => v.citation ?? "a procedural vote";

export interface AlertCopy {
  title: string;
  body: string;
}

/** The final alert for members whose "How they voted" is on (round 8, section C). */
export function finalMembersAlert(v: PushVote, members: ActivityMember[]): AlertCopy {
  const sorted = [...members].sort((a, b) => a.name.localeCompare(b.name));
  const subject = subjectOf(v);
  const verbs = new Set(sorted.map(verbOf));
  let title: string;
  let lead = "";
  if (sorted.length === 1) {
    title = `${sorted[0]!.name} ${verbOf(sorted[0]!)} on ${subject}.`;
  } else if (verbs.size === 1 && sorted.length <= 3) {
    title = `${joinNames(sorted.map((m) => m.name))} ${verbOf(sorted[0]!)} on ${subject}.`;
  } else if (verbs.size === 1) {
    title = `${sorted.length} of your members ${verbOf(sorted[0]!)} on ${subject}.`;
  } else {
    title = `Your members split on ${subject}.`;
    lead = `${sorted.map((m) => `${m.name} ${verbOf(m).replace(/^voted /, "")}`).join(", ")}. `;
  }
  // A procedural vote has no citation to name in the title, so its body says which question it was.
  const sentence = v.citation ? `It ${outcomeClause(v)}.` : `${v.question}: it ${outcomeClause(v)}.`;
  return { title, body: `${lead}${sentence}` };
}

/** The final alert for a followed bill when none of your alerting members is on the vote. */
export function finalBillAlert(v: PushVote): AlertCopy {
  const clause = outcomeClause(v);
  return { title: `A vote on ${subjectOf(v)}, which you follow.`, body: `${v.question}: it ${clause}.` };
}

/** "A House vote opened: H.R. 1013, On Passage." (round 8, section C). */
export function openedAlert(v: PushVote): AlertCopy {
  const what = v.citation ? `${v.citation}, ${v.question}` : v.question;
  return { title: `A ${CHAMBER_NAME[v.chamber]} vote opened: ${what}.`, body: v.title ? `${v.title.replace(/\.$/, "")}.` : "" };
}

export interface DigestDay {
  /** Bioguide ID → surname, and how many votes they cast in today's alerted finals. */
  members: { name: string; votes: number }[];
  /** Finals alerted today for a followed bill only. */
  billVotes: number;
}

/** "Your members cast 6 votes today." / "Doggett 2 · Cornyn 2 · Cruz 2. Tap to catch up." */
export function digestAlert(day: DigestDay): AlertCopy {
  const counted = day.members.filter((m) => m.votes > 0).sort((a, b) => b.votes - a.votes);
  const total = counted.reduce((n, m) => n + m.votes, 0);
  const bills = day.billVotes > 0 ? `${day.billVotes} ${day.billVotes === 1 ? "vote" : "votes"} on bills you follow` : "";
  if (total === 0) {
    return { title: `${bills.charAt(0).toUpperCase()}${bills.slice(1)} today.`, body: "Tap to catch up." };
  }
  const shown = counted.slice(0, 4).map((m) => `${m.name} ${m.votes}`);
  if (counted.length > 4) shown.push(`${counted.length - 4} more`);
  return {
    title: `Your members cast ${total} ${total === 1 ? "vote" : "votes"} today.`,
    body: `${shown.join(" · ")}${bills ? `, and ${bills}` : ""}. Tap to catch up.`,
  };
}

// MARK: - Payloads

const link = (voteId: string | null) => (voteId ? `floor://vote/${voteId}` : "floor://open");

export function alertPayload(copy: AlertCopy, voteId: string | null): Record<string, unknown> {
  const alert: Record<string, string> = { title: copy.title };
  if (copy.body) alert.body = copy.body;
  return { aps: { alert, sound: "default", "thread-id": THREAD_ID }, link: link(voteId) };
}

/** Push-to-start (iOS 17.2+): starts the Live Activity with no tap; its alert is the "vote opened" line. */
export function startPayload(v: PushVote, members: ActivityMember[], copy: AlertCopy, nowS: number): Record<string, unknown> {
  return {
    aps: {
      timestamp: nowS,
      event: "start",
      "content-state": activityContent(v, members),
      "attributes-type": ACTIVITY_TYPE,
      attributes: activityAttributes(v),
      "stale-date": nowS + ACTIVITY_STALE_S,
      alert: { title: copy.title, body: copy.body },
      // iOS 18: hand the started activity its own update token at once.
      "input-push-token": 1,
    },
    link: link(v.id),
  };
}

/** The final, then the activity ends itself 15 minutes later. No alert: the final alert is its own push. */
export function endPayload(v: PushVote, members: ActivityMember[], nowS: number): Record<string, unknown> {
  return {
    aps: {
      timestamp: nowS,
      event: "end",
      "content-state": activityContent(v, members),
      "dismissal-date": nowS + ACTIVITY_LINGER_S,
    },
  };
}

// MARK: - Reading the database

interface VoteRow {
  id: string;
  chamber: Chamber;
  kind: "question" | "election";
  congress: number;
  roll_number: number | null;
  question: string;
  result: string | null;
  threshold: Threshold;
  state: "open" | "final" | "scheduled";
  yea: number;
  nay: number;
  present: number;
  not_voting: number;
  candidates: { name: string; total: number }[] | null;
  opened_at: Date | null;
  announced_at: Date | null;
  bill_id: string | null;
  bill_ref: string | null;
  bill_type: string | null;
  bill_number: number | null;
  short_title: string | null;
  bill_title: string | null;
  nomination_citation: string | null;
  nominee_name: string | null;
}

const iso = (d: Date | null) => (d ? new Date(d).toISOString() : null);

/** A vote with what it is on. An open vote's bill is read from its reference: linking comes later. */
export async function loadVote(db: Db, id: string): Promise<PushVote | null> {
  const { rows } = await db.query<VoteRow>(
    `select v.id, v.chamber, v.kind, v.congress, v.roll_number, v.question, v.result, v.threshold, v.state,
            v.yea, v.nay, v.present, v.not_voting, v.candidates, v.opened_at, v.announced_at, v.bill_id, v.bill_ref,
            b.bill_type, b.number as bill_number, b.short_title, b.title as bill_title,
            n.citation as nomination_citation, n.nominee_name
       from votes v
       left join bills b on b.id = v.bill_id
       left join nominations n on n.id = v.nomination_id
      where v.id = $1`,
    [id],
  );
  const r = rows[0];
  if (!r) return null;
  let bill = r.bill_id;
  let type = r.bill_type;
  let number = r.bill_number;
  let title = r.short_title ?? r.bill_title;
  if (!bill) {
    const ref = parseMeasureRef(r.bill_ref);
    if (ref?.kind === "bill") {
      bill = billId(r.congress, ref.type, ref.number);
      type = ref.type;
      number = ref.number;
      const { rows: b } = await db.query<{ short_title: string | null; title: string }>(
        "select short_title, title from bills where id = $1",
        [bill],
      );
      title = b[0] ? (b[0].short_title ?? b[0].title) : null;
    }
  }
  const citation = type && number != null ? `${BILL_LABEL[type] ?? type.toUpperCase()} ${number}` : (r.nomination_citation ?? null);
  return {
    id: r.id,
    chamber: r.chamber,
    kind: r.kind,
    rollNumber: r.roll_number,
    question: r.question,
    result: r.result,
    threshold: r.threshold,
    state: r.state,
    totals: { yea: r.yea, nay: r.nay, present: r.present, notVoting: r.not_voting },
    candidates: r.candidates ?? [],
    openedAt: iso(r.opened_at),
    announcedAt: iso(r.announced_at),
    billId: bill,
    citation,
    title: r.nomination_citation && !type ? r.nominee_name : title,
  };
}

interface Target {
  device: string;
  apnsToken: string | null;
  pushToStartToken: string | null;
  /** Your members on the vote: in the chamber (open), or with a position (final). */
  members: ActivityMember[];
  /** Of those, the ones whose "How they voted" is on (final only). */
  alertMembers: ActivityMember[];
  /** The vote's bill, when this phone follows it ("How they voted" on, for a final). */
  alertBill: boolean;
}

async function targets(db: Db, v: PushVote, env: "sandbox" | "production"): Promise<Target[]> {
  const final = v.state === "final";
  // Open: a member is on the vote by sitting in its chamber (nobody's position is known yet).
  // Final: by having a position on it. A followed bill is on it by being the vote's bill.
  const { rows } = await db.query<{
    device: string;
    apns_token: string | null;
    push_to_start_token: string | null;
    member_id: string | null;
    last_name: string | null;
    position: VotePosition | null;
    choice: string | null;
    target_kind: "member" | "bill";
    how_voted: boolean;
  }>(
    `select d.id::text as device, d.apns_token, d.push_to_start_token, s.target_kind, s.how_voted,
            m.bioguide_id as member_id, m.last_name, p.position, p.choice
       from devices d
       join device_subscriptions s on s.device_id = d.id
       left join members m on s.target_kind = 'member' and m.bioguide_id = s.target_id
       left join vote_positions p on p.vote_id = $1 and p.member_id = m.bioguide_id
      where d.apns_env = $4
        and ($3::boolean or d.vote_opened)
        and (
          (s.target_kind = 'member' and m.bioguide_id is not null and
            case when $3::boolean then p.member_id is not null
                 else m.chamber = $2::chamber and m.term_end > now()::date end)
          or (s.target_kind = 'bill' and s.target_id = $5)
        )
      order by d.id`,
    [v.id, v.chamber, final, env, v.billId ?? ""],
  );
  const byDevice = new Map<string, Target>();
  for (const r of rows) {
    let t = byDevice.get(r.device);
    if (!t) {
      t = { device: r.device, apnsToken: r.apns_token, pushToStartToken: r.push_to_start_token, members: [], alertMembers: [], alertBill: false };
      byDevice.set(r.device, t);
    }
    if (r.target_kind === "bill") {
      if (r.how_voted) t.alertBill = true;
      continue;
    }
    const m: ActivityMember = { id: r.member_id!, name: r.last_name!, position: r.position, choice: r.choice };
    t.members.push(m);
    if (r.how_voted) t.alertMembers.push(m);
  }
  return [...byDevice.values()];
}

/** Claims sends in push_log; returns the devices that had not been sent this kind for this vote. */
async function claim(
  db: Db,
  voteId: string,
  kind: "opened" | "final" | "activity_start" | "activity_end",
  rows: { device: string; members?: string[]; bills?: string[] }[],
  day: string,
  now: Date,
): Promise<Set<string>> {
  if (rows.length === 0) return new Set();
  const { rows: claimed } = await db.query<{ device_id: string }>(
    `insert into push_log (device_id, vote_id, kind, members, bills, day, sent_at)
     select x.device::uuid, $1, $2, coalesce(x.members, '{}'), coalesce(x.bills, '{}'), $3::date, $4::timestamptz
       from jsonb_to_recordset($5::jsonb) as x(device text, members text[], bills text[])
     on conflict (device_id, vote_id, kind) do nothing
     returning device_id::text`,
    [voteId, kind, day, now.toISOString(), JSON.stringify(rows.map((r) => ({ device: r.device, members: r.members ?? [], bills: r.bills ?? [] })))],
  );
  return new Set(claimed.map((r) => r.device_id));
}

/** How many of `kind` each device was sent on `day`, this one included. */
async function sentToday(db: Db, devices: string[], kind: "opened" | "final", day: string): Promise<Map<string, number>> {
  if (devices.length === 0) return new Map();
  const { rows } = await db.query<{ device: string; n: number }>(
    `select device_id::text as device, count(*)::int as n from push_log
      where device_id = any($1::uuid[]) and kind = $2 and day = $3::date group by device_id`,
    [devices, kind, day],
  );
  return new Map(rows.map((r) => [r.device, r.n]));
}

/** Each device's finals today, for its digest: who cast how many, and the bill-only ones. */
async function digestDays(db: Db, devices: string[], day: string): Promise<Map<string, DigestDay>> {
  if (devices.length === 0) return new Map();
  // Members in the order their first vote of the day was alerted, so the evening's first name (your
  // rep, usually, on the House's first vote) leads the line, as the mock's "Doggett 2 · Cornyn 2".
  const { rows } = await db.query<{ device: string; member_id: string | null; name: string | null; votes: number; bill_votes: number }>(
    `with today as (
       select device_id, members, bills, sent_at from push_log
        where device_id = any($1::uuid[]) and kind = 'final' and day = $2::date
     )
     select device, member_id, name, votes, bill_votes from (
       select t.device_id::text as device, u.member_id, m.last_name as name, count(*)::int as votes, 0 as bill_votes,
              min(t.sent_at) as first, min(u.ord) as ord
         from today t cross join lateral unnest(t.members) with ordinality as u(member_id, ord)
         join members m on m.bioguide_id = u.member_id
        group by t.device_id, u.member_id, m.last_name
       union all
       select device_id::text, null, null, 0, count(*)::int, null, null from today where cardinality(members) = 0 and cardinality(bills) > 0 group by device_id
     ) x order by device, first nulls last, ord, name`,
    [devices, day],
  );
  const out = new Map<string, DigestDay>();
  for (const r of rows) {
    const d = out.get(r.device) ?? { members: [], billVotes: 0 };
    if (r.member_id && r.name) d.members.push({ name: r.name, votes: r.votes });
    else d.billVotes += r.bill_votes;
    out.set(r.device, d);
  }
  return out;
}

// MARK: - Sending

export interface PushSender {
  readonly enabled: boolean;
  send(msg: ApnsMessage): Promise<ApnsResult>;
}

/** Runs `fn` over `items`, `limit` at a time. */
async function pool<T>(items: T[], limit: number, fn: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) await fn(items[next++]!);
  });
  await Promise.all(workers);
}

export interface PushStats {
  sent: number;
  failed: number;
  unregistered: number;
}

export class PushBroadcaster implements Broadcaster {
  constructor(
    private readonly deps: {
      db: Db;
      apns: PushSender;
      /** Which gateway the sender talks to; only tokens from that environment are sent to. */
      environment: "sandbox" | "production";
      now?: () => Date;
      log?: (msg: string) => void;
      concurrency?: number;
    },
  ) {}

  get enabled(): boolean {
    return this.deps.apns.enabled;
  }

  /** Never throws: a push problem must not hold up the Realtime broadcast or stamping `broadcast_at`. */
  async publish(changes: VoteStateChange[]): Promise<void> {
    if (!this.enabled) return;
    for (const change of changes) {
      try {
        const stats = await this.handle(change);
        if (stats.sent || stats.failed || stats.unregistered) {
          this.deps.log?.(`push ${change.id} ${change.state}: ${stats.sent} sent, ${stats.failed} failed, ${stats.unregistered} tokens gone`);
        }
      } catch (err) {
        this.deps.log?.(`push ${change.id} ${change.state} failed: ${err instanceof Error ? err.message : String(err)}`);
      }
    }
  }

  async handle(change: VoteStateChange): Promise<PushStats> {
    const { db } = this.deps;
    const stats: PushStats = { sent: 0, failed: 0, unregistered: 0 };
    const vote = await loadVote(db, change.id);
    if (!vote || (vote.state !== "open" && vote.state !== "final")) return stats;
    const now = (this.deps.now ?? (() => new Date()))();
    const day = easternWallClock(now).slice(0, 10);
    const messages: { msg: ApnsMessage; onGone: () => Promise<unknown> }[] = [];
    const all = await targets(db, vote, this.deps.environment);
    if (vote.state === "open") await this.planOpen(vote, all, day, now, messages);
    else await this.planFinal(vote, all, day, now, messages);
    await pool(messages, this.deps.concurrency ?? PUSH_CONCURRENCY, async ({ msg, onGone }) => {
      const res = await this.deps.apns.send(msg).catch((err: unknown) => ({ ok: false, reason: String(err) }) as ApnsResult);
      if (res.ok) stats.sent++;
      else if (res.unregistered) {
        stats.unregistered++;
        await onGone();
      } else {
        stats.failed++;
        if (res.reason && !res.skipped) this.deps.log?.(`push ${vote.id}: APNs refused (${res.status ?? "?"} ${res.reason})`);
      }
    });
    return stats;
  }

  private clearAlertToken = (device: string) =>
    this.deps.db.query("update devices set apns_token = null where id = $1::uuid", [device]);
  private clearStartToken = (device: string) =>
    this.deps.db.query("update devices set push_to_start_token = null where id = $1::uuid", [device]);

  private async planOpen(
    vote: PushVote,
    all: Target[],
    day: string,
    now: Date,
    out: { msg: ApnsMessage; onGone: () => Promise<unknown> }[],
  ): Promise<void> {
    const { db } = this.deps;
    const reachable = all.filter((t) => t.pushToStartToken || t.apnsToken);
    const claimed = await claim(db, vote.id, "opened", reachable.map((t) => ({ device: t.device })), day, now);
    const counts = await sentToday(db, [...claimed], "opened", day);
    const copy = openedAlert(vote);
    const nowS = Math.floor(now.getTime() / 1000);
    // A phone that already runs an activity for this vote (the app started it while open, and sent
    // its token) gets the plain alert, not a second activity.
    const { rows: running } = await db.query<{ device: string }>(
      "select device_id::text as device from live_activity_tokens where vote_id = $1",
      [vote.id],
    );
    const hasActivity = new Set(running.map((r) => r.device));
    for (const t of reachable) {
      if (!claimed.has(t.device)) continue;
      if (t.pushToStartToken && !hasActivity.has(t.device)) {
        out.push({
          msg: { deviceToken: t.pushToStartToken, pushType: "liveactivity", payload: startPayload(vote, t.members, copy, nowS), priority: 10 },
          onGone: () => this.clearStartToken(t.device),
        });
      } else if (t.apnsToken) {
        // Past the third, opens replace one another rather than stacking up on the lock screen.
        const stacked = (counts.get(t.device) ?? 1) <= OPENED_STACK_MAX;
        out.push({
          msg: {
            deviceToken: t.apnsToken,
            pushType: "alert",
            payload: alertPayload(copy, vote.id),
            collapseId: stacked ? `opened-${vote.id}` : `opened-${day}`,
            // An "opened" alert an hour late is wrong, not late.
            expiration: nowS + 3600,
          },
          onGone: () => this.clearAlertToken(t.device),
        });
      }
    }
  }

  private async planFinal(
    vote: PushVote,
    all: Target[],
    day: string,
    now: Date,
    out: { msg: ApnsMessage; onGone: () => Promise<unknown> }[],
  ): Promise<void> {
    const { db } = this.deps;
    const nowS = Math.floor(now.getTime() / 1000);
    const alerting = all.filter((t) => t.apnsToken && (t.alertMembers.length > 0 || t.alertBill));
    const cast = (m: ActivityMember) => m.position !== null && m.position !== "not_voting";
    const claimed = await claim(
      db,
      vote.id,
      "final",
      alerting.map((t) => ({
        device: t.device,
        members: t.alertMembers.filter(cast).sort((a, b) => a.name.localeCompare(b.name)).map((m) => m.id),
        bills: t.alertBill && vote.billId ? [vote.billId] : [],
      })),
      day,
      now,
    );
    const mine = alerting.filter((t) => claimed.has(t.device));
    const counts = await sentToday(db, mine.map((t) => t.device), "final", day);
    const busy = mine.filter((t) => (counts.get(t.device) ?? 1) > DIGEST_AFTER);
    const days = await digestDays(db, busy.map((t) => t.device), day);
    for (const t of mine) {
      const digest = days.get(t.device);
      const copy = digest ? digestAlert(digest) : t.alertMembers.length > 0 ? finalMembersAlert(vote, t.alertMembers) : finalBillAlert(vote);
      out.push({
        msg: {
          deviceToken: t.apnsToken!,
          pushType: "alert",
          payload: alertPayload(copy, digest ? null : vote.id),
          // The digest is one notification for the day, replaced in place as the night goes on.
          collapseId: digest ? `digest-${day}` : `final-${vote.id}`,
          expiration: nowS + 86_400,
        },
        onGone: () => this.clearAlertToken(t.device),
      });
    }

    // Every Live Activity running for this vote: the final, then gone 15 minutes later.
    const { rows: activities } = await db.query<{ device: string; token: string }>(
      `select t.device_id::text as device, t.token from live_activity_tokens t join devices d on d.id = t.device_id
        where t.vote_id = $1 and d.apns_env = $2`,
      [vote.id, this.deps.environment],
    );
    const ended = await claim(db, vote.id, "activity_end", activities.map((a) => ({ device: a.device })), day, now);
    const membersOf = new Map(all.map((t) => [t.device, t.members]));
    for (const a of activities) {
      if (!ended.has(a.device)) continue;
      out.push({
        msg: { deviceToken: a.token, pushType: "liveactivity", payload: endPayload(vote, membersOf.get(a.device) ?? [], nowS), priority: 10 },
        onGone: () => db.query("delete from live_activity_tokens where device_id = $1::uuid and vote_id = $2", [a.device, vote.id]),
      });
    }
  }
}

/** Runs several broadcasters in order; pushes first, because they never throw. */
export function composeBroadcasters(...all: Broadcaster[]): Broadcaster {
  return {
    enabled: all.some((b) => b.enabled),
    async publish(changes) {
      for (const b of all) if (b.enabled) await b.publish(changes);
    },
  };
}
