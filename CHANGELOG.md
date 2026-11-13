# Changelog

`MAJOR.MINOR.PATCH` in `VERSION`, mirrored by `MARKETING_VERSION` in
`ios/project.yml`. The `changelog` guard enforces that the top header equals
`VERSION`, is new relative to `main`, and increases monotonically. A MINOR bump
is a milestone and ships a retro under `docs/retros/`.

Older series live in [`docs/changelog/`](docs/changelog) (0.1.x: [`0.1.md`](docs/changelog/0.1.md)).
Before 0.1.0 the history is the commit log on `main`.

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
