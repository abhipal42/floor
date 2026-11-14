-- Every bill of the current Congress, not only the ones that reached a recorded vote (Round 10:
-- follow bills and topics). Adds where each bill stands on the road to law, the bookkeeping the
-- incremental Congress.gov listing needs, and full-text search.

-- `status` was created in the core migration and never written: every row is null. It becomes the
-- stage the worker derives from the bill's actions and votes (apps/worker/src/stage.ts), so a list
-- of bills never fetches actions per row. Null until the worker has staged the bill.
alter table bills rename column status to stage;
alter table bills add constraint bills_stage_check check (stage in (
  'introduced', 'passed_house', 'passed_senate', 'passed_both', 'to_president',
  'law', 'vetoed', 'failed', 'adopted'
));

alter table bills
  -- Congress.gov's updateDate from the bill list (a date, not a time). The listing's high-water mark.
  add column list_updated_on date,
  -- When the worker last fetched the bill's detail, actions and summary. A bill is due again once
  -- the list says it changed after that (see `detailsDue` in apps/worker/src/catalog.ts).
  add column details_fetched_at timestamptz,
  -- Short title first, then the official title, then the CRS summary, weighted in that order.
  add column search tsvector generated always as (
    setweight(to_tsvector('english', coalesce(short_title, '')), 'A') ||
    setweight(to_tsvector('english', title), 'B') ||
    setweight(to_tsvector('english', coalesce(summary, '')), 'C')
  ) stored;

-- Every bill stored before this migration came from the per-vote path, which fetched its details.
update bills set details_fetched_at = updated_at;

create index bills_search on bills using gin (search);
-- A topic page: one Congress, one policy area, newest action first, keyset-paginated on (date, id).
create index bills_topic on bills (congress, policy_area, latest_action_on desc nulls last, id desc);
-- The listing's high-water mark.
create index bills_list_updated on bills (congress, list_updated_on);

-- No new table: `bills` already has row-level security with its public read policy
-- (20261111000200_core_rls.sql), and only the service connection writes.
