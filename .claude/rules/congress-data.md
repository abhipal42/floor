---
paths:
  - "apps/api/**"
  - "apps/worker/**"
  - "packages/**"
---

# Congress data: things that are easy to get wrong

Lesson numbers are `docs/HANDOFF.md` §3.

- **Never log Congress.gov URLs** — they carry the API key (lesson 7).
- **Switch `CONGRESS` to 120 in `apps/api/src/district.ts` on 2027-01-03** (lesson 4).
- A Speaker election's `result` is the ballot's leader, not a winner (lesson 16).
