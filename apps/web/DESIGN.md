---
name: Floor
description: Congress, called like a game.
colors:
  ground: "#07080a"
  panel: "#0b0c0f"
  surface: "#14161b"
  surface-2: "#1e2128"
  line: "#2a2e36"
  muted: "#9ba1ad"
  body: "#c4c9d2"
  ink: "#f2f4f7"
  yea: "#34d399"
  yea-hover: "#6ee7b7"
  nay: "#fb923c"
  accent: "#facc15"
  ai: "#c4b5fd"
  live: "#ff453a"
typography:
  display:
    fontFamily: "Barlow Condensed, sans-serif"
    fontSize: "clamp(64px, 8.4vw, 124px)"
    fontWeight: 900
    lineHeight: 0.84
  headline:
    fontFamily: "Barlow Condensed, sans-serif"
    fontSize: "clamp(52px, 6vw, 88px)"
    fontWeight: 900
    lineHeight: 0.86
  title:
    fontFamily: "Barlow Condensed, sans-serif"
    fontSize: "26px"
    fontWeight: 800
  body:
    fontFamily: "Inter, system-ui, sans-serif"
    fontSize: "17px"
    fontWeight: 400
    lineHeight: 1.55
  label:
    fontFamily: "Barlow Condensed, sans-serif"
    fontSize: "16px"
    fontWeight: 800
rounded:
  sm: "8px"
  md: "12px"
  lg: "18px"
  pill: "999px"
spacing:
  gutter: "24px"
  section: "96px"
components:
  button-primary:
    backgroundColor: "{colors.yea}"
    textColor: "{colors.ground}"
    rounded: "{rounded.sm}"
    padding: "9px 14px"
  button-primary-hover:
    backgroundColor: "{colors.yea-hover}"
  button-solid:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.ground}"
    rounded: "10px"
    padding: "13px 20px"
  card:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.lg}"
  tab:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.body}"
    rounded: "10px"
    padding: "9px 13px"
---

# Design System: Floor

<!-- Records the shipped landing page (apps/web/public/styles.css, locked mock of 2026-11-12).
     A light mode and a Congress-inspired patina are being designed in a separate environment;
     when they land, re-run /impeccable document so this file matches the code. -->

## Overview

**Creative North Star: "The Night Game Broadcast"**

Floor presents Congress the way primetime sports TV presents a game: a dark stadium, a lit
scoreboard, loud condensed italic headlines and crisp stat graphics. Every vote is a final score,
every member a player card, every bill a drive down the field. The energy comes from type, colour
for outcomes, and motion, never from betting on outcomes.

The page is dense but legible: big numbers lead, the detail sits one step away in cards, tabs and
callouts. Components are punchy and tactile, with collectible-card gradients, hover lift, skewed
chips and a split-flap board.

**Direction in progress:** the owner is adding a light mode and a patina inspired by Congress
(the materials of the Capitol) to this broadcast world. Until that work lands, the dark tokens
below are the only implemented theme. Don't invent the light values here.

**Key Characteristics:**
- Near-black ground with layered dark surfaces, no light theme yet
- Condensed italic uppercase display type against a plain Inter body
- Colour means outcome: green yea, orange nay, yellow for thresholds and boss levels, violet for AI
- Scoreboard devices: split-flap board, ticker, box scores, player cards, a drive-chart field

## Colors

A dark broadcast palette where colour is reserved for meaning.

### Primary
- **Yea Green** (#34d399): yea votes, passing, primary calls to action, kickers, links.

### Secondary
- **Nay Orange** (#fb923c): nay votes and failures. Always paired with Yea Green, never decorative.

### Tertiary
- **Threshold Yellow** (#facc15): the line a vote had to beat, boss levels, crossovers, focus ring.
- **AI Violet** (#c4b5fd): anything AI-written, with its source tags.
- **Live Red** (#ff453a): the live dot and live kicker only.

### Neutral
- **Stadium Night** (#07080a): page ground.
- **Press Box** (#0b0c0f): full-width bands.
- **Card Slate** (#14161b) and **Raised Slate** (#1e2128): cards, then active or raised elements.
- **Seam** (#2a2e36): borders and tracks.
- **Ink** (#f2f4f7), **Body** (#c4c9d2), **Muted** (#9ba1ad): text, from strongest to quietest.

**The Outcome Colour Rule.** Green and orange mean yea and nay. Don't use them for decoration,
section theming or brand flourish.

**The Labelled AI Rule.** AI Violet marks AI-written content and nothing else, so the colour itself
works as the label.

## Typography

**Display Font:** Barlow Condensed (with sans-serif fallback)
**Body Font:** Inter (with system-ui)
**Source Font:** Georgia, only for quoted official summary paragraphs

**Character:** stadium signage over a clean broadcast lower-third. The condensed italic carries the
energy; Inter keeps the facts calm.

### Hierarchy
- **Display** (900 italic, clamp(64px, 8.4vw, 124px), 0.84): hero title only, uppercase.
- **Headline** (900 italic, clamp(52px, 6vw, 88px), 0.86): section titles, uppercase, set on short broken lines.
- **Title** (800, 22–34px): card titles, member names, uppercase.
- **Body** (400, 17px, 1.55): ledes, kept to about 440px wide; card text is 14–15px.
- **Label** (800, 16px): numbered kickers ("01 · CATCH UP") in Yea Green.
- **Scores** (800, up to 72px, tabular numbers): every tally uses Barlow Condensed.

**The Scores Are Condensed Rule.** Every number that is a score, count or amount is set in Barlow
Condensed 800. Inter never carries a score.

## Layout

Content sits in a 1240px container with 24px gutters. Sections alternate between the plain ground
and full-bleed Press Box bands, with 96px vertical padding. Two-up splits (copy plus a live widget)
wrap to one column with flex-basis wrapping rather than fixed breakpoints; one breakpoint at 600px
tightens mobile. The sticky header is 65px with a blurred translucent ground.

## Elevation & Depth

Depth comes from tonal layering (ground, band, card, raised) with a 1px Seam border. Shadows are
large and soft, used only on objects meant to feel physical: the deck cards, the split-flap board,
stacked level cards, player cards and the phone.

**The Physical Objects Rule.** Only things you could hold get a shadow (cards in a deck, a board, a
phone). Flat panels stay flat.

## Shapes

Generous rounding: 18–20px on cards, 12–14px on inner panels, 8–10px on buttons and tabs, pills for
member chips. Skewed (-10°) chips mark results, like a broadcast graphic.

## Components

### Buttons
- **Shape:** gently rounded (8–10px).
- **Primary:** Yea Green on Stadium Night text, bold (header "Get the app", "Deal me in").
- **Solid:** Ink fill with dark text (deck "Next").
- **Hero call to action:** dark button inside a rotating green-to-yellow conic border.
- **Hover:** a 2px lift on deck buttons; green brightens to #6ee7b7.

### Tabs
- **Style:** Card Slate with a Seam border; selected is solid Ink with dark text.
- **Member tabs:** pill with a round photo; selected gets a Yea Green border.

### Cards / Containers
- **Corner Style:** 18px.
- **Background:** Card Slate, a 1px Seam border, 22px padding.
- **Callouts:** Raised Slate with a yellow condensed italic key word ("TWIST").

### Player cards (signature)
A tier-gradient frame (gold, silver, green) around a dark card: photo with a moving shine, name in
condensed uppercase, stats split by a hairline. Tier comes only from how often a member breaks with
their party.

### Split-flap board (signature)
A 20-column departure-board grid of flap cells cycling through recent finals in the hero.

## Do's and Don'ts

### Do:
- **Do** keep every colour a token on `:root` in `styles.css`.
- **Do** set scores, counts and money in Barlow Condensed 800 with tabular numbers.
- **Do** pair yea and nay as green and orange, and label AI content with AI Violet and a source tag.
- **Do** respect `prefers-reduced-motion`, which already stops the page's loops.

### Don't:
- **Don't** use outcome colours as decoration.
- **Don't** add betting, picks or prediction visuals (odds tickers, "who wins?" prompts).
- **Don't** add light-mode values here before the light mode work lands.
