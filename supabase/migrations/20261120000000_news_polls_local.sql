-- v0.2.60: members' news and polls (the News page), and state and city records (the Local tab).
--
-- Headlines are Google News RSS items: title, source, date and link only, never article text
-- (apps/worker/src/news.ts). Kept 14 days. Tone and stories are AI-read and labelled as such.

-- Stories: AI groups of headlines about the same event, with a neutral title the AI wrote.
-- Replaced whole for a member each time their headlines are read.
create table member_news_stories (
  id text primary key,                           -- '<member>:<n>:<read time>'
  member_id text not null references members (bioguide_id) on delete cascade,
  title text not null,
  created_at timestamptz not null default now()
);
create index member_news_stories_member on member_news_stories (member_id);

create table member_news (
  id text primary key,                           -- '<member>:<Google News guid>'
  member_id text not null references members (bioguide_id) on delete cascade,
  title text not null,                           -- the headline, the " - Source" suffix removed
  source text not null,                          -- the publisher as Google News names it
  source_url text,                               -- the publisher's site
  url text not null,                             -- the Google News link to the article
  published_at timestamptz not null,
  -- favorable / neutral / critical toward the member as the headline frames them (AI); office =
  -- from the member's own office or another .gov (set by the worker, never by the AI); null = unread.
  tone text check (tone in ('favorable', 'neutral', 'critical', 'office')),
  story_id text references member_news_stories (id) on delete set null,
  read_at timestamptz                            -- when the AI last read it; null = not yet
);
create index member_news_member on member_news (member_id, published_at desc);

-- When the worker last asked Google News about a member (the hourly budget walks oldest first).
create table member_news_checks (
  member_id text primary key references members (bioguide_id) on delete cascade,
  checked_at timestamptz not null
);

-- Polls that name a member, one file per poll in apps/worker/polls, reviewed in a PR.
create table polls (
  id text primary key,                           -- the file's name without .json
  pollster text not null,
  fielded_from date not null,
  fielded_to date not null,
  population text not null,                      -- "U.S. adults", "registered voters"
  sample_size int check (sample_size > 0),
  positive_label text not null,                  -- as the pollster worded it
  positive_pct numeric not null check (positive_pct between 0 and 100),
  negative_label text not null,
  negative_pct numeric not null check (negative_pct between 0 and 100),
  other_label text,
  other_pct numeric check (other_pct between 0 and 100),
  url text not null check (url like 'https://%'),
  check (fielded_from <= fielded_to),
  check (positive_pct + negative_pct + coalesce(other_pct, 0) <= 100)
);

create table poll_members (
  poll_id text not null references polls (id) on delete cascade,
  member_id text not null references members (bioguide_id) on delete cascade,
  primary key (poll_id, member_id)
);
create index poll_members_member on poll_members (member_id);

-- State bills (Open States) and city council matters (Legistar). Kept 90 days, which is also how
-- far back `coverage: records` looks.
create table local_items (
  id text primary key,                           -- 'openstates:<ocd-bill id>' or 'legistar:<client>:<MatterId>'
  jurisdiction_id text not null,                 -- the registry's id: 'ny', 'nyc', 'seattle'
  identifier text not null,                      -- "S 1234", "CB 121276"
  title text not null,
  summary text,
  body text not null,                            -- "State Senate", "Assembly", "City Council"
  date date not null,                            -- signed / became law / passed / passed the second chamber
  status text not null check (status in ('signed', 'became_law', 'passed', 'awaiting_governor')),
  yes int check (yes >= 0),
  no int check (no >= 0),
  url text,
  updated_at timestamptz not null default now()
);
create index local_items_jurisdiction on local_items (jurisdiction_id, date desc);

-- Each jurisdiction's headlines, like member_news but never AI-read. Kept 14 days.
create table local_news (
  id text primary key,                           -- '<jurisdiction>:<Google News guid>'
  jurisdiction_id text not null,
  title text not null,
  source text not null,
  source_url text,
  url text not null,
  published_at timestamptz not null
);
create index local_news_jurisdiction on local_news (jurisdiction_id, published_at desc);

create table local_checks (
  jurisdiction_id text not null,
  source text not null check (source in ('records', 'news')),
  checked_at timestamptz not null,
  primary key (jurisdiction_id, source)
);

-- Public data like `member_posts`: readable by anyone, written only by the worker (service role).
alter table member_news_stories enable row level security;
alter table member_news enable row level security;
alter table member_news_checks enable row level security;
alter table polls enable row level security;
alter table poll_members enable row level security;
alter table local_items enable row level security;
alter table local_news enable row level security;
alter table local_checks enable row level security;
create policy "public read" on member_news_stories for select using (true);
create policy "public read" on member_news for select using (true);
create policy "public read" on member_news_checks for select using (true);
create policy "public read" on polls for select using (true);
create policy "public read" on poll_members for select using (true);
create policy "public read" on local_items for select using (true);
create policy "public read" on local_news for select using (true);
create policy "public read" on local_checks for select using (true);
