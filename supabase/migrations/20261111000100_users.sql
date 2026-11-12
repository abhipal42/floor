-- Per-user data. Every table is row-level secured on auth.uid().

create table profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  state char(2),
  district smallint,
  county_fips char(5),
  attributes jsonb not null default '{}',  -- opt-in only: renter, income_band, veteran, ...
  created_at timestamptz not null default now()
);

create table follows (
  user_id uuid not null references auth.users (id) on delete cascade,
  target_kind text not null check (target_kind in ('member', 'bill')),
  target_id text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, target_kind, target_id)
);

create table devices (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  apns_token text not null unique,
  live_activity_push_to_start_token text,
  updated_at timestamptz not null default now()
);

alter table profiles enable row level security;
alter table follows enable row level security;
alter table devices enable row level security;

create policy "own profile" on profiles for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own follows" on follows for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own devices" on devices for all using (user_id = auth.uid()) with check (user_id = auth.uid());
