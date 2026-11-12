# Handoff: where Floor stands and what's next

Last updated 2026-11-12. Read this first, then [`plan.md`](plan.md) for the full design and reasoning.

**In one paragraph:** M0 (foundation) is done. M1 (data backbone) is done except for finishing one bill load and two deferred items. Staging Postgres holds every House and Senate roll call since January 2023, and every one matches the official totals. The API serves district lookup, member votes, votes, bills and data freshness from that database. The iOS app is still a skeleton (one scoreboard card on sample data). M2 builds the real app screens on this API.

---

## 1. Get set up

### Access you need (ask the repo owner)

| What | Why | Who grants it |
|---|---|---|
| GitHub `abhipal42/floor` write access | Push to `main` | Repo owner |
| Supabase org "pokator's Org", project **floor-staging** (`uyyocajwihypaiosecvs`, us-east-1) | Database URL for `.env`, dashboard, SQL editor | Sourav (org owner) |
| api.data.gov key | Congress.gov bill data | Sign up yourself at https://api.data.gov/signup (free, instant) |
| The v2 design canvas (claude.ai artifact "Live Vote Tracker – UI Options") | Screen designs for M2 | Sourav (it's private; ask for a share) |

### Local setup

```bash
git clone https://github.com/abhipal42/floor.git && cd floor
npm install
cp .env.example .env    # then fill in the two values (see below)
npm run check           # lint + typecheck + 81 tests; must pass before every push
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
```

iOS (needs a Mac with Xcode 16+): `brew install xcodegen && cd ios && xcodegen && open Floor.xcodeproj`. CI builds it on a macOS runner on every push.

---

## 2. What exists today

### Repo layout

| Path | What | Key files |
|---|---|---|
| `packages/shared` | Types + roll call parsers (House Clerk XML, Senate LIS XML) | `src/rollcall.ts`, fixtures in `fixtures/` (real government files) |
| `packages/db` | Migration loader used by tests | `src/migrations.test.ts` |
| `supabase/migrations` | Postgres schema (applied to staging in filename order) | 6 migrations, all applied to staging |
| `apps/worker` | Ingest CLI: members, roll calls, bills | `src/cli.ts`, `rollcalls.ts`, `bills.ts`, `members.ts`, `db.ts` |
| `apps/api` | Hono REST API with OpenAPI at `/openapi.json` | `src/app.ts` (routes + schemas), `pg.ts` (Postgres), `district.ts` (Census) |
| `ios/` | SwiftUI app (XcodeGen), `FloorKit` package (`Models`, `DesignSystem`) | `FloorKit/Sources/Models/Vote.swift`, `DesignSystem/ScoreboardCard.swift` |
| `.github/workflows/ci.yml` | Node job (lint/typecheck/tests) + macOS job (Swift tests + simulator build) | |
| `docs/` | `plan.md` / `plan.html` (design + plan), this file | |

### API endpoints (all live against staging)

| Route | Returns |
|---|---|
| `GET /v1/reps?address=` | District (119th Congress map) + House member + senators. The address goes only to the Census geocoder and isn't stored or logged. |
| `GET /v1/members/{bioguideId}/votes?limit=` | A member's recent votes with their position (and candidate, for Speaker elections) |
| `GET /v1/votes/{id}` | One vote: totals, threshold, kind, bill link. IDs look like `house-119-1-100` |
| `GET /v1/bills/{id}` | Title, short title, CRS summary, sponsor, policy area, CBO estimates, last 30 actions, every vote on it. IDs look like `119-hr-2207` |
| `GET /v1/status` | Last successful run and last error per ingest source, with `stale` flags |
| `GET /openapi.json` | The contract. Generate Swift types from it in M2. |

### Data in staging (as of this commit)

| Table | Rows | Notes |
|---|---|---|
| `members` | 716 | Everyone serving now, plus anyone whose last term ended after 2022-11-01 |
| `votes` | 3,532 | House + Senate, 118th–119th Congress, Jan 3 2023 → Nov 11 2026. 20 are Speaker elections (`kind = 'election'`) |
| `vote_positions` | 995,806 | Verified: every vote's positions add up to its official totals; no vote lacks positions |
| `bills` / `actions` | ~550 / ~12k, **load in progress** | See "Finish M1" below |
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
9. **Applying migrations to staging:** apply each new file in `supabase/migrations` in order (Supabase SQL editor or `supabase db push`). Tests run all migrations against PGlite, so a migration that breaks shows up in `npm run check` first.

---

## 4. Finish M1 (small)

1. **Finish the bill load.** Re-run `npm run ingest -w @floor/worker -- bills`. It only fetches bills not yet linked, so it's safe to re-run. Done when this returns `0`:
   ```sql
   select count(*) from votes where bill_id is null and bill_ref is not null and bill_ref !~ '^(PN|QUORUM|ADJOURN|Treaty)';
   ```
   Any that stay unlinked are bills Congress.gov returned errors for. Check `ingest_runs` where `source = 'bills'`.
2. **Spot-check 5 bills** from `/v1/bills/{id}` against congress.gov (title, sponsor, latest action, summary).
3. **Nominations (deferred from M1).** About 900 Senate votes are on nominations (`PN…`). Add a `nominations` table and an ingest from Congress.gov `/nomination/{congress}/{number}` (nominee, position, agency), and link the votes. Follow the `bills.ts` pattern, including tests on saved real responses.
4. **Posting-latency measurement (moved to M3).** We can only measure how long the Clerk and LIS take to post roll call files on a live session day with polling running.

---

## 5. Remaining milestones

The working rhythm so far: break each milestone into tasks. For each task, write tests on real saved data first, then build, run `npm run check`, commit with a descriptive message and push to `main`, and keep CI green. Every push runs CI (Node + macOS).

### M2: iOS core on real data
**Goal:** a TestFlight build that shows how your reps voted, from real data. No live updates yet.

- Generate Swift `Models` from `/openapi.json` (swift-openapi-generator) and replace the hand-written `Vote.swift`, keeping its tests.
- `APIClient` package: URLSession client for the five routes; base URL from build config (staging vs. prod).
- **Onboarding:** an address field (or "use my location" → reverse geocode → address) → `/v1/reps` → save state, district and member IDs locally. Never send the address anywhere except the API call.
- **Home:** your delegation strip, then recent final votes for your reps (`/v1/members/{id}/votes`), using `ScoreboardCard`. Add the Speaker election card variant.
- **Vote detail:** totals, threshold bar, party breakdown, how each of your reps voted.
- **Bill screen:** short title, CRS summary, sponsor, CBO links, the "Path to law" stepper built from actions, and votes on the bill.
- **Rep screen:** recent votes, and votes with/against party (computable from `vote_positions`).
- SwiftData cache for offline; snapshot tests for each card state.
- **Backend for M2:** deploy the API (plan: Hono on Vercel, or a container alongside the worker) and point the app at it. Add CORS and rate limiting on `/v1/reps`.
- **Exit:** TestFlight build where a tester enters their address and sees yesterday's votes by their reps.

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

### M5: Beta hardening + App Store
Accessibility (Dynamic Type, VoiceOver on score cards), privacy labels, a vote-night load test, App Review prep, public TestFlight.

---

## 6. Open product decisions (owner: Sourav)

- Ship the House OCR tally if M3 validates it, or launch with "vote open → result" only?
- Show prediction-market odds at all, or only our own projection?
- Which optional profile questions are OK for "What it means for you"?
- Android timing.
- Production Supabase project and API hosting (staging is on the free tier).
