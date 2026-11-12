# Floor

A live federal vote tracker for iOS: how your members of Congress are voting, how each vote is going, what the bill does, and what it means for you.

- **Start here:** [`docs/HANDOFF.md`](docs/HANDOFF.md): current state, setup, lessons learned, remaining milestones
- **Plan:** [`docs/plan.md`](docs/plan.md) (rendered: [`docs/plan.html`](docs/plan.html))
- **Shipping rules:** [`CLAUDE.md`](CLAUDE.md) · history: [`CHANGELOG.md`](CHANGELOG.md) · retros: [`docs/retros/`](docs/retros)
- **Status (v0.2.0):** M0 and M1 done · the landing page is built (`apps/web`, not yet hosted) · M2 (iOS core on real data) nearly done: the API is live at <https://floor-api.vercel.app> and the app runs end to end against it; left are the Speaker election card on Home, the offline cache, snapshot tests and TestFlight

## Repo layout

| Path | What |
|---|---|
| `docs/` | Plan, handoff, retros |
| `packages/shared` | Shared TypeScript types and roll call parsers |
| `packages/db` | Migration loader for tests |
| `apps/api` | Public REST API (Hono, OpenAPI), deployed on Vercel |
| `apps/worker` | Ingest CLI: members, roll calls, bills, nominations (always-on poller in M3) |
| `apps/web` | Landing page: static HTML/CSS/TypeScript, one typed data snapshot (`src/data.ts`) |
| `supabase/migrations` | Postgres schema |
| `ios/` | SwiftUI app and the `FloorKit` package (XcodeGen); widgets and Live Activity come in M3 |
| `.github/` | CI (`ci.yml`) and the shipping guards (`guards.yml`, `scripts/guards.conf`) |

## Development

```bash
npm install
cp .env.example .env   # fill in DATABASE_URL and CONGRESS_API_KEY (see docs/HANDOFF.md)
npm run check          # lint + typecheck + tests
npm run dev -w @floor/api
npm run build -w @floor/web && npm run serve -w @floor/web   # the landing page
```

iOS builds run on macOS (locally with Xcode 16+, or in CI on a macOS runner), the same two steps CI runs:

```bash
swift test --package-path ios/FloorKit
cd ios && xcodegen && xcodebuild build -project Floor.xcodeproj -scheme Floor \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

## Shipping a change

Every change is a short branch and a PR into `main` with a `VERSION` bump, a `CHANGELOG.md` entry and a
`vX.Y.Z type: summary` title. Run the guards before pushing:

```bash
bash .github/scripts/guards.sh all
```
