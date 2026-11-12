# Handoff: where Floor stands and what's next

Last updated 2026-11-12. Read this first, then [`plan.md`](plan.md) for the full design and reasoning.

**In one paragraph:** M0 (foundation) is done. M1 (data backbone) is done; the one item still open against it, measured posting latency, has moved to M3, because it can only be taken on a live session day with polling running. Staging Postgres holds every House and Senate roll call since January 2023, and every one matches the official totals; every vote now has a subject attached, bills and nominations alike. The API serves district lookup, member votes, votes, bills, nominations and data freshness from that database, and now also the per-party breakdown of a vote, your own delegation's positions on it, and a member's party-loyalty record. The iOS app is still a skeleton (one scoreboard card on sample data). **M2 is in progress:** the API contract it needs is complete, and the iOS `Models` package is written against it and tested on real staging responses. The screens are next.

---

## 1. Get set up

### Access you need (ask the repo owner)

| What | Why | Who grants it |
|---|---|---|
| GitHub `abhipal42/floor` write access | Push to `main` | Repo owner |
| Supabase org "pokator's Org", project **floor-staging** (`uyyocajwihypaiosecvs`, us-east-1) | Database URL for `.env`, dashboard, SQL editor | Sourav (org owner) |
| api.data.gov key | Congress.gov bill data | Sign up yourself at https://api.data.gov/signup (free, instant) |
| The v2 design canvas (claude.ai artifact "Live Vote Tracker – UI Options") | Screen designs for M2 | Sourav (it's private; ask for a share) |

### Local setup

```bash
git clone https://github.com/abhipal42/floor.git && cd floor
npm install
cp .env.example .env    # then fill in the two values (see below)
npm run check           # lint + typecheck + 103 tests; must pass before every push
```

`.env` (never committed):

- `DATABASE_URL`: Supabase → floor-staging → **Connect** → the Postgres connection string (`postgresql://…`), not the `https://…supabase.co` API URL. The direct `db.<ref>.supabase.co:5432` host and the Session pooler both work.
- `CONGRESS_API_KEY`: your api.data.gov key.

### Run things

```bash
npm run dev -w @floor/api                                         # API on http://localhost:8787, reads .env
npm run ingest -w @floor/worker -- members                        # refresh members
npm run ingest -w @floor/worker -- rollcalls house 119 2          # new House votes this session (resumes automatically)
npm run ingest -w @floor/worker -- rollcalls senate 119 2         # same for the Senate
npm run ingest -w @floor/worker -- bills                          # load bills that votes refer to (only missing ones)
npm run ingest -w @floor/worker -- nominations                    # load nominations that Senate votes refer to
npm run openapi -w @floor/api                                    # regenerate apps/api/openapi.json after changing routes
swift test --package-path ios/FloorKit                           # Swift models + contract tests
```

`apps/api/openapi.json` is the committed contract. Re-run `npm run openapi` after any change to
`app.ts`; CI fails if it has drifted, and the Swift contract tests check the models against it.

iOS (needs a Mac with Xcode 16+): `brew install xcodegen && cd ios && xcodegen && open Floor.xcodeproj`. CI builds it on a macOS runner on every push.

---

## 2. What exists today

### Repo layout

| Path | What | Key files |
|---|---|---|
| `packages/shared` | Types + roll call parsers (House Clerk XML, Senate LIS XML) | `src/rollcall.ts`, fixtures in `fixtures/` (real government files) |
| `packages/db` | Migration loader used by tests | `src/migrations.test.ts` |
| `supabase/migrations` | Postgres schema (applied to staging in filename order) | 7 migrations, all applied to staging |
| `apps/worker` | Ingest CLI: members, roll calls, bills, nominations | `src/cli.ts`, `rollcalls.ts`, `bills.ts`, `nominations.ts`, `members.ts`, `db.ts` |
| `apps/api` | Hono REST API with OpenAPI at `/openapi.json` | `src/app.ts` (routes + schemas), `pg.ts` (Postgres), `district.ts` (Census) |
| `ios/` | SwiftUI app (XcodeGen), `FloorKit` package (`Models`, `DesignSystem`) | `FloorKit/Sources/Models/` (one file per area, `Samples.swift` for previews), `FloorKit/Tests/ModelsTests/ContractTests.swift`, `DesignSystem/ScoreboardCard.swift` |
| `.github/workflows/ci.yml` | Node job (lint/typecheck/tests) + macOS job (Swift tests + simulator build) | |
| `docs/` | `plan.md` / `plan.html` (design + plan), this file | |

### API endpoints (all live against staging)

| Route | Returns |
|---|---|
| `GET /v1/reps?address=` | District (119th Congress map) + House member + senators. The address goes only to the Census geocoder and isn't stored or logged. |
| `GET /v1/members/{id}` | A member, plus how often they sided with their own party's majority |
| `GET /v1/members/{bioguideId}/votes?limit=` | A member's recent votes with their position (and candidate, for Speaker elections) |
| `GET /v1/votes/{id}` | One vote: totals, threshold, kind, bill link, **per-party breakdown**, and for a Speaker election **which candidate each party backed**. `?members=A000370,C001098` (up to ten) also returns those members' own positions, so the vote screen loads your delegation in one round trip. IDs look like `house-119-1-100` |
| `GET /v1/bills/{id}` | Title, short title, CRS summary, sponsor, policy area, CBO estimates, last 30 actions, every vote on it. IDs look like `119-hr-2207` |
| `GET /v1/nominations/{id}` | Nominee, position, agency, received and latest action, every Senate vote on it. IDs look like `119-pn-1093-3` |
| `GET /v1/status` | Last successful run and last error per ingest source, with `stale` flags |
| `GET /openapi.json` | The contract. Generate Swift types from it in M2. |

### Data in staging (as of this commit)

| Table | Rows | Notes |
|---|---|---|
| `members` | 716 | Everyone serving now, plus anyone whose last term ended after 2022-11-01. One party is corrected on ingest; see lesson 14 |
| `votes` | 3,532 | House + Senate, 118th–119th Congress, Jan 3 2023 → Nov 11 2026. 20 are Speaker elections (`kind = 'election'`). Every vote with a measure reference is linked to a bill or a nomination |
| `vote_positions` | 995,806 | Verified: every vote's positions add up to its official totals; no vote lacks positions |
| `bills` / `actions` | 1,049 / 19,714 | Every bill a vote refers to; 976 have a CRS summary. All 2,319 votes on bills are linked (`votes.bill_id`) |
| `nominations` | 448 | Every nomination a vote refers to; 201 are parts of a split nomination, 10 are military (no named nominee). All 905 nomination votes are linked (`votes.nomination_id`) |
| `ingest_runs` | | Every ingest run with item count and error, which feeds `/v1/status` |

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
4. **Posting-latency measurement (moved to M3).** We can only measure how long the Clerk and LIS take to post roll call files on a live session day with polling running.

---

## 5. Remaining milestones

The working rhythm so far: break each milestone into tasks. For each task, write tests on real saved data first, then build, run `npm run check`, commit with a descriptive message and push to `main`, and keep CI green. Every push runs CI (Node + macOS).

### M2: iOS core on real data
**Goal:** a TestFlight build that shows how your reps voted, from real data. No live updates yet.

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
- `APIClient` package: URLSession client for the seven routes; base URL from build config (staging vs. prod). `Models` has no networking in it and no dependencies, so this is the only place URLSession appears.
- **Onboarding:** an address field (or "use my location" → reverse geocode → address) → `/v1/reps` → save state, district and member IDs locally. Never send the address anywhere except the API call.
- **Home:** your delegation strip, then recent final votes for your reps (`/v1/members/{id}/votes`), using `ScoreboardCard`. Add the Speaker election card variant, which `candidateTotals` now feeds.
- **Fix `ScoreboardCard` before building Home.** `score()` renders a 48pt condensed number inside a
  five-child `HStack`; at 402pt width SwiftUI breaks each number across lines, so 216 renders as
  2/1/6 stacked vertically. Needs `.lineLimit(1)` and a `.minimumScaleFactor()`.
- **Vote detail:** totals, threshold bar, party breakdown, how each of your reps voted — all from one `/v1/votes/{id}?members=` call.
- **Bill screen:** short title, CRS summary, sponsor, CBO links, the "Path to law" stepper built from actions, and votes on the bill.
- **Rep screen:** recent votes, and votes with/against party from `/v1/members/{id}`. Show nothing when `partyLoyalty.votes` is 0 (see lesson 15).
- SwiftData cache for offline; snapshot tests for each card state.
- **Backend for M2:** deploy the API (plan: Hono on Vercel, or a container alongside the worker) and point the app at it. Add CORS and rate limiting on `/v1/reps`.
- **Exit:** TestFlight build where a tester enters their address and sees yesterday's votes by their reps.

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

- Deploy the worker as an always-on container (Fly.io or Railway) with session-aware polling: every 10 s in session, every 5 min otherwise.
- Floor events: House Clerk floor summary XML; Senate floor activity pages (scraped, with contract tests).
- Votes get state `open` from floor events, then `final` when the roll call XML posts.
- Supabase Realtime broadcast to open apps; APNs pushes; Live Activities (push-to-start, iOS 17.2+); widgets.
- **Measure** Clerk and LIS posting latency on real session days (deferred from M1).
- House running-tally OCR prototype from the floor video → go/no-go decision.
- Alerting: page someone when `/v1/status` reports `ok: false` during a session.

### M4: AI summaries + projections
- Layer 1 bill analysis per bill version (Claude, server-side): purpose, provisions, affected groups, impact rules, section citations, plus a verifier pass and a ~50-bill eval set.
- Layer 2 "What it means for you" from coarse opt-in profile attributes + county data (Census ACS, FCC). No names or addresses go to the model.
- Projection model v1 (per-member probabilities → chamber simulation), backtested on the 3,500 stored roll calls (they're already in staging) and calibrated against a party-line baseline.
- Optional display-only market odds (pending product decision).

### M5: Beta hardening + App Store
Accessibility (Dynamic Type, VoiceOver on score cards), privacy labels, a vote-night load test, App Review prep, public TestFlight.

---

## 6. Open product decisions (owner: Sourav)

- Ship the House OCR tally if M3 validates it, or launch with "vote open → result" only?
- Show prediction-market odds at all, or only our own projection?
- Which optional profile questions are OK for "What it means for you"?
- Android timing.
- Production Supabase project and API hosting (staging is on the free tier).
