# Changelog

`MAJOR.MINOR.PATCH` in `VERSION`, mirrored by `MARKETING_VERSION` in
`ios/project.yml`. The `changelog` guard enforces that the top header equals
`VERSION`, is new relative to `main`, and increases monotonically. A MINOR bump
is a milestone and ships a retro under `docs/retros/`.

Older series live in [`docs/changelog/`](docs/changelog) ([`0.1.md`](docs/changelog/0.1.md), [`0.2.md`](docs/changelog/0.2.md)).
Before 0.1.0 the history is the commit log on `main`.

## 0.3.0 — 2026-11-12

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

