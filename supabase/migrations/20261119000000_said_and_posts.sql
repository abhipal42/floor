-- What members said: their official social accounts, the promises on the campaign site that won
-- them this term, and their recent posts on the networks that can be read for free.
--
-- members.social: {twitter, facebook, instagram, youtube, youtubeId, mastodon, bluesky}, strings or
-- absent. Every field but bluesky is congress-legislators' legislators-social-media.json; bluesky is
-- an account Bluesky itself marks verified (or a .senate.gov / .house.gov handle) whose name is the
-- member's, and absent otherwise: never a guess (apps/worker/src/social.ts).
alter table members add column social jsonb;

-- The campaign site behind the race that won the current term, as the Wayback Machine held it
-- before election day. One row per member once the worker has looked; no row = not checked yet.
create table campaign_sites (
  member_id text primary key references members (bioguide_id),
  election_year smallint not null,               -- the race that won this term (term_start year - 1 for a Jan 3 start)
  site_url text,                                 -- the campaign site as found (the FEC committee's website)
  source text not null check (source in ('fec', 'manual')),
  snapshot_url text,                             -- the Wayback snapshot used (the human URL, not the id_ form)
  snapshot_at timestamptz,                       -- its timestamp, always before election day
  page_url text,                                 -- the issues/priorities page within the site, if one
  status text not null check (status in ('promises', 'no_platform', 'no_site', 'no_snapshot', 'failed')),
  checked_at timestamptz not null default now()
);

-- Verbatim quotes only. The AI picks lines; the worker keeps a line only when `quote` and `headline`
-- are both found in the archived page's text (whitespace and quote marks normalised).
create table campaign_promises (
  id bigint generated always as identity primary key,
  member_id text not null references members (bioguide_id) on delete cascade,
  position int not null,
  heading text,                                  -- the site's own section heading, as written
  quote text not null,                           -- verbatim from the page
  headline text not null,                        -- a clause of `quote`, verbatim, for the deck's big line
  topic text                                     -- one of the 32 CRS policy areas, or null
);
create index campaign_promises_member on campaign_promises (member_id, position);

-- Recent posts from the free networks. Kept about 30 days, at most 30 per member. Never ranked:
-- served newest first, with no like or repost counts (none are stored).
create table member_posts (
  id text primary key,                           -- '<network>:<native id>'
  member_id text not null references members (bioguide_id) on delete cascade,
  network text not null check (network in ('youtube', 'bluesky', 'mastodon')),
  posted_at timestamptz not null,
  text text,                                     -- as posted (YouTube: the video title)
  url text not null,                             -- the original
  media_url text                                 -- a thumbnail if any (YouTube's, the first Bluesky image)
);
create index member_posts_member on member_posts (member_id, posted_at desc);

-- Public data like `members`: readable by anyone, written only by the worker (service role).
alter table campaign_sites enable row level security;
alter table campaign_promises enable row level security;
alter table member_posts enable row level security;
create policy "public read" on campaign_sites for select using (true);
create policy "public read" on campaign_promises for select using (true);
create policy "public read" on member_posts for select using (true);
