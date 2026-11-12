-- Public legislative data is readable by anyone and writable only by the
-- ingest worker, which connects with the service role (bypasses RLS).

do $$
declare t text;
begin
  foreach t in array array[
    'members', 'bills', 'bill_versions', 'actions', 'votes', 'vote_positions',
    'tally_snapshots', 'floor_events', 'statements', 'projections', 'bill_analyses'
  ] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy "public read" on %I for select using (true)', t);
  end loop;
end $$;
