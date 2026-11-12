-- Bill details from the Congress.gov API, shown on the Bill screen.

alter table bills
  add column origin_chamber chamber,
  add column policy_area text,
  add column summary text,                 -- latest CRS summary, plain text
  add column summary_stage text,           -- e.g. "Introduced in House", "Passed House"
  add column latest_action_on date,
  add column latest_action_text text,
  add column cbo_estimates jsonb not null default '[]',  -- [{ title, url, pubDate }]
  add column source_updated_at timestamptz;              -- Congress.gov updateDate

create index votes_bill on votes (bill_id) where bill_id is not null;
create index actions_bill_date on actions (bill_id, acted_on desc);
