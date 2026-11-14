# Handoff: where Floor stands and what's next

Last updated 2026-11-13. Read this first, then [`plan.md`](plan.md) for the full design and reasoning.

**In one paragraph:** M0 (foundation) is done. M1 (data backbone) is done; the one item still open against it, measured posting latency, has moved to M3, because it can only be taken on a live session day with polling running. Staging Postgres holds every House and Senate roll call since January 2023, and every one matches the official totals; every vote now has a subject attached, bills and nominations alike. The API serves district lookup, member votes, votes, bills, nominations and data freshness from that database, and now also the per-party breakdown of a vote, your own delegation's positions on it, and a member's party-loyalty record. **M2 is nearly done:** the API is deployed at <https://floor-api.vercel.app> and a Release build of
the app runs the whole flow against it — onboarding to a real district, then Home, Vote, Bill and
Rep. Since v0.2.3 those screens match the landing page (three tabs: Finals, Bills, Your three). Every
screen now opens on its last-seen data when offline or slow, from a SwiftData cache. Snapshot tests
landed in v0.2.25, with M5's accessibility pass and privacy manifests; one item remains, listed at
the top of the M2 section: TestFlight distribution. **M3's backend is
built but not deployed** (v0.2.24): the live worker, vote state, `/v1/live`, realtime, APNs and
alerting plumbing. Turning it on needs a Fly account and a migration applied; see the M3 section.
**Round 10's server side is built** (v0.2.26): every bill of the Congress (not only voted ones),
a stored road-to-law stage, and `/v1/topics`, `/v1/topics/{name}/bills` and `/v1/search`. It waits
on a migration and a 10–16-hour backfill; see "Round 10" in §5.

---

## 1. Get set up

### Access you need (ask the repo owner)

| What | Why | Who grants it |
|---|---|---|
| GitHub `abhipal42/floor` write access | Open and merge PRs | Repo owner |
| Supabase org "pokator's Org", project **floor-staging** (`uyyocajwihypaiosecvs`, us-east-1) | Database URL for `.env`, dashboard, SQL editor | Sourav (org owner) |
| api.data.gov key | Congress.gov bill data | Sign up yourself at https://api.data.gov/signup (free, instant) |
| The v2 design canvas (claude.ai artifact "Live Vote Tracker – UI Options") | Screen designs for M2 | Sourav (it's private; ask for a share) |

### Local setup

```bash
git clone https://github.com/abhipal42/floor.git && cd floor
npm install
cp .env.example .env    # then fill in the two values (see below)
npm run check           # lint + typecheck + Node tests; must pass before every PR
```

`.env` (never committed):

- `DATABASE_URL`: Supabase → floor-staging → **Connect** → the Postgres connection string (`postgresql://…`), not the `https://…supabase.co` API URL. Use the Session pooler (`postgres.<ref>@aws-1-us-east-1.pooler.supabase.com:5432`): the direct `db.<ref>.supabase.co` host is IPv6-only and fails with `EHOSTUNREACH` on a network without IPv6 (it did from here on 2026-11-13). Close the worker when you are done with it — every open session-pooler connection is one of the 15 slots the whole project shares (lesson 37).
- `CONGRESS_API_KEY`: your api.data.gov key.
- `ANTHROPIC_API_KEY` (only for `analyze` and the analysis eval): a Claude API key. Optional
  overrides: `FLOOR_AI_MODEL` (default `claude-sonnet-5-5`), `FLOOR_AI_VERIFIER_MODEL` (defaults to
  `FLOOR_AI_MODEL`), `FLOOR_AI_EFFORT` (`low` / `medium` / `high`, default `medium`). See M4.

### Run things

```bash
npm run dev -w @floor/api                                         # API on http://localhost:8787, reads .env
npm run ingest -w @floor/worker -- members                        # refresh members
npm run ingest -w @floor/worker -- rollcalls house 119 2          # new House votes this session (resumes automatically)
npm run ingest -w @floor/worker -- rollcalls senate 119 2         # same for the Senate
npm run ingest -w @floor/worker -- rollcalls house current        # the session in progress (what the hourly schedule runs)
npm run ingest -w @floor/worker -- bills                          # load bills that votes refer to (only missing ones)
npm run ingest -w @floor/worker -- bill-catalog                   # every bill of the Congress: list, details where due, stage (1,200 requests max)
npm run ingest -w @floor/worker -- bill-catalog --full --budget 46000 --rate 3000   # the one-time backfill (~16 h, leaves the hourly job room; see Round 10)
npm run ingest -w @floor/worker -- nominations                    # load nominations that Senate votes refer to
npm run ingest -w @floor/worker -- fec-totals                     # campaign totals for every current member (OpenFEC, ~10 min)
npm run ingest -w @floor/worker -- fec-pacs 2026                  # committee-to-candidate totals from the FEC bulk files (~30 s)
npm run ingest -w @floor/worker -- analyze 25                     # AI analysis (M4 Layer 1) of up to 25 bills that need one; costs money
npm run eval:analysis -w @floor/worker -- --out /tmp/eval.json    # the ~50-bill analysis eval; prints "Not run" without ANTHROPIC_API_KEY
npm run ingest -w @floor/worker -- live                           # the always-on live worker (M3); Ctrl-C stops it after the poll in flight
npm run ingest -w @floor/worker -- latency 30                     # roll call posting latency the live worker measured, last 30 days
npm run loadtest -w @floor/api -- --duration 30 --connections 50 # vote-night load test against a LOCAL API (refuses production)
npm run openapi -w @floor/api                                    # regenerate apps/api/openapi.json after changing routes
npm run build -w @floor/web && npm run serve -w @floor/web       # build and serve the landing page from apps/web/dist
swift test --package-path ios/FloorKit                           # all FloorKit tests (317): models, contract, client, screen models, snapshots
```

`apps/api/openapi.json` is the committed contract. Re-run `npm run openapi` after any change to
`app.ts`; CI fails if it has drifted — on `main`, after the merge, so run it yourself first — and
the Swift contract tests check the models against it.

iOS (needs a Mac with Xcode 16+): `brew install xcodegen && cd ios && xcodegen && open Floor.xcodeproj`. CI builds it on a macOS runner on pushes to `main` only, so run
`swift test --package-path ios/FloorKit` locally before you open a PR.
If `swift test` dies with `Library not loaded: … SWBBuildService.framework`, `xcode-select` points at the
Command Line Tools rather than Xcode: run it with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
(or `sudo xcode-select -s` that path).

---

## 2. What exists today

### Repo layout

| Path | What | Key files |
|---|---|---|
| `packages/shared` | Types + roll call parsers (House Clerk XML, Senate LIS XML) + floor-event parsers (House floor summary, Senate schedule, floor page and vote menu) and Eastern-time helpers | `src/rollcall.ts`, `src/floor.ts`, fixtures in `fixtures/` (real government files) |
| `packages/db` | Migration loader used by tests | `src/migrations.test.ts` |
| `supabase/migrations` | Postgres schema (applied to staging in filename order) | 12 migrations; `20261113000100_ingest_failed.sql` (lesson 38), `20261114000000_bill_analyses_ai.sql` (M4), `20261114000100_live_layer.sql` (M3) and `20261115000000_bill_catalog.sql` (Round 10) are **not yet applied** to staging |
| `apps/worker` | Ingest CLI: members, roll calls, bills, nominations, campaign finance, AI bill analysis; the always-on live worker (M3) | `src/cli.ts`, `rollcalls.ts`, `bills.ts`, `catalog.ts` (every bill of the Congress), `stage.ts` (road-to-law stage), `nominations.ts`, `members.ts`, `fec.ts`, `analysis.ts` (M4 Layer 1), `analysis-eval.ts`, `db.ts`; live: `live.ts`, `realtime.ts`, `apns.ts`, `alert.ts`, `Dockerfile`, `fly.toml` |
| `apps/api` | Hono REST API with OpenAPI at `/openapi.json` | `src/app.ts` (routes + schemas), `pg.ts` (Postgres), `bills.ts` (citations, short labels, bill-number parsing, the 32 topics), `district.ts` (Census) |
| `apps/web` | Landing page (v0.2.0): static HTML/CSS/TypeScript built with `tsc`, no framework | `src/data.ts` (every figure, with source and date), `src/logic.ts` (pure helpers), `src/main.ts` (rendering), `public/` |
| `ios/` | SwiftUI app (XcodeGen, `project.yml`), `FloorKit` package: `Models`, `APIClient`, `DesignSystem`, `Onboarding`, `Home`, `VoteScreen`, `BillScreen`, `RepScreen`, `WidgetFeed`; `FloorWidgets/` (the WidgetKit extension) | `FloorKit/Sources/Models/` (one file per area, `Samples.swift` for previews), `FloorKit/Tests/ModelsTests/ContractTests.swift`, `DesignSystem/ScoreboardCard.swift`, `DesignSystem/Components.swift`, `DesignSystem/Fonts/` (Barlow Condensed, OFL), `Home/FloorShell.swift` (tabs), `Home/CatchUp.swift`, `Models/VoteOutcome.swift`, `BillScreen/LawLevels.swift`, `APIClient/ResponseCache.swift` (offline cache), `DesignSystem/SavedDataNote.swift` |
| `.github/workflows/ci.yml` | `scope` job (which parts changed) + node job (lint/typecheck/tests + OpenAPI drift) + macOS job (Swift tests + simulator build). **Pushes to `main` only** since 2026-11-13 — a PR never builds the code — and the macOS job runs only when the push touched `ios/` or `.github/` | |
| `.github/workflows/ingest.yml` | **Hourly ingest** (since v0.2.20): members, then House and Senate roll calls for the session in progress (`rollcalls <chamber> current`), then bills and nominations, one after another in one job, in a `concurrency: ingest` group so a slow run makes the next wait instead of overlapping it. Members runs once a day (06 UTC) and on manual runs; GitHub disables the schedule after 60 days of repo inactivity (lesson 37). **Inert until the repo has a `DATABASE_URL` secret** (session pooler string) and `CONGRESS_API_KEY`; without the first it logs a warning and skips. Adding them needs repo admin (lesson 37) | |
| `.github/workflows/guards.yml` | Shipping guards on every PR (the only workflow that still runs there): changelog, version, docs, tests, retro, PR title | `.github/scripts/guards.conf` (this repo's settings), `guards.sh` (shared, do not edit) |
| `docs/` | `plan.md` / `plan.html` (design + plan), this file, `retros/` (one per milestone) | |
| `VERSION`, `CHANGELOG.md` | Current version (mirrored by `MARKETING_VERSION` in `ios/project.yml`) and what each version shipped | |

### API endpoints (all live against staging)

| Route | Returns |
|---|---|
| `GET /v1/reps?address=` or `?lat=&lng=` | District (119th Congress map) + House member + senators. Send an address *or* coordinates (e.g. from the browser's location), not both. Coordinates are rounded to 4 decimals (~11 m). Either goes only to the Census geocoder and isn't stored or logged. |
| `GET /v1/members/{id}` | A member, plus how often they sided with their own party's majority |
| `GET /v1/members/{id}/funding` | Their current campaign's money: what the campaign reported receiving (small-dollar, itemized, PAC, party, other, cash on hand) and the committees that reported giving to it, biggest direct giver first. `?committees=` (0-50, default 10). No individual donor is named |
| `GET /v1/members/{bioguideId}/votes?limit=` | A member's recent votes with their position (and candidate, for Speaker elections) |
| `GET /v1/votes/{id}` | One vote: totals, threshold, kind, bill link, **per-party breakdown**, and for a Speaker election **which candidate each party backed**. `?members=A000370,C001098` (up to ten) also returns those members' own positions, so the vote screen loads your delegation in one round trip. IDs look like `house-119-1-100` |
| `GET /v1/bills/{id}` | Title, short title, CRS summary, sponsor, policy area, CBO estimates, last 30 actions, every vote on it. IDs look like `119-hr-2207` |
| `GET /v1/bills/{id}/analysis` | AI analysis of the bill's CRS summary (M4 Layer 1): purpose, provisions, affected groups, impact. `ai: true` on the response and on every line, a `disclaimer` to show with it, and per line the summary paragraph it cites (1-based, into `source.paragraphs`), a verbatim quote and the bill section. `source.stale` means the summary has changed since and a new analysis is pending. 404 until the worker has analysed the bill (the app reads that as "none" and saves it like a response). Shown at the top of the Bill screen since v0.2.27 |
| `GET /v1/nominations/{id}` | Nominee, position, agency, received and latest action, every Senate vote on it. IDs look like `119-pn-1093-3` |
| `GET /v1/live?since=` | Each chamber's session state as the live worker last saw it (`inSession`, `convenesAt`, `checkedAt`), and the votes that are `open` (named in the last day) or that the worker published as `final` within `since` minutes (`broadcast_at`; default 120, max 1440) and that were themselves voted in the last day, with `openedAt` / `announcedAt` / `postedAt`. Sent with `Cache-Control: public, max-age=5, s-maxage=5`, so Vercel's edge answers vote-night polling. Empty — `{chambers: [], votes: []}`, not an error — on a database without the M3 migration (Postgres `42P01`/`42703` are read as "nothing live"), and until the worker runs |
| `GET /v1/topics?congress=` | The 32 CRS policy areas in a fixed order, each with its bill count, how many of those had a floor vote, and the latest action date, for one Congress (default: the one in session). Areas with no bills are listed with zeros. Cached (`TOPICS_CACHE_CONTROL`, 5 min / edge 15 min); 120 a minute per caller |
| `GET /v1/topics/{name}/bills?filter=all\|moving\|law\|stalled&cursor=&limit=` | A topic's bills, newest action first, 25 a page (max 50), keyset-paginated: pass `nextCursor` back as `cursor`. Each row: citation, plain short `label`, full title, `stage` (null for a bill not yet fetched in detail, which counts as unsettled), `stalled`, latest action, `hasFloorVote`. The cursor carries the stored action date, so a row with a date but no action text pages correctly. `moving` = not settled and acted on in 90 days; `stalled` = not settled, no action in 90 days (computed per request); settled = law, adopted, vetoed, failed. `name` is case-insensitive (`health`, `Arts%2C%20Culture%2C%20Religion`); 404 for anything not one of the 32, 400 for a cursor it did not issue. Same cache and limit as `/v1/topics`, and one count shared with it (each request counts once) |
| `GET /v1/search?q=` | `{members, bills, topics}` in one call. A bill number in any spelling (`hr 1013`, `H.R.1013`, `s 2`, `hjres 12`, `s.j.res.197`, `119-hr-1013`) returns exactly that bill in every Congress, newest first, with `billNumber: true`, and nothing else. Otherwise words match bills by Postgres full-text search (short title, title, CRS summary; GIN index; current Congress ranked first; 20 max), topics by name, and serving members by name, state (`TX`, `Texas`) or district (`TX-35`, `WY-AL`) via `memberQuery` in `pg.ts` (10 max). Companion bills (the House and Senate versions of one measure) are separate results, not linked. 2–100 characters. Cached 1 min / edge 5 min; 60 a minute per caller |
| `GET /v1/status` | Per ingest source: last successful run, `lastNewDataAt` (last successful run that stored anything — the freshness signal `stale` cannot give once ingest is scheduled, lesson 38), the error of its latest run with an outcome (null once a later run succeeds; `abandoned run` for one that never finished within an hour, lessons 35 and 38), and `stale` |
| `GET /openapi.json` | The contract. The Swift models are hand-written against it, and `ContractTests` fail CI if they drift (see M2). |

### Data in staging (as of this commit)

| Table | Rows | Notes |
|---|---|---|
| `members` | 716 | Everyone serving now, plus anyone whose last term ended after 2022-11-01. One party is corrected on ingest; see lesson 14 |
| `votes` | 3,532 | House + Senate, 118th–119th Congress, Jan 3 2023 → Nov 11 2026. 20 are Speaker elections (`kind = 'election'`). Every vote with a measure reference is linked to a bill or a nomination |
| `vote_positions` | 995,806 | Verified: every vote's positions add up to its official totals; no vote lacks positions |
| `bills` / `actions` | 1,050 / 19,714 | Every bill a vote refers to (531 from the 118th Congress, 519 from the 119th); 976 have a CRS summary. All 2,319 votes on bills are linked (`votes.bill_id`). **Round 10 widens this to every bill of the 119th Congress (19,964 listed on 2026-11-13) once `20261115000000_bill_catalog.sql` is applied and the backfill has run**; until then `stage`, `list_updated_on`, `details_fetched_at` and `search` do not exist and the topic and search routes answer empty |
| `nominations` | 448 | Every nomination a vote refers to; 201 are parts of a split nomination, 10 are military (no named nominee). All 905 nomination votes are linked (`votes.nomination_id`) |
| `campaign_finance` | 512 | One row per current member: OpenFEC totals for their current campaign to date (House 2025–26; senators since their last election), with cash on hand. Of 537 current members, 23 have no totals filed for that campaign and 2 appointed senators (OK, SC) have no FEC ID yet; the page must say so rather than show nothing |
| `pac_contributions` | 103,564 | Per member and giving committee, 2026 cycle: direct and earmarked totals, committee designation, type and organization type. No memo text, no individual names (lesson 23) |
| `bill_analyses` / `bill_analysis_runs` | 0 / 0 | M4 Layer 1: the public analysis, one row per bill and CRS summary stage; and the private run log (attempts, errors, cost, rejected claims; no RLS policy, service role only). Their migration is not applied to staging yet, and no analysis has been generated (no Claude key on the project); see M4 |
| `ingest_runs` | | Every ingest run with item count and error, which feeds `/v1/status`. The live worker writes one per chamber per poll and prunes empty successful runs older than two days (keeping errors, runs that stored something, and the newest per source) |
| `floor_events`, `chamber_status`, `votes.announced_at` / `posted_at` / `broadcast_at` | 0 | M3. The migration sets `broadcast_at` on every vote already final (to its `occurred_at`), so the worker's first poll announces none of them. Written only by the live worker, after `20261114000100_live_layer.sql` is applied (not yet) |

Verification query (should return zeros for the last four columns):

```sql
with pos as (select vote_id,
  count(*) filter (where position='yea') yea, count(*) filter (where position='nay') nay,
  count(*) filter (where position='present') present, count(*) filter (where position='not_voting') nv,
  count(*) filter (where position='candidate') cand from vote_positions group by vote_id)
select count(*) votes,
  count(*) filter (where p.vote_id is null) without_positions,
  count(*) filter (where v.kind='question' and (coalesce(p.yea,0)<>v.yea or coalesce(p.nay,0)<>v.nay
    or coalesce(p.present,0)<>v.present or coalesce(p.nv,0)<>v.not_voting)) question_mismatches,
  count(*) filter (where v.kind='election' and coalesce(p.cand,0) <>
    (select coalesce(sum((c->>'total')::int),0) from jsonb_array_elements(v.candidates) c)) election_mismatches
from votes v left join pos p on p.vote_id = v.id;
```

---

## 3. Things we learned the hard way

Real data broke our first assumptions several times. Each case below is now handled and tested; keep them in mind.

1. **Speaker elections aren't yea/nay.** Members vote for a candidate ("Jeffries", "McCarthy"). These are stored as `kind='election'` with `votes.candidates` and `vote_positions.position='candidate'` + `choice`. The UI needs an election variant of the scoreboard card.
2. **Concurrent ingests can deadlock.** Running House and Senate at once hit `deadlock detected`. Upserts now retry on `40P01`/`40001`, and each vote and its positions are written in **one SQL statement**, so a vote is never half-saved. Each run also refetches any vote that has no positions.
3. **Members-elect can appear on roll calls.** Rep. McEachin died after re-election but is on the first 2023 roll call. The member window starts 2022-11-01 for that reason.
4. **Census "Current" maps run ahead of Congress.** The geocoder's current vintage already returns the **120th** Congress districts (post-redistricting), but members serve 119th districts until Jan 3 2027. `district.ts` pins `ACS2025_Current` for the 119th. **Switch `CONGRESS` to 120 on Jan 3, 2027.**
5. **Congress.gov sub-resources are links, not arrays.** `bill.titles`, `summaries` and `actions` come back as `{count, url}`; each needs its own request. Use the `list()` guard in `bills.ts`.
6. **Measure references differ by chamber.** The House writes `H R 2207` / `H CON RES 14`; the Senate writes `H.R. 2207` / `S.J.Res. 10` / `PN1093-3`. `parseMeasureRef` normalizes both and recognizes nominations.
7. **Never log Congress.gov URLs.** They contain the API key. `congressClient` errors print only the path.
8. **Row-level security is on for every table.** Public tables are read-only via a `public read` policy, and only the service connection writes. `ingest_runs` has no public policy. Supabase's security advisor reports zero issues; re-check it after any migration.
9. **Congress.gov short titles include titles for *portions* of a bill.** Big measures carry a short title per
   division, tagged `… for portions of this bill`, at the same stage as the real one. Taking the first match made
   H.R. 2670 (118th) read "Radiation Exposure Compensation Act Amendments" instead of "National Defense
   Authorization Act for Fiscal Year 2024". `pickShortTitle` now drops portion titles. Bills whose only short
   titles are portion titles (some appropriations bills) correctly end up with `short_title = null`, so clients
   must fall back to `title`.
10. **Summaries are ordered by stage, not by `updateDate`.** Congress.gov reindexes summaries in arbitrary order:
   H.R. 3746 (118th) has its Public Law summary stamped three minutes *before* its Passed Senate one. Sort on
   `actionDate`.
11. **Congress.gov sub-resources page at 20 by default.** `/titles` was fetched without a limit, so bills with
   more than 20 titles (H.R. 815 of the 118th has 44) were silently truncated. Pass `limit=250`, as `/actions` does.
12. **A nomination's parts are separate Congress.gov records.** The Senate cites a split nomination as
   `PN1093-3`, and `/nomination/119/1093` is *not* that nominee — it is the undivided original, with no
   actions and no `latestAction`. The part is its own record at `/nomination/119/1093-3`, whose `partNumber`
   is the zero-padded `"03"`. Fetching the base number instead would attach the wrong nominee to the vote.
13. **Military nominations name no nominee.** They promote officers in bulk, so they carry no `description`
   at all — only `nominees[].positionTitle` ("Major General"), `organization` ("Air Force") and an
   `introText`. `nominations.nominee_name` is null for those, so clients must fall back to position and
   organization.
14. **congress-legislators had a member's party wrong.** It lists Kevin Kiley (CA-3) as
   "Independent" for the 119th Congress; his 118th-term entry says "Republican", he voted for
   McCarthy in the January 2023 Speaker election, and he sides with the House Republican majority on
   88% of the 1,879 roll calls we hold against 42% with the Democrats. As the only "I" member in the
   House he put a spurious one-vote third-party row on the party breakdown of nearly every House
   vote. `PARTY_OVERRIDES` in `members.ts` corrects him, keyed by Bioguide ID **and term start** so
   the override lapses at his next term instead of outliving the upstream error. Genuine
   independents are untouched. Re-run `ingest members` after changing it. Worth reporting upstream.
15. **Party loyalty is meaningless for a party of one.** "Voted with their party" compares a member
   with the majority of their own party, so for an independent it compares them with themselves and
   always reads 100%. `partyLoyalty` therefore skips any vote where fewer than five of the member's
   party voted, as well as votes where the party split evenly. Sanders and King come back with
   `votes = 0`, and clients must show no figure rather than a figure that means nothing. If we ever
   want a real number for them it needs a notion of which caucus they sit with — the data says both
   vote with the Democratic majority about 92% of the time.
16. **A Speaker election's `result` is the ballot's leader, not a winner.** On every one of the 20
   Speaker ballots since 2023, `votes.result` holds the name of whoever led *that ballot* — and only
   3 of those 20 actually elected anyone. Showing `result` as the outcome would have the app announce
   Jeffries as Speaker off the tenth ballot of January 2023. A Speaker needs a majority of the votes
   cast **for a person**, so members voting present lower the bar: McCarthy was elected with 216 of
   428 on the fifteenth ballot, which a flat 218 threshold misses. `Vote.electedSpeaker` in the Swift
   models implements this; `Vote.leadingCandidate` is the weaker, always-valid question.
17. **zod-openapi can hoist `nullable` onto a shared component.** Registering a component and then
   using it nullably *before* any non-nullable use moves `nullable: true` onto the component itself,
   which makes it nullable at every `$ref` — including uses that must not accept null. `LatestAction`
   is nullable at both of its uses so it is correct there, and an `app.test.ts` case asserts it is the
   only component carrying component-level nullability. Check how a component is used before widening
   that list.
18. **Applying migrations to staging:** apply each new file in `supabase/migrations` in order (Supabase SQL editor or `supabase db push`). Tests run all migrations against PGlite, so a migration that breaks shows up in `npm run check` first.
19. **The Census coordinates lookup answers in a different shape.** `geographies/coordinates` puts
    the layers straight on `result.geographies`; `geographies/onelineaddress` nests them under
    `result.addressMatches[0].geographies`. A point outside the U.S. (we checked London) is not an
    error: it comes back `200` with an empty `geographies` object. `parseCensusDistrict` reads
    both shapes and returns null for the empty one, which `/v1/reps` turns into a 404.
20. **Portraits come from `unitedstates.github.io/images/congress/<size>/<bioguide>.jpg`.** The
    `theunitedstates.io` host for the same project failed its TLS handshake from here (2026-11-12).
21. **A `.safeAreaInset` on a `NavigationStack` does not reach the screens pushed onto it.** The
    floating tab bar covered the bottom of every pushed Vote and Bill screen until the inset moved
    onto each screen itself.
22. **The count and the record can disagree, and the record wins.** A Vice President breaks a 50–50
    tie ("Motion Agreed to"), a unanimous-consent agreement sets 60 on a vote the API reports as
    majority, and the arithmetic counts "present" where the House doesn't. `ThresholdLine` then
    reports `contradicted` and no over/short, so nothing prints "1 short" under AGREED. And
    **"Veto Sustained" is a failure**: the veto stands and the override lost. Found by review of
    v0.2.3, not by data, so watch real results for wordings the lists in `recordedOutcome` miss.
23. **FEC committee-to-candidate rows are not all PAC checks, and none fit a $10,000 cap.** The bulk
    file (`pas2`) mixes three kinds of money under transaction type `24K`:
    - **Earmarked contributions:** individuals' money a committee passes through (MORPAC, AIPAC PAC).
      Only the memo text says so ("EARMARK FROM …"), and that memo **names the individual**. The
      importer reads the memo for the word EARMARK, then drops it, so no donor name is ever stored
      (product rule). Jeffries' MORPAC row is $10,000 direct plus $30,747 earmarked.
    - **Joint fundraising transfers** (committee designation `J`, e.g. "Johnson Leadership Fund", $1M)
      and **party committees** (type `X`/`Y`/`Z`, e.g. NRSC, $62,000). Neither is a PAC check;
      `isPac()` leaves both out.
    - Even then about 280 PAC rows exceed $10,000, legally: the limit is $5,000 *per election*, and
      one two-year cycle can hold a primary, a runoff, the general and old debt. Never present a
      cycle total as "the maximum" without checking which elections it covers.
    Voided checks are negative rows that net out; amended filings repeat a transaction, so keep the
    latest filing per committee and transaction ID.
24. **OpenFEC allows 60 requests a minute on our key**, not per hour (`x-ratelimit-remaining`
    refills within a minute). One totals call per member loads all 535 in about 10 minutes. Totals
    are what the *campaign* reported receiving; `pas2` is what *committees* reported giving. The two
    disagree (Jeffries: $2.77M vs $2.53M from PACs), so label each by its source.

25. **The dark palette's outcome colours fail on white.** Mint `#34D399` reads at about 1.9:1 on
    white and the threshold yellow `#FACC15` at about 1.5:1, so light mode cannot reuse them. Every
    text colour in light mode is a darker partner of its dark value (yea `#0B7A57`, nay `#A8481A`,
    threshold `#8A6500`), and `PaletteTests` checks each one at 4.5:1 on the ground, panels and cards.
26. **A screen's secondary requests must neither blank nor hide.** The models loaded the bill
    under a vote with `bill = try? await api.bill(...)`, which writes nil when it fails. Harmless
    with one pass; with the offline cache's second (network) pass it blanked the level the saved
    pass had just drawn. The first fix (keep what is on screen) then hid the problem instead: the
    vote refreshed, the bill silently stayed saved, and the screen claimed to be fresh. So every
    best-effort load (the vote's bill, the bill's member positions, the loyalty rings) goes through
    `Pass.bestEffort`, which falls back to the saved copy *and records that it did*, keeping the note
    up. Any new best-effort load must use it.
27. **The simulator cannot be taken offline on its own; swap what serves the API's port instead.**
    It shares the Mac's network, and cache keys carry the host and port, so two builds pointed at
    different URLs do not share a cache. Use one Debug build (it talks to `localhost:8787`) and swap
    the server behind that port: one that answers (the API, or the captured fixtures in
    `Tests/ModelsTests/Fixtures`), then one that accepts and never answers (weak signal: the note
    reads "refreshing…" for the 60 s request timeout, then "Offline"), or nothing at all (refused:
    "Offline" at once). The delegation can be seeded without typing an address via `simctl spawn
    <udid> defaults write app.floor.ios floor.delegation.v1 -data <hex of the JSON>`. Two traps:
    this Mac's Xcode-beta has no Simulator.app GUI, so nothing can tap the app (`simctl` cannot);
    and the deployed API answered 500 on `/v1/members/…` on 2026-11-13 while the cache was being
    checked, so do not assume it is up.
28. **The local web server lets the browser cache.** `serve.mjs` sends no cache headers, so after a
    rebuild a normal reload kept the old CSS and title. Hard-reload (Ctrl+Shift+R) before judging a
    change at `localhost:8790`; the deployed site is unaffected.
29. **A delegation is not always three, and district 0 means two things.** `/v1/reps` for D.C.
    (38.8977, −77.0365) returns one member — Norton, `chamber: house`, `district: 0` — and no
    senators; Wyoming's at-large seat (Cheyenne) is also `district: 0`, with two senators. Code that
    printed the number straight out wrote "R-WY-0" and "D-DC-0". Use `Member.seatBadge` /
    `seatCaption` / `title` (`Delegate`, `Resident Commissioner` for Puerto Rico), which know both
    cases, rather than formatting `district` by hand. Norton's House record is real — 616
    party-counted votes, nearly all "On Agreeing to the Amendment" — because delegates vote in the
    Committee of the Whole but not on passage.
30. **XcodeGen writes its own version numbers unless told not to.** With `info.properties` set and no
    `CFBundleShortVersionString`, the generated `Info.plist` said `1.0` / `1`, so a build reported
    1.0 whatever `MARKETING_VERSION` was. `project.yml` now maps both keys to `$(MARKETING_VERSION)`
    and `$(CURRENT_PROJECT_VERSION)`; check the built app's plist, not the spec, if it ever looks off.
31. **`CLLocationManager` calls `locationManagerDidChangeAuthorization` the moment its delegate is
    set**, with `.notDetermined`. A permission request that resumes on the first callback returns
    before the person has answered. `CoreLocationProvider` waits for a determined status.
32. **A mock's faint grey can fail the contrast test it was never measured against.** LocApp's
    privacy line is `#6B7280`, which reads at 4.1:1 on the dark ground and 3.3:1 on a card. As a
    text token it would fail `PaletteTests`, so `textFaint` is `#858B95` in dark (5.8:1 on the
    ground) and `#636E69` in light (4.6:1). Check a new text colour against the ground, panels and
    cards before taking it from a mock.
33. **`campaign_finance.cycle` and `pac_contributions.cycle` are different things, and joining on
    them silently empties the Senate.** The first is the election a campaign is *for* — 2028 for a
    senator elected in 2022, 2030 for one elected in 2024. The second is the two-year FEC bulk file
    the committee rows came from, currently 2026. `/v1/members/{id}/funding` first matched one to
    the other, which looked right and passed every seeded test: House members are up every cycle,
    so for them the two numbers agree. Against staging, Schumer (2028), Gillibrand (2030) and
    Murkowski (2028) each came back with totals and **zero committees** — a senator up in 2028 is
    still taking PAC money in the 2026 cycle. The query now takes the most recent cycle held for
    that member, and the response carries `committeesCycle` next to `cycle` so a client can say
    which period the committee list covers instead of implying it matches the campaign's.
34. **In the browser pane, a programmatic scroll right after a viewport change can fire no `scroll`
    event at all.** Testing the floating header, `scrollTo({top: 2445, behavior: "instant"})` moved
    the page and the bar stayed docked; a fresh listener attached just for the check counted **zero**
    scroll events while `scrollY` went from 0 to 2445. It happens just after `resize_window` switches
    device emulation (any width under 768px emulates a phone). Real wheel input fired events and the
    bar behaved every time, so it was the harness, not the code — but it reads exactly like a bug. Test
    scroll-driven UI with real wheel scrolls, and if a scripted scroll seems to do nothing, count the
    events before debugging the handler. Two related traps on this page: `html` has
    `scroll-behavior: smooth`, so a plain `scrollTo` is still in flight when you read `scrollY` (pass
    `behavior: "instant"`), and an instant jump across six pinned sections takes over a second to
    settle while they re-measure.
35. **`/v1/status` reported errors that were already fixed.** On 2026-11-13 it showed
    `house_rollcalls` failing with `Unknown vote position: "Jeffries"` and `senate_rollcalls` with
    `deadlock detected`, which read as two live ingest bugs. `ingest_runs` said otherwise: both
    errors came from the first backfill, 2026-11-12 04:19–04:24 UTC, and every later run of both
    sources succeeded. The "Jeffries" runs (ids 2 and 6, 1 item each) failed on the January 2023
    Speaker ballot minutes **before** election support was committed (9e9de64, 04:23:45 UTC); run 10
    then stored all of 118-1, and all 20 Speaker ballots in the database parse today. The status
    query took the latest error *ever* recorded, so a superseded failure stayed on the page for good.
    `lastError` is now the error of the most recent finished run, null once a later run succeeds.
    The parser also gained a second election signal — the question "Election of the Speaker" — so
    a ballot whose file lacked the `<totals-by-candidate>` block would still parse; checked against
    all 20 real ballots with that block cut out, the counted totals match on every one (on 5 of
    them, candidates tied on votes come out alphabetical instead of in the Clerk's order).
36. **The one recorded deadlock was a migration landing mid-backfill.** Senate run 8 failed with
    `deadlock detected` at 04:23:44.4 UTC; Supabase's `schema_migrations` stamps the elections
    migration — `alter type vote_position add value`, `alter table votes`, `alter table
    vote_positions` — at 04:23:43, while that run was upserting into those tables. The retry on
    `40P01` did not exist yet (c350de4, 04:25:18). So it was not two cron jobs: there was no cron
    job (lesson 37). What the worker now does: waits double and are jittered between five attempts
    (`withRetry`), so a short migration is outlasted rather than fatal. Ordering is *not* the
    defence against two ingests writing the same vote, and does not need to be: `upsertRollCall`
    upserts the `votes` row first, and that row lock makes the second writer wait for the first to
    commit before it touches any position. (Positions are still written in member-ID order and
    deduplicated by `positionRows`, which makes the write deterministic and stops a member listed
    twice from failing the vote.) Apply a migration that alters `votes` or `vote_positions` when no
    ingest is running.
37. **Nothing ran the ingest on a schedule.** No workflow, cron, `pg_cron` job (the extension is
    not installed) or host timer called the worker: every row in `ingest_runs` was typed by hand, and
    the last roll-call run was 2026-11-12 04:30 UTC, so the House votes of 12 November (rolls 322
    and 323) were never stored and both roll-call sources went `stale` 24 hours later. That — not a
    parse error — is why ingest looked stuck. `.github/workflows/ingest.yml` now runs hourly (members
    once a day, at 06 UTC), but **it needs `DATABASE_URL` and `CONGRESS_API_KEY` as repository
    secrets, which only a repo admin can add** (our access is write, not admin). **GitHub disables a
    scheduled workflow after 60 days without activity in a public repo**, and says so only by email:
    if the data goes quiet with no error, check the workflow is still enabled before anything else. Related: on 2026-11-13 something hit
    `EMAXCONNSESSION max clients reached in session mode - pool_size: 15`. That is Supavisor's
    *session* pooler (port 5432), where every open connection holds one of 15 slots shared by the
    API, the worker and anyone at a SQL prompt. The API now passes its pool to Vercel's
    `attachDatabasePool`, because a suspended function runs no timers and would otherwise keep its
    idle connection open, drops idle connections after 5 s, and warns at boot if `DATABASE_URL` is
    not the transaction pooler (`poolerMode` in `pg.ts`); the worker uses one connection, not two.
    The code is already transaction-mode safe — node-postgres prepares only statements given a
    `name` and the `Db` interface cannot pass one, and nothing sets session state. **What remains is
    in the Vercel dashboard:** confirm `DATABASE_URL` for `floor-api` ends in `:6543` (this file
    says it should; the error says something connected in session mode), then force a redeploy. The
    worker should stay on 5432: it is one connection at a time, and session mode is what a script
    holding a connection for many statements expects.
38. **Once ingest is scheduled, `stale` stops meaning "the data is current".** `stale` asks
    whether a run *succeeded* recently, and an hourly job succeeds every hour whether or not
    anything new arrived — including when the Clerk moves its files, a parser starts finding
    nothing, or Congress is simply out. So `stale` alone no longer catches an upstream break.
    `/v1/status` now also reports `lastNewDataAt`, the latest successful run that stored anything;
    a gap there during a session week is the signal. Two more ways the status page could mislead,
    both fixed in v0.2.20: a run that died without recording an outcome (killed runner, a throw
    before its `try`) used to vanish from the status, so the success before it stood — it now
    reads as `abandoned run` an hour after it started, and every ingest records an outcome on every
    path. And one bill or nomination Congress.gov will not serve used to set the run's `error`
    ("1 bills failed") on every run, pinning the source as failed for as long as the reference
    existed; per-item failures now go in `ingest_runs.failed` (migration
    `20261113000100_ingest_failed.sql`) and `error` is only for a run that failed as a whole. The
    worker still closes runs on a database without that column, so applying it can follow the
    deploy, but apply it.
39. **An API change can break the Swift tests without touching `ios/`, and nothing runs them.**
    v0.2.13 added the `PacCheck`, `Funding` and `MemberFunding` schemas to `openapi.json`;
    `ContractTests.everySchemaIsModelled` failed from then until v0.2.21. CI's macOS job runs only
    when a push touches `ios/` or `.github/`, and PRs build nothing, so eight releases went by red
    and unseen. After any change to `apps/api/src/app.ts`, run `swift test --package-path ios/FloorKit`
    too, even if no Swift changed.
40. **CRS summaries are the only AI source we have, and they label their own sections.** Of 1,049
    stored bills, 976 have a summary; `bill_versions` is empty (no bill text is ingested), so M4
    Layer 1 analyses the summary, keyed by its stage. Long summaries say which section each paragraph
    covers — "(Sec. 101) This section provides…" — so the analysis reads the section off the cited
    paragraph instead of trusting the model to name one. Lengths run from a sentence (a post office
    naming) to ~292k characters (a continuing resolution with many divisions): median 762, 90th
    percentile ~1,750 (2026-11-13). Paragraph splits are the `\n\n` that `htmlToText` writes, so a
    change to `htmlToText` renumbers every citation and must bump `PROMPT_VERSION`.
41. **No official source says a vote has opened.** Checked against real files on 2026-11-13:
    - The **Clerk's floor summary** (`clerk.house.gov/floor/YYYYMMDD.xml`) lists a recorded vote as one
      action that already carries its roll number, result and tally: *"On agreeing to the resolution
      Agreed to by recorded vote: 215 - 209 (Roll no. 319)"*. Its `action_time` (6:20:53 p.m.) is the
      vote's start, but the entry's `update-date-time` is 6:32 — about when the vote ended, and the same
      stamp as roll 318's. Whether the entry first appears earlier, mid-vote, can only be seen by polling
      on a session day (the live worker logs it: `announcedAt` vs `openedAt`).
    - **senate.gov has no per-action feed.** `legislative/LIS/floor_activity/...` daily files are gone
      (see lesson 42); what exists is `legislative/schedule/floor_schedule.json` (the next convening,
      rewritten two minutes after the Senate adjourned on 2026-11-12), `legislative/floor_activity_pail.htm`
      (the last meeting's convene and adjourn times) and the LIS vote menu
      (`roll_call_lists/vote_menu_{congress}_{session}.xml`), which lists a vote with its result and no time
      of day. The Democrats' and Republicans' floor pages are end-of-day wrap-ups.
    - So the worker's `open` means "on the record, roll call XML not posted yet". For "vote open" while
      members are still voting, the candidate is **live.house.gov's own JSON API**
      (`liveproxy-azapp-prod-eastus2-003.azurewebsites.net`, routes `/latest/floor`, `/latest/votes`, a
      websocket), found in its page script. It is undocumented and its host is an Azure app name, so it is
      **not used yet**; it answered `200` and `[]` from `/latest/votes` out of session. Try it on a session
      day before building on it.
42. **senate.gov answers a missing page with `200`.** `floor_activity/2026/11_12_2026_Senate_Floor.xml`
    (the pattern its own 2014-era index links to) returns HTTP 200 and an HTML page whose
    `<meta name="description">` is "404 Error Page". Check the body, not the status: the worker requires
    `<legislative_activity` in a House floor file and an XML root in every parser for the same reason
    (the Clerk does the same for roll calls; see `fetchRollCall`).
43. **senate.gov refuses a burst.** On the first real-site run the roll call ingest refetched ~260 Senate
    files back to back (a test database whose votes had no positions, so each was "repaired"), and the
    very next request — `floor_schedule.json` — got **HTTP 403**. It was 200 again within a minute. The
    worker survives it (each step fails on its own and the next poll retries), but anything that sends
    hundreds of requests to senate.gov at once should pace itself. The live worker now does: it backs off
    a host for 30 s after a 403 or 429 (doubling to 5 min), polls senate.gov every 10 s only while the
    Senate sits, and re-fetches position-less votes at most hourly instead of every poll.
44. **The vote menu lists the whole session.** Treating every menu vote not stored as `final` as "open"
    announced all 262 of 2026's Senate votes as open against an empty table. Two rules now: only votes
    after the newest stored `final` roll are stored as `open` at all (an older gap is the roll call
    ingest's to repair), and of those, only a vote dated today (Eastern) or seen by a poll under 60 s
    after the previous one is *news* — announced and broadcast. Anything else (the worker was down, or
    this is its first run against a fresh table) is stored quietly, with no `announced_at`. The House
    floor summary follows the same news rule. `lastRollNumber` counts only `final` rows, or an `open` row
    would make the ingest start one past a vote it has never fetched.
45. **`.font(.system(size: 13))` ignores Dynamic Type completely.** Every screen shipped with fixed
    sizes, and nothing looked wrong, because nobody had their text size changed. A fixed point size
    is not "13 at the default and more when asked"; it is 13 always. `scaledFont` keeps the mock's
    size at the default and scales from there, and the AX5 snapshots are what catch the next row
    that cannot hold it. Related: SwiftUI's `accessibilityReduceMotion` is read-only, so a test or a
    preview cannot ask for the settled frame through it — hence `playsArrivalAnimations`.

46. **Most bills of a Congress never reach a vote, and the House reserves numbers.** On 2026-11-13
    Congress.gov listed 19,964 bills and resolutions for the 119th Congress; 519 of them had a roll call.
    The list also carries placeholders the House holds for its leadership — H.R. 1–11 read "Reserved for
    the Speaker." or "Reserved for the Minority Leader." with no action, sponsor or text — and the catalog
    skips them (a number later introduced for real changes title and `updateDate`, and is listed then).
47. **The bill list's `updateDate` is a date, not a time.** `/bill/{congress}` gives `2026-11-12`, while a
    bill's own detail says `2026-11-12T05:53:39Z`. So an incremental run cannot ask "changed since my last
    run": it lists from a day before the newest date stored, and a bill fetched during the day it changed
    is fetched once more after that day ends (`detailsDue` in `catalog.ts`), or a second change the same day
    would go unseen. `fromDateTime` works without `toDateTime`. Offset paging over a list sorted by update
    date can skip a row when a bill earlier in it is updated mid-run, so the daily 06 UTC run re-lists in
    full (~80 requests).
48. **Most bills have no CRS summary, and the display title usually is the short title.** Of 30 random
    119th-Congress bills, 8 had a CRS summary (CRS writes them weeks to months after introduction) and all
    30 had a policy area. Full-text search over summaries therefore finds mostly voted and older bills;
    titles carry the rest. Congress.gov's `title` is the short title when the bill had one at introduction
    (306 of the 326 stored 118th-Congress bills with a short title showed it as `title`), so the catalog
    fetches `/titles` only when the title reads like an official one ("To amend …", 62 of 750 listed):
    about 2.35 requests a bill on average instead of 4.
49. **Presented, vetoed and signed are House actions too, not only markers.** "Presented to President.",
    "Vetoed by President." and "Signed by President." appear under the House's source system as well as
    Library of Congress markers, so the stage reads them from any action's text. A veto override that
    fails is its own marker ("Failed of passage in House over veto"), not "Failed of passage/not agreed
    to", so H.R. 131 (119th) stages as `vetoed`, not `failed`.
50. **A failed suspension vote is not a failed bill.** "Failed of passage/not agreed to in House On
    motion to suspend the rules and pass the bill …" is the same marker a real defeat gets, but a
    suspension needs two thirds and the House can still pass the bill under a rule. In staging on
    2026-11-13, four 119th-Congress bills carried that marker with no later passage — among them
    H.R. 9238 (198–218) and S. 2503, which had passed the Senate and then fell short in the House
    264–133, a majority. Both would have staged `failed` (settled, so hidden from "moving"); they
    stage `introduced` and `passed_senate`.
51. **Our api.data.gov key's limit is 20,000 requests an hour, not 5,000**, and every response says
    how many are left: `X-RateLimit-Limit: 20000`, `X-RateLimit-Remaining: 19944` on 2026-11-13. The
    catalog reads `X-RateLimit-Remaining` and stops below 500, so it yields to the per-vote and
    nominations steps and the live worker however much they spent. The 4,500-an-hour default pace
    was set for a standard 5,000 key and is left there: it is the safe figure if the key is ever
    replaced, and `--rate` raises it. A listing row can also lack `updateDate`; none has been seen,
    and the catalog skips and counts such a row rather than store it with no high-water mark.

---

## 4. Finish M1 (small)

1. ~~Finish the bill load~~ **Done** (1,049 bills, 0 failures). As new votes arrive, re-run `npm run ingest -w @floor/worker -- bills`; it only fetches bills not yet linked. This should always return `0`:
   ```sql
   select count(*) from votes where bill_id is null and bill_ref is not null and bill_ref !~ '^(PN|QUORUM|ADJOURN|Treaty)';
   ```
2. ~~Spot-check 5 bills~~ **Done**, and it found three mapping bugs (lessons 9-11 above), now fixed with tests on
   saved real responses. Title, sponsor, introduced date, policy area and latest action were correct on all five.
   Measured against the API on two samples: a random 60 bills were 100% correct, but of the 58 largest bills
   (omnibus, appropriations, NDAA, reconciliation) **36% had the wrong `short_title` and 16% the wrong
   `summary_stage`** — exactly the bills the app will show most.
   **Staging has been repaired.** All 1,049 bills were rebuilt with `bills --refresh`, 0 failures, and both
   samples then came back **0% wrong**: H.R. 2670 (118th) now reads "National Defense Authorization Act for
   Fiscal Year 2024", H.R. 1 (119th) "One Big Beautiful Bill Act". Use the same command whenever a mapping fix
   means stored rows need rebuilding (~1s per bill, so ~18 minutes for all of them):
   ```bash
   npm run ingest -w @floor/worker -- bills --refresh
   ```
   It re-fetches each stored bill and leaves `votes.bill_id` alone.
   One case is still imperfect: H.R. 815 (118th) was gutted and replaced by the Senate, and `pickShortTitle`
   ranks "as Passed House" and "as Passed Senate" equally, so it keeps the House title. Ranking the chambers by
   which acted last would fix it.
3. ~~Nominations~~ **Done** (448 nominations, 905 votes linked, 0 failures). `nominations.ts` follows the
   `bills.ts` pattern, with the same `--refresh` mode and tests on saved real responses, and the API exposes
   `/v1/nominations/{id}`. As new Senate votes arrive, re-run it; this should always return `0`:
   ```sql
   select count(*) from votes where nomination_id is null and bill_ref ~ '^PN';
   ```
   Checked beyond that count: Congress.gov stamps the confirmation vote's number into the nomination's latest
   action, and for all 446 nominations that carry one, that exact roll call is the one we linked — so the part
   mapping (lesson 12) is right across the whole set, not just the samples.
4. **Posting-latency measurement (moved to M3).** We can only measure how long the Clerk and LIS take to post roll call files on a live session day with polling running. The live worker now records it (`votes.posted_at`); `npm run ingest -w @floor/worker -- latency` reports it once the worker has run through a session.

---

## 5. Remaining milestones

The working rhythm: break each milestone into tasks. For each task, write tests on real saved data first, then build and run `npm run check`. Ship it as a short branch and a PR into `main` — bump `VERSION` (and `MARKETING_VERSION` in `ios/project.yml`), add a `CHANGELOG.md` entry, and title the PR `vX.Y.Z type: summary`. The `guards` check must be green before merging, but it does not build anything: `ci.yml` runs on `main` after the merge, so the local commands in `CLAUDE.md` › Before every PR are the real gate, and a red trunk is reverted rather than left. A MINOR bump (a milestone) also ships a retro in `docs/retros/`. The full rules are in [`CLAUDE.md`](../CLAUDE.md#shipping).

### M2: iOS core on real data
**Goal:** a TestFlight build that shows how your reps voted, from real data. No live updates yet.

> **M2 is not finished.** The app works end to end against the deployed API — onboarding, Finals,
> Vote, Bill and Your three, all on real data — but two items from the list below are still open
> (items 1 and 2 are kept for the record):
>
> 1. ~~**The Speaker election card on Home.**~~ **Done in v0.2.3** (`ScoreboardCard`'s Speaker-ballot
>    variant, "MAJORITY OF NAMES"). What it was: Built on the Vote screen, never on the feed. `HomeView`
>    hands every vote to `ScoreboardCard`, and a Speaker ballot has `yea: 0, nay: 0`, so it renders
>    as "0 … Final … 0, Needs 1" — a meaningless card, under a row summary that is correct
>    ("Doggett voted Jeffries"), which makes it look like bad data rather than a missing variant.
>    Rare today (one member has a ballot in their last 25 votes) but it is the top of every feed in
>    January of a new Congress, fifteen times over in a contested one. Smallest of the four and the
>    only one that is visibly wrong.
> 2. ~~**SwiftData offline cache.**~~ **Done.** How it works:
>    - **What is stored:** the JSON body of every successful response a screen reads, exactly as
>      sent, with its fetch date — one SwiftData row per key (`CachedResponse` in
>      `APIClient/ResponseCache.swift`), in `Caches/FloorResponses.store`, so the system may purge it
>      and it is not backed up. The key is host (and port), path and percent-encoded query:
>      `floor-api.vercel.app/v1/members/D000399/votes?limit=25`. The host keeps a Debug build's
>      localhost responses apart from the deployment's; the encoded query keeps a value holding `&`
>      or `=` from reading as another parameter. Bodies, not an `@Model` per type: the screens already
>      decode them, `ContractTests` already pins their shape, and a second schema for the same types
>      is a second place for the contract to drift. A body the current build cannot decode is a miss.
>    - **What is not:** `/v1/reps?address=` (the key would be the street address; the district and
>      members are already kept by `UserDefaultsDelegationStore`, unchanged) and `/v1/status` (a
>      saved freshness report is wrong by its own age). `FloorAPI`'s default session has **no
>      `URLCache`** (`FloorAPI.defaultSession`, `.reloadIgnoringLocalCacheData`): the shared session's
>      would have written the address lookup to `Caches/Cache.db`. Changing district
>      (`startOver`) clears the cache before onboarding shows, since the old members' entries name
>      the old district. Tests assert no key or body holds the address and the session has no cache.
>    - **Stale-while-revalidate:** `revalidate(api, report:) { pass in … }` runs a screen's whole
>      load twice, first against `api.savedOnly()` (cache only, no network), then against the
>      network, which saves as it goes. A screen with several requests therefore shows all its saved
>      data at once. `report` hears the screen's state as it changes, and the model keeps it in
>      `saved`:
>      - saved pass drew → `.refreshing`, dated by the oldest response it read;
>      - network pass succeeded → nil, unless a best-effort request (`pass.bestEffort`: the vote's
>        bill, the bill's positions, the loyalty rings) failed and fell back to its saved copy — then
>        `.offline` or `.refreshFailed`, dated by that copy, because the screen is partly saved;
>      - network pass failed → `.offline` (transport) or `.refreshFailed` (the server answered),
>        dated by the saved pass; with nothing saved, the error is rethrown and the screen fails
>        exactly as before.
>    - **Cancellation is not failure.** A pushed screen or a tab switched away cancels the view's
>      `.task`; `FloorAPI` turns a cancelled request into `CancellationError` (never `.transport`),
>      `revalidate` reports nothing for it, and the note stays at "refreshing…". Each model has
>      `needsRefresh` — true until a load has finished with everything fresh — and the screens'
>      `.task` (Finals, Vote, rep, and Your three's `loadAll`) load when it is true, so a refresh that
>      was cancelled, or ended on saved data, runs again when the screen reappears. A screen already
>      showing data keeps it while it reloads rather than flashing a spinner.
>    - **Overlapping loads** (pull-to-refresh beside the screen's own task): each model counts its
>      loads, and a load that has been overtaken drops its results — items, phase and note alike.
>    - **UI:** one muted caption, `SavedDataNote`, at the top of a loaded Finals, Bills, Vote, Bill
>      or rep record while any of it is saved: "Saved 2 h ago · refreshing…", then "Offline · saved
>      2 h ago" or "Couldn't refresh · saved 2 h ago", gone once everything is fresh. Nothing else
>      changed visually.
>    - **Bounds:** 30 days and 200 entries (`CachePolicy`). An entry past 30 days is neither served
>      nor kept; beyond 200 the oldest go first. Eviction fetches only the rows to delete, and only
>      their keys. A screen costs one to six entries at tens of KB each.
>    - **Seam:** `FloorAPI(baseURL:session:cache:now:)` takes any `ResponseCache`; tests use
>      `SwiftDataResponseCache.inMemory()`, previews pass none. A store that will not open (a failed
>      migration, a corrupt file) is deleted with its `-wal` and `-shm` and opened once more; only if
>      that fails too does the app run with no cache.
> 3. ~~**Snapshot tests per card state.**~~ **Done in v0.2.25** (closes
>    [#1](https://github.com/abhipal42/floor/issues/1)); see **Snapshot tests** below.
> 4. **TestFlight distribution.** Needs an Apple Developer account, signing and the upload. The
>    build itself is proven: see **Exit** below.
>
> "Use my location" on onboarding, once noted here as unbuilt, **is built** — see the Onboarding
> bullet below.

- ~~Complete the API contract the screens need~~ **Done.** The Vote screen's party breakdown and
  delegation positions, and the Rep screen's party-loyalty record, did not exist and would have
  meant generating Swift models twice. `/v1/votes/{id}` now returns `partyTotals`,
  `candidateTotals` and `positions`, and `/v1/members/{id}` is new. `Vote` itself is unchanged, so
  the vote lists inside Bill and Nomination stay cheap.
- ~~Swift `Models`~~ **Done**, hand-written rather than generated. `swift-openapi-generator` was set
  up and run against the real contract first: it works, but produced 2,280 lines for these 7
  endpoints (1,217 of it operation wrappers an own `APIClient` does not use), named types
  `Components.Schemas.Bill.ActionsPayloadPayload`, turned nullable `$ref`s into wrapper structs
  instead of optionals (OpenAPI 3.1 does not help — zod-openapi emits `allOf` either way), and added
  an OpenAPIRuntime dependency plus a ~20s generator build in CI, which has no SPM cache. The
  hand-written models are ~600 lines across `Sources/Models/`, and `ContractTests` compares every
  model's fields and every enum's cases against `apps/api/openapi.json`, so the drift that gutted the
  old `Vote.swift` is caught in CI instead of on a phone. Tests decode nine real staging responses in
  `Tests/ModelsTests/Fixtures/`. **If you ever do want generation,** the contract is already factored
  for it (lesson: 25 named components, no inline enums), so it is one command away.
- ~~`APIClient` package~~ **Done.** URLSession client for the seven routes; `Models` has no
  networking and no dependencies, so this is the only place URLSession appears. The base URL comes
  from the build configuration: Debug talks to `localhost:8787`, Release to the deployment, via a
  generated `Info.plist` key `FloorAPIBaseURL`. Twelve tests drive it through a stubbed
  `URLProtocol`; six more run against a real server and are skipped unless `FLOOR_API_URL` is set:
  `npm run dev -w @floor/api` then
  `FLOOR_API_URL=http://localhost:8787 swift test --package-path ios/FloorKit`.
- ~~**Onboarding**~~ **Done**, address field **and "Use my location"**. Resolves through
  `/v1/reps`, shows who it found, and stores the district and members only once confirmed. The
  address is used for one request and dropped — it is not part of `Delegation`, so it never reaches
  disk, and a test encodes a saved record to assert the typed address does not appear in it.

  **"Use my location"** is built to round 7 of the canvas (`LocApp`, "Onboarding with location").
  When-in-use permission only (`NSLocationWhenInUseUsageDescription` in `ios/project.yml`), one
  `requestLocation()` fix with a 15 s timeout, then `GET /v1/reps?lat=&lng=` with both rounded to 4
  decimals on the phone as well as on the server (`FloorAPI.reps(latitude:longitude:)`). The point
  lives in one local for one request: never stored, never logged and **never cached** — the
  coordinates lookup passes `cacheable: false`, as the address lookup does, because the offline
  cache's key would be the location, and the app's session (`FloorAPI.defaultSession`) has no
  `URLCache`. Tests check the saved record, the whole `UserDefaults` suite, the response cache and
  the model itself for it. Core Location sits behind `LocationProvider` (`Onboarding/Location.swift`),
  so `OnboardingModel` is tested with a stub, and `OnboardingModel` builds its `CoreLocationProvider`
  on first use rather than with the model, which SwiftUI may build and discard.

  The provider always answers, so the disabled button cannot stick. Location Services off for the
  whole phone is checked first (`CLLocationManager.locationServicesEnabled()`, off the main thread).
  A permission request ends with the delegate's answer, or `.denied` when the app comes back active
  with nothing decided, or after a 120 s backstop; a fix ends with a location, a `LocationFailure`,
  or the 15 s timeout. A second tap while one is pending joins it, and a late callback after a
  timeout is ignored (`PendingAnswer`, tested on its own). `CLError.denied` mid-fix reads as
  "Location is off", not "no fix in time". `OnboardingModel` ignores a second lookup while one runs
  and drops a result that lands after an edit or "Not your district?" (a generation counter).
  How each mock state maps:

  | Mock state | Code |
  |---|---|
  | System alert | The OS's own, from `requestWhenInUseAuthorization()`; the screen behind stays as it is |
  | Loading | `phase == .looking` with `source == .location`: "FINDING YOUR DISTRICT…" over three skeleton cards; the field is hidden |
  | Done | `.found`: district label and member cards; "Not your district? Type an address" (`typeAddressInstead()`) when `source == .location` |
  | Location off | `notice == .locationOff` (denied): banner + "Open Settings ›" (`UIApplication.openSettingsURLString`); field stays usable |
  | Outside the U.S. | the API's 404 for a point → `notice == .outsideUS`, field shown |
  | Precise off | `accuracyAuthorization == .reducedAccuracy` → `.found` plus `notice == .approximate` above it |
  | D.C. | one card in a three-column row, plus the "One, not three" note (`OnboardingModel.singleMemberNote`) |

  Where the build differs from the mock, and why:
  - **Restricted** (Screen Time, a profile) has its own banner body and **no** Settings link: Settings
    › Floor can't lift a restriction, so the link would be a dead end. The mock has only "denied".
  - **Location Services off** for the whole phone is its own banner: "Location Services are off on
    this iPhone — Settings › Privacy & Security › Location Services", with no app link, since
    Floor's own Settings page has no switch for it.
  - **No fix in time** is a fifth banner ("Couldn’t find where you are"), and it is the one case that
    offers "Use my location" again; the mock has no location-error state. A network error after a
    fix lands on the address field with the client's usual message.
  - **After an address lookup the field stays visible**, as in the earlier locked AppOnboarding
    build, where typing again is how a wrong match is corrected; the mock hides it in every done
    state. It is hidden only behind a location result, which has its own "Not your district?" link.
  - **Coming back from Settings retries by itself** while the "Location is off" or "Location
    Services are off" banner is up (`retryAfterSettings()`, on a return from the background, not on
    the alert closing): the mock offers no button in that state, so without it turning location on
    would change nothing. If it is still off, nothing changes on screen and the banner is not
    re-posted, so VoiceOver does not announce it again.
  - **Puerto Rico and the territories** get the D.C. note in their own words ("a resident
    commissioner", "Guam"), since `/v1/reps` treats them the same way.

  **One member, and district 0.** `/v1/reps` for D.C. returns only Eleanor Norton
  (`chamber: house`, `district: 0`, no senators); an at-large state like Wyoming also sends
  `district: 0`. What that touched outside onboarding: `Member.partyAndSeat` printed `R-WY-0` and
  `D-DC-0` (now `R-WY-AL` and `D-DC`); `Member` gained `isDelegate`, `title`, `seatBadge` and
  `seatCaption`, which the Home strip, the vote screen's rows, onboarding's cards and the Rep
  screen's `roleLine`/`seatLine` now share (Norton reads "Delegate · DC", not "House · DC-AL" or
  "U.S. Representative"); the sponsor line reads "Del."; `District.name` (Home's header chip) reads `DC`, not `DC-AL`; `StateName.districtName` says "District of
  Columbia", not "District of Columbia's at-large district"; and Home's Senate filter says D.C. has
  no senators instead of "No recent votes in this chamber". Already fine with one member: the feed
  merge, `YourThreeModel` (its agreement fact needs exactly two senators and falls back otherwise),
  the vote screen's other-chamber note and the bill screen's member list. The tab is still called
  "Your three" for D.C. — a name, not a count, and the mock keeps "Pull your three." too.
- ~~**Home**~~ **Done, except the election variant.** Delegation strip, chamber filter, and the
  merged feed of recent votes. One request per member in parallel, grouped by vote so two senators
  on one roll call make one card carrying both positions. **Still to do:** the Speaker election card
  variant that `candidateTotals` feeds — see item 1 above.
- ~~**Fix `ScoreboardCard`**~~ **Done.** The row is a fixed 56pt side, a flexible score, a fixed
  92pt status and the mirror; default `HStack` spacing added 32pt across four gaps, leaving each
  score about 69pt where "216" needs nearer 79, so it wrapped to 2/1/6 stacked. Gaps are now zero
  and the score takes `lineLimit(1)` with a `minimumScaleFactor`, so it cannot stack again whatever
  the totals. The header was clipping mid-word too, so the chamber and the question are now separate
  lines.
- ~~**Vote detail**~~ **Done.** Totals, threshold bar, each party's split beneath its score, your
  own members' positions, and the whole roll by party — one `/v1/votes/{id}?members=` call. A
  Speaker election gets its own board and says plainly when a ballot elected nobody.
- ~~**Bill screen**~~ **Done.** Short title, CRS summary, sponsor, policy area, CBO links, votes,
  and the "Path to law" stepper. The stepper reads the actions Congress.gov marks with **no
  chamber** — its own summary labels (`Introduced in House`, `Passed/agreed to in Senate: …`,
  `Failed of passage/not agreed to in House …`, `Became Public Law No: …`) — which is far steadier
  than the free-text actions. Two traps it handles: the action list is capped at 30 so a
  long-running bill loses its introduction off the end (`introducedOn` is the authority), and bill
  actions lag their votes, so a chamber's own roll call settles passage when the marker has not
  landed yet.
- ~~**Rep screen**~~ **Done.** Party unity, crossovers and recent votes, each row saying whether
  they sided with the outcome. The screen spells out the denominator — votes where their party had a
  clear majority, not every vote cast — because a bare percentage invites the wrong reading, and
  shows a sentence rather than a figure when `partyLoyalty.votes` is 0 (lesson 15).
- ~~**SwiftData cache for offline**~~ **Done**; see item 2 above.
- ~~**Snapshot tests for each card state**~~ **Done in v0.2.25**
  ([#1](https://github.com/abhipal42/floor/issues/1)). Why it mattered: every layout bug in this
  milestone — the stacked digits, a duplicated title, a date rendering a day early — was caught by
  eye on a simulator screenshot, and the unit tests cannot reach that layer.

  **Snapshot tests.** `ios/FloorKit/Tests/SnapshotTests`, references in its `__Snapshots__/`.
  - **What is covered** (53 images from 24 tests, about 13 MB): `ScoreboardCard` in ten states — passed with three
    digits a side (295–128), failed short of two-thirds, nay leading one digit against two (1–94),
    a 424–0 shutout, a 1,309-character title, a procedural vote with no citation, two senators on
    one card, a Speaker ballot that elected nobody, open, scheduled — each in **light, dark and the
    largest accessibility text size (AX5)**. Screens: Vote (a question with your rep, bill level and
    full roll; cloture short of 60; a Speaker election), Bill (the stepper enacted, rejected in the
    House, still moving), Rep (Cruz, with a unity figure), Onboarding (editing, Austin's three dealt,
    offline failure), Home (loaded, loading, offline failure). Every one is drawn from the captured
    responses in `ModelsTests/Fixtures`, through `FixtureServer` (a `URLProtocol` that answers the
    API's routes from those files and 404s anything else). Open and scheduled take a real final and
    change only its state, since the API has served neither yet.
  - **Not covered, and why:** four-digit totals (no chamber has a thousand members, so no real vote
    has one); a tied vote and the independent Rep case (no captured response has either — capture
    one with `curl` when it turns up, rather than invent it); Home empty after a chamber filter
    (needs a delegation whose records are not captured). Portraits always draw as initials: the
    tests refuse `unitedstates.github.io` (`NoPortraits`) so nothing depends on the network.
  - **The Xcode-version tension, resolved by pinning the simulator OS, not CI's Xcode.** An image
    depends on the iOS that drew it, and CI runs on `macos-latest`, whose Xcode moves on its own.
    Pinning `macos-15` was tried and left jobs unscheduled for 15 minutes, so CI keeps
    `macos-latest`, and instead the references are pinned to **the iOS 26.2 simulator**:
    `SnapshotEnvironment` skips every snapshot test, with the reason in the log, on any other OS —
    including `swift test` on macOS, where the target compiles to nothing (`#if os(iOS)`). CI's
    `ios` job runs them as its last step, after the app build, with `DEVELOPER_DIR` set to
    `/Applications/Xcode_26.2.app` explicitly, on the simulator named "iPhone 17 Pro" (else any
    26.2 iPhone). It **fails** — it does not skip — when that Xcode or a 26.2 iPhone simulator is
    missing, with an error pointing here: a check that turns green without checking anything is
    worse than none. Rendering is in points at a fixed 402pt width and 2x scale, so the device model
    does not matter, only the OS. Two thresholds: 98% perceptual precision per pixel absorbs
    anti-aliasing between machines, and at most 0.5% of pixels may differ beyond that (`precision:
    0.995`), so a moved digit or a wrapped line fails. When the step starts failing on `main` for
    a missing Xcode or runtime (the runner image dropped 26.2), re-record on the new runtime in one
    PR, bump `pinnedOS` and the step's Xcode path, and review every image.
  - **Run, record, review:**
    ```bash
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
    xcrun simctl create "Floor Snapshots" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
      com.apple.CoreSimulator.SimRuntime.iOS-26-2       # once; prints the UDID
    cd ios/FloorKit
    xcodebuild test -scheme FloorKit-Package -destination 'platform=iOS Simulator,id=<UDID>' \
      -only-testing:SnapshotTests                       # compare
    TEST_RUNNER_SNAPSHOT_TESTING_RECORD=failed xcodebuild test …   # re-record what differs
    ```
    `xcodebuild` passes the test runner only variables prefixed `TEST_RUNNER_`. A missing reference
    is recorded and the test fails once, by design. **Re-recording is where a real regression gets
    waved through**: open every changed PNG in the PR diff and say in the PR why each one changed.
    A failure on CI uploads the images it drew as the `snapshot-failures` artifact.
  - **Why `swift-snapshot-testing`** (pointfreeco, pinned to exactly 1.19.7, test target only — the app links nothing
    new): SwiftUI's own `ImageRenderer` would need no dependency, but it cannot draw `ScrollView`,
    `ProgressView`, `TextField` or a navigation bar (they come out as placeholders), and every
    screen is made of them. The library hosts the view in a real window with the traits applied
    (appearance, content size category, scale), records missing references, and writes diffs.
    Resolving it also fetches `swift-syntax` (for its inline-snapshot target, which is not built);
    `Package.resolved` pins all of it.
- **Backend for M2:** ~~CORS and rate limiting~~ **Done**, and the API is **deployed**:
  <https://floor-api.vercel.app> (Vercel project `floor-api`, team Abtanix Labs, root directory
  `apps/api`, Node 22, framework detection **off**). Two things that cost a deploy each, so do not
  undo them: Vercel's Hono preset only looks for an entrypoint under `src/` that imports `hono`
  directly and never sees `api/`, hence framework `null` plus `vercel.json`; and the handler must use
  `@hono/node-server/vercel`, not `hono/vercel` — the latter returns a fetch-style handler while the
  Node runtime calls `(req, res)`, so every request hangs to the function timeout.
  `DATABASE_URL` is set and the deployment serves real data; `/v1/status` reports `ok: true`.
  Four things about that variable, the first three of which each cost a failed deploy:
  - **It must be the pooler string, and the username differs too.** Not
    `postgres@db.<ref>.supabase.co:5432` — that host does not resolve from Vercel at all (Supabase's
    direct connections are IPv6-only), so it fails with `ENOTFOUND` rather than a timeout. Use
    `postgres.<ref>@aws-1-us-east-1.pooler.supabase.com:6543`.
  - **It is `aws-1`, not `aws-0`.** Supabase's docs and most examples show `aws-0-us-east-1` for this
    region; that host exists but rejects the tenant with "tenant/user not found".
  - **Changing it needs a redeploy.** Vercel bakes environment variables into a deployment at build
    time, so an existing deployment keeps the environment it was built with. A redeploy of the same
    commit is deduplicated and hands back the old build with the old value, so force a new one
    (`vercel --force`, or `forceNew` through the API) when the point of the redeploy is the variable.
  - **It is set for Production *and* Preview** (2026-11-13). It was production-only until then, so
    every PR preview silently fell back to the stub repositories in `apps/api/api/index.ts`: a
    preview answered `/v1/status` with every source null and `/v1/members/{id}` with a 404, which
    reads as missing data rather than a missing database. Adding Preview is what makes a PR preview
    queryable against staging. Note what that implies — a preview build now carries the staging
    credentials, which is contained only because preview URLs sit behind Vercel Authentication, and
    is the strongest argument for the read-only role below.

  Optionally set `ALLOWED_ORIGINS` (comma-separated) for a future web client; unset means no browser
  origin may read a response, which does not affect the iOS app.

  **Latency:** `/v1/members/{id}` is the slowest route — about 0.7s warm but **7s on a cold start**,
  because the party-loyalty query scans `vote_positions` (996k rows) and recomputes each party's
  majority per vote. The Rep screen wears that as a spinner. A materialised per-member tally is the
  fix if it starts to bite; the function timeout is 15s, so there is headroom but not a lot.
  **Worth doing before this is public for real:** the API only ever reads, so give it a read-only
  Postgres role rather than the service connection, which bypasses RLS and can write.
- **Exit:** TestFlight build where a tester enters their address and sees yesterday's votes by their reps.
  **Everything but the distribution is done:** a Release build of the app, pointed at
  <https://floor-api.vercel.app> by its build configuration, runs the whole flow — onboarding to a
  real district, Home, Vote, Bill and Rep — against the deployment with no local server. What is
  left is an Apple Developer account, signing and the upload itself.

**The designs.** The canvas has two pages and launches on **v2 · Live + impact**, so that is the
direction: its four phone artboards are `Home` (Floor scoreboard), `Matchup` (→ Vote detail), `Bill`
and `Player` (→ Rep), all 390pt wide and scrolling to 1360-1960. Be aware **v2 includes M3 and M4
work** — a "Live on the Floor" section with countdown timers, a "PROJECTED TO PASS" row, and a purple
"For you ·" AI impact block. Build v2's structure without them for M2; the projection row already
sits behind a `showOdds` prop that can be switched off. The score row's geometry
(`56 | number | 92 | number | 56`) is what `ScoreboardCard` already implements, so it carries over,
but the design sets the numbers in **Barlow Condensed** where the card currently uses SF Rounded
condensed. Ground `#07080A` under a green gradient, cards `#1E2128`, yea `#34D399`, nay `#FB923C`,
live `#FF453A`, muted text `#9BA1AD`.

### M3: Live layer
**Goal:** "vote open" on the phone within 30 s, and your rep's vote within 60 s of the roll call posting.

**The backend is built (v0.2.24) and not deployed.** Read lesson 41 first: neither chamber publishes
"vote opened", so `open` currently means "named on the floor, roll call not posted yet".

**Built:**

| Piece | Where | Notes |
|---|---|---|
| Floor-event parsers | `packages/shared/src/floor.ts` | House floor summary; Senate `floor_schedule.json`, floor activity page, vote menu. Contract tests on real responses saved 2026-11-13 (`packages/shared/fixtures/house-floor-*.xml`, `senate-*`) |
| Vote state | `apps/worker/src/live.ts` | A roll call named by a floor source and not yet stored goes in as `open` (House: with the floor's time as `opened_at`, plus the announced tally); `upsertRollCall` makes it `final` when the XML lands. A final vote is never reopened. Every House floor action is kept in `floor_events`. A vote is **news** (announced, `announced_at` stamped, broadcast) only when the chamber's previous poll was under 60 s ago or the vote is dated today (Eastern); one found after downtime or on a first run is stored `open` quietly (lesson 44). `parseHouseFloor` refuses a file without its Congress and session, so no vote is filed under Congress 0 to sit open forever |
| Publishing | `publishFinals` | Every poll, in a `finally` so it runs even when a step threw: select `state = 'final' and broadcast_at is null`, publish, stamp `broadcast_at`. However a vote became final (this poll, a poll that threw halfway, the hourly workflow, a run before a restart) it is announced exactly once; if the broadcast fails nothing is stamped and the next poll retries. A final vote from more than a day ago is stamped without being published. Opens are published from the poll that stored them |
| Stuck votes | `stuckOpenVotes` | Hourly: votes still `open` six hours after a floor source first named them (`floor_events.observed_at`) are logged, and posted to the alert webhook once each. The bill and nomination pages list only `final` votes (an open vote's tally is the floor's, not the roll call's) |
| Session awareness | `houseSession`, `senateSession` | House: an unfinished legislative day = sitting (recesses included); a finished one names the next convening, and we poll fast from 15 min before it. Senate: from the schedule's convening (less its offset) until the floor page says that meeting adjourned, 16 h at most. A failed source never flips a chamber: the House keeps its last good day; the Senate keeps its last good schedule and floor page for 30 minutes (a floor page with no meeting blocks — senate.gov's 200 error page — counts as failed), then counts as out. `chamber_status` is written only from a poll that succeeded |
| Always-on loop | `npm run ingest -w @floor/worker -- live` | **Per chamber**: a chamber's sources and roll calls every 10 s while it sits, every 5 min otherwise, so senate.gov is not asked every 10 s because the House is in. A host that answers 403 or 429 is not asked again for 30 s, doubling to 5 min while it keeps refusing (lesson 43). Votes saved without positions are re-fetched at most hourly; with no House file in the last week, the week's lookback is retried hourly. Roll call fetches time out at 15 s, the Realtime broadcast at 10 s, an APNs stream at 10 s. A pool `error` and an unhandled rejection are logged, not fatal; `fly.toml` restarts the machine on any exit. Each step fails alone. SIGTERM/SIGINT finish the poll in flight, then exit 0 (checked in Docker). ETag/Last-Modified revalidation, so the 170 KB vote menu is a 304 when unchanged; a body is remembered only once what it says is stored, so a failed store is retried next poll rather than skipped as "unchanged". Links bills and nominations for new votes every 5 min when `CONGRESS_API_KEY` is set |
| Deploy files | `apps/worker/Dockerfile`, `apps/worker/fly.toml`, `/.dockerignore` | Image built and run against a throwaway Postgres on 2026-11-13: one real poll stored House roll 323 and Senate 262, then stopped cleanly on `docker stop` |
| Realtime | `apps/worker/src/realtime.ts` | Supabase Realtime **broadcast** over REST: each change to topics `floor:votes` and `vote:<id>`, event `vote_state`, payload = id, chamber, state, question, result, the three timestamps. No-op without env |
| APNs | `apps/worker/src/apns.ts` | Token (ES256 JWT) auth over HTTP/2, alert / background / liveactivity push types, collapse IDs, 410 → `unregistered`. **Nothing calls it**: what a push says is UI (below). No-op without env |
| Alerting | `apps/worker/src/alert.ts` | While a chamber sits, asks the deployed `/v1/status` at most once a minute. Three failed checks in a row (`ok: false` or no answer) POST `{text, content}` to a webhook (Slack/Discord shape); it repeats every 30 min, and three good checks in a row post "recovered". Never two posts within 30 min, so a flapping status cannot spam. No-op without env |
| API | `GET /v1/live` | See §2. Edge-cached 5 s. Swift models `Live`, `LiveVote`, `ChamberStatus` (`Models/Live.swift`) decode it, checked by `ContractTests` and `LiveTests` on a response the real API code gave from real 2026-11-10 data; no screen uses them yet |
| Latency | `votes.announced_at`, `votes.posted_at`; `... -- latency [days]` | `posted_at` (latency only; publishing uses `broadcast_at`) is stamped on a chamber's unpublished final votes only when that chamber's previous roll call poll was under 60 s earlier, so a backfill after downtime records nothing rather than our own outage. A vote the hourly workflow stored between two worker polls is stamped at the next poll, at most 10 s late. `latency` takes a whole number of days, 1 to 3650. Each finalized vote also logs `latency <id>: XML seen N s after the floor's vote time, M s after a floor source named it` |
| Load test | `npm run loadtest -w @floor/api` | The vote-night mix (`/v1/live` most, then the vote screen, member votes, member, bill, status). Refuses floor-api.vercel.app always, and any non-local host unless named with `--allow-host`. Against a local API with no database on 2026-11-13: 183k requests in 10 s at 50 connections, p95 4.8 ms, 0 errors — the framework's ceiling, not the database's; run it with `DATABASE_URL` pointed at a non-production database for a real number |

**To turn it on (needs accounts we don't have):**

1. **Apply `supabase/migrations/20261114000100_live_layer.sql` to staging** (Supabase SQL editor; needs
   dashboard access — Sourav), then re-check the **security advisor**: the new `chamber_status` table has
   RLS with a `public read` policy, like the other public tables. Until then `/v1/live` answers empty
   (`{chambers: [], votes: []}`), since its tables don't exist.
2. **Deploy the worker** (needs a Fly.io account; Railway works the same way from the Dockerfile):
   ```bash
   fly launch --no-deploy --copy-config --config apps/worker/fly.toml --name floor-worker
   fly secrets set --config apps/worker/fly.toml DATABASE_URL='postgresql://...'   # plus any below
   fly deploy --config apps/worker/fly.toml --dockerfile apps/worker/Dockerfile .  # from the repo root
   fly logs --config apps/worker/fly.toml                                          # "live worker starting: ..."
   ```
   Run **one** machine (`fly scale count 1`): two would race for the same rows (harmless, but double
   broadcasts). It needs no inbound port. It holds **one** connection on the session pooler (port
   5432, lesson 37) for as long as it runs — one of the 15 slots. The hourly `ingest.yml` workflow can
   keep running beside it: both upsert the same rows idempotently, `upsertRollCall` locks the vote row
   first (lesson 36), and the workflow becomes the backstop for when the worker is down. Its roll
   call steps could be dropped once the worker has run a few weeks.
3. Environment, all secrets:

   | Var | Needed for | Where it comes from |
   |---|---|---|
   | `DATABASE_URL` | everything | Supabase → Connect → **Session pooler** (the direct host is IPv6-only and unreachable from many networks, including this Mac's on 2026-11-13) |
   | `CONGRESS_API_KEY` | linking new votes to bills/nominations | api.data.gov (already have one) |
   | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | Realtime broadcast | Supabase → Project settings → API |
   | `ALERT_WEBHOOK_URL` | paging | a Slack/Discord incoming webhook for whoever is on call |
   | `FLOOR_STATUS_URL` | optional | defaults to `https://floor-api.vercel.app/v1/status` |
   | `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, `APNS_TOPIC`, `APNS_ENV` | pushes (not wired yet) | Apple Developer → Keys → an APNs key (.p8); topic `app.floor.ios`; `production` for TestFlight |

4. On the first session day with it running, run `latency` and write the numbers here (and answer
   lesson 41's open question: does the Clerk's entry appear before the vote closes?).

**Left, and what each waits on:**

- **"Vote open" while members are still voting** — needs a source that has it: live.house.gov's
  undocumented feed (lesson 41) or the OCR prototype. Try the feed on a session day first.
- **Pushes and Live Activities (push-to-start, iOS 17.2+)** — UI (home-screen widgets landed in v0.2.23, see "Widgets"; they refresh about every 30 minutes, so they are not part of the 30 s goal): what a push says and what a Live
  Activity shows need a design mock locked first (CLAUDE.md). Also needs a device-registration route: the
  `devices` table exists, but nothing writes it, and writing it needs Supabase Auth in the app.
- **The app subscribing to Realtime** — iOS work, behind the same design.
- **House running-tally OCR prototype** → go/no-go. Not started.
- **Measured posting latency** — needs the worker running through a session day (above).
- Watch for wordings `ROLL_TEXT` in `floor.ts` doesn't know (it reads "Agreed to / Passed / Failed /
  Sustained / Ordered"); an unknown one still opens the vote, with `question` = the whole action text.

### M4: AI summaries + projections
- Layer 1 bill analysis per bill version (Claude, server-side): purpose, provisions, affected groups, impact rules, section citations, plus a verifier pass and a ~50-bill eval set.
- Layer 2 "What it means for you" from coarse opt-in profile attributes + county data (Census ACS, FCC). No names or addresses go to the model.
- Projection model v1 (per-member probabilities → chamber simulation), backtested on the 3,500 stored roll calls (they're already in staging) and calibrated against a party-line baseline.
- Optional display-only market odds (pending product decision).

**Layer 1, server side: built in v0.2.22.** What exists and how it works:

- **Source and version.** The only input is the bill's stored CRS summary (`bills.summary`), split
  into paragraphs on blank lines; a version is its `summary_stage` (lesson 40). One row per
  `(bill_id, source_kind, source_stage)` in `bill_analyses` (migration
  `20261114000000_bill_analyses_ai.sql`, which repurposes the empty core table; `bill_version_id`
  becomes optional for a later bill-text analysis). `source_hash` is sha256 of `stage + "\n" +
  summary`; the job regenerates a row when that hash or `PROMPT_VERSION` changes, and a new stage
  adds a row and keeps the old one. Each row stores `model`, `verifier_model`, `prompt_version`,
  `generated_at` and the analysed paragraphs, so citations resolve after the summary moves on.
- **Public vs private.** `bill_analyses` has the shared tables' public-read policy, so **everything in
  it is readable by anyone through PostgREST** — it holds only what readers may see. Run bookkeeping
  lives in `bill_analysis_runs`, one row per `(bill_id, source_hash, prompt_version)`: failed
  `attempts`, `last_error`, `succeeded_at`, and `stats` (counts, tokens per model, cost, and the
  claims the verifier rejected with its reasons). It has RLS on and **no policy**, so only the
  service role can read it. Rejected claims must never reach a reader; don't add a policy to it.
  **Re-run Supabase's security advisor after applying the migration.**
- **Pipeline** (`apps/worker/src/analysis.ts`). (1) A draft call with structured JSON output writes
  purpose, up to 8 provisions, affected groups and impact; every claim cites 1–3 paragraphs, each
  with a verbatim quote. (2) `checkCitations` drops citations whose paragraph doesn't exist or doesn't
  contain the quote (case, whitespace and curly quotes folded). A quote must be at least 20
  characters and contain a word outside a stopword list of CRS boilerplate, so "This bill requires
  the" or "among other things, the" — found in any paragraph — prove nothing and are cut. Claims left
  with no citation are cut. The section ("Sec. 101") is the last CRS "(Sec. N)" label at or before
  the quote's position in the paragraph (a paragraph can cover several sections), never taken from
  the model. (3) A verifier call rules on each surviving claim against its cited paragraphs only;
  unsupported claims, claims it doesn't rule on, and claims it gives conflicting verdicts on (a
  repeated id) are cut. Nothing is softened. Both calls: `@anthropic-ai/sdk`, `claude-sonnet-5-5`,
  effort `medium`, the fixed system prompt marked `cache_control`, and the server-side refusal
  fallback (`fallbacks: "default"`).
- **Failures.** A refusal, truncation, malformed output or other API error fails that bill: stored
  nowhere public, counted in `bill_analysis_runs.attempts`, retried on later runs. After **3**
  failed attempts a source is left alone until its summary or the prompt version changes, so one
  bad bill can't be billed forever or starve the queue. Summaries over 600k characters are never
  sent (not truncated). Errors no bill would avoid — `AuthenticationError`, `PermissionDeniedError`,
  a `RateLimitError` that outlasted the SDK's retries — end the run at once, exit non-zero, and do
  not count against the bill.
- **Run it:** `npm run ingest -w @floor/worker -- analyze [limit]` (default 25 per run, newest
  activity first; `limit` must be a positive integer and `FLOOR_AI_EFFORT` one of
  `low|medium|high`, both checked before any call). A run holds a Postgres session advisory lock
  (`pg_try_advisory_lock(4200001)`) on one dedicated connection, so a second, overlapping run
  logs "another analysis run is in progress" and exits without spending anything. A session lock
  needs a session connection: run it on the session pooler (5432) like the rest of the worker,
  never the transaction pooler (6543), where consecutive statements can land on different backends. Logs bill ID,
  counts and cost only — never the summary, never a key. Cost is summed per model across
  `usage.iterations` (a refusal fallback bills the declined attempt too, at its own model's rate)
  and printed as "unknown" if any model that ran has no known price.
  `ingest_runs.source = 'bill_analyses'`; deliberately not in `/v1/status`'s freshness list, so an
  unrun job never marks the API unhealthy.
- **Env:** `ANTHROPIC_API_KEY` (required), `FLOOR_AI_MODEL`, `FLOOR_AI_VERIFIER_MODEL`,
  `FLOOR_AI_EFFORT` (see §1).
- **API:** `GET /v1/bills/{id}/analysis` (§2). `ai: true` and `label: "AI-generated"` on the
  response, `ai: true` on every line, and `disclaimer` ("…It may contain errors…").
- **Eval:** `apps/worker/fixtures/analysis/bills.json` is 51 real bills from staging (2026-11-13),
  stratified by summary stage: 12 Introduced in House, 11 Passed House, 9 Public Law, 8 Reported to
  House, 5 Introduced in Senate, 3 Passed Senate, one each of the rarer stages; 27 H.R., 10 H.Res.,
  9 S.J.Res., 3 S., 2 H.J.Res.; summaries 150–30,000 characters. `npm run eval:analysis -w
  @floor/worker` scores **citation validity** (share of drafted citations that resolve and quote
  exactly), **verifier drop rate** (share of check-passing claims the verifier cut), keep rate, empty
  analyses, **output validity** (every stored citation re-checked; must be 100%) and cost per bill.
  **It has not been run:** no Claude key was available to the session that built it. Run it before
  the backfill and record the numbers here.
- **Cost estimate per bill** (Sonnet 5.5 at $2 / $10 per million input / output tokens; *not yet
  measured* — the eval reports the real figure). A median summary (~760 characters, ~200 tokens):
  draft ~1.1k input + ~2–3k output (adaptive thinking plus JSON), verify ~1.5k input + ~1–1.5k
  output, so roughly **$0.03–0.05**. The largest stored summary (~75k tokens) is ~$0.35–0.50.
  Backfilling all 976 summarised bills: roughly **$40–60** once; after that only new or changed
  summaries cost anything. Both system prompts are ~600 tokens, just over Sonnet 5.5's 512-token
  caching minimum, so caching saves little per bill; the eval's `cache read tokens` line shows
  whether it is hitting.

**Left for Layer 1:**
- Apply the migration to staging (and re-check Supabase's security advisor), set `ANTHROPIC_API_KEY`
  where the worker runs, run the eval, then backfill with `analyze`.
- Schedule `analyze` after the `bills` ingest (with the M3 worker deploy).
- Richer sources: bill text from GovInfo (then `bill_versions` rows and section citations into the
  text itself), CBO estimates, committee reports; cost and supporter/opponent arguments wait on them.
- Human review of the top 20 bills each week (`reviewed_by`), feedback buttons.
- **The web.** The analysis is not on the website yet; the app has it (below).

**The Bill screen's AI section: built in v0.2.27**, to section "E · AI on the bill screen" of the
locked live/AI design <https://claude.ai/artifact/X5NwWSe1NmugSRoCKh3vBn>.

- **Where and what.** At the top of the Bill screen, under the title (the app has no Overview tab,
  so this is the mock's "top of the Overview"): the violet AI tag, "Written by AI from the CRS
  summary", then one heading per non-empty field — What it does (`purpose`), What it changes
  (`provisions`), Who it touches (`affectedGroups`), Impact (`impact`) — and the response's own
  `disclaimer`, never a hard-coded one. Each line has a chip per citation (`CRS ¶2`, or
  `CRS ¶5 · Sec. 101` when the response names the section); tapping one opens that paragraph of
  `source.paragraphs` verbatim, in Georgia, under `CRS SUMMARY · ¶5 · PUBLIC LAW`. One open at a
  time. VoiceOver reads a line as "AI-written: …, cited from CRS paragraph 2".
- **States** (`BillScreenModel.AnalysisPhase`): `loading` (the skeleton, only while the request is
  out); `loaded`; `hidden` — a 404 for a bill that **has** a CRS summary, so the screen promises
  nothing the worker may not have written yet; `noSummary` — a 404 for a bill with no summary, the
  mock's dashed "No summary yet" card; `failed` — the request failed with nothing saved, a one-line
  AI card with Try again. `source.stale` adds "The CRS summary has changed since this was written."
- **How "every AI line carries an AI label" is met.** Not with a tag on each line: the lines sit
  inside one violet card that carries the AI tag and "Written by AI from the CRS summary", and
  nothing that isn't AI-written goes in that card. A sighted reader can't see a line without its
  label above it; VoiceOver, which reads lines one at a time, hears "AI-written:" at the start of
  every line. Product rule and review agreed on this reading (PR #36).
- **Cut, not softened.** `AIAnalysis` drops any citation whose paragraph is out of range or whose
  quote isn't in that paragraph (compared as the worker's `normalize` does: case, whitespace runs,
  curly quotes, en/em dashes, a leading or trailing ellipsis), any line with blank text, and any line
  left with no citation; an analysis left with no lines counts as none.
- **Contrast.** The card is the ground washed with `ai` at `Tones.aiCardTint` (8%) at its top. In
  light mode `textMuted` reads only 4.1:1 there, so the card's headings, stale note, source label
  and disclaimer use `textSecondary`; `PaletteTests.aiCardTextReadsOnItsTint` checks every text
  token on the tint in both themes.
- **Touch targets.** Each chip is a laid-out 44pt-tall target (the chip itself stays small and
  centred in it), so rows of wrapped chips touch without their targets overlapping.
- **Try again** goes straight back to the skeleton, then reloads; a refresh that brings a different
  analysis closes any open citation (its id could now name another line's).
- **Offline.** `FloorAPI.billAnalysis(id:)` returns nil on the route's 404 — only when the body is
  the API's own `{ "error": … }`; a proxy's 404 page stays an error and is not saved — and saves
  `null` under the request's key, so a bill opened offline knows there was nothing rather than
  failing. A saved `null` gives way as soon as the network has an analysis. The
  analysis is a best-effort request in the screen's `revalidate` pass, like your members; the saved
  pass's miss is not a failure (`Pass.isSaved`), and a saved bill whose network pass failed before
  reaching the analysis ends in `failed`, not an endless skeleton.
- **Fixture.** `ModelsTests/Fixtures/bill-analysis.json` is H.R. 6363's real CRS summary (from the
  eval set) run through the worker's own `analyzeBill` with the claim wording of
  `analysis.test.ts`, shaped as `pg.ts` returns it — not a captured response, since staging has no
  analyses yet.
- **Snapshots.** `AIAnalysisSnapshotTests` draws the section on its own (citation open in light,
  dark and AX5; stale; No summary yet; failed), recorded on the iOS 26.2 "Floor Snapshots"
  simulator. The Bill screens' own snapshots are unchanged: their fixture server answers the
  analysis route 404 and every captured bill has a summary, so the section is hidden there. The
  skeleton has no reference (it animates). At AX5 the first render overflowed the card sideways —
  the `CRS ¶5 · Sec. 101` chip was wider than the line — so chips now wrap inside themselves.
  **Recording on a shared simulator:** twice while recording these, a run sat for 10+ minutes
  launching `xctest` (`xpcproxy_sim` in state `U`, no test output) while other agents were using
  "Floor Snapshots" too; a `simctl shutdown`/`boot` cleared it once. The cause wasn't pinned down.
  Check `ps -eo pid,command | grep 'xcodebuild test'` before starting, and wait for another run.

**Not built, on purpose:** Layer 2 ("What it means for you") is blocked on Sourav's open decision
about which profile questions are acceptable (§6). Projections and market odds are not part of this
work.

### The landing page (v0.2.0)

Built to the locked design canvas <https://claude.ai/artifact/FKWYDhCej75UPy94csYLsU> (five rounds;
the product rules they settled are in `CLAUDE.md` › Product rules). What to know:

- **It is a snapshot.** Every figure is in `apps/web/src/data.ts` with its source and date, checked by
  `data.test.ts`. Votes come from this API; funding from FEC filings (OpenFEC); holdings and trades
  from House Clerk financial disclosures and periodic transaction reports. Refreshing it is a manual
  edit today.
- **It is deployed:** <https://floor-web-seven.vercel.app> (Vercel project `floor-web`, team Abtanix
  Labs, linked to `abhipal42/floor`, so each merge into `main` redeploys it). Unlike `floor-api`, its
  **root directory is the repo root, not `apps/web`** — the build script resolves `tsc` from the root
  `node_modules`, which a root directory of `apps/web` does not install. Settings: framework
  detection **off**, build command `npm run build -w @floor/web`, output directory `apps/web/dist`,
  install command default, Node 22. Builds in about 5s.
  Two things to know about the URL: the public one is `floor-web-seven.vercel.app`, the suffix being
  Vercel's own when the plain project name is taken; and the `floor-web-abtanix-labs.vercel.app` and
  `-git-main-` aliases sit behind the team's Vercel Authentication, so they answer `302` to anyone not
  signed in. A custom domain, when there is one, is public by the same setting.
- **What's live and what's the sample (v0.3.0 steps 2–3).** The "your members" strip (since
  v0.2.13 a slim bar inside 04 · Your reps, under the report; its member chips are hidden there) and the scouting report read the API in the browser; everything else is still the
  `data.ts` snapshot. Built to the locked mock `LocWeb` (canvas round "Your members"):
  - **Strip** (`#yours`, `src/locate.ts` state machine + `yours()` in `main.ts`): idle shows the NY-8
    sample labelled SAMPLE → *Use my location* (button reads "Waiting for your browser…" while the
    permission prompt is up) → skeleton chips → your district, members as chips, "Not your district?
    Type an address", "Back to the sample". Blocked location and no fix (timeout/unavailable) open the
    address field. A 404 from `/v1/reps` means two things: for a **point** it is "Not in a U.S.
    district"; for an **address** it is the geocoder not matching it, "We couldn't find that address"
    (the API's own words). A 400 on an address is an address problem, 429 is "Too many lookups, try
    again in a minute", a 200 with no members is the vacant-seat wording, and a network or CORS
    failure is "Couldn't reach Floor's vote server"; in all of them the page stays on the sample. Every
    step with the address field has a *Cancel* back to where you came from (the sample, or the
    district you had). Addresses shorter than six characters or a bare 5-digit ZIP are refused before
    any request, as in the mock. Coordinates are rounded to 4 decimals in the page before they are
    sent.
  - **Scouting report** (`#scout`) switches to the found members: per-member tabs, portrait
    (`unitedstates.github.io/images/congress/225x275/<id>.jpg`; the `theunitedstates.io` host fails
    TLS), with-party % and "X of Y" from `/v1/members/{id}`, showed-up / winning-side / crossovers and
    the last-40 grid from `/v1/members/{id}/votes?limit=40`, and the latest call. Each member loads on
    its own: if one member's calls fail (or a vote comes back with a position outside the five the
    API documents), that tab says "Couldn't load <name>'s records" with *Try again* and the others
    show; if all fail the members stay and the panel says "Couldn't load their records". An
    independent has `partyLoyalty.votes === 0` (Sanders, checked 2026-11-12), so with-party,
    "X of Y" and crossovers read "—" and the note says there's no party bloc to measure against. A
    Speaker-ballot vote for a candidate counts as showing up but has no winning side. A delegate
    (D.C., and the territories) gets the one-member note in the strip and a DELEGATE box whose count
    and date are computed from her votes (Norton, 2026-11-12: all 40 of her last 40 are amendment
    votes, the latest Jul 22).
  - **Labelled SAMPLE once someone else's members show:** the five finals (each card's blurb and twist
    are hand-written and it carries its own party splits, so it can't honestly be rebuilt from a
    member's vote list; its "Your three" chips read "NY-8 SAMPLE"), money and donor context, the
    portfolio, and the live replay. None of them ever shows New York's money under another member's
    name. The player cards and leaderboard are national and don't change.
  - **Winning side reads the recorded result the way the app does** (`logic.ts` `outcome`, mirroring
    FloorKit `Vote.recordedOutcome`): rejection words first ("Not Agreed to", "Not Guilty", "Veto
    Sustained" are failures), then "Passed", "Agreed", "Confirmed", "Overridden", "Guilty"… carry. A
    truncated or unfamiliar result ("Motion to Discharge Re") has no outcome and is left out of the
    count instead of counted as a loss. That changed two sample figures from the locked mock:
    Schumer's winning side 14/40 → 14/38 and Gillibrand's 12/39 → 12/37 (two Senate results in their
    last 40 are truncated by the clerk).
  - **Remembered:** the found district, its Congress and its members go in `localStorage`
    (`floor.yours.v1`) so a return visit opens on them; never the point or the address. Storage
    follows the screen: leaving a found district (*Not your district?*, *Back to the sample*) clears
    it, and a new district or *Cancel* back to it writes it again, so an address lookup that fails
    after *Not your district?* can't bring the old district back on reload. A district saved for an
    earlier Congress is dropped (the 120th starts 2027-01-03; lesson 4).
  - **Privacy line diverges from the locked mock on purpose.** The mock said Floor "keeps neither the
    point nor the address". The page now says only what it does itself: "Floor rounds the point to
    about 11 m and uses it once to find your district; this page stores only the district." See the
    open item below.
  - **Open (for the API team): `/v1/reps` puts the address and coordinates in the URL.** It is a GET,
    so the address or rounded point is a query string that Vercel's request logs may record. That
    contradicts "keeps neither the point nor the address" unless log retention is short or the query
    is redacted, or the route moves to POST with the place in the body. Until one of those is done,
    the page must not make that claim.
  - **API base** is `src/config.ts` (production); `FLOOR_API_BASE=<url> npm run build -w @floor/web`
    points a build elsewhere (https or localhost only).
  - Dates on vote rows are Eastern time: a Senate vote at 7:37 p.m. on Nov 10 is `2026-11-11T00:37Z`
    in the API, and reads Nov 10 on the page (the mock, which used the UTC date, said Nov 11).
- **CORS.** `ALLOWED_ORIGINS=https://floor-web-seven.vercel.app` is set on the `floor-api` Vercel
  project (production, 2026-11-12), so the deployed site reads the API. Any other origin is refused
  and the page shows the "Couldn't reach" state: that includes `localhost` and Vercel **preview**
  deploys (`floor-web-git-<branch>-abtanix-labs.vercel.app`, which also sit behind Vercel
  Authentication). To try a preview against live data, add its exact origin to `ALLOWED_ORIGINS` and
  redeploy `floor-api`; it takes exact origins, not wildcards. Locally: only the Vercel entry
  (`apps/api/api/index.ts`) reads `ALLOWED_ORIGINS`; `npm run dev -w @floor/api` (`src/server.ts`)
  passes no origins, so a local API refuses every browser origin too. Verifying the page locally
  therefore means routing the requests in Playwright to the recorded responses in
  `apps/web/fixtures/` (captured from production with curl, 2026-11-12), which is how v0.3.0's states
  were checked.
- **New data sources, not yet ingested:** FEC (the same api.data.gov key as Congress.gov works; the
  shared `DEMO_KEY` allows 40 calls an hour) and House financial disclosures
  (`disclosures-clerk.house.gov/public_disc/financial-pdfs/<year>FD.zip` is a tab-separated index of
  every filing; `ptr-pdfs/<year>/<DocID>.pdf` are the trade reports). Senate disclosures (eFD) have no
  bulk index. Disclosures report value **ranges** and omit homes, which is why the page shows ranges.
- **The bottom form is inert.** Beta sign-up at the foot of the page shows "opens soon" until there
  is a backend. (Address entry that works is in the strip at the top.)

### Landing page round (v0.2.11)

- **Hero:** stacked and centred, built to <https://claude.ai/artifact/3Qk6vGVNnJ7h9gDjyXjJP9>
  (option C). The finals board is 24 flaps wide with at most 20 characters a line, so the text always
  has blank flaps either side; cells size from the board's width with container query units
  (`100cqi`), and phones (≤600px) hide the four padding flaps.
- **Road to law:** a sticky title and six-stop map beside one road of level cards, built to
  <https://claude.ai/artifact/WgULeauwdE8usqmXcXRkwT>. `levelCards()` in `main.ts` renders it and
  tracks the current level on scroll (rAF-throttled) through `activeLevel()`. Below 900px the aside
  is `display: contents` so its strip can stay stuck for the whole road.
- **Design context for agents:** `apps/web/PRODUCT.md` (users, purpose, binding voice and product
  rules) and `apps/web/DESIGN.md` (the dark "Night Game Broadcast" tokens as shipped). The light mode
  and Congress patina are designed elsewhere; when they land, re-run `/impeccable document` so
  DESIGN.md matches the code.
- **Editing copy visually:** `/impeccable live` (config in `apps/web/.impeccable/live/config.json`;
  `apps/web/.gitignore` keeps its runtime files out) injects a helper script into
  `public/index.html` while it runs; `impeccable live-server stop` removes it. Never commit with the
  `impeccable-live-start` block present. Rebuild (`npm run build -w @floor/web`) after each edit,
  since `serve` serves `dist/`.
- The unbuilt part of the mock is a **section rail** (a strip under the header naming the current
  section, for every section). It was offered and skipped; the mock still has the toggle.

### Pinned sections (v0.2.14)

Sections 01–06 hold still while the reader scrolls, and each stretch of scroll moves them one step.
`pin(stage, steps)` in `main.ts` does it with plain `position: sticky` over an empty run after the
stage, so scrolling is never intercepted (a fling or a keyboard jump passes through, the scrollbar
stays honest); `stickTop`, `stepLength` and `scrollStep` in `logic.ts` are the tested maths. A
reader's own click on a tab, card or Next moves the scroll to that step, and a pill at the bottom
shows the step with a **Skip** button.

| Section | Steps | Not pinned |
|---|---|---|
| 01 Finals | the five finals (a step forward keeps the deal animation); since v0.2.16 there is no Back or Next, and the dots under the card jump to a final (the only way through the deck on phones) | — |
| 02 Road to law | seven: six levels, then the condensed drive chart as the road's last box (since v0.2.17). A CSS football rides the dashed rail and the rail fills yellow behind it; the stop, ball, yellow line and lit box share one index (`setStep` in `levelCards()`), and the lane moves so the lit box sits centred | — |
| 03 Explained | the first bill's points, each lighting its source paragraph; only the current point opens | bill tabs stay manual |
| 04 Your reps | your three members; the "Make it your three" bar sits under the report | — |
| 05 Players | one: the card fan holds, then the leaderboard scrolls up below it | the leaderboard |
| 06 Money | your three members' funding (live from `/funding` once you're located, since v0.2.19) | the donor explainer |

07 Portfolio and 08 Live are deliberately not pinned (another three-member bounce straight after
Money, and a phone that already animates). A section pins only when the window is at least 900px
wide, 640px tall and tall enough for its whole stage (Explained and Money drop out on short laptop
screens), and never with reduced motion; otherwise it is the ordinary page. A stage whose content
grows while pinned (the location form opening) is re-measured by a `ResizeObserver` and lets go if it
no longer fits.

### The floating header (v0.2.15)

The header starts as a full-width bar (mark left, links centred, "Get the app" right) and draws in to
a centred glass capsule once the reader scrolls past 48px, settling back under 16px. Picked by the
owner from three options in the nav artifact (<https://claude.ai/artifact/3hyQwvnXUeJJWtGoKaQCVX>),
after Flighty's header. What to know:

- **The band's height never changes; only the inner bar moves.** Pinned sections, the Road to law
  strip and anchor offsets all read `#site-head`'s height (`--head-h`). A bar that shrank as it
  floated would make every pinned stage jump mid-scroll, so `.site-head` keeps its 72px and
  `.site-head__in` animates width, radius and fill inside it.
- **Two thresholds, not one** (`headFloats` in `logic.ts`). A phone's elastic overscroll or a
  trackpad coming to rest can sit right on a single line and toggle the bar every frame.
- **The fill is raised from Flighty's.** Theirs is `rgba(10,10,10,.2)` behind `blur(24px)`, which
  reads white on their light page because glass takes the colour behind it. On Floor's near-black
  ground it vanishes, so the capsule is `rgba(16,18,22,.62)`.
- At 860px and under the links hide, as before, and the capsule hugs the mark and the button (250px).
- **At 900px and under, the band behind the capsule turns solid once it floats.** That is where Road
  to law's level map becomes a strip stuck straight under the header. With a see-through band the
  road's cards slid past in the 10px between the floating capsule and the solid strip, which read as
  unfinished; solid, the header and strip stack as one block. The owner chose this over keeping the
  glass on phones (2026-11-13). The band carries a 1px border in both states, so the header is 73px
  here and 72px above 900, the same in both states at each width. **Keep the band's breakpoint equal
  to the strip's** (`max-width: 900px`): if they drift, the gap comes back.
- The outer band is `pointer-events: none` so the see-through area around the capsule doesn't
  swallow clicks on what scrolls under it; the bar takes them back.

### The app redesign (v0.2.3)

The iOS screens were rebuilt to the phone mocks in round 6 of the same canvas
(<https://claude.ai/artifact/FKWYDhCej75UPy94csYLsU>): `AppOnboarding`, `AppHome`, `AppVote`, `AppBill`,
`AppRep`. Palette colours are unchanged; Barlow Condensed is bundled for display type. Where the
build differs from the mocks, and why:

- **No names on the full roll.** `/v1/votes/{id}` returns party totals and your own delegation's
  positions, not every member's, so the squares are drawn from party counts and can't be tapped.
  Adding all positions to that route would make "tap a square to see who" possible.
- **Feed cards show the question type**, not the party split: the feed has no per-party numbers,
  and fetching them would be one request per card.
- **Catch-up cards show the recorded result** where the mock had a one-line bill summary, because
  that line would have to be AI-written (M4).
- **The Bill screen shows the CRS summary**, labelled as CRS. Since v0.2.27 the AI section (M4) sits above it, and the CRS panel's heading is "CRS summary" rather than "What it does", which is now the AI section's first heading.
- **Your three's Record / Money / Portfolio switch** landed in v0.2.21; see "The Money segment"
  below. Portfolio is still a placeholder.
- **BOSS levels** are marked on House or Senate only when one of the bill's own votes there needed
  60 or two-thirds; Signed is always marked (veto override).
- **"Winning side" is the outcome, not the larger side** (`sidedWithOutcome`). They differ when a
  majority loses to a threshold — H.J.Res. 1 lost 212–206.

### The Money segment (v0.2.21)

The member screen (Your three, and a member pushed from a vote) has the mock's Record / Money /
Portfolio switch, built to `AppRepMoney` (round 6, <https://claude.ai/artifact/FKWYDhCej75UPy94csYLsU>).
Code: `RepScreen/MoneyView.swift` (views), `MoneyModel` in `RepScreenModel.swift`, `Models/Funding.swift`
(models plus `MoneyFormat`, `FundingDates`, `CommitteeName`), `FloorAPI.funding(id:committees:)`.

- **Data.** `/v1/members/{id}/funding`, loaded the first time Money is shown for a member and saved for
  offline through `revalidate` like the record (`MoneyModel.needsRefresh`, `SavedDataNote`). A nil
  `funding` is an answer, not an error: "No campaign filings yet".
- **Same words as the landing page.** `CommitteeName.display`, `MoneyFormat` and `FundingDates` port
  `committeeName`, `formatMoney`/`formatPac` and `coverageRange` rule for rule, and `FundingTests` uses
  the web tests' own expectations on the same five captures (`ModelsTests/Fixtures/funding-*.json`,
  copied from `apps/web/fixtures`). Change one side, change both.
- **Where it differs from the mock:** the donor explainer ("✦ FLOOR EXPLAINS · AI") is a labelled
  "not loaded yet" card and PAC rows are not tappable, because donor context needs LDA filings and the
  M4 label-and-cite pipeline; the PAC list has a heading and names its FEC cycle (lesson 33) and a
  footnote says totals and the list won't add up (lesson 24); the period reads "2026 campaign" as the
  landing page does, not "2026 cycle"; no "NEW DATA" banner on Money (the data exists now); no back
  chevron (the switch is the way back). The header is the compact one from the Money mock in place of
  the player card; on Record the switch sits under the card, as in `AppRep`.
- **Portfolio** shows the mock's dashed "not loaded yet" box and a line on what it will show
  (ranges, never net worth). No disclosure ingest exists; that is v0.3.0 item 6.
- **Colours.** New tokens `teal` and `dim` (bar fills) and `ai` (text, so in `Tones.textTokens` and
  contrast-tested). The fills are `Tones.moneyBar`, and `PaletteTests` holds each pair of
  neighbours at 1.5:1 and each fill at 3:1 against the empty track, light and dark. That is why they
  are darker than the mock's: its teal `#2DD4BF` read 1.2:1 beside the small-dollar green, and its
  grey `#6B7280` 2.8:1 on the track. The landing page still uses the mock's colours.
- **A negative remainder.** "Transfers & other" is party money plus `other`, and the worker computes
  `other` as receipts minus every other part (`toFinanceRow` in `apps/worker/src/fec.ts`), so refunds
  and adjustments can make it negative. The app (`Funding.shown`, `shareBase`, `adjustmentNote`) and
  the landing page (`fundingFrom`'s `shareBase`, `adjustNote`) both draw it as 0 in the bar and the
  legend, take the shares of the parts drawn so they still add to 100%, and say under the legend that
  it includes refunds/adjustments. None of the five captured members is negative.
- **Money in words.** `MoneyFormat.total` and the web's `formatMoney` round before they pick the
  unit ($999,500 is "$1.00M") and put the sign first ("−$12K"). `MoneyFormat.spoken` is what
  VoiceOver hears: "17.9 million dollars".
- **Candidate committees.** A committee whose FEC type is H, S or P is another candidate's own
  campaign ("SMITH FOR CONGRESS"). It names a politician, not an individual donor, so it is listed,
  with the kind "Candidate committee" (API `pacKind`, from the stored `committee_type`; no re-ingest).
- **Dynamic Type.** Body text uses text styles; at accessibility sizes the totals stack, the legend
  goes to one column and each PAC row puts the name on its own line. VoiceOver reads the totals as one
  sentence, each legend item with its share and amount, and each PAC as name, kind, whole dollars.
- **State that outlives a view.** The section lives on `YourThreeModel` (it survives switching member)
  and the picked grid square on `RepScreenModel.selectedCall` (it survives a trip to Money, which
  rebuilds the record view).

### Widgets (v0.2.23)

Two home-screen widgets, built to the locked design, section "D · Widgets" of
<https://claude.ai/artifact/X5NwWSe1NmugSRoCKh3vBn>.

- **Small, "Latest final":** the newest *final* vote any of your members took part in — chamber,
  the bill's citation, the result word, yea and nay in yea green and nay orange, and one member's
  chip (your representative on a House vote, the first senator by surname on a Senate one). The
  result word is `Vote.outcomeWord`, i.e. what the chamber recorded, not which side had more
  votes: cloture that lost 53–47 reads REJECTED. A Speaker ballot shows its two leading
  candidates' totals and ELECTED or NO ONE ELECTED (lesson 16), never the leader as a winner.
- **Medium, "Your three · TX-37":** one row per member, representative first — position chip
  (YEA, NAY, DNV, PRESENT, or the candidate they named on a Speaker ballot), surname, citation and
  result (`H.R. 2347 · Agreed 62–21`), date. One member reads "Your delegate · DC" with a line
  saying the jurisdiction has no senators and delegates vote on amendments, not passage; a vacancy
  reads "Your two". A member with no votes yet gets a "—" chip and "No recorded votes yet".
- **Where things live.** Everything the widgets show is built and tested in FloorKit's `WidgetFeed`
  (`WidgetSnapshot.make`, `WidgetText`); `ios/FloorWidgets/FloorWidgets.swift` is the WidgetKit
  timeline and the drawing only. Colours are `Palette` tokens, light and dark; the background is
  the new `Palette.widget` swatch (#0B0C0F dark, white light), checked for contrast with the rest.
- **Data.** The widget reads the delegation from the **App Group `group.$(FLOOR_BUNDLE_ID)`** —
  `group.app.floor.ios` by default — and fetches `/v1/members/{id}/votes?limit=10` for each member
  from the same `FloorAPIBaseURL` build setting as the app, on its own session (12 s request
  timeout, no URL cache). Timeline: next refresh after 30 minutes (15 after a failure), plus a
  second entry at the moment the data turns two hours old, when a muted "As of 3:40 PM" (or "As of
  Nov 12") appears. A failed refresh shows the last snapshot saved for the same district
  (`WidgetSnapshotStore`, key `floor.widget.snapshot.v1`), else "Couldn't reach Floor". No district
  yet: "Open Floor to pick your members". The gallery placeholder is TX-37 exactly as staging
  returned it on 2026-11-12; a test checks it against the captured fixtures.
- **A refresh can be overtaken by "Change address".** `WidgetFeed.refresh` reads the delegation
  again once the votes arrive and saves (and shows) the snapshot only if it still belongs to the
  delegation in the group; otherwise it shows the empty state. Without that, a fetch in flight
  wrote the old district's votes back into the group the app had just cleared.
- **The move to the App Group.** `UserDefaultsDelegationStore.shared()` replaces the app's
  standard-defaults store. On first launch of this build it copies `floor.delegation.v1` into the
  group (a record already there wins), **keeps the old copy** so a group that turns out not to work
  loses nothing, and reloads the widgets so one already on the home screen stops saying "pick your
  members". `clear()` removes the key from both suites and `save()` drops the legacy copy, so an
  old district cannot come back. The group counts as present only when
  `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` returns a container —
  `UserDefaults(suiteName:)` hands back a process-private suite for any name, entitled or not.
  Without the group the app keeps using its own defaults and the widget shows the empty state.
- **Privacy.** Unchanged: the group holds the district, the members and their public votes —
  never an address or a coordinate (tested). The widget snapshot also drops the district's
  `countyFips`. "Change address" clears the delegation, the response cache and the widget's saved
  snapshot, then reloads the widgets.
- **Taps.** `floor://vote/<id>` (`Models/FloorLink.swift`, scheme registered in the app's
  Info.plist). Any app can open a `floor://` URL, so only ids shaped `^(house|senate)-\d+-\d+-\d+$`
  (ASCII digits) are accepted, and `FloorAPI` now escapes `/` in every path id and no longer
  encodes a path twice (`appendingPathComponent` turned `%2F` into `%252F`). The small widget opens
  its vote; each medium row opens its own vote (`Link`), and the rest of the medium widget opens the
  newest one shown. The app's `onOpenURL` hands the link to `FloorShell`, which switches to Finals
  and pushes the vote screen. A link that arrives before onboarding waits until there is a shell.
- **Tinted home screens.** In the accented and vibrant rendering modes every pixel is one tint, so
  the chips become outlines rather than fills that would swallow their text.
- **Versions.** `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` moved to the project-level
  `settings` in `project.yml`, so the app and the extension cannot disagree (App Store Connect
  rejects that). Both Info.plists use `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`.
- **Bundle ids and the group come from one setting.** `FLOOR_BUNDLE_ID` (default
  `app.floor.ios`) is the app's id; the widget is `$(FLOOR_BUNDLE_ID).widgets`; the App Group is
  `FLOOR_APP_GROUP = group.$(FLOOR_BUNDLE_ID)`, written into both entitlements and both
  Info.plists (`FloorAppGroup`, which Swift reads; fallback `group.app.floor.ios`). **A personal
  device build on your own team passes `FLOOR_BUNDLE_ID=com.yourname.floor`** to `xcodebuild` (or
  sets it in Xcode). Overriding `PRODUCT_BUNDLE_IDENTIFIER` instead gives the app and the widget the
  same id, and the old hard-coded group would have been registered under your team.
- **Signing, when TestFlight comes:** the App Group has to be registered in the developer account
  and enabled for both bundle ids, `app.floor.ios` and `app.floor.ios.widgets`.
- **Not built here:** Live Activities, push, and the AI section (M3/M4, other work in flight).

### Light mode on the landing page (v0.2.17)

The landing page has the same light direction as the app, with its own switch.

- **Where.** `:root[data-theme="light"]` in `apps/web/public/styles.css` redefines every page colour
  token. The dark rule's selector also matches `.flap`, `.ticker`, `.field` and `.phone` under the
  light theme, so those lit displays keep the dark values. A new colour token needs a light value
  too, or `theme.test.ts` fails.
- **Switch.** `#theme-btn` in the header steps System → Light → Dark. `theme.ts` holds the rule;
  `localStorage` key `floor-theme`. The inline script at the top of `index.html` repeats the rule so
  the first paint is right, and `theme.test.ts` runs it against the module's answer.
- **Light text is darker than the app's.** Yea is `#0a7353` here, not the app's `#0b7a57`, because
  the page's chip surface (`--surface-2`, `#e2e7e5`) is darker than anything in the app.
- **Checked** at all six standard viewports, header at rest and floating, in light mode; the other
  sections were walked at 1440 × 900 in light and spot-checked in dark.

### Light mode (v0.2.5)

The app follows the system appearance. Dark is the canvas palette, unchanged; light is direction D,
"Marble & Patina", from the re-theme proposal (<https://claude.ai/artifact/AinA8SbyMWgrsC2rsB5U9h>).

- **Where colours live.** Each token in `DesignSystem/Palette.swift` is a `Swatch` with a light and
  a dark hex; `Tones` lists them as data and `Palette` turns them into `Color`s that resolve from
  the current appearance. Add a colour by adding a `Swatch`, never a literal in a view.
- **Lit displays stay dark.** The split-flap board (Finals) and the turf scoreboard (Vote) call
  `litObject()`, which pins them to dark, so every token inside resolves to its dark value. Silver
  (the player card) is the same in both appearances, so text on it uses `Palette.silverInk`.
- **Contrast is tested.** `PaletteTests` fails if a text token drops below 4.5:1 on the ground, a
  panel or a card in either appearance (lesson 25).
- **Not decided yet:** the yea and nay hues (the proposal's round 2 compares four pairings) and the
  accent. Light mode uses the proposal's patina accent and darker versions of today's green and
  orange.
- **Appearance switch (v0.2.6).** The round button beside the district chip on Finals
  (`AppearanceMenu`) offers System, Light or Dark, stored under the `appearance` key in
  `UserDefaults`. `FloorApp` applies it by setting the window's `overrideUserInterfaceStyle`
  rather than `preferredColorScheme`, because `preferredColorScheme(nil)` does not reliably return
  to following the system once it has been set. Onboarding has no switch; it follows the last choice.
- **Not mocked:** the proposal mocked Home only. Vote, Bill, Your three, Onboarding and the deck take
  their light colours from the same tokens without a screen-by-screen mock.

### v0.3.0: Your members on the web (in progress)

**Goal:** the landing page shows *your* three members, found from your location, instead of the
fixed New York demo (Jeffries, Schumer, Gillibrand). Approved by Sourav on 2026-11-12. Intermediate
steps ship as 0.2.x PATCH releases; 0.3.0 closes the milestone with its retro.

1. **Location → your members (API).** Landed in 0.2.2: `/v1/reps?lat=&lng=`. CORS for the site is
   on: `https://floor-web-seven.vercel.app` is in `ALLOWED_ORIGINS` on the `floor-api` Vercel project
   (2026-11-12).
2. **Mock for Ishan.** Locked 2026-11-12 (canvas round "Your members", `LocWeb`). **Built:** the
   strip under the site header with every state in the mock, plus "no fix" and "couldn't reach the
   server"; see "The landing page" above for what each state does.
3. **Sections the API already serves.** **Built:** the scouting report switches to your members
   (loyalty, last 40, latest call, the delegate case). The five finals stay on the sample, labelled:
   a card's blurb and twist are hand-written, so the deck can't honestly be rebuilt from vote lists.
   The player cards are a national leaderboard and don't depend on your district.
4. **Campaign finance for every member.** Data landed in 0.2.4: `campaign_finance` (OpenFEC
   totals for each member's current campaign: small-dollar, itemized, PAC, party, other, cash on
   hand) and `pac_contributions` (every committee's direct and earmarked totals per member from the
   2026 bulk file, with FEC's organization type for the "kind"). **The API route landed in 0.2.13:**
   `/v1/members/{id}/funding`, which keeps the two FEC sources apart (lesson 24) and excludes party
   and joint fundraising committees (lesson 23). **The page section landed in 0.2.19:** "Who
   funds them" loads the route for each member found by location (`fundingFrom` and `committeeName`
   in `apps/web/src/locate.ts`), with a "no campaign filings yet" card for the 25 members FEC has no
   current totals for, and a per-member Try again. The NY sample still uses the `funding` snapshot.
   Gaps: about 22% of PAC dollars come from committees FEC gives no organization type, so they show
   with no kind; names are title-cased from FEC's capitals by rule, so an odd one (L3HARRIS) slips
   through; the donor explainer below stays Jeffries' until donor context (item 5) lands.
5. **Donor context** from Senate LDA lobbying filings (what each PAC's organization lobbies on),
   matched to the member's votes by topic. The plain-English "who they are" lines are AI-written and
   wait for M4's label-and-cite pipeline.
6. **Financial disclosures: spike first.** House filings are PDFs (some scanned); Senate eFD has no
   bulk index. 5 U.S.C. §13107 bars using these reports for commercial purposes other than news
   media, so the spike reports both what parses reliably and the open legal question before any
   build.

### Round 10: follow bills and topics — the server side (v0.2.26)

**Design:** locked artifact "Round 10 · Follow bills and topics"
(<https://claude.ai/artifact/8Qfr9ymPEKuYGSLjiuXdS2>). This PR is the API and data only; the
Following tab's Bills and Topics segments, the topic page and "+ Add" search are a later iOS PR on
these routes, and member following is being built separately.

- **Every bill of the Congress** (`apps/worker/src/catalog.ts`, command `bill-catalog`). Lists
  `/bill/{congress}` 250 at a time oldest update first, upserting what the list gives (title, type,
  number, origin, introduced date, latest action, `updateDate` → `list_updated_on`); then fetches the
  detail of each bill whose list date is newer than its `details_fetched_at` (bill + actions always;
  summaries only when it has one; titles only when the title is not already a short one — lesson 48);
  then stages every fetched bill that has no stage. Bills already fetched that changed are fetched
  before never-fetched ones (`order by (details_fetched_at is null), details_fetched_at, …`), so the
  backfill never holds up a followed bill's news. Actions are paged past 250. Concurrency 4, paced
  by `RequestBudget` (default 4,500 requests an hour, `--rate`; client retries count), capped per
  run (`--budget`, default 1,200); it stops quietly on a 429 that survives the client's retries, or
  once the key's `X-RateLimit-Remaining` is below the reserve (`--reserve`, default 500; lesson 51).
  A re-list only writes rows whose listed fields changed (`is distinct from`), a page is
  deduplicated by id before its upsert, and a full listing logs a warning when the stored count
  differs from Congress.gov's `pagination.count`. It logs what is due and the estimated requests
  and hours to clear it. The per-vote `bills` step is unchanged and still links
  votes; it now also stamps `details_fetched_at` and restages the bill after linking.
- **The hourly ingest** (`ingest.yml`) runs `bill-catalog --budget 1200` after Nominations, and
  `--full` at 06 UTC and on manual runs (lesson 47). Still inert until the repo has its secrets.
- **Stage** (`apps/worker/src/stage.ts`, stored in `bills.stage`, formerly the never-written
  `status`): `introduced`, `passed_house`, `passed_senate`, `passed_both`, `to_president`, `law`,
  `vetoed`, `failed`, and `adopted` for a resolution agreed to by every chamber it needs. The same
  reading as FloorKit's `BillProgress`/`LawLevels` — Congress.gov's chamber-less summary markers, plus
  a chamber's own passage roll call when the marker lags (H.R. 1013) — tested on twelve real bills.
  "Stalled" is not stored: the API computes it per request (not settled, no action in 90 days). A
  failed motion to proceed or cloture, or a failed suspension vote (lesson 50), leaves a bill
  `introduced`/`passed_*` (the design's "VOTE FAILED" chip is the latest action, which every row
  carries). Motions to table, refer, commit or reconsider never count as passage, and a concurrent
  resolution agreed to "with an amendment" is not adopted until the other chamber agrees. **A bill
  known only from the list has stage null** — the list's one latest action cannot say where it
  stands — except "Became Public Law No: …", which settles it as `law`; the API's contract already
  says null means "not staged yet".
- **Short labels** (`billLabel` in `apps/api/src/bills.ts`): the short title; else Congressional Review
  Act resolutions become "Disapproving X's rule: Y", arms-sale disapprovals "Disapproving the arms sale
  to Qatar" (with the title's own verb: "arms export" for an export licence, "arms transfer"), House rules "Rule for H.R. 140, H.J.Res. 27 and S. 619", en bloc nomination resolutions
  "Confirming nominations en bloc", and anything else loses "A bill"/"A joint resolution" and ", and for
  other purposes"; capped at 160 characters at a word. Deterministic, tested on 16 real titles and one
  constructed transfer title.
- **Search** uses `bills.search`, a stored generated `tsvector` (short title A, title B, summary C)
  with a GIN index, queried with `websearch_to_tsquery`. Member matching is `memberQuery` in `pg.ts`,
  written to be shared: the member-following work's `GET /v1/members?q=` (not on `main` when this
  landed) should call it rather than parse names again.
- **Topics** are the 32 CRS policy areas (`POLICY_AREAS`). Congress.gov also uses "Private
  Legislation"; it is not offered as a topic. Counts are per Congress (default: the one in session,
  `congressOn`), so the design's "29 bills with a floor vote" for Health (both Congresses) reads 9 for
  the 119th alone until the backfill adds the rest.
- **Swift:** `BillStage`, `TopicFilter`, `BillListItem`, `Topic`, `TopicList`, `TopicBills`,
  `SearchResults` in `FloorKit/Sources/Models/Topics.swift` (samples in `TopicSamples.swift`), covered
  by `ContractTests`. `BillListItem` decodes a stage it does not know as nil, so a stage added on the
  server cannot fail a page. No client methods or UI yet.

**Turning it on (in this order):**

1. Apply `supabase/migrations/20261115000000_bill_catalog.sql` (renames `bills.status` to `stage` with
   a check, adds `list_updated_on`, `details_fetched_at` — set to `updated_at` for the 1,050 bills
   already stored — and the generated `search` column with its GIN index, plus `bills_topic`). No new
   table, so no new policy: `bills` keeps its public read policy. Re-run Supabase's security advisor
   afterwards anyway (lesson 8). **Apply it before running this version's worker**: `bills` and
   `bill-catalog` write the new columns and fail without them. The API is safe either way: until the
   migration the topic pages and bill search answer empty (`liveQuery`), and `/v1/topics` counts by
   `policy_area`, which exists already.
2. Run the backfill once, from a machine with the production `.env`. Measured on 2026-11-13: 19,964
   listed, ~19,400 of them never fetched, ~2.35 requests a bill → about **46,000 requests**. The
   hourly ingest shares the key (its catalog step alone spends up to 1,200 an hour), so either:
   - **leave the workflow running and slow the backfill down** (~16 hours):
     `npm run ingest -w @floor/worker -- bill-catalog --full --budget 46000 --rate 3000`; or
   - **pause the workflow** (`gh workflow disable ingest.yml -R abhipal42/floor`), run
     `npm run ingest -w @floor/worker -- bill-catalog --full --budget 46000` (~10 hours at the
     default 4,500 an hour), then `gh workflow enable ingest.yml -R abhipal42/floor`.

   Either way the run stops itself if the key drops below 500 requests left this hour (lesson 51);
   it resumes where it stopped (run it again). Without a manual run, the hourly step clears it in
   about 38 runs (~1.6 days) once the repo has its secrets. The run stages all 1,050 existing bills
   from their stored actions on its way out, with no requests; bills not yet fetched stay unstaged.
3. Then add `bill_catalog: 48` to `MAX_AGE_HOURS` in `apps/api/src/app.ts`, so `/v1/status` watches the
   source. It is left out until the first run, or `/v1/status` would report `ok: false` (and the alerter
   fire) from the moment this deploys.

### M5: Beta hardening + App Store
Accessibility (Dynamic Type, VoiceOver on score cards), privacy labels, a vote-night load test, App Review prep, public TestFlight.

**Accessibility — done for the score cards, member cards and the vote screen (v0.2.25).** The rest
of the app (Bill, Rep, Home's header and deck, onboarding's form) still uses fixed sizes; that is
the remaining M5 accessibility work. Seen in the AX5 references and not fixed here: onboarding's
"PULL YOUR THREE." headline truncates to "PULL…", and Home's "YOUR FINALS" wraps beside its
chamber filter.

- **Dynamic Type.** Every `.font(.system(size: N))` was a fixed size that ignored the reader's
  setting. `scaledFont(N, weight:)` (`DesignSystem/ScaledFont.swift`) draws the same N points at the
  default size — so the locked mocks are unchanged — and grows with the text style nearest N
  (`Typography.textStyle(forPointSize:)`: 11 → caption2, 13 → footnote, 15 → subheadline…).
  Applied to `ScoreboardCard`, the vote screen, Home's delegation cards and onboarding's member
  cards. Where the mock has a fixed row: `ViewThatFits` falls back to stacking (the card's header
  and footer, the broadcast header, the threshold caption, the ballot rows, the full roll's header
  and party buttons); your members' rows and the three member cards switch to one column at
  accessibility sizes (`AnyLayout`), as do the vote screen's result strips (PASSED above the title,
  not a column beside it that left the title a few letters a line); the box score gives each
  party's name its own row at accessibility sizes, and its cells take a `minimumScaleFactor`
  rather than clip; a card title's three-line limit becomes eight at accessibility sizes (not unlimited: the
  1,309-character title would fill several screens). The big scores
  and the card's YEA/NAY column labels stay at the mock's size, as before — they are a fixed row,
  and VoiceOver reads the card as a sentence anyway. The navigation
  bar's roll label stays fixed too: a navigation bar does not grow. Checked by the AX5 snapshots.
- **VoiceOver.** Each score card is one element reading one sentence, built by `Spoken` (`Models`,
  tested in `SpokenTests` on real fixtures): "H.R. 1013, On Passage, passed, 295 yea to 128 nay; your rep
  Jeffries voted nay. Retirement Fairness for Charities and Educational Institutions Act of 2025.
  House, Nov 11, needed 212." The outcome and your members come first, the title and detail after,
  because a VoiceOver user swiping the feed hears the first clause of every card. Senators who voted
  alike are read together ("your senators Cornyn and Cruz voted yea"); a Speaker ballot says who
  led and that nobody was elected (lesson 16). Member cards spell the seat out ("Representative for
  Texas' 37th District") instead of reading "House · TX-37" as "House dot T X dash 37".
- **Reduce Motion.** Audited: the only animations are the split-flap board's scramble and the
  catch-up deck's count-up and card throw, and both already drew settled under Reduce Motion. Both
  now also honour `playsArrivalAnimations` (an environment value, default true), because SwiftUI's
  Reduce Motion value is read-only and the snapshot tests need the settled frame. Onboarding's
  `.transition(.opacity)` is a crossfade, which Reduce Motion permits.

**Privacy manifest and App Store privacy labels (v0.2.25).** `ios/Floor/PrivacyInfo.xcprivacy`
for the app and `ios/FloorWidgets/PrivacyInfo.xcprivacy` for the widget extension (an extension is
its own bundle and needs its own), both checked by `PrivacyManifestTests`. XcodeGen copies each
into its target's bundle from the target's `sources` folder.

- **Required-reason APIs:** `UserDefaults` only. The app: **CA92.1** for its own defaults (the
  appearance choice, `@AppStorage`, and the pre-widget copy of the district it migrates from) and
  **1C8F.1** for the App Group suite it writes the district and members to
  (`UserDefaultsDelegationStore.shared`). The widget: **1C8F.1** only — it reads and writes that
  suite. None of
  the other categories is used — no file timestamps (the SwiftData cache deletes its store files but
  never reads their dates), disk space, boot time or active keyboards. Re-check this when adding an
  SDK: each SDK ships its own manifest.
- **Tracking:** none, no tracking domains, in either bundle.
- **Collected data:** the app, Precise Location, Physical Address and Coarse Location; the
  widget, Coarse Location. All **not linked**, **not used for tracking**, purpose **App
  Functionality** only. Coarse Location because every request after onboarding names your members
  by Bioguide ID in its path (`/v1/members/{id}/votes`), and three members identify one district.

App Store Connect › App Privacy, the answers to give:

| Question | Answer |
|---|---|
| Do you or your third-party partners collect data from this app? | **Yes** |
| Location › Precise Location | Collected. Used for **App Functionality**. **Not linked** to identity. **Not used for tracking** |
| Location › Coarse Location | Collected. Used for **App Functionality**. **Not linked**. **Not used for tracking** |
| Contact Info › Physical Address | Collected. Used for **App Functionality**. **Not linked**. **Not used for tracking** |
| Every other type (identifiers, usage data, diagnostics, contacts, health, financial, browsing, search, purchases, user content, sensitive info) | **Not collected** |
| Resulting label | *Data Not Linked to You:* Location, Contact Info. *Data Used to Track You:* none. *Data Linked to You:* none |

Why "collected" when Floor keeps neither: collected under Apple's definition, the address or
coordinates leave the phone and may be kept beyond the request by the hosting provider's request
logs and by the U.S. Census geocoder, whose retention Floor does not control. Floor's own code
stores neither and never joins them to any identifier. (The API rounds coordinates to four
decimals, ~11 m, which is still "precise" by Apple's three-decimal line.) The stricter answer
costs a few words on the label; the looser one, if wrong, is a rejected or pulled app.
**Follow-up, not done:** `/v1/reps?address=` carries the address in the query string, which is
exactly what request logs keep. Moving that input from the query string to a `POST` body would
keep it out of Vercel's logs; it is an API and client change, so it is its own PR. No
crash reporter or analytics SDK is in the app; adding one changes this table (Diagnostics, and
probably Identifiers).

---

## 6. Open product decisions (owner: Sourav)

- Ship the House OCR tally if M3 validates it, or launch with "vote open → result" only?
- Show prediction-market odds at all, or only our own projection?
- Which optional profile questions are OK for "What it means for you"?
- Android timing.
- Production Supabase project and API hosting (staging is on the free tier).
