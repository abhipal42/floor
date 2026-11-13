# Changelog

`MAJOR.MINOR.PATCH` in `VERSION`, mirrored by `MARKETING_VERSION` in
`ios/project.yml`. The `changelog` guard enforces that the top header equals
`VERSION`, is new relative to `main`, and increases monotonically. A MINOR bump
is a milestone and ships a retro under `docs/retros/`.

Older series live in [`docs/changelog/`](docs/changelog) (0.1.x: [`0.1.md`](docs/changelog/0.1.md)).
Before 0.1.0 the history is the commit log on `main`.

## 0.2.3 — 2026-11-13

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
- `docs/HANDOFF.md` lessons 20–21: what the FEC files actually contain, and the rate limit.

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
