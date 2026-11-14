# Changelog

`MAJOR.MINOR.PATCH` in `VERSION`, mirrored by `MARKETING_VERSION` in
`ios/project.yml`. The `changelog` guard enforces that the top header equals
`VERSION`, is new relative to `main`, and increases monotonically. A MINOR bump
is a milestone and ships a retro under `docs/retros/`.

Older series live in [`docs/changelog/`](docs/changelog) (0.1.x: [`0.1.md`](docs/changelog/0.1.md)).
Before 0.1.0 the history is the commit log on `main`.

## 0.2.26 — 2026-11-13

Round 10, server side: every bill of the Congress, where each stands on the road to law, and the
topic and search routes the Following tab will use. Design: the locked "Round 10 · Follow bills
and topics" artifact. No UI in this release.

### Added
- **`bill-catalog` worker command** (`apps/worker/src/catalog.ts`): lists every bill of the
  Congress from Congress.gov (`/bill/{congress}`, 250 a page, incremental from the last listing),
  fetches details only where the list says a bill changed (bill and actions; summaries and titles
  only when needed — about 2.35 requests a bill; every page of actions past 250), and stages every
  fetched bill. A bill known only from the list stays unstaged (null) unless the list says it
  became law. Changed bills are fetched ahead of never-fetched ones. Concurrency 4, paced to 4,500
  requests an hour with retries counted, capped per run (`--budget`, default 1,200), and it stops
  quietly on the key's hourly limit or once api.data.gov's `X-RateLimit-Remaining` for the shared
  key falls below a reserve (`--reserve`, default 500) left for the other jobs. Logs the budget and
  the estimated time to clear what is due. Skips the numbers the House reserves for its leadership
  and counts rows with no `updateDate`; a re-list writes only the bills that changed, and a full
  listing warns when the stored count disagrees with Congress.gov's.
- **Road-to-law stage** (`apps/worker/src/stage.ts`, `bills.stage`): introduced, passed House or
  Senate, passed both, to the President, law, vetoed, failed, and adopted for resolutions — from
  Congress.gov's summary markers and the chambers' passage roll calls, tested on twelve real bills.
  A failed motion to suspend the rules does not make a bill `failed` (H.R. 9238, S. 2503); motions
  to table, refer, commit or reconsider are never passage; agreeing "with an amendment" does not
  adopt a concurrent resolution. The per-vote bill import stages each bill after linking its votes.
- **`GET /v1/topics`**, **`GET /v1/topics/{name}/bills`** (filters all, moving, law, stalled;
  keyset-paginated) and **`GET /v1/search`** (a bill number in any spelling resolves exactly;
  otherwise full-text over short titles, titles and CRS summaries, topic names, and serving members
  by name, state or district). Rate-limited per caller and cached at the edge. "Stalled" (no action
  in 90 days) is computed per request. Companion bills are not linked to each other.
- **Plain short labels** for long CRS titles (`billLabel`): "Disapproving the Department of
  Education's rule: …", "Disapproving the arms sale to Qatar" (or "arms export", "arms transfer",
  as the title says), "Rule for H.R. 8029". Deterministic, tested on real titles.
- **Migration `20261115000000_bill_catalog.sql`**: `bills.status` becomes `stage` (with a check),
  plus `list_updated_on`, `details_fetched_at`, a generated full-text `search` column with a GIN
  index, and a topic-page index. Not applied yet; see the handoff for the order.
- **Swift models** `BillStage`, `TopicFilter`, `BillListItem`, `Topic`, `TopicList`, `TopicBills`,
  `SearchResults`, covered by the contract tests. A stage newer than the build decodes as nil, so
  it cannot fail a whole page.

### Changed
- The hourly ingest runs the bill catalog after Nominations (`--full` at 06 UTC).
- `rateLimit` takes a `scope` (routes sharing a store keep separate counts) and a `message`.

## 0.2.25 — 2026-11-13

Snapshot tests for the cards and screens, an accessibility pass, and the privacy manifests.

### Added
- **Snapshot tests** (`ios/FloorKit/Tests/SnapshotTests`, closes #1): 53 references from 24 tests.
  `ScoreboardCard` in ten states (three digits a side, failed short of two-thirds, nay leading,
  a shutout, a 1,309-character title, no citation, two senators, a Speaker ballot with no winner,
  open, scheduled), each in light, dark and AX5; Vote, Bill, Rep, Onboarding and Home screens.
  All from the captured fixtures, served by a `URLProtocol`. Built on `swift-snapshot-testing`
  1.19.7, pinned exactly (test target only). Recorded on the iOS 26.2 simulator and skipped on
  any other OS; CI's `ios` job runs them with Xcode 26.2 after the app build, and fails if that
  Xcode or a 26.2 iPhone simulator is missing.
- **`Spoken`** (`Models`): the VoiceOver sentence for each card — "H.R. 1013, On Passage, passed,
  295 yea to 128 nay; your rep Jeffries voted nay. …" — tested on real fixtures.
- **`scaledFont(_:weight:)`**: the mock's point size at the default text size, scaled with
  Dynamic Type from there.
- **Privacy manifests** for the app and the widget (`PrivacyInfo.xcprivacy`): no tracking;
  `UserDefaults` for CA92.1 and 1C8F.1; the app declares Precise Location, Physical Address and
  Coarse Location, and the widget Coarse Location (member ids in request paths reveal the
  district), all not linked, for App Functionality. The App Store privacy-label answers are in the handoff (M5).

### Changed
- **Dynamic Type** on `ScoreboardCard`, the vote screen and the member cards (Home's delegation
  strip, onboarding's three). Rows that cannot hold large text stack; member rows and cards go to
  one column at accessibility sizes. Default-size layouts are unchanged.
- **VoiceOver**: scores name their side ("failed, 212 yea to 206 nay" rather than "212 to 206");
  a tied Speaker ballot names both candidates; the box score says "did not vote" throughout. Score
  cards, the vote screen's board and member rows, and member cards read one
  sentence each, with the seat spelled out rather than "House · TX-37".
- **Reduce Motion**: the split-flap board and the catch-up deck also settle when
  `playsArrivalAnimations` is false, so tests and previews can draw the settled frame.

## 0.2.24 — 2026-11-13

The M3 live layer's backend: an always-on worker that tracks the floor, moves votes from `open` to
`final`, and measures how long the chambers take to post. Built and tested, not deployed (needs a Fly
account and the new migration applied; HANDOFF › M3 lists every step and variable).

### Added
- **Floor-event parsers** (`packages/shared/src/floor.ts`) for the House Clerk's floor summary and the
  Senate's floor schedule, floor activity page and vote menu, with contract tests on real responses
  saved 2026-11-13.
- **Vote state.** A roll call a floor source names before its XML posts is stored as `open` (House: with
  the floor's own time and announced tally); the roll call ingest makes it `final`. Every House floor
  action is kept in `floor_events`.
- **The live worker** (`npm run ingest -w @floor/worker -- live`): polls each chamber every 10 s while it
  sits and every 5 minutes otherwise, backs off a host that answers 403/429 (30 s doubling to 5 min),
  survives any one upstream failing (a failed Senate source is replaced by its last good copy for 30
  minutes; a failed chamber's stored status is left alone), revalidates with ETags (a body counts as seen
  only once it is stored), and on SIGTERM finishes the poll in flight and exits. Timeouts on every
  outbound call; a dropped database connection or an unhandled rejection is logged, not fatal.
  `apps/worker/Dockerfile` and `fly.toml` (restart policy `always`) deploy it.
- **Every final vote is published exactly once**, from the table: each poll publishes
  `state = 'final' and broadcast_at is null` and stamps it, in a `finally`, so a vote is not lost when a
  poll throws halfway, when the hourly workflow stored it, or across a restart. Votes found after
  downtime or on a first run are stored quietly, not announced as open. Votes still open after six hours
  are logged and posted to the alert webhook once.
- **`GET /v1/live`**: each chamber's session state and the votes open or just final, edge-cached for 5 s.
  Swift models `Live`, `LiveVote` and `ChamberStatus` decode it (no screen yet), so the contract
  test that every schema is modelled stays green.
- **Realtime broadcast** (Supabase, REST) of every vote state change, **an APNs sender** (ES256 token
  auth, HTTP/2), and **alerting** to a webhook when `/v1/status` is not ok during a session (three failed
  checks to alert, three good ones to recover, never two posts within 30 minutes). Each is a
  no-op until its env vars are set; nothing sends a push yet, because push copy is UI.
- **Posting latency**: `votes.announced_at` / `posted_at`, a log line per vote, and
  `npm run ingest -w @floor/worker -- latency`.
- **Vote-night load test** (`npm run loadtest -w @floor/api`), which refuses the production host.
- Migration `20261114000100_live_layer.sql`: `chamber_status` (RLS, public read), `votes.announced_at`,
  `votes.posted_at`, `votes.broadcast_at` (set for every vote already final), `floor_events.observed_at`,
  `floor_events.roll_number`.

### Changed
- `lastRollNumber` counts only `final` votes, so an `open` row never makes the roll call ingest skip it.
- Bill and nomination pages list only `final` votes.
- `parseHouseFloor` refuses a file without its Congress and session; the roll-result wording must be
  followed by the tally or the roll number; `parseSenateFloorActivity` refuses a page with no meeting
  blocks; a Senate vote menu's early-January votes after December ones are dated the next year.
- `/v1/live` answers empty, not 500, on a database without the M3 migration.

### Learned (HANDOFF lessons 41–44)
- Neither chamber publishes "vote opened": the Clerk's floor summary adds a vote around its close, with
  the result, and senate.gov has no per-action feed. `open` means "named, not yet posted".
- senate.gov answers a missing page with HTTP 200, refuses bursts with 403, and its vote menu lists
  the whole session.

## 0.2.23 — 2026-11-13

Floor on the home screen: the last final, and your three.

### Added
- **Two home-screen widgets** (`FloorWidgets` extension), built to the locked design (section
  "D · Widgets"). **Small** shows the newest final vote involving your members: chamber, citation,
  the recorded result (PASSED, REJECTED…), yea and nay, and one member's chip. **Medium** shows
  each member's most recent vote: chip (YEA, NAY, DNV, PRESENT, or the Speaker candidate they
  named), name, citation and result, date. A lone D.C. or territory delegate gets a line saying
  why there is one member. Light and dark from `Palette`; VoiceOver reads each as sentences.
- **Tap to open the vote.** `floor://vote/<id>` (`FloorLink`) opens the vote screen on Finals.
- `WidgetFeed` in FloorKit: the snapshot, the wording and the fetch (the app's own
  `/v1/members/{id}/votes?limit=10`), refreshed about every 30 minutes; a failed refresh shows the
  last snapshot for the same district. Empty state: "Open Floor to pick your members".

### Changed
- The saved delegation moved to the App Group `group.$(FLOOR_BUNDLE_ID)` (`group.app.floor.ios`)
  so the widget can read it. The first launch copies it across, keeps the old copy, and reloads
  the widgets; clearing removes both, so "Change address" cannot bring an old district back. The
  group is used only when its container exists. Still only the district and the members.
- "Change address" also clears the widget's saved snapshot and reloads the widgets, and a widget
  refresh that was in flight no longer writes the old district's votes back.
- Bundle ids and the App Group come from one setting, `FLOOR_BUNDLE_ID`: a personal device build
  passes `FLOOR_BUNDLE_ID=com.yourname.floor` and gets its own app, widget and group ids.
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` are set once for the whole project, so the app
  and the extension always match.

### Fixed
- `FloorAPI` escapes `/` inside a path id and no longer percent-encodes a path twice.
- `floor://vote/` links accept only roll call ids (`house-119-2-321`); anything else is refused.

## 0.2.22 — 2026-11-13

M4 Layer 1, server side: an AI analysis of each bill's CRS summary, every line cited and checked.
No app or web UI shows it yet; that needs a locked design. A PATCH on the 0.2 line by the team's
convention: 0.3.0 is reserved for the "your members on the web" milestone.

### Added
- **`analyze` worker job** (`apps/worker/src/analysis.ts`): for each bill whose CRS summary has no
  analysis at this prompt version, Claude (`claude-sonnet-5-5`, structured JSON output, cached system
  prompt, server-side refusal fallback) writes purpose, provisions, affected groups and impact, each
  citing summary paragraphs with verbatim quotes. A citation must resolve, quote its paragraph
  exactly, and be at least 20 characters with a word outside CRS boilerplate; claims left without
  one are cut. A second call verifies each remaining claim against its cited paragraphs; a claim is
  kept only if every verdict for it supports it. The bill section is the last CRS "(Sec. N)" label
  before the quote. Regenerates only when the summary (sha256 of stage and text) or the prompt
  version changes.
- **Run safety**: a session advisory lock, so overlapping runs never pay twice; at most 3 failed
  attempts per source (bill, summary hash, prompt version); summaries over 600k characters never
  sent; bad credentials, no permission or an exhausted rate limit end the run without charging the
  bill an attempt; `FLOOR_AI_EFFORT` and the limit are validated before any call. Cost is summed
  per model over `usage.iterations` (fallback attempts included) and reported as unknown when a
  model has no known price.
- **Migration `20261114000000_bill_analyses_ai.sql`**: `bill_analyses` (public read, as before) keyed
  by bill and CRS summary stage with source hash, prompt version, verifier model and generated-at,
  and a new **private** `bill_analysis_runs` (RLS on, no policy) for attempts, errors, tokens, cost
  and the claims the verifier rejected. Not yet applied to staging; re-run Supabase's security
  advisor after applying it.
- **`GET /v1/bills/{id}/analysis`**: the analysis with `ai: true` on the response and every line, a
  disclaimer, the analysed paragraphs, and a `stale` flag when the summary has changed since.
  FloorKit models for it (no views).
- **Eval**: 51 real bills from staging (`apps/worker/fixtures/analysis/bills.json`) and
  `npm run eval:analysis -w @floor/worker`, scoring citation validity, verifier drop rate, output
  validity and cost. Not run yet (no Claude key available).
- Env: `ANTHROPIC_API_KEY`, `FLOOR_AI_MODEL`, `FLOOR_AI_VERIFIER_MODEL`, `FLOOR_AI_EFFORT`.

### Changed
- `zod` resolves to 3.25.76 (was 3.24.1): `@anthropic-ai/sdk` 1.8.0 needs `^3.25`.

## 0.2.21 — 2026-11-13

The member screen in the app gets its Money segment.

### Added
- **Record / Money / Portfolio switch** on Your three and on a pushed member screen, built to the
  locked AppRepMoney mock (canvas round 6). The segment you pick stays when you switch member.
- **Money** loads `/v1/members/{id}/funding`: the campaign's total and cash on hand, the four-part
  bar (small-dollar, larger gifts, PACs, transfers and other) with its legend, the "context, not
  cause" line, and the ten biggest PAC checks, with FEC's committee names title-cased by the
  landing page's own rule. It has loading, error (Try again) and "No campaign filings yet" states,
  opens offline on the last saved copy like the record, and follows light and dark through new
  `teal`, `dim` and `ai` palette tokens.
- **Portfolio** is a visible "not loaded yet" placeholder: disclosures have no data or API yet.
- Swift models `PacCheck`, `Funding`, `MemberFunding`, `FloorAPI.funding(id:committees:)`,
  `MoneyModel`; the five real `/funding` captures copied into `ModelsTests/Fixtures`.
- **"Candidate committee"** as a PAC kind (API `pacKind`): another candidate's own campaign
  committee (FEC committee type H, S or P, "SMITH FOR CONGRESS") is labelled as one rather than
  left bare. It is computed from the stored `committee_type`, so it needs no re-ingest.

### Changed
- The bar's larger-gifts teal and transfers grey are darker than the mock's: the mock's teal read
  1.2:1 against the small-dollar green beside it. `PaletteTests` now holds every pair of
  neighbouring bar parts at 1.5:1 and each part at 3:1 against the empty track, light and dark.
- VoiceOver speaks money as words ("17.9 million dollars"), like the PAC rows.
- The record's picked grid square survives a trip to Money and back.
- Committee names capitalise after a leading O' or D' (O'Brien) and treat Y as a vowel in words of
  three letters or more (Lynn), on the landing page and in the app alike.

### Fixed
- `ContractTests.everySchemaIsModelled` had failed on `main` since 0.2.13, because the funding
  schemas had no Swift models. It passes again.
- **A negative "Transfers & other"** (the worker computes it as receipts minus the other parts, so
  refunds can push it below zero) is drawn as 0 in both the bar and the legend, with shares of the
  parts drawn, and a note says it includes refunds/adjustments. The landing page does the same.
- **Money formatting** rounds before it picks the unit ($999,500 is "$1.00M", not "$1000K") and
  puts the sign before the dollar ("−$12K"), on the landing page and in the app.

## 0.2.20 — 2026-11-13

Ingest was not stuck on a bad vote; it had never been scheduled. It now runs hourly, and the status
page stops reporting errors that were already fixed.

### Fixed
- **`/v1/status` showed superseded errors as current.** `lastError` was the latest error ever
  recorded, so two failures from the first backfill on 2026-11-12 — `Unknown vote position:
  "Jeffries"` and `deadlock detected`, both fixed in code within minutes and followed by clean runs —
  still read as live a day later. It is now the error of the latest run with an outcome, null once a
  later run succeeds (HANDOFF lesson 35).
- **A run that never finished hid failures.** A run with no outcome an hour after it started now
  reads as `abandoned run`, and every ingest (members included) records an outcome on every path,
  setup failures too (lesson 38).
- **One bad bill or nomination marked the source failed every run.** Per-item failures go in the new
  `ingest_runs.failed` column (migration `20261113000100_ingest_failed.sql`); `error` is only for a
  run that failed as a whole. The worker still closes runs on a database without the column.
- **A Speaker ballot is recognized by its question as well as its candidate totals**, so a file
  without the `<totals-by-candidate>` block parses as an election instead of failing on the first
  candidate name. Tested on the real 2025 ballot (`house-2025-roll002.xml`) with and without the
  block; all 20 ballots in production give the same totals either way. "Election of the Speaker pro
  tempore" is not matched, a ballot so titled whose every answer is yea/nay is refused, and a file
  with no totals names its roll call in the error.

### Added
- **`lastNewDataAt` on `/v1/status`**: the latest successful run that stored anything. A scheduled
  job keeps `stale` false even when upstream quietly stops, so this is the freshness signal now
  (lesson 38). Modelled in FloorKit's `SourceStatus`.
- **Hourly ingest** (`.github/workflows/ingest.yml`): House roll calls, Senate roll calls, bills,
  nominations, in sequence, in one `concurrency` group so runs never overlap; members once a day at
  06 UTC. Every step after install is gated on `npm ci` succeeding. It needs the
  `DATABASE_URL` and `CONGRESS_API_KEY` repository secrets, which a repo admin has to add; until then
  it skips with a warning (lesson 37).
- `rollcalls <house|senate> current` polls the session in progress and, in early January, the one
  just ended after it (`sessionsToPoll`). A session that fails does not stop the other; the first
  failure is rethrown after both (`ingestSessions`).

### Changed
- **Deadlock hardening** (lesson 36): `withRetry` makes five attempts with doubling, jittered waits.
  A vote's positions are now written in member-ID order, one row per member (`positionRows`), which
  makes the write deterministic; writers of the same vote were already serialized by its row lock.
- **Fewer database connections.** The API hands its pool to Vercel's `attachDatabasePool`
  (`@vercel/functions` 3.10.4) so a suspended instance doesn't sit on an idle connection, closes idle
  connections after 5 s instead of 10, and warns at boot unless `DATABASE_URL` is the transaction
  pooler (`poolerWarning`; port 6543 counts as transaction mode whatever the host). The worker uses
  one connection instead of two (lesson 37).

## 0.2.19 — 2026-11-13

"Who funds them" shows your members' campaign money, not New York's.

### Added
- **Live funding for your members.** Once the page finds your district, the money section loads
  `/v1/members/{id}/funding` for each of your members: totals, cash on hand, the four-part bar and
  the ten biggest PAC checks. Each member loads on its own; one that fails gets **Try again**.
- **No filings yet.** A member FEC has no current-campaign totals for (an appointed senator, or one
  who hasn't filed) gets a card saying so instead of a blank.
- `fundingFrom`, `committeeName`, `coverageRange` in `locate.ts`, tested against real `/funding`
  responses for Jeffries, Doggett, Cornyn, Cruz and Armstrong (`apps/web/fixtures/funding-*.json`).
  FEC's all-capitals committee names are title-cased, with nicknames in parentheses dropped and
  initialisms kept.
- The local API (`npm run dev -w @floor/api`) reads `ALLOWED_ORIGINS`, defaulting to the local web
  server, so a page built with `FLOOR_API_BASE=http://localhost:8787` can call it.

### Changed
- The New York flag in the money section now sits on the donor explainer only, the one part still
  written for the sample.
- PAC amounts round to a tenth of a thousand (`$2.5K`), and under $1,000 read in dollars (`$750`).
  Party money rides in "Transfers & other", whose note says so.

## 0.2.18 — 2026-11-13

The landing page has a light theme and a switch for it.

### Added
- **Light theme** for the landing page: "Marble & Patina", the same direction as the iOS app's light
  mode. Every page colour token has a light value under `:root[data-theme="light"]`; text colours
  read at 4.5:1 or better on every light surface. The finals board, ticker, Road to law field and
  phone stay dark, as lit displays.
- **Theme button** in the header, between the section links and "Get the app": System, Light, Dark
  in turn. The choice is kept in `localStorage` (`floor-theme`); System follows the device and
  changes with it. An inline script in `index.html` sets the theme before the first paint.
- `theme.ts` and `theme.test.ts`: the choice logic, a check that the inline script agrees with it,
  that the light theme covers every page token, and the contrast of every light text colour.

### Changed
- The header's capsule, divider and link hover colours are tokens now (`--head-capsule`,
  `--head-line`, `--head-shadow-*`, `--head-div`, `--nav-hover`). The floating capsule is 52px wider
  (716px, 296px on narrow screens) to fit the button.
- The drive's three colours from 0.2.17 (`--accent-glow`, `--floodlight`, `--chalk`) get light
  values, each re-based on this theme's version of its source colour. The two releases were built
  side by side; this theme's own test, that every dark colour has a light counterpart, caught the
  three on the merged tree.

## 0.2.17 — 2026-11-13

Road to law and the drive chart become one drive, built to the locked mock
<https://claude.ai/artifact/JZSvMDroyo5tVNVoKBA657>.

### Changed

- **A football rides the road.** In 02 · Road to law a ball (drawn in CSS) sits on the current box's
  title line and slides along the dashed rail as you scroll, and the rail fills yellow behind it. The
  stop on the left, the ball, the yellow line and the lit box all follow one step index.
- **The drive chart is the road's last box.** After level 6 the path ends at a condensed drive chart
  (bill tabs, status, a progress bar that is green for law, orange for a stall and yellow otherwise,
  and the plays), the seventh pinned step and the seventh stop on the map. The separate drive chart
  below the levels is gone.
- **Alignment:** pinned, both columns share one top and one bottom edge, the lit box is centred on
  the box itself (not its leg's top gap), and every pin sits on its box's title line at each width.
- **"BOSS" labels removed** from the level map and the cards.
- **Background:** the section keeps the site's dark panel, with chalk hash marks along the rail and a
  soft light behind the box in play.
- **Copy (by the owner):** "Six drives to law. Every bill shares the same field.", section 1 renamed
  "The scoreboard." (nav "Scoreboard"), a shorter 03 lede, and plainer level descriptions.

### Added

- `activeStep()` in `logic.ts`: on an unpinned road the last box counts once it is fully in view at
  the page's end. Tested. `driveBall()` is removed with the old field.

## 0.2.16 — 2026-11-13

### Changed

- **01 Finals has no Back or Next.** Scrolling deals the cards where the section pins; the five dots
  under the card are now buttons that jump to a final (44px tap targets, each named for its vote),
  which is how phones move through the deck.

### Fixed

- **The score no longer runs into the result chip on small phones.** The score scales with the
  scoreboard's width, and below about 270px of scoreboard the PASSED/FAILED chip moves above the two
  numbers. At 320px wide, "417" used to sit on top of "PASSED".

## 0.2.15 — 2026-11-13

The landing page's header floats.

### Changed

- **A full-width bar that draws in to a glass capsule.** At the top of the page the header spans the
  width: the mark on the left, the four section links centred, "Get the app" on the right. Past
  48px of scroll it narrows to a centred 664px capsule with a blurred fill, a hairline edge and a
  divider after the mark, and it settles back under 16px. Picked from three options in the nav
  artifact, after Flighty's header. At 860px and under the links stay hidden, as before, and the
  capsule hugs the mark and the button.
- The header's band keeps one height in both states. Pinned sections, the Road to law strip and
  anchor offsets read it, so only the inner bar animates.
- **At 900px and under, the band behind the capsule turns solid once it floats**, so the header and
  Road to law's stuck level strip stack as one block. With a see-through band, the road's cards slid
  past in the gap between them. On phones and tablets that trades away the glass for a clean edge.
- "Get the app" moves out of the section links into its own place in the header.

### Added

- `headFloats`, `HEAD_FLOAT_AT` and `HEAD_DOCK_AT` in `logic.ts`, with tests: two thresholds so the
  bar cannot flicker when a scroll comes to rest on one line.
- `docs/HANDOFF.md`: the floating header, and **lesson 34** — in the browser pane, a programmatic
  scroll right after a viewport change can fire no `scroll` event, which reads exactly like a bug in
  a scroll handler.

### Fixed

- `docs/HANDOFF.md` named two releases wrongly after today's version collisions: the funding API
  route landed in 0.2.13, not 0.2.12, and pinned sections in 0.2.14, not 0.2.13.

## 0.2.14 — 2026-11-13

Sections that hold still while you scroll through them.

### Changed

- **Pinned sections on wide screens.** 01 Finals, 02 Road to law, 03 Explained, 04 Your reps,
  05 Players and 06 Money stay put while the reader scrolls, and each stretch of scroll moves them one
  step: the next final, the next level, the next explained point (with its source paragraph lit), the
  next member. Steps swap with a short transition. It
  is sticky positioning over empty scroll space, so scrolling is never intercepted; a pill shows the
  step and offers **Skip**. Phones, short windows and reduced motion get the ordinary page.
- **Road to law, pinned:** the connected road stays, moving so the focused card sits centred while
  the others fade.
- **"Make it your three" moved** from the top of the page into 04 · Your reps, under the report it
  fills, as a slim bar (tagline, location button, address link; the member chips are left to the
  report's own tabs).
- **Players:** the card fan holds for one stretch of scroll, then the leaderboard scrolls up below it,
  spaced like the drive chart under the levels.
- Left unpinned on purpose: the drive chart, the donor explainer, 07 Portfolio and 08 Live.

### Added

- `stickTop`, `stepLength` and `scrollStep` in `logic.ts`, with tests.
- **A layout rule in `CLAUDE.md`:** any change to the website's shape or layout is checked at six
  standard viewports (320×640, 375×812, 820×1180, 1280×760, 1440×900, 1920×1080) before it ships,
  and the PR says how.

## 0.2.13 — 2026-11-13

Step 4 of the v0.3.0 milestone, "Your members on the web": the API side of campaign finance. The
data landed in 0.2.4; this serves it. The page section is what remains of the step.

### Added

- **`GET /v1/members/{id}/funding`** — a member's current campaign: what they reported receiving
  (small-dollar, itemized, PAC, party, other, cash on hand) and the committees that reported giving
  to them, biggest direct giver first. `?committees=` takes 0–50, default 10.
- The two halves are labelled by source rather than presented as one breakdown, because they come
  from different FEC filings and do not reconcile (lesson 24). Party and joint fundraising
  committees are excluded: neither is a PAC check (lesson 23). Direct money is kept apart from
  earmarked pass-throughs, and no individual donor is named — a committee carries only the seven
  keys a test pins, so a memo field cannot be added quietly.
- A committee's `kind` comes from FEC's own organization type, and is **null** when FEC classifies
  it as nothing, rather than being guessed into a category.

### Changed

- `docs/HANDOFF.md`: the route table, v0.3.0 step 4, and **lesson 33** — `campaign_finance.cycle`
  (the election a campaign is for) and `pac_contributions.cycle` (the two-year FEC filing cycle)
  are different things. Matching them passed every seeded test, because House members are up every
  cycle, and returned zero committees for every senator against real data.
- **`DATABASE_URL` on the `floor-api` Vercel project is now set for Preview as well as Production**
  (an environment change, not a code one). Previews were falling back to the stub repositories, so
  a PR preview answered `/v1/status` with every source null and any member route with a 404, which
  reads as missing data rather than a missing database. The PR preview for this branch now returns
  real rows. Recorded in `docs/HANDOFF.md` with the caveat it brings: a preview build now carries
  the staging credentials, contained only by Vercel Authentication on preview URLs.

## 0.2.12 — 2026-11-13

"Use my location" on the iOS app's onboarding, built to the locked canvas round 7 board `LocApp`
(<https://claude.ai/artifact/FKWYDhCej75UPy94csYLsU>).

### Added
- **"Use my location"** above the address field, with "or type an address" under it. It asks for
  when-in-use permission (the system alert carries "Floor finds your congressional district from
  where you are, then forgets the location."), takes one fix and calls `/v1/reps?lat=&lng=` through
  the new `FloorAPI.reps(latitude:longitude:)`.
- **Its states, as the mock draws them:** loading ("FINDING YOUR DISTRICT…" over three skeleton
  cards), found (with "Not your district? Type an address"), location off for Floor (banner and
  "Open Settings ›"), outside the U.S. (the API's 404), and approximate location (Precise Location
  off: the result, under a warning that it can land in the next district). Beyond the mock:
  Location Services off for the whole phone (names the system switch, no app link), restricted
  (no link), and no fix in time (offers the button again). Coming back from Settings retries once.
- **One member, and district 0.** D.C. deals one card, Eleanor Norton, with "One, not three: D.C.
  has a delegate in the House and no senators…"; the territories get the same note in their own
  words. `Member` gained `isDelegate`, `title`, `seatBadge` and `seatCaption`.
- Three palette tokens from the mock, each a light/dark `Swatch` checked by `PaletteTests`:
  `warningPanel` (`#FBF0E6` / `#1E1610`) and `warningBorder` (`#E2B48E` / `#5A3A1E`) for the
  banner, whose title, body and link read at 5.19, 9.16 and 4.75:1 in light and 7.88, 11.28 and
  9.28:1 in dark; and `textFaint` (`#636E69` / `#858B95`) for the privacy line, 4.58:1 on the light
  ground and 5.84:1 on the dark one.

### Changed
- At-large and delegate seats read correctly everywhere: "R-WY-AL" and "D-DC", not "R-WY-0" and
  "D-DC-0"; Norton is "Delegate · DC" on Home, the vote screen and her record, and "Del." as a
  sponsor; Home's district chip reads "DC", not "DC-AL"; and D.C.'s Senate filter says it has no
  senators instead of "No recent votes in this chamber".
- The built app reports its real version: `Info.plist` maps `CFBundleShortVersionString` and
  `CFBundleVersion` to `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`. XcodeGen had been
  writing its defaults, `1.0` and `1`.
- The privacy line under onboarding's button: "Floor keeps the district and drops the street — and
  the location."

### Privacy
- The point is rounded to 4 decimals (about 11 m) on the phone before it is sent, and again by the
  API. It is never stored, logged or cached: `reps(latitude:longitude:)` bypasses the offline
  cache, as the address lookup does, and the app's `URLSession` has no `URLCache`. Only the
  district and its members are kept, as before. Tests check the saved record, the whole
  `UserDefaults` suite, the response cache and the model for the coordinates.

## 0.2.11 — 2026-11-13

A round of landing page changes, made by clicking on the live page with Impeccable's live mode.

### Changed

- **Hero, stacked and centred** (locked mock <https://claude.ai/artifact/3Qk6vGVNnJ7h9gDjyXjJP9>,
  option C): headline, lede and calls to action on top, the finals board as a band beneath, the stats
  under the board. New lede: "A political scoreboard, broadcasting the box score by party. See how
  bills impact you, how your reps voted, and who's footing their check." The page title, description
  and share tags follow it (`Floor — Congress, the game`).
- **The finals board is 24 flaps wide**, so every 20-character line keeps at least two blank flaps
  each side. Cells and letters size from the board's own width (container query units); phones hide
  the four padding flaps. `FLAP_WIDTH` is 24 and `FLAP_TEXT_MAX` 20, with tests for both.
- **Road to law, rebuilt** (locked mock <https://claude.ai/artifact/WgULeauwdE8usqmXcXRkwT>): the
  section title and a six-stop level map hold still in the left column while the levels scroll past
  as one connected road. The current stop and card light up, earlier ones read as cleared, and a stop
  jumps to its level. Below 900px the map becomes a sticky strip under the header. The level the
  reader is on comes from `activeLevel()` in `logic.ts`, tested.
- **Header centred and trimmed** to Finals, Road to law, Your reps and Money plus Get the app.
- **Finals section:** the copy centres on the card rather than on the card plus its controls.

### Added

- `apps/web/PRODUCT.md` and `apps/web/DESIGN.md`: product truth and the incumbent visual system, which
  Impeccable reads before any design work, plus `apps/web/.impeccable/live/config.json` for live mode.
## 0.2.10 — 2026-11-13

Steps 2–3 of the v0.3.0 milestone, "Your members on the web": the landing page finds *your*
members from your location or address, built to the locked canvas round 7 (`LocWeb`,
<https://claude.ai/artifact/FKWYDhCej75UPy94csYLsU>).

### Added
- **The "your members" strip** under the site header. It opens on the New York sample, labelled
  SAMPLE. "Use my location" sends the point rounded to 4 decimals, or you can type an address
  (a ZIP alone is refused). It finds your district and members, with states for asking, loading,
  found, location blocked, outside the U.S., an address the Census can't match, too many lookups,
  a vacant seat, and the API unreachable. Every state has a way back (Cancel, "Back to the sample").
- **The scouting report switches to your members:** party loyalty, crossovers, showed up, winning
  side, the last 40 calls and the latest call, from `/v1/members/{id}` and `/votes?limit=40`. One
  member failing marks only that member and offers Try again.
- **One-member and no-bloc cases:** D.C. and the territories get one member and a delegate note
  computed from their votes. Independents (no party bloc) show "—", not an invented zero.
- Sections whose data is New York only (the five finals, money and donor context, the portfolio,
  the live replay) carry a "SAMPLE · NEW YORK" flag while someone else's members are shown.
- The found district (never the point or the address) is kept in `localStorage` with its Congress
  number, and dropped when a new Congress starts.
- `FLOOR_API_BASE` at build time points the page at another API (https or localhost only).

### Changed
- Winning side follows the recorded result: "Veto Overridden" and "Guilty" carried; "Not Agreed
  to", "Veto Sustained" and "Not Guilty" did not. A result the clerk's record cuts off mid-word is
  left out rather than counted as a loss, which moves Schumer's sample from 14/40 to 14/38 and
  Gillibrand's from 12/39 to 12/37. Speaker-ballot votes count as showing up.
- On screens 860px and narrower the sticky header keeps only the logo and "Get the app". The seven
  section links wrapped it to about 130px, a sixth of a phone screen.
- The strip's privacy line says only what the page does ("uses it once to find your district;
  this page stores only the district"), because `/v1/reps` takes the address in a GET query string
  that Vercel's request logs may keep. That's open for the API in `docs/HANDOFF.md`.

## 0.2.9 — 2026-11-13

The iOS app works offline: it opens on the last data it saw, then refreshes (M2 item 2).

### Added
- **Offline cache.** Each successful response body is saved in SwiftData (`SwiftDataResponseCache`,
  in Caches, so the system may purge it and it isn't backed up), keyed by host, path and encoded
  query. A screen loads twice through `revalidate`, once from the cache and then from the network,
  so a screen that makes several requests shows all its saved data at once. Entries older than 30
  days are neither shown nor kept; beyond 200 the oldest go first. A store that won't open is
  deleted and recreated once rather than abandoned.
- One muted line while any of a screen is saved data: "Saved 2 h ago · refreshing…" during the
  refresh, then "Offline · saved 2 h ago", or "Couldn't refresh · saved …" when the server answered
  with an error. It stays up when the main request refreshed but a best-effort one (a vote's bill, a
  bill's member positions, a loyalty ring) fell back to its saved copy.

### Changed
- A cancelled refresh (a pushed screen, a tab switched away) is no longer reported as offline, and
  Finals, Vote, the rep screen and Your three refresh again on reappearing until a load has finished
  fresh (`needsRefresh`), instead of only when empty or still loading.
- Overlapping loads (pull-to-refresh beside a screen's own task) no longer let the older one write
  over the newer; a screen already showing data keeps it while it reloads.
- A screen's best-effort loads fall back to their saved copy when they fail, instead of clearing
  what is on screen.

### Privacy
- The address lookup is never cached — its key would be the street address — and neither is the
  data-freshness status, whose saved answer would be wrong by its own age.
- `FloorAPI`'s session has no `URLCache`, which would have written the address lookup to
  `Caches/Cache.db`.
- Changing district clears the saved responses, which name the old members.

## 0.2.8 — 2026-11-13

### Changed

- **The macOS CI job runs only when `ios/` or `.github/` changed.** A new `scope` job in `ci.yml`
  reuses `SCOPE_RULES` from `guards.conf`, so what counts as an iOS change is defined in one place.
  It costs one ubuntu runner start (~15s) and spares a job that takes 1–3 minutes and queues for
  longer; `.github/` is included so a change to the workflow still proves the job it changes.
- That gate needed a refinement to do anything at all: `version-sync` requires `MARKETING_VERSION`
  in `ios/project.yml` to mirror `VERSION`, so **every** release touches `ios/`, and a plain
  `^ios/` test is true on a docs-only PR. The scope job discounts a `project.yml` change that is
  only the version mirror. Checked against the last five merges: 0.2.1 (docs), 0.2.4 (FEC data) and
  0.2.6 (the CI change itself, which still runs via `.github/`) versus 0.2.3 and 0.2.7, which build.

## 0.2.7 — 2026-11-13

An in-app switch for light and dark.

### Added
- **Appearance menu** on Finals, beside the district chip: System, Light or Dark. The choice is
  kept in `UserDefaults` (`appearance`: `system`, `light` or `dark`) and applied to the window, so it
  covers every tab, pushed screen and navigation bar. System is the default.
- `Appearance` and `AppearanceMenu` in DesignSystem, with `AppearanceTests` (stored values are
  stable, an unknown value falls back to System, each choice maps to its colour scheme).

## 0.2.6 — 2026-11-13

### Changed

- **CI runs on `main` only.** `ci.yml` loses its `pull_request` trigger, so a PR no longer compiles
  or tests the code; the node and macOS jobs run once, on the push that merges. `guards.yml` is
  unchanged and still runs on every PR, but it reads git and PR metadata and builds nothing.
- `CLAUDE.md` and `docs/HANDOFF.md` say so where they used to promise CI on a PR: the commands under
  **Before every PR** (`npm run check`, and `swift test` for anything under `ios/`) are the gate now,
  and a failure that used to turn a PR red lands on the trunk, where it is reverted rather than left.

## 0.2.5 — 2026-11-12

The iOS app has a light mode and follows the system appearance. Light is direction D, "Marble &
Patina", from the re-theme proposal (<https://claude.ai/artifact/AinA8SbyMWgrsC2rsB5U9h>); dark is
unchanged.

### Added
- **Light mode.** Every `Palette` token now has a light and a dark value (`Swatch`, listed in
  `Tones`). Light is a cool marble ground, white panels, ink text and a patina accent; yea, nay,
  live, scheduled and the threshold line are darkened so text in them reads at 4.5:1 on the ground
  and on panels.
- **`litObject()`**, which keeps the split-flap board on Finals and the turf scoreboard on a vote
  dark in both appearances, because they are lit displays rather than surfaces.
- `Palette.shadow` (the catch-up deck's drop shadow, lighter in light mode) and `Palette.silverInk`
  (dark text on the silver player-card chip).
- `PaletteTests`: WCAG contrast for every text token on the ground, panels and cards in both
  appearances, the ground on every chip colour, the large-text minimum for the losing score, yea
  and nay never matching a party colour, and the dark values pinned to the canvas's.

### Changed
- No screen forces dark mode any more: `.preferredColorScheme(.dark)` is gone from the app and
  every screen. The pushed screens' navigation bar sits on the ground colour in either appearance
  (`groundNavigationBar()`, formerly `darkNavigationBar()`).

## 0.2.4 — 2026-11-13

Step 4 of the v0.3.0 milestone, "Your members on the web": campaign finance for every member.

### Added

- **`campaign_finance`**: OpenFEC totals for each current member's campaign to date (House: the
  2025–26 cycle; senators: since their last election): small-dollar, itemized, PAC, party, other
  receipts and cash on hand. `npm run ingest -w @floor/worker -- fec-totals` (about 10 minutes for
  everyone at FEC's 60 requests a minute; skips members refreshed in the last 20 hours).
- **`pac_contributions`**: every committee's direct and earmarked totals per member, from the FEC
  bulk file of committee-to-candidate contributions, with FEC's committee designation, type and
  organization type (corporation, labor, trade, membership…). `fec-pacs 2026`, about 30 seconds.
- Earmarked pass-throughs are separated from a committee's own checks, and the memo text that names
  individual donors is never stored (product rule: no individual donors' names). `isPac()` leaves
  party and joint fundraising committees out of PAC lists.
- Members now keep their FEC candidate IDs (`members.ids.fec`).
- `docs/HANDOFF.md` lessons 23–24: what the FEC files actually contain, and the rate limit.

## 0.2.3 — 2026-11-12

The iOS app is rebuilt to the six phone screens locked in round 6 of the design canvas
(<https://claude.ai/artifact/FKWYDhCej75UPy94csYLsU>). Colours are unchanged; the type, layout and
navigation are new.

### Added
- **Barlow Condensed** (OFL, bundled in `DesignSystem/Fonts/`, registered at runtime with a system
  fallback) for display type, plus named tokens for colours Palette lacked: `threshold`, the
  split-flap greys, `panel`, `panelBorder`, `raised`, `groundGlow`, turf stripes, silver.
- **Three tabs** — Finals, Bills, Your three — each with its own navigation stack (`FloorShell`).
- **Finals:** your three as ringed portraits, a split-flap board of the latest final, a catch-up
  deck (rule, score, twist, your three) and scoreboard cards with the threshold line.
- **Vote:** a broadcast-style score, the threshold bar ("83 votes over the line"), a box score by
  party, your three, the bill's level, and the full roll as party squares.
- **Bill:** six levels to law with BOSS levels where 60 or two-thirds applied, the bill's own
  votes, the CRS summary (labelled as theirs), and your three on it.
- **Your three:** a player card, rings for party loyalty, attendance and winning side, the last 40
  calls as a grid, and computed facts.
- `VoteOutcome` (threshold maths; the chamber's recorded result wins over arithmetic),
  `LawLevels`, `CatchUp`, `RecordStats`/`RecordFacts`, and 8 real API fixtures captured 2026-11-12.

### Changed
- "Winning side" reads the actual outcome (`sidedWithOutcome`), not which side had more votes —
  they differ when a majority loses to a threshold (H.J.Res. 1 lost 212–206).
- The Speaker ballot now has its own feed card ("MAJORITY OF NAMES"), closing M2 item 1. It says
  VOTING or SOON until the ballot is final, never ELECTED or NO WINNER mid-count.
- When the count and the chamber's record disagree (a Vice President's tie-break, a 60-vote
  unanimous-consent bar on a vote reported as majority, "present" votes), `ThresholdLine` reports
  neither "over" nor "short", and the catch-up twist names the record instead of a line.
- "Veto Sustained" reads as a failed override (it read as carried); "Veto Overridden" shows
  OVERRIDDEN, and the Senate's override question is classed as a veto override, not passage.
- A chamber is "stuck" only if its latest blocking vote failed, so a later cloture win clears it.
- `isFinalPassage` follows `outcome`, so "Not Agreed to" no longer counts as the House passing it.
- One missing font file no longer stops the other faces registering.

### Not in this release
- Money and Portfolio on Your three, and the AI bill explainer (M4).

## 0.2.2 — 2026-11-12

First step of the v0.3.0 milestone, "Your members on the web": the API can find someone's members
from their location as well as from a typed address.

### Added

- `GET /v1/reps` accepts `lat` and `lng` (for example from the browser's location) as an
  alternative to `address`. Coordinates are rounded to 4 decimal places (about 11 m) before they
  go to the Census geocoder's coordinates endpoint, and are never stored or logged. A point outside
  every U.S. district (abroad, at sea) gets a 404 that suggests entering an address instead.
- `400` responses on `/v1/reps` when a request sends both an address and coordinates, neither, or
  only one coordinate, or coordinates out of range.

### Changed

- `AppDeps.geocode(address)` is now `AppDeps.locate(place)`, taking `{ address }` or `{ lat, lng }`.
- `docs/HANDOFF.md` and `docs/plan.md`/`plan.html` record the v0.3.0 milestone.

## 0.2.1 — 2026-11-12

### Changed

- **The landing page is deployed:** <https://floor-web-seven.vercel.app> (Vercel project `floor-web`,
  team Abtanix Labs, linked to `abhipal42/floor`, so merges into `main` redeploy it). `docs/HANDOFF.md`
  said it was unhosted and guessed at the settings; it now records the ones that work. The root
  directory is the repo root rather than `apps/web`, because the build script resolves `tsc` from the
  root `node_modules`, and the note about CORS now says the page makes no requests today.

## 0.2.0 — 2026-11-12

The web landing page. Retro: [`docs/retros/0.2.0-landing-page.md`](docs/retros/0.2.0-landing-page.md).

### Added

- **`apps/web` (`@floor/web`)** — Floor's landing page, built to the locked design canvas
  (<https://claude.ai/artifact/FKWYDhCej75UPy94csYLsU>): static HTML, CSS and TypeScript compiled with
  the repo's `tsc`, no framework and no new dependencies. Sections: a split-flap finals board, a
  five-finals story deck, the six levels to law with a drive chart, AI bill explainers that cite the
  CRS summary paragraph by paragraph, a scouting report with each member's last 40 roll calls, player
  cards and a maverick leaderboard, campaign funding from FEC filings with donor context ("context,
  not cause"), a portfolio from House financial disclosures (reported ranges only), and a Live
  Activity preview.
- Every figure on the page lives in one typed snapshot (`apps/web/src/data.ts`) with its source and
  date, and tests check it against itself: party splits sum to totals, grid counts match the stated
  records, funding segments sum to totals, every AI point cites a paragraph that exists.
- CI builds the site (`npm run build -w @floor/web`) in the node job.

### Changed

- `CHANGELOG.md` keeps one MINOR series; 0.1.x moved to `docs/changelog/0.1.md`.
- `CLAUDE.md` gains the product rules the design rounds settled (informational only, context not
  cause, ranges not net worth, AI labelled and cited, no donor names).
