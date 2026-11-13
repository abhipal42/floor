-- Campaign finance from the FEC, for every member.
--
-- campaign_finance: one row per member, the totals of their current campaign to date, from the
-- OpenFEC candidate totals endpoint (what the campaign reported receiving).
-- pac_contributions: one row per member, cycle and giving committee, from the FEC bulk file of
-- committee-to-candidate contributions (what each committee reported giving). Earmarked
-- contributions — individuals' money passed through a committee — are kept apart from the
-- committee's own direct contributions. No memo text and no individual donor is ever stored.

create table campaign_finance (
  member_id text primary key references members (bioguide_id) on delete cascade,
  fec_candidate_id text not null,
  cycle smallint not null,                       -- the election the campaign is for, e.g. 2026
  coverage_start date,
  coverage_end date,
  receipts numeric(14, 2) not null,
  individual_unitemized numeric(14, 2) not null, -- under $200 per donor: "small-dollar"
  individual_itemized numeric(14, 2) not null,
  pac numeric(14, 2) not null,                   -- other political committees
  party numeric(14, 2) not null,
  other numeric(14, 2) not null,                 -- transfers, the candidate's own money, refunds, other receipts
  cash_on_hand numeric(14, 2),
  updated_at timestamptz not null default now()
);

create table pac_contributions (
  member_id text not null references members (bioguide_id) on delete cascade,
  cycle smallint not null,                       -- the two-year FEC cycle of the bulk file
  committee_id text not null,
  committee_name text not null,
  committee_designation text,                    -- FEC CMTE_DSGN: J joint fundraising, U unauthorized, B lobbyist PAC, D leadership PAC, ...
  committee_type text,                           -- FEC CMTE_TP: Q/N PAC, H/S/P candidate, X/Y/Z party, ...
  org_type text,                                 -- FEC ORG_TP: C corporation, L labor, T trade, M membership, V cooperative, W corporation w/o stock
  connected_org text,
  direct_amount numeric(12, 2) not null default 0,
  earmarked_amount numeric(12, 2) not null default 0,
  primary key (member_id, cycle, committee_id)
);
create index pac_contributions_member on pac_contributions (member_id, cycle, direct_amount desc);

alter table campaign_finance enable row level security;
alter table pac_contributions enable row level security;
create policy "public read" on campaign_finance for select using (true);
create policy "public read" on pac_contributions for select using (true);
