-- A paper filing Floor can't read by machine can still be shown, once transcribed (lesson 73).
-- transcribed_by says who turned the scan into rows: 'ai' is a model reading the pages, which the
-- app labels as AI with "may contain errors" and the link to the original, like every AI line.
-- null means the rows came from the electronic filing itself. The rows are the same tables.
alter table disclosure_filings
  add column transcribed_by text check (transcribed_by in ('ai'));
