-- Core legislative data. Written by the ingest worker only.

create type chamber as enum ('house', 'senate');
create type vote_position as enum ('yea', 'nay', 'present', 'not_voting');
create type vote_state as enum ('scheduled', 'open', 'final');
create type vote_threshold as enum ('majority', 'three_fifths_sworn', 'two_thirds');
create type tally_source as enum ('ocr', 'xml');
create type stance as enum ('yea', 'leans_yea', 'undecided', 'leans_nay', 'nay');

create table members (
  bioguide_id text primary key,
  first_name text not null,
  last_name text not null,
  party text not null,
  state char(2) not null,
  district smallint,                -- null for senators; 0 for at-large
  chamber chamber not null,
  term_start date not null,
  term_end date not null,
  ids jsonb not null default '{}'   -- govtrack, lis, thomas, etc. from congress-legislators
);
create index members_state_chamber on members (state, chamber);

create table bills (
  id text primary key,              -- e.g. 119-hr-2207
  congress smallint not null,
  bill_type text not null,          -- hr, s, hjres, hres, ...
  number integer not null,
  title text not null,
  short_title text,
  status text,
  sponsor_id text references members (bioguide_id),
  introduced_on date,
  updated_at timestamptz not null default now(),
  unique (congress, bill_type, number)
);

create table bill_versions (
  id bigint generated always as identity primary key,
  bill_id text not null references bills (id) on delete cascade,
  version_code text not null,       -- ih, rh, eh, enr, ...
  issued_on date,
  text_url text,
  unique (bill_id, version_code)
);

create table actions (
  id bigint generated always as identity primary key,
  bill_id text not null references bills (id) on delete cascade,
  acted_on date not null,
  chamber chamber,
  action_code text,
  text text not null
);
create index actions_bill on actions (bill_id, acted_on);

create table votes (
  id text primary key,              -- e.g. house-119-1-412
  chamber chamber not null,
  congress smallint not null,
  session smallint not null,
  roll_number integer,              -- null until the clerk assigns it
  bill_id text references bills (id),
  question text not null,
  threshold vote_threshold not null default 'majority',
  state vote_state not null default 'scheduled',
  yea integer not null default 0 check (yea >= 0),
  nay integer not null default 0 check (nay >= 0),
  present integer not null default 0 check (present >= 0),
  not_voting integer not null default 0 check (not_voting >= 0),
  result text,
  opened_at timestamptz,
  closed_at timestamptz,
  unique (chamber, congress, session, roll_number)
);
create index votes_open on votes (state) where state <> 'final';

create table vote_positions (
  vote_id text not null references votes (id) on delete cascade,
  member_id text not null references members (bioguide_id),
  position vote_position not null,
  primary key (vote_id, member_id)
);
create index vote_positions_member on vote_positions (member_id);

create table tally_snapshots (
  id bigint generated always as identity primary key,
  vote_id text not null references votes (id) on delete cascade,
  observed_at timestamptz not null,
  yea integer not null,
  nay integer not null,
  remaining_seconds integer,
  source tally_source not null
);
create index tally_snapshots_vote on tally_snapshots (vote_id, observed_at);

create table floor_events (
  id bigint generated always as identity primary key,
  chamber chamber not null,
  occurred_at timestamptz not null,
  kind text not null,               -- vote_open, vote_close, motion, adjourn, ...
  text text not null,
  vote_id text references votes (id),
  source_ref text,                  -- upstream id used to dedupe
  unique (chamber, source_ref)
);

create table statements (
  id bigint generated always as identity primary key,
  member_id text not null references members (bioguide_id),
  bill_id text not null references bills (id) on delete cascade,
  stance stance not null,
  quote text,
  url text not null,
  published_at timestamptz not null
);

create table projections (
  id bigint generated always as identity primary key,
  vote_id text not null references votes (id) on delete cascade,
  computed_at timestamptz not null default now(),
  p_pass numeric(5, 4) not null check (p_pass between 0 and 1),
  projected_yea integer not null,
  projected_nay integer not null,
  model_version text not null
);

create table bill_analyses (
  id bigint generated always as identity primary key,
  bill_version_id bigint not null references bill_versions (id) on delete cascade,
  analysis jsonb not null,          -- purpose, provisions, affected groups, impact rules, citations
  model text not null,
  reviewed_by text,
  created_at timestamptz not null default now(),
  unique (bill_version_id)
);
