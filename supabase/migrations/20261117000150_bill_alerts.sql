-- Alerts for the bills you follow (round 11, section E "Alerts" → "Bills you follow"), and topic
-- follows that can alert too ("Through topics too").
--
-- A bill moving on its road to law is recorded once, as a `bill_events` row, by whatever noticed it:
-- the stage changing (`restage`, apps/worker/src/stage.ts, run by the catalog ingest and the
-- per-vote bill linking), a new committee action in the catalog's detail fetch, or a bill appearing
-- on a chamber's floor schedule (`floor_schedule`, its own migration). The live worker then sends
-- each event to the phones that follow the bill, or its topic if they opted in, honouring one
-- switch per step (the six `bill_*` columns below), and marks it sent.
--
-- Nothing here is public, as in 20261116000000_device_alerts.sql: RLS on, no policy, so only the
-- service connection reads or writes. An event is public data about a bill; the push log holds a
-- device id and an event id, nothing else.

-- The "Bills you follow" switches, with the locked design's defaults.
alter table devices
  -- "Scheduled for the floor": on a chamber's weekly schedule (the House Majority Leader's).
  add column bill_scheduled boolean not null default true,
  -- "Passes or fails a chamber, with the score".
  add column bill_chamber_vote boolean not null default true,
  -- "Sent to the President".
  add column bill_to_president boolean not null default true,
  -- "Becomes law or is vetoed".
  add column bill_law boolean not null default true,
  -- "Committee action": hearings, markups, reported. Off by default: busy.
  add column bill_committee boolean not null default false,
  -- "Through topics too": bills in a followed topic alert as if followed. Off by default.
  add column bill_through_topics boolean not null default false;

-- A phone may now follow a topic (a Congress.gov policy area, by its canonical name). Topic rows
-- alert only for bill steps, and only with `bill_through_topics` on; the vote alerts ignore them.
-- The longest policy area ("Civil Rights and Liberties, Minority Issues") is 43 characters.
alter table device_subscriptions drop constraint device_subscriptions_target_kind_check;
alter table device_subscriptions add constraint device_subscriptions_target_kind_check
  check (target_kind in ('member', 'bill', 'topic'));
alter table device_subscriptions drop constraint device_subscriptions_target_id_check;
alter table device_subscriptions add constraint device_subscriptions_target_id_check
  check (length(target_id) between 1 and 80);

-- One row per step a bill took. `dedupe_key` makes recording idempotent: a re-run of the catalog,
-- a retried restage or the schedule read again never records the same step twice.
create table bill_events (
  id bigint generated always as identity primary key,
  bill_id text not null references bills (id) on delete cascade,
  kind text not null check (kind in (
    'floor_scheduled', 'chamber_passed', 'chamber_failed', 'to_president', 'law', 'vetoed', 'committee'
  )),
  chamber chamber,
  -- What the alert says beyond the kind: the score and vote id of a chamber vote, the week of a
  -- schedule entry, the text of a committee action. Public data only.
  detail jsonb not null default '{}',
  dedupe_key text not null unique check (length(dedupe_key) between 1 and 200),
  created_at timestamptz not null default now(),
  -- Set once the live worker has sent it (or decided it was too old to send).
  pushed_at timestamptz
);
create index bill_events_unsent on bill_events (id) where pushed_at is null;
create index bill_events_bill on bill_events (bill_id, created_at desc);

-- What the worker already sent per phone, so a drain that is retried never alerts twice, and a
-- busy day can be counted (past three, bill alerts replace one another). Purged after two days.
create table bill_push_log (
  device_id uuid not null references devices (id) on delete cascade,
  event_id bigint not null references bill_events (id) on delete cascade,
  -- Eastern calendar day the push belongs to.
  day date not null,
  sent_at timestamptz not null default now(),
  primary key (device_id, event_id)
);
create index bill_push_log_day on bill_push_log (device_id, day);

alter table bill_events enable row level security;
alter table bill_push_log enable row level security;
-- No policies, deliberately (see the top of this file).
