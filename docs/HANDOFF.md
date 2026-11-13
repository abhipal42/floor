# Handoff: where Floor stands and what's next

Last updated 2026-11-13. Read this first, then [`plan.md`](plan.md) for the full design and reasoning.

**In one paragraph:** M0 (foundation) is done. M1 (data backbone) is done; the one item still open against it, measured posting latency, has moved to M3, because it can only be taken on a live session day with polling running. Staging Postgres holds every House and Senate roll call since January 2023, and every one matches the official totals; every vote now has a subject attached, bills and nominations alike. The API serves district lookup, member votes, votes, bills, nominations and data freshness from that database, and now also the per-party breakdown of a vote, your own delegation's positions on it, and a member's party-loyalty record. **M2 is nearly done:** the API is deployed at <https://floor-api.vercel.app> and a Release build of
the app runs the whole flow against it — onboarding to a real district, then Home, Vote, Bill and
Rep. Since v0.2.3 those screens match the landing page (three tabs: Finals, Bills, Your three). Every
screen now opens on its last-seen data when offline or slow, from a SwiftData cache. Two items remain,
listed at the top of the M2 section: snapshot tests and TestFlight distribution.

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
npm run check           # lint + typecheck + 382 tests; must pass before every PR
```

`.env` (never committed):

- `DATABASE_URL`: Supabase → floor-staging → **Connect** → the Postgres connection string (`postgresql://…`), not the `https://…supabase.co` API URL. Use the Session pooler (`postgres.<ref>@aws-1-us-east-1.pooler.supabase.com:5432`): the direct `db.<ref>.supabase.co` host is IPv6-only and fails with `EHOSTUNREACH` on a network without IPv6 (it did from here on 2026-11-13). Close the worker when you are done with it — every open session-pooler connection is one of the 15 slots the whole project shares (lesson 37).
- `CONGRESS_API_KEY`: your api.data.gov key.

### Run things

```bash
npm run dev -w @floor/api                                         # API on http://localhost:8787, reads .env
npm run ingest -w @floor/worker -- members                        # refresh members
npm run ingest -w @floor/worker -- rollcalls house 119 2          # new House votes this session (resumes automatically)
npm run ingest -w @floor/worker -- rollcalls senate 119 2         # same for the Senate
npm run ingest -w @floor/worker -- rollcalls house current        # the session in progress (what the hourly schedule runs)
npm run ingest -w @floor/worker -- bills                          # load bills that votes refer to (only missing ones)
npm run ingest -w @floor/worker -- nominations                    # load nominations that Senate votes refer to
npm run ingest -w @floor/worker -- fec-totals                     # campaign totals for every current member (OpenFEC, ~10 min)
npm run ingest -w @floor/worker -- fec-pacs 2026                  # committee-to-candidate totals from the FEC bulk files (~30 s)
npm run openapi -w @floor/api                                    # regenerate apps/api/openapi.json after changing routes
npm run build -w @floor/web && npm run serve -w @floor/web       # build and serve the landing page from apps/web/dist
swift test --package-path ios/FloorKit                           # all FloorKit tests (248): models, contract, client, screen models
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
| `supabase/migrations` | Postgres schema (applied to staging in filename order) | 9 migrations; `20261113000100_ingest_failed.sql` is **not yet applied** to staging (lesson 38) |
| `apps/worker` | Ingest CLI: members, roll calls, bills, nominations | `src/cli.ts`, `rollcalls.ts`, `bills.ts`, `nominations.ts`, `members.ts`, `db.ts` |
| `apps/api` | Hono REST API with OpenAPI at `/openapi.json` | `src/app.ts` (routes + schemas), `pg.ts` (Postgres), `district.ts` (Census) |
| `apps/web` | Landing page (v0.2.0): static HTML/CSS/TypeScript built with `tsc`, no framework | `src/data.ts` (every figure, with source and date), `src/logic.ts` (pure helpers), `src/main.ts` (rendering), `public/` |
| `ios/` | SwiftUI app (XcodeGen, `project.yml`), `FloorKit` package: `Models`, `APIClient`, `DesignSystem`, `Onboarding`, `Home`, `VoteScreen`, `BillScreen`, `RepScreen` | `FloorKit/Sources/Models/` (one file per area, `Samples.swift` for previews), `FloorKit/Tests/ModelsTests/ContractTests.swift`, `DesignSystem/ScoreboardCard.swift`, `DesignSystem/Components.swift`, `DesignSystem/Fonts/` (Barlow Condensed, OFL), `Home/FloorShell.swift` (tabs), `Home/CatchUp.swift`, `Models/VoteOutcome.swift`, `BillScreen/LawLevels.swift`, `APIClient/ResponseCache.swift` (offline cache), `DesignSystem/SavedDataNote.swift` |
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
| `GET /v1/nominations/{id}` | Nominee, position, agency, received and latest action, every Senate vote on it. IDs look like `119-pn-1093-3` |
| `GET /v1/status` | Per ingest source: last successful run, `lastNewDataAt` (last successful run that stored anything — the freshness signal `stale` cannot give once ingest is scheduled, lesson 38), the error of its latest run with an outcome (null once a later run succeeds; `abandoned run` for one that never finished within an hour, lessons 35 and 38), and `stale` |
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
> 3. **Snapshot tests per card state.** Not started; filed as
>    [#1](https://github.com/abhipal42/floor/issues/1) with the states to cover and the
>    Xcode-version tension against running CI on `macos-latest`.
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

- Deploy the worker as an always-on container (Fly.io or Railway) with session-aware polling: every 10 s in session, every 5 min otherwise. Until then, `.github/workflows/ingest.yml` polls hourly (lesson 37), which keeps `/v1/status` fresh but is far from the 30 s goal.
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
- **The Bill screen shows the CRS summary**, labelled as CRS, where the AI explainer will go (M4).
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

### M5: Beta hardening + App Store
Accessibility (Dynamic Type, VoiceOver on score cards), privacy labels, a vote-night load test, App Review prep, public TestFlight.

---

## 6. Open product decisions (owner: Sourav)

- Ship the House OCR tally if M3 validates it, or launch with "vote open → result" only?
- Show prediction-market odds at all, or only our own projection?
- Which optional profile questions are OK for "What it means for you"?
- Android timing.
- Production Supabase project and API hosting (staging is on the free tier).
