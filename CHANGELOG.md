# Changelog

`MAJOR.MINOR.PATCH` in `VERSION`, mirrored by `MARKETING_VERSION` in
`ios/project.yml`. The `changelog` guard enforces that the top header equals
`VERSION`, is new relative to `main`, and increases monotonically. A MINOR bump
is a milestone and ships a retro under `docs/retros/`.

Older series live in [`docs/changelog/`](docs/changelog) (0.1.x: [`0.1.md`](docs/changelog/0.1.md)).
Before 0.1.0 the history is the commit log on `main`.

## 0.2.5 — 2026-11-12

The iOS app has a light mode and follows the system appearance. Light is direction D, "Marble &
Patina", from the re-theme proposal (<https://claude.ai/artifact/AinA8SbyMWgrsC2rsB5U9h>); dark is
unchanged. Skips 0.2.4, which the open `feat/fec-funding` branch has taken.

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
