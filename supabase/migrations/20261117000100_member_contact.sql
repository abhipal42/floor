-- How to reach a member's office, from congress-legislators' latest term (apps/worker/src/members.ts).
-- All nullable: many House members have no contact_form upstream (the app falls back to the House's
-- "Write Your Representative" form), and a member-elect may have none of these yet.
-- `members` already has row-level security with its public read policy (20261111000200_core_rls.sql);
-- these are the office's public phone, web form, website, room and mailing address. Upstream's `fax`
-- and `rss_url` are left out: nobody reaches an office by fax, and `ids.rss_url` already holds the feed.
alter table members
  add column phone text,
  add column contact_form text,
  add column website text,
  add column office text,
  add column address text;
