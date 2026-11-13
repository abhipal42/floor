-- M3 live layer: vote state from floor events, chamber session state, and the timestamps that
-- measure how long the Clerk and the LIS take to post a roll call.
--
-- votes.state already exists ('scheduled' | 'open' | 'final', core migration). The live worker
-- sets 'open' when a floor source names a roll call whose XML is not posted yet; upsertRollCall
-- sets 'final' when the XML lands. votes.opened_at already exists too: the floor's own time for
-- the vote (House only; the Senate's sources give no time of day).

alter table votes
  add column announced_at timestamptz,  -- when the worker first saw a floor source name this roll call
  add column posted_at timestamptz;     -- when the worker first saw its roll call XML, polling live

comment on column votes.announced_at is 'Worker clock: first time a floor source named this roll call';
comment on column votes.posted_at is 'Worker clock: first time the roll call XML was seen by a live poll (null for backfilled votes)';

create index votes_posted on votes (posted_at desc) where posted_at is not null;

-- When the live worker published this vote as final. A final vote with none is one nobody has been
-- told about yet: the worker selects `state = 'final' and broadcast_at is null` every poll, however
-- the row got there (its own poll, the hourly ingest workflow, a poll that threw halfway, a restart),
-- publishes it and stamps it. posted_at stays the latency measurement only.
alter table votes add column broadcast_at timestamptz;
comment on column votes.broadcast_at is 'Worker clock: when the live worker published this vote as final (backfilled for votes final before M3)';

-- Every vote already final is old news: without this the worker's first poll would announce all of
-- them. Stamped with the vote's own time, so none of them shows up as "just final" on /v1/live.
update votes set broadcast_at = coalesce(occurred_at, now()) where state = 'final';

create index votes_unbroadcast on votes (chamber, roll_number) where state = 'final' and broadcast_at is null;
create index votes_broadcast on votes (broadcast_at desc) where broadcast_at is not null;

-- When the worker first saw a floor event; occurred_at is the chamber's own clock.
alter table floor_events
  add column observed_at timestamptz not null default now(),
  add column roll_number integer;

-- One row per chamber: is it sitting, and when does it next meet. Written by the live worker each poll.
create table chamber_status (
  chamber chamber primary key,
  in_session boolean not null,
  convenes_at timestamptz,          -- next (or current) convening, when the source says
  legislative_day date,             -- the House's legislative day, or the Senate's meeting date
  source text not null,             -- which upstream answered: house_floor, senate_schedule
  checked_at timestamptz not null default now()
);

-- Public legislative state: readable by anyone, written only by the worker's service connection.
alter table chamber_status enable row level security;
create policy "public read" on chamber_status for select using (true);
