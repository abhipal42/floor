# Handoff: where Floor stands and what's next

Last updated 2026-11-12. Read this first, then [`plan.md`](plan.md) for the full design and reasoning.

**In one paragraph:** M0 (foundation) is done. M1 (data backbone) is done; the one item still open against it, measured posting latency, has moved to M3, because it can only be taken on a live session day with polling running. Staging Postgres holds every House and Senate roll call since January 2023, and every one matches the official totals; every vote now has a subject attached, bills and nominations alike. The API serves district lookup, member votes, votes, bills, nominations and data freshness from that database, and now also the per-party breakdown of a vote, your own delegation's positions on it, and a member's party-loyalty record. **M2 is nearly done:** the API is deployed at <https://floor-api.vercel.app> and a Release build of
the app runs the whole flow against it — onboarding to a real district, then Home, Vote, Bill and
Rep. Since v0.2.3 those screens match the landing page (three tabs: Finals, Bills, Your three). Three
items remain, listed at the top of the M2 section: a SwiftData offline cache, snapshot tests, and
TestFlight distribution.

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
npm run check           # lint + typecheck + 131 tests; must pass before every PR
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
npm run ingest -w @floor/worker -- fec-totals                     # campaign totals for every current member (OpenFEC, ~10 min)
npm run ingest -w @floor/worker -- fec-pacs 2026                  # committee-to-candidate totals from the FEC bulk files (~30 s)
npm run openapi -w @floor/api                                    # regenerate apps/api/openapi.json after changing routes
npm run build -w @floor/web && npm run serve -w @floor/web       # build and serve the landing page from apps/web/dist
swift test --package-path ios/FloorKit                           # all FloorKit tests (96): models, contract, client, screen models
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
| `packages/shared` | Types + roll call parsers (House Clerk XML, Senate LIS XML) | `src/rollcall.ts`, fixtures in `fixtures/` (real government files) |
| `packages/db` | Migration loader used by tests | `src/migrations.test.ts` |
| `supabase/migrations` | Postgres schema (applied to staging in filename order) | 7 migrations, all applied to staging |
| `apps/worker` | Ingest CLI: members, roll calls, bills, nominations | `src/cli.ts`, `rollcalls.ts`, `bills.ts`, `nominations.ts`, `members.ts`, `db.ts` |
| `apps/api` | Hono REST API with OpenAPI at `/openapi.json` | `src/app.ts` (routes + schemas), `pg.ts` (Postgres), `district.ts` (Census) |
| `apps/web` | Landing page (v0.2.0): static HTML/CSS/TypeScript built with `tsc`, no framework | `src/data.ts` (every figure, with source and date), `src/logic.ts` (pure helpers), `src/main.ts` (rendering), `public/` |
| `ios/` | SwiftUI app (XcodeGen, `project.yml`), `FloorKit` package: `Models`, `APIClient`, `DesignSystem`, `Onboarding`, `Home`, `VoteScreen`, `BillScreen`, `RepScreen` | `FloorKit/Sources/Models/` (one file per area, `Samples.swift` for previews), `FloorKit/Tests/ModelsTests/ContractTests.swift`, `DesignSystem/ScoreboardCard.swift`, `DesignSystem/Components.swift`, `DesignSystem/Fonts/` (Barlow Condensed, OFL), `Home/FloorShell.swift` (tabs), `Home/CatchUp.swift`, `Models/VoteOutcome.swift`, `BillScreen/LawLevels.swift` |
| `.github/workflows/ci.yml` | Node job (lint/typecheck/tests + OpenAPI drift) + macOS job (Swift tests + simulator build). **Pushes to `main` only** since 2026-11-13 — a PR never builds the code | |
| `.github/workflows/guards.yml` | Shipping guards on every PR (the only workflow that still runs there): changelog, version, docs, tests, retro, PR title | `.github/scripts/guards.conf` (this repo's settings), `guards.sh` (shared, do not edit) |
| `docs/` | `plan.md` / `plan.html` (design + plan), this file, `retros/` (one per milestone) | |
| `VERSION`, `CHANGELOG.md` | Current version (mirrored by `MARKETING_VERSION` in `ios/project.yml`) and what each version shipped | |

### API endpoints (all live against staging)

| Route | Returns |
|---|---|
| `GET /v1/reps?address=` or `?lat=&lng=` | District (119th Congress map) + House member + senators. Send an address *or* coordinates (e.g. from the browser's location), not both. Coordinates are rounded to 4 decimals (~11 m). Either goes only to the Census geocoder and isn't stored or logged. |
| `GET /v1/members/{id}` | A member, plus how often they sided with their own party's majority |
| `GET /v1/members/{bioguideId}/votes?limit=` | A member's recent votes with their position (and candidate, for Speaker elections) |
| `GET /v1/votes/{id}` | One vote: totals, threshold, kind, bill link, **per-party breakdown**, and for a Speaker election **which candidate each party backed**. `?members=A000370,C001098` (up to ten) also returns those members' own positions, so the vote screen loads your delegation in one round trip. IDs look like `house-119-1-100` |
| `GET /v1/bills/{id}` | Title, short title, CRS summary, sponsor, policy area, CBO estimates, last 30 actions, every vote on it. IDs look like `119-hr-2207` |
| `GET /v1/nominations/{id}` | Nominee, position, agency, received and latest action, every Senate vote on it. IDs look like `119-pn-1093-3` |
| `GET /v1/status` | Last successful run and last error per ingest source, with `stale` flags |
| `GET /openapi.json` | The contract. The Swift models are hand-written against it, and `ContractTests` fail CI if they drift (see M2). |

### Data in staging (as of this commit)

| Table | Rows | Notes |
|---|---|---|
| `members` | 716 | Everyone serving now, plus anyone whose last term ended after 2022-11-01. One party is corrected on ingest; see lesson 14 |
| `votes` | 3,532 | House + Senate, 118th–119th Congress, Jan 3 2023 → Nov 11 2026. 20 are Speaker elections (`kind = 'election'`). Every vote with a measure reference is linked to a bill or a nomination |
| `vote_positions` | 995,806 | Verified: every vote's positions add up to its official totals; no vote lacks positions |
| `bills` / `actions` | 1,049 / 19,714 | Every bill a vote refers to; 976 have a CRS summary. All 2,319 votes on bills are linked (`votes.bill_id`) |
| `nominations` | 448 | Every nomination a vote refers to; 201 are parts of a split nomination, 10 are military (no named nominee). All 905 nomination votes are linked (`votes.nomination_id`) |
| `campaign_finance` | 512 | One row per current member: OpenFEC totals for their current campaign to date (House 2025–26; senators since their last election), with cash on hand. Of 537 current members, 23 have no totals filed for that campaign and 2 appointed senators (OK, SC) have no FEC ID yet; the page must say so rather than show nothing |
| `pac_contributions` | 103,564 | Per member and giving committee, 2026 cycle: direct and earmarked totals, committee designation, type and organization type. No memo text, no individual names (lesson 23) |
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

The working rhythm: break each milestone into tasks. For each task, write tests on real saved data first, then build and run `npm run check`. Ship it as a short branch and a PR into `main` — bump `VERSION` (and `MARKETING_VERSION` in `ios/project.yml`), add a `CHANGELOG.md` entry, and title the PR `vX.Y.Z type: summary`. The `guards` check must be green before merging, but it does not build anything: `ci.yml` runs on `main` after the merge, so the local commands in `CLAUDE.md` › Before every PR are the real gate, and a red trunk is reverted rather than left. A MINOR bump (a milestone) also ships a retro in `docs/retros/`. The full rules are in [`CLAUDE.md`](../CLAUDE.md#shipping).

### M2: iOS core on real data
**Goal:** a TestFlight build that shows how your reps voted, from real data. No live updates yet.

> **M2 is not finished.** The app works end to end against the deployed API — onboarding, Finals,
> Vote, Bill and Your three, all on real data — but three items from the list below are still open
> (item 1 is kept for the record):
>
> 1. ~~**The Speaker election card on Home.**~~ **Done in v0.2.3** (`ScoreboardCard`'s Speaker-ballot
>    variant, "MAJORITY OF NAMES"). What it was: Built on the Vote screen, never on the feed. `HomeView`
>    hands every vote to `ScoreboardCard`, and a Speaker ballot has `yea: 0, nay: 0`, so it renders
>    as "0 … Final … 0, Needs 1" — a meaningless card, under a row summary that is correct
>    ("Doggett voted Jeffries"), which makes it look like bad data rather than a missing variant.
>    Rare today (one member has a ballot in their last 25 votes) but it is the top of every feed in
>    January of a new Congress, fifteen times over in a contested one. Smallest of the four and the
>    only one that is visibly wrong.
> 2. **SwiftData offline cache.** Not started.
> 3. **Snapshot tests per card state.** Not started; filed as
>    [#1](https://github.com/abhipal42/floor/issues/1) with the states to cover and the
>    Xcode-version tension against running CI on `macos-latest`.
> 4. **TestFlight distribution.** Needs an Apple Developer account, signing and the upload. The
>    build itself is proven: see **Exit** below.
>
> One judgement call to be aware of: the Onboarding bullet reads *an address field (**or** "use my
> location" …)*, and only the address field is built. Read strictly that satisfies the bullet; if
> you want both, it is unbuilt work and not tracked anywhere.

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
- ~~**Onboarding**~~ **Done** (address field only; see the note above about "use my location").
  Resolves through `/v1/reps`, shows who it found, and stores the district and members only once
  confirmed. The address is used for one request and dropped — it is not part of `Delegation`, so it
  never reaches disk, and a test encodes a saved record to assert the typed address does not appear
  in it.
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
- **SwiftData cache for offline — not started.** Items 2 and 3 above.
- **Snapshot tests for each card state — not started**, filed as
  [#1](https://github.com/abhipal42/floor/issues/1). Worth knowing why it matters here: every layout
  bug in this milestone — the stacked digits, a duplicated title, a date rendering a day early — was
  caught by eye on a simulator screenshot, not by a test, and the unit tests cannot reach that
  layer.
- **Backend for M2:** ~~CORS and rate limiting~~ **Done**, and the API is **deployed**:
  <https://floor-api.vercel.app> (Vercel project `floor-api`, team Abtanix Labs, root directory
  `apps/api`, Node 22, framework detection **off**). Two things that cost a deploy each, so do not
  undo them: Vercel's Hono preset only looks for an entrypoint under `src/` that imports `hono`
  directly and never sees `api/`, hence framework `null` plus `vercel.json`; and the handler must use
  `@hono/node-server/vercel`, not `hono/vercel` — the latter returns a fetch-style handler while the
  Node runtime calls `(req, res)`, so every request hangs to the function timeout.
  `DATABASE_URL` is set and the deployment serves real data; `/v1/status` reports `ok: true`.
  Three things about that variable, each of which cost a failed deploy:
  - **It must be the pooler string, and the username differs too.** Not
    `postgres@db.<ref>.supabase.co:5432` — that host does not resolve from Vercel at all (Supabase's
    direct connections are IPv6-only), so it fails with `ENOTFOUND` rather than a timeout. Use
    `postgres.<ref>@aws-1-us-east-1.pooler.supabase.com:6543`.
  - **It is `aws-1`, not `aws-0`.** Supabase's docs and most examples show `aws-0-us-east-1` for this
    region; that host exists but rejects the tenant with "tenant/user not found".
  - **Changing it needs a redeploy.** Vercel bakes environment variables into a deployment at build
    time, so an existing deployment keeps the environment it was built with.

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
- **Live data needs CORS — but not yet.** The page makes no requests at all today: it is pure static
  HTML, CSS and compiled TypeScript, with every figure baked in at build time. If it ever reads the
  API in the browser, add its origin to `ALLOWED_ORIGINS` on the `floor-api` Vercel project and
  redeploy, since unset means no browser origin may read a response.
- **New data sources, not yet ingested:** FEC (the same api.data.gov key as Congress.gov works; the
  shared `DEMO_KEY` allows 40 calls an hour) and House financial disclosures
  (`disclosures-clerk.house.gov/public_disc/financial-pdfs/<year>FD.zip` is a tab-separated index of
  every filing; `ptr-pdfs/<year>/<DocID>.pdf` are the trade reports). Senate disclosures (eFD) have no
  bulk index. Disclosures report value **ranges** and omit homes, which is why the page shows ranges.
- **Forms are inert.** Beta sign-up and address entry show "opens soon" until there is a backend.

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
- **The Bill screen shows the CRS summary**, labelled as CRS, where the AI explainer will go (M4).
- **Your three has no Record / Money / Portfolio switch** until Money and Portfolio have data
  (FEC and disclosure ingest; see the landing page section).
- **BOSS levels** are marked on House or Senate only when one of the bill's own votes there needed
  60 or two-thirds; Signed is always marked (veto override).
- **"Winning side" is the outcome, not the larger side** (`sidedWithOutcome`). They differ when a
  majority loses to a threshold — H.J.Res. 1 lost 212–206.

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

1. **Location → your members (API).** Landed in 0.2.2: `/v1/reps?lat=&lng=`. Still needed before the
   site can call it: `https://floor-web-seven.vercel.app` in `ALLOWED_ORIGINS` on the `floor-api`
   Vercel project, then a redeploy (someone on the Abtanix Labs team).
2. **Mock for Ishan.** The location prompt, the "your members" switcher, and the loading, denied,
   not-found and no-data states, as a claude.ai artifact. The web UI work waits for his lock
   (`CLAUDE.md` › Large UI changes).
3. **Sections the API already serves:** five finals (how *your* members voted), scouting report
   (last 40 roll calls), player cards (party loyalty).
4. **Campaign finance for every member.** Data landed in 0.2.3: `campaign_finance` (OpenFEC
   totals for each member's current campaign: small-dollar, itemized, PAC, party, other, cash on
   hand) and `pac_contributions` (every committee's direct and earmarked totals per member from the
   2026 bulk file, with FEC's organization type for the "kind"). Still to do: the API route and the
   section, which waits on the mock lock.
5. **Donor context** from Senate LDA lobbying filings (what each PAC's organization lobbies on),
   matched to the member's votes by topic. The plain-English "who they are" lines are AI-written and
   wait for M4's label-and-cite pipeline.
6. **Financial disclosures: spike first.** House filings are PDFs (some scanned); Senate eFD has no
   bulk index. 5 U.S.C. §13107 bars using these reports for commercial purposes other than news
   media, so the spike reports both what parses reliably and the open legal question before any
   build.

### M5: Beta hardening + App Store
Accessibility (Dynamic Type, VoiceOver on score cards), privacy labels, a vote-night load test, App Review prep, public TestFlight.

---

## 6. Open product decisions (owner: Sourav)

- Ship the House OCR tally if M3 validates it, or launch with "vote open → result" only?
- Show prediction-market odds at all, or only our own projection?
- Which optional profile questions are OK for "What it means for you"?
- Android timing.
- Production Supabase project and API hosting (staging is on the free tier).
