-- Members-elect: who won a seat in the last election and has not taken office yet, and the seats
-- whose race is not settled. Shown only until takes_office; after that congress-legislators lists
-- the new members in `members` and nothing here is served.
--
-- Floor never calls a race. Every elect row names who did (called_by: the AP for a Senate race,
-- the House Clerk's member-elect list for the House) and links the source; a seat with no call is
-- a pending seat, never a leader or a projection.
--
-- id: 'elect-<cycle>-<state>-<seat>', lower case: 'elect-2026-mi-sen', 'elect-2026-ny-12',
-- 'elect-2026-ak-al' for an at-large seat (stored as district 0, as `members` stores it).

create table members_elect (
  id text primary key,
  cycle smallint not null,
  bioguide_id text,                              -- when assigned (the Clerk's list has them); null for most senators-elect
  first_name text not null,
  last_name text not null,
  party text not null,
  state text not null,
  district smallint,                             -- null for the Senate; 0 at large
  chamber chamber not null,
  replaces text references members (bioguide_id), -- the member leaving that seat; null when unknown
  takes_office date not null,
  called_by text not null check (called_by in ('AP', 'House Clerk')),
  called_on date,
  source_url text not null,
  fec_candidate_id text,
  -- OpenFEC candidate totals (apps/worker fec-elect), what the campaign reported; null until fetched.
  receipts numeric,
  disbursements numeric,
  coverage_end date,
  finance_cycle smallint,
  finance_fetched_at timestamptz
);
create index members_elect_state on members_elect (state, chamber);
create index members_elect_replaces on members_elect (replaces);

create table seats_pending (
  id text primary key,                           -- same scheme as members_elect
  cycle smallint not null,
  state text not null,
  district smallint,
  chamber chamber not null,
  status text not null check (status in ('uncalled', 'runoff')),
  runoff_on date,
  incumbent text references members (bioguide_id),
  source_url text not null
);

-- A candidate's financial disclosure belongs to an elect, not a member: member_id stays null.
alter table disclosure_filings
  add column elect_id text references members_elect (id) on delete set null;
create index disclosure_filings_elect on disclosure_filings (elect_id, filed_on desc);

-- Public data like `members`: readable by anyone, written only by the worker (service role).
alter table members_elect enable row level security;
alter table seats_pending enable row level security;
create policy "public read" on members_elect for select using (true);
create policy "public read" on seats_pending for select using (true);
