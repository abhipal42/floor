-- Items that failed one by one while a run carried on (a bill Congress.gov will not serve).
-- They used to go in `error`, which /v1/status reports as the source's failure, so a single
-- bad reference marked bills failed on every run (HANDOFF lesson 38). `error` is now only for
-- a run that failed as a whole.

alter table ingest_runs add column failed integer not null default 0;
