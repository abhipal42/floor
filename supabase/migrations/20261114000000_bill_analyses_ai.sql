-- M4 Layer 1: AI analysis of a bill, one row per version of its source.
--
-- The core migration sketched bill_analyses against bill_versions (GPO text versions), which nothing
-- fills yet. What Floor stores today is the latest CRS summary per bill and the stage it describes
-- ("Introduced in House", "Passed House", ...), so that is the version an analysis is of:
-- (bill_id, source_kind, source_stage). A summary that changes within a stage changes source_hash,
-- and the worker regenerates that row; a new stage gets a new row and the old one is kept.
-- bill_version_id stays for a later bill-text analysis and is now optional.
--
-- analysis jsonb: { purpose, provisions[], affectedGroups[], impact[], sourceParagraphs[] }, where
-- every item is { text, citations: [{ paragraph (1-based), quote, section }] } and has passed both the
-- mechanical citation check and the verifier pass. Nothing uncited is stored.
--
-- RLS: bill_analyses already has row level security and a public read policy (core_rls), so
-- everything in it is readable by anyone through PostgREST. That is why it holds only what readers
-- may see. Run bookkeeping — attempts, errors, token counts, cost, and the claims the verifier
-- rejected — lives in bill_analysis_runs, which has RLS on and NO policy: only the worker, on the
-- service role, can read or write it. Re-run Supabase's security advisor after applying this.

alter table bill_analyses alter column bill_version_id drop not null;

alter table bill_analyses
  add column bill_id text references bills (id) on delete cascade,
  add column source_kind text not null default 'crs_summary' check (source_kind in ('crs_summary', 'bill_text')),
  add column source_stage text not null default '',   -- bills.summary_stage the analysis was made from
  add column source_hash text not null default '',    -- sha256 hex of stage || '\n' || summary
  add column prompt_version text not null default '',
  add column verifier_model text,
  add column generated_at timestamptz not null default now(),
  add constraint bill_analyses_subject check (bill_id is not null or bill_version_id is not null);

create unique index bill_analyses_bill_source on bill_analyses (bill_id, source_kind, source_stage)
  where bill_id is not null;

-- One row per attempt target: a bill's source (by hash) at a prompt version. The worker stops
-- retrying a source after 3 failed attempts, so one bad bill can't be billed forever or starve the
-- queue; a changed summary or prompt is a new row and gets fresh attempts.
create table bill_analysis_runs (
  bill_id text not null references bills (id) on delete cascade,
  source_hash text not null,
  prompt_version text not null,
  source_stage text not null,
  attempts integer not null default 0 check (attempts >= 0),  -- failed attempts
  last_error text,
  last_at timestamptz not null default now(),
  succeeded_at timestamptz,
  stats jsonb,          -- counts, tokens per model, cost estimate, the verifier's rejected claims
  primary key (bill_id, source_hash, prompt_version)
);

alter table bill_analysis_runs enable row level security;
-- No policy, deliberately: rejected claims and costs are not for the public API.
