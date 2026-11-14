---
paths:
  - "apps/web/**"
---

# Layout changes are checked at every standard viewport

Set by the owner on 2026-11-13. Any change to the website's shape or layout (spacing, sizing,
position, a section's structure, what pins or stacks) is checked and confirmed issue-free before it
ships, at each of these viewports:

| Viewport | Size |
|---|---|
| Small phone | 320 × 640 |
| Phone | 375 × 812 |
| Tablet | 820 × 1180 |
| Laptop (short) | 1280 × 760 |
| Desktop | 1440 × 900 |
| Wide desktop | 1920 × 1080 |

At each one, confirm: no sideways scroll; nothing overlaps, clips or overflows its box; text fits
and wraps cleanly; spacing between and inside sections reads as intended rather than cramped or
stranded; and anything that pins, sticks or animates behaves (pins only where it fits, lets go
cleanly). A layout that is merely unbroken but looks wrong at a size counts as a failure. Say in the
PR which viewports were checked and how.
