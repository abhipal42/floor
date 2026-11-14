-- Financial disclosures of members of both chambers: annual reports' assets and periodic
-- transaction reports (trades), from the House Clerk and the Senate's eFD.
--
-- Stored and served by the API, but OFF in the product: the route answers {enabled:false} until
-- DISCLOSURES_ENABLED is set, pending the team's answer to the 5 U.S.C. §13107(c) commercial-use
-- question (docs/HANDOFF.md, "Financial disclosures"). For the same reason none of these tables has
-- a policy: with RLS on and no policy, PostgREST's anon and authenticated roles read nothing, and
-- only the service connection (worker and API) can.
--
-- Values are kept as filed — the range text, never a number — so nothing downstream can add them
-- up into a net worth (product rule: ranges, never net worth).

create table disclosure_filings (
  id text primary key,                          -- house-<DocID> or senate-<report uuid>
  chamber chamber not null,
  member_id text references members (bioguide_id) on delete set null,  -- null: filer not matched to a member
  filer_name text not null,                     -- as the source lists it
  filer_state_district text,                    -- House index StateDst, e.g. AL04; null for the Senate
  kind text not null check (kind in ('annual', 'ptr')),
  amendment boolean not null default false,
  report_year smallint,                         -- calendar year an annual report covers; null when the source does not say
  filed_on date,
  source_url text not null,
  format text check (format in ('electronic', 'paper')),  -- null until the document has been looked at
  parse_status text not null default 'pending' check (parse_status in ('pending', 'parsed', 'paper', 'failed')),
  parse_error text,
  parsed_at timestamptz,
  listed_at timestamptz not null default now()
);
create index disclosure_filings_member on disclosure_filings (member_id, kind, filed_on desc);

create table disclosure_assets (
  id bigint generated always as identity primary key,
  filing_id text not null references disclosure_filings (id) on delete cascade,
  position integer not null,                    -- order in the filing
  name text not null,
  asset_type text,                              -- readable: the House code's name, or the Senate's type
  asset_type_code text,                         -- the House's two-letter code ([ST]); null for the Senate
  account text,                                 -- the holding it sits in: House "Subholding of", Senate parent row
  owner text check (owner in ('self', 'spouse', 'joint', 'dependent')),
  value_range text,                             -- as filed, e.g. "$15,001 - $50,000", "None", "Undetermined"
  income_type text,
  income_range text,
  description text
);
create index disclosure_assets_filing on disclosure_assets (filing_id, position);

create table disclosure_transactions (
  id bigint generated always as identity primary key,
  filing_id text not null references disclosure_filings (id) on delete cascade,
  position integer not null,
  owner text check (owner in ('self', 'spouse', 'joint', 'dependent')),
  asset_name text not null,
  ticker text,
  asset_type text,
  asset_type_code text,
  tx_type text not null check (tx_type in ('buy', 'sell', 'exchange')),
  tx_type_filed text not null,                  -- as filed: "S (partial)", "Sale (Full)", ...
  amount_range text not null,                   -- as filed
  transacted_on date not null,
  notified_on date,                             -- House only: when the filer was notified of the trade
  cap_gains_over_200 boolean,
  comment text
);
create index disclosure_transactions_filing on disclosure_transactions (filing_id, transacted_on desc);

alter table disclosure_filings enable row level security;
alter table disclosure_assets enable row level security;
alter table disclosure_transactions enable row level security;
