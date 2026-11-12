-- Raw measure reference and vote time from the roll call, plus a log of ingest runs
-- used for freshness monitoring.

alter table votes add column bill_ref text;
alter table votes add column occurred_at timestamptz;
create index votes_occurred on votes (occurred_at desc);

create table ingest_runs (
  id bigint generated always as identity primary key,
  source text not null,             -- members, house_rollcalls, senate_rollcalls, ...
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  items integer not null default 0,
  error text
);
create index ingest_runs_source on ingest_runs (source, started_at desc);

-- Operational table: no public policy, so only the service role can read or write it.
alter table ingest_runs enable row level security;
