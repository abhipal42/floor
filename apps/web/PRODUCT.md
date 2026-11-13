# Product

<!-- impeccable:product-schema 1 -->

Scope: the Floor landing page (`apps/web`). The iOS app shares this product truth; its own design
lives under `ios/`.

## Platform

web

## Users

Casual citizens who don't follow Congress closely but want to know how their three members of
Congress (one representative, two senators) voted, and what each vote means. They arrive curious,
not expert, and should understand a vote at a glance, the way a box score explains a game.

## Product Purpose

Floor is a live federal vote tracker for iOS: how your members of Congress vote, how each vote is
going, what the bill does, and what it means for you. The landing page shows the product on real
data and turns a visit into an iPhone beta signup (address plus email, "Deal me in").

## Positioning

Congress called like a game: every House and Senate vote as a final score, with a box score by
party, how your three members played it, how far each bill has driven toward law, and who funds
them. Built on official sources (House Clerk, Senate, Congress.gov, FEC, U.S. Census) rather than
third-party aggregators.

## Operating Context

- Static HTML/CSS/TypeScript page; all shown data comes from one typed snapshot (`src/data.ts`).
- Deployed at <https://floor-web-seven.vercel.app>.
- The address entered is used to find the member trio; Floor keeps the district and drops the street.

## Capabilities and Constraints

- Sections: Finals (catch-up deck), Road to law, Bills explained (AI), Your reps (scouting report),
  Players (member cards and maverick leaderboard), Money (FEC), Portfolio (disclosures), Live
  (preview of a feature in development), Get the app.
- Live Activities and running tallies are in development; anything shown of them is labelled a preview.

## Brand Commitments

- **Name:** Floor.
- **Voice (binding):** sports broadcast. Finals, box scores, player cards, scouting reports, drive
  charts, streaks. Short, confident, plain English.
- **Informational only.** Never pick, predict, guess or bet on an outcome: gamified presentation
  yes, gamified participation in outcomes no.
- **Context, not cause.** Donor context sits beside votes; never claims money explains a vote, or
  the reverse. Every donor gets the same treatment.
- **Ranges, not net worth.** Financial disclosures show reported value bands and leave out homes;
  never a single net-worth figure.
- **AI is labelled and cited.** Every AI-written line carries an AI label, points at its source and
  says it may contain errors. An unsourced claim is cut, not softened.
- **No individual donors' names**, even though the FEC publishes them.
- **Nonpartisan.**

## Evidence on Hand

- Real roll calls, bills, CRS summaries, FEC totals and member photos in `src/data.ts` and
  `public/img/`.
- No testimonials, user counts, press or ratings exist. Do not invent them.
- Privacy and contact pages do not exist yet; the footer shows `[PRIVACY]` and `[CONTACT]` placeholders.

## Product Principles

1. **Real data or a visible placeholder.** Never an invented number, quote or example.
2. **A vote should read at a glance.** The score first, the detail one step away.
3. **Your three first.** Personal relevance (your rep and senators) beats national breadth.
4. **Every claim traces to a source.** Official feeds, cited paragraphs, labelled AI.

## Accessibility & Inclusion

Keyboard reachable (skip link, visible focus ring), semantic tabs and live regions on the existing
page. Keep that level.
