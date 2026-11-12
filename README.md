# Floor

A live federal vote tracker for iOS: how your members of Congress are voting, how each vote is going, what the bill does, and what it means for you.

- **Start here:** [`docs/HANDOFF.md`](docs/HANDOFF.md): current state, setup, lessons learned, remaining milestones
- **Plan:** [`docs/plan.md`](docs/plan.md) (rendered: [`docs/plan.html`](docs/plan.html))
- **Status:** M0 done · M1 (data backbone) nearly done · next: M2 (iOS core on real data)

## Repo layout

| Path | What |
|---|---|
| `docs/` | Implementation plan |
| `packages/shared` | Shared TypeScript types and roll call parsers |
| `packages/db` | Migration loader for tests |
| `apps/api` | Public REST API (Hono, OpenAPI) |
| `apps/worker` | Ingest CLI: members, roll calls, bills (always-on poller in M3) |
| `supabase/migrations` | Postgres schema |
| `ios/` | SwiftUI app, widgets and Live Activity (XcodeGen) |

## Development

```bash
npm install
cp .env.example .env   # fill in DATABASE_URL and CONGRESS_API_KEY (see docs/HANDOFF.md)
npm run check          # lint + typecheck + tests
npm run dev -w @floor/api
```

iOS builds run on macOS (locally with Xcode 16+, or in CI on a macOS runner):

```bash
cd ios && xcodegen && xcodebuild test -scheme Floor -destination 'platform=iOS Simulator,name=iPhone 16'
```
