# Changelog

`MAJOR.MINOR.PATCH` in `VERSION`, mirrored by `MARKETING_VERSION` in
`ios/project.yml`. The `changelog` guard enforces that the top header equals
`VERSION`, is new relative to `main`, and increases monotonically. A MINOR bump
is a milestone and ships a retro under `docs/retros/`.

Before this file existed (2026-11-11 → 2026-11-12) the history is the commit log
on `main`; the 0.1.0 entry below summarises it rather than listing every commit.

## 0.1.0 — 2026-11-12

M0 and M1 done, M2 in progress. Retro: [`docs/retros/0.1.0-m0-m1.md`](docs/retros/0.1.0-m0-m1.md).

### Added

- **Shipping guards** from the RIA template (`.github/scripts/guards.sh`, `guards.yml`, template
  2.0.0): changelog, docs, tests, version-sync (`VERSION` ↔ `ios/project.yml`), bump-level, retro,
  retro follow-ups, PR title, workflow injection. Configured for this layout in
  `.github/scripts/guards.conf`. Dependabot for GitHub Actions, a PR template, `VERSION`, this
  changelog, `docs/retros/` and a `CLAUDE.md` for agents.
- **M0 — foundation.** npm workspace (TypeScript, ESLint, Vitest), Postgres schema in
  `supabase/migrations` tested against PGlite, Hono API with a committed OpenAPI contract, XcodeGen
  iOS project, CI on Node and macOS.
- **M1 — data backbone.** House Clerk and Senate LIS roll call parsers; ingest CLI for members,
  roll calls, bills and nominations; every House and Senate roll call since January 2023 in staging,
  each matching its official totals; district lookup through the Census geocoder; `/v1/status`
  freshness.
- **M2 so far.** API routes for reps, members (with party loyalty), member votes, votes (party
  breakdown, Speaker candidates, delegation positions), bills and nominations; CORS and rate
  limiting; deployed at <https://floor-api.vercel.app>. iOS: hand-written `Models` checked against
  the contract, `APIClient`, Onboarding, Home, Vote, Bill (path-to-law stepper) and Rep screens.

### Changed

- Docs brought up to date: test counts, the iOS module list, Swift models being hand-written rather
  than generated, and the README's milestone status.
- `.gitignore` ignores every `.env*` variant, not only `.env` and `.env.*`.
