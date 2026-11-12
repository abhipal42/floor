# Floor

A live federal vote tracker for iOS: how your members of Congress are voting, how each vote is going, what the bill does, and what it means for you.

- **Plan:** [`docs/plan.md`](docs/plan.md) (rendered: [`docs/plan.html`](docs/plan.html))
- **Status:** M0 — foundation and test harness

## Repo layout

| Path | What |
|---|---|
| `docs/` | Implementation plan |
| `packages/shared` | Shared TypeScript types and parsers (roll calls, floor events) |
| `apps/api` | Public REST API (Hono, OpenAPI) |
| `apps/worker` | Always-on ingest worker (pollers, event bus, push) |
| `supabase/migrations` | Postgres schema |
| `ios/` | SwiftUI app, widgets and Live Activity (XcodeGen) |

## Development

```bash
npm install
npm run check   # lint + typecheck + tests
```

iOS builds run on macOS (locally with Xcode 16+, or in CI on a macOS runner):

```bash
cd ios && xcodegen && xcodebuild test -scheme Floor -destination 'platform=iOS Simulator,name=iPhone 16'
```
