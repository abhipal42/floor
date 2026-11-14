-- What each chamber expects to take up in a week (the week-ahead view). Written by the worker's
-- `schedule` ingest (apps/worker/src/schedule.ts) from the House's weekly floor schedule
-- (docs.house.gov/floor, billsthisweek/YYYYMMDD.xml), and for the Senate from the measures the
-- Daily Digest's "Program for <day>" names. The Senate publishes no list like the House's; what it
-- does publish is in `senate_meetings` below. See docs/HANDOFF.md §3.
--
-- An item is never deleted: when the House takes it off the week's list (a remove-date) or it
-- disappears from the file, `removed_at` is set, so the app can show "pulled" rather than lose it.

create table floor_schedule (
  chamber chamber not null,
  -- The Monday of the week, as the source names it.
  week_of date not null,
  -- The source's own id for the item: the House's `floor-item id`; for the Senate, the meeting
  -- date and the measure ("2026-11-16:hr2347").
  item_id text not null,
  category text not null check (category in ('rule', 'suspension', 'other')),
  -- The category as the source words it, e.g. "Items that may be considered under suspension of the rules".
  category_text text not null,
  -- As the source prints it: "H.R. 5267", "H. Res. 1650", or a placeholder such as "H. Res. ___".
  legis_num text not null,
  -- The bill it names, when that bill is in `bills`. Re-resolved on every run, so a bill the
  -- catalog stores later gets linked then. Not a foreign key: the bill may not be stored yet.
  bill_id text,
  title text not null,
  sort_order integer not null default 0,
  added_at timestamptz,
  removed_at timestamptz,
  -- When the source last edited the week's file.
  source_updated_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (chamber, week_of, item_id)
);

create index floor_schedule_bill on floor_schedule (bill_id) where bill_id is not null;

-- Public data, like bills and votes: anyone may read, only the service connection writes.
alter table floor_schedule enable row level security;
create policy "public read" on floor_schedule for select using (true);

-- The Senate's next meetings: when it convenes (senate.gov's session-day file, floor_schedule.xml,
-- updated about a minute after it adjourns) and, once the Congressional Record is out the next
-- morning, the Daily Digest's program for that day in its own words. One row per meeting day.
create table senate_meetings (
  meeting_date date primary key,
  convenes_at timestamptz,
  -- A pro forma session: the Senate meets for seconds and does no business.
  pro_forma boolean not null default false,
  -- The Digest's heading ("3 p.m., Monday, November 16") and program, verbatim but for whitespace.
  -- Null until that day's Record is published.
  digest_heading text,
  program text,
  -- The Congressional Record issue the program came from, e.g. "172/171".
  record_issue text,
  source_updated_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table senate_meetings enable row level security;
create policy "public read" on senate_meetings for select using (true);
