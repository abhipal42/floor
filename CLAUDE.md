# Floor — rules for agents and contributors

Floor is a live federal vote tracker for iOS. Read [`docs/HANDOFF.md`](docs/HANDOFF.md) first:
it is the current state, setup, the lessons real data taught us, and what is left per milestone.
[`docs/plan.md`](docs/plan.md) is the design and the reasoning behind it.

## Before every PR

Since 2026-11-13 `ci.yml` runs on pushes to `main` only — **a PR does not build or
test your code.** These commands are the gate, not a rehearsal of one: whatever you
skip here lands on the trunk and is found there.

```bash
npm run check                              # lint + typecheck + Node tests
swift test --package-path ios/FloorKit     # if anything under ios/ changed
npm run openapi -w @floor/api              # if apps/api/src/app.ts changed; commit the result
bash .github/scripts/guards.sh all         # the shipping guards, as CI runs them
```

## Shipping

`main` is the trunk. Every change is a short branch (`feat/`, `fix/`, `chore/`, `docs/`) and a PR
into `main`; nothing is committed straight to it, because that is the one path the guards never see.

- **Bump `VERSION`** and keep `MARKETING_VERSION` in `ios/project.yml` equal to it (`version-sync`
  fails otherwise). PATCH for a fix, MINOR for a milestone or new capability, MAJOR when something
  breaks (and say what under `### Breaking`).
- **Add a `CHANGELOG.md` entry** whose header is the new version. A released entry is closed: never
  append to one that is already on `main`.
- **Title the PR `vX.Y.Z type: summary`** (`feat`, `fix`, `docs`, `refactor`, `perf`, `test`,
  `chore`, `build`, `ci`, `revert`). A single-commit PR's commit subject must match too, because the
  repo squashes with it.
- **Code ships with its test and its doc.** Code is TypeScript under `apps/*/src`, `apps/*/api` and
  `packages/*/src`, the Swift sources, `ios/project.yml` and `supabase/migrations`. Docs are
  `docs/*.md`, `README.md` and this file — usually `docs/HANDOFF.md`.
- **A MINOR bump ships a retro** in `docs/retros/` (copy `TEMPLATE.md`). Every row of its
  `## Gaps found` table is `landed …` or `blocked: <reason>`; a bare "deferred" fails CI.
- Merge only when **every** check is green (`gh pr checks <N>` exits 0), not just `guards`.
  Green is a weaker claim than it used to be: on a PR it means the guards and the Vercel
  deployments, since `ci.yml` no longer runs there. Watch the `CI` run on `main` after you
  merge, and revert rather than leave the trunk red.

Escape hatches exist for the genuine case — a label (`docs-exempt`, `tests-exempt`,
`changelog-exempt`, `retro-exempt`, `patch-intentional`) or a tag in a commit subject
(`[skip docs]`) — and should be used on purpose, not to get past a red check.

The guard logic is `.github/scripts/guards.sh` (shared with other projects; `bootstrap` replaces it on
upgrade, so do not edit it here). This repo's settings are `.github/scripts/guards.conf`.

## Docs stay current

Any change to a capability updates `docs/HANDOFF.md` in the same PR: routes, tables and row counts,
the setup steps, and — most valuable — anything real data taught you, as a numbered lesson in §3.
A change of design, stack or milestone also updates `docs/plan.md` **and** `docs/plan.html`, which
mirror each other. When something a doc says stops being true, fix the doc rather than adding a
correction somewhere else.

## Product rules (settled 2026-11-12, during the landing page rounds)

These are product decisions, not style. Each one was a correction to a design that got it wrong.

- **Informational only.** Floor never lets anyone pick, predict, guess or bet on an outcome — no
  pick'em, no odds to act on. Gamified *presentation* (scoreboards, box scores, player cards,
  streaks for catching up) is wanted; gamified *participation in outcomes* is not.
- **Context, not cause.** Donor context says who a donor is, what they lobby on, and which of the
  member's votes touch the same topic — side by side. Never that money explains a vote, or the
  reverse. Every donor gets the same treatment.
- **Ranges, not net worth.** Financial disclosures report value bands and leave out homes. Show the
  reported ranges and say why; never print a single net-worth figure.
- **AI is labelled and cited.** Every AI-written line carries an AI label, points at the source it
  came from (the CRS summary paragraph, the filing), and says it may contain errors. A claim that
  can't be tied to a source is cut, not softened.
- **No individual donors' names**, even though the FEC publishes them.
- **Real data or a visible placeholder.** Never an invented number, quote or example.

## Things that are easy to get wrong

- **Never log Congress.gov URLs** — they carry the API key (lesson 7).
- **Switch `CONGRESS` to 120 in `apps/api/src/district.ts` on 2027-01-03** (lesson 4).
- Every table has row-level security; re-check Supabase's security advisor after any migration.
- A Speaker election's `result` is the ballot's leader, not a winner (lesson 16).

<!-- ria:ui-artifact-first v1 — source: RIA/templates/agent-rules/ui-artifact-first.md; edit there, not here -->
## Large UI changes: artifact first, then build

**Before building a large UI change, send Ishan a Claude artifact of it and
iterate until he locks it in.** Set by the owner on 2026-11-04 for every
project.

- **What counts as large:** a new screen, page, view or face; a redesign or
  re-layout of an existing one; a new navigation or interaction model; a
  visual-language change (colour, type, spacing, motion) that touches more
  than one screen. A bug fix, a copy tweak, or a small change that matches an
  approved design does not count.
- **How:** publish a claude.ai Artifact (the `Artifact` tool in Claude Code) —
  a clickable HTML mock, close enough to the real thing to react to, with the
  real content and states (empty, loading, error) rather than lorem ipsum.
  Give him the link. RIA working from her own turns uses `publish_artifact`.
- **Iterate:** revise the same artifact (same URL) on each reaction. Do not
  write the production UI while the mock is still moving.
- **Lock:** build only after he says it is locked (or plainly approves it).
  Then build to the artifact, and put its link in the PR description.
  If the build has to diverge from it, say where and why in the PR.
- Unattended runs (a schedule, a self-ship) cannot get a lock, so they must not
  ship a large UI change: publish the mock and stop.
<!-- /ria:ui-artifact-first -->
