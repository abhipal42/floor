-- Presidential nominations the Senate votes on, from the Congress.gov API.
--
-- About a quarter of Senate roll calls are on nominations rather than bills, so they need
-- their own subject to link to. The Senate cites them as "PN1905" or, when a nomination is
-- split into parts the Senate acts on separately, "PN1093-3"; both are one row here.

create table nominations (
  id text primary key,              -- e.g. 119-pn-1093-3, or 119-pn-1905 when unpartitioned
  congress smallint not null,
  number integer not null,
  part smallint not null default 0, -- 0 when the nomination was never split
  citation text not null,           -- as the Senate writes it, e.g. PN1093-3
  nominee_name text,                -- null for military nominations, which list officers in bulk
  position_title text,              -- e.g. "United States District Judge for the Southern District of Ohio"
  organization text,                -- agency or service, e.g. "The Judiciary", "Army"
  description text,                 -- Congress.gov's full sentence, including the "vice ..." clause
  nominee_count integer,            -- officers or nominees covered, 1 for a single appointment
  is_military boolean not null default false,
  received_on date,
  latest_action_on date,
  latest_action_text text,
  source_updated_at timestamptz,    -- Congress.gov updateDate
  updated_at timestamptz not null default now(),
  unique (congress, number, part)
);

alter table votes add column nomination_id text references nominations (id);
create index votes_nomination on votes (nomination_id) where nomination_id is not null;

-- Same as every other public table: readable by anyone, written only by the service connection.
alter table nominations enable row level security;
create policy "public read" on nominations for select using (true);
