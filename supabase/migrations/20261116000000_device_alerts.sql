-- Alerts and Live Activities without accounts (round 8 sections A-C, round 9/10 "Alerts").
--
-- The core migration's `devices` table belonged to a Supabase Auth user (`user_id` → auth.users,
-- RLS "own devices"). Floor has no accounts: a phone identifies itself with a random 32-byte key it
-- generates and keeps (never shown, never sent to anyone but the API), and the API stores only the
-- key's SHA-256. So `devices` is re-made around that hash. Nothing has ever written the old table
-- (no route did, and the app had no account to write it with); the guard below refuses to drop it
-- if that has stopped being true, rather than lose rows.
--
-- Nothing here is public: RLS is on and there is NO policy on any of these tables, so PostgREST's
-- anon and authenticated roles can neither read nor write them. Only the API's and the worker's
-- service connection do. No address, no coordinates, no account: a token, a hash, and the public
-- ids of members and bills the phone wants alerts about.

do $$
begin
  if exists (select 1 from devices) then
    raise exception 'devices has rows; migrate them by hand before re-making the table';
  end if;
end
$$;

drop table devices;

create table devices (
  id uuid primary key default gen_random_uuid(),
  -- hex SHA-256 of the phone's device key. The key itself is never stored.
  key_hash text not null unique check (key_hash ~ '^[0-9a-f]{64}$'),
  -- The APNs device token for alerts; null until the phone has notification permission, and
  -- cleared when Apple answers 410 (the app was deleted or the token rotated).
  apns_token text unique check (apns_token ~ '^[0-9a-f]{64,200}$'),
  -- Which APNs gateway the token belongs to: a Debug build's tokens are sandbox tokens.
  apns_env text not null default 'production' check (apns_env in ('sandbox', 'production')),
  -- ActivityKit's push-to-start token (iOS 17.2+), so the worker can start a Live Activity.
  push_to_start_token text unique check (push_to_start_token ~ '^[0-9a-f]{64,200}$'),
  -- "A vote opened": the push alert. Off by default (round 9, section C).
  vote_opened boolean not null default false,
  -- "Live Activities": start one, silently, when a vote involving this phone's members or bills
  -- opens (round 8, section A). On by default.
  live_activities boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- What a phone wants alerts about: each member (Bioguide ID) and bill (Floor bill id) it follows or
-- represents, with its "How they voted" switch. A followed item whose switch is off is still listed:
-- "A vote opened" covers votes involving any of your members, not only the ones whose result alerts
-- you. Topics are not here: see docs/HANDOFF.md, M3.
create table device_subscriptions (
  device_id uuid not null references devices (id) on delete cascade,
  target_kind text not null check (target_kind in ('member', 'bill')),
  target_id text not null check (length(target_id) between 1 and 40),
  how_voted boolean not null,
  primary key (device_id, target_kind, target_id)
);
create index device_subscriptions_target on device_subscriptions (target_kind, target_id);

-- The push token of each running Live Activity, by vote, so the worker can show the final and end it.
create table live_activity_tokens (
  device_id uuid not null references devices (id) on delete cascade,
  vote_id text not null references votes (id) on delete cascade,
  token text not null check (token ~ '^[0-9a-f]{64,200}$'),
  updated_at timestamptz not null default now(),
  primary key (device_id, vote_id)
);

-- What the worker already sent, so a retried poll never sends twice and a busy night can be counted
-- for the digest. `members` are the Bioguide IDs who cast a vote (yea, nay, present, a candidate)
-- on it, `absent` those whose alert reported they did not vote — absences are facts and alert
-- too, and count toward the day's digest; `bills` the followed bills it matched. Purged after two
-- days by the worker.
create table push_log (
  device_id uuid not null references devices (id) on delete cascade,
  vote_id text not null references votes (id) on delete cascade,
  kind text not null check (kind in ('opened', 'final', 'activity_start', 'activity_end')),
  members text[] not null default '{}',
  absent text[] not null default '{}',
  bills text[] not null default '{}',
  -- Eastern calendar day the push belongs to, for "today" in the digest.
  day date not null,
  sent_at timestamptz not null default now(),
  primary key (device_id, vote_id, kind)
);
create index push_log_day on push_log (device_id, day, kind);

-- New registrations per caller per day, so one address cannot mint keys without limit. The
-- address is stored only as a SHA-256 (of the address and the day), and rows go after a week.
create table device_signups (
  ip_hash text not null check (ip_hash ~ '^[0-9a-f]{64}$'),
  day date not null,
  count integer not null default 0,
  primary key (ip_hash, day)
);

alter table devices enable row level security;
alter table device_signups enable row level security;
alter table device_subscriptions enable row level security;
alter table live_activity_tokens enable row level security;
alter table push_log enable row level security;
-- No policies, deliberately (see the top of this file).
