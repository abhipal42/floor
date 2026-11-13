// Pure functions behind the landing page: no DOM, no timers, so every number the page animates
// toward can be tested in Node. Each one mirrors a calculation in the locked design mock.

/** Flaps per row: 20 for the text plus two blank padding flaps each side (hidden on phones). */
export const FLAP_WIDTH = 24;
/** The longest line the board shows, so every line keeps at least two blank flaps each side. */
export const FLAP_TEXT_MAX = 20;
export const FLAP_ROWS = 3;
/** Characters a split-flap cell shows while it is still spinning. */
export const FLAP_CHARSET = "ABCDEFGHIJKLMNOPRSTUVWXYZ0123456789-";
/** The scramble runs for this many 50 ms ticks; every cell has settled by then. */
export const FLAP_TICKS = 24;

/**
 * The level the reader is on: the last card whose top has scrolled above the reading line.
 * Before the first card reaches the line, that is still the first level.
 */
export function activeLevel(tops: readonly number[], line: number): number {
  let on = 0;
  tops.forEach((top, i) => {
    if (top < line) on = i;
  });
  return on;
}

/** Upper-cases, truncates to the board width and centres a line (extra space goes right). */
export function padFlap(text: string, width = FLAP_WIDTH): string {
  const s = text.toUpperCase().slice(0, width);
  const left = Math.floor((width - s.length) / 2);
  return (" ".repeat(left) + s + " ".repeat(width)).slice(0, width);
}

/** The tick at which each cell (row-major) stops spinning: later columns and rows settle later. */
export function flapSettle(random: () => number = Math.random): number[] {
  const out: number[] = [];
  for (let r = 0; r < FLAP_ROWS; r++) {
    for (let c = 0; c < FLAP_WIDTH; c++) out.push(3 + Math.floor(c * 0.55 + r * 1.5 + random() * 5));
  }
  return out;
}

/** What one cell shows at a tick: its target once settled, a cycling character before. */
export function flapChar(target: string, row: number, col: number, tick: number, settleAt: number | undefined): string {
  if (settleAt === undefined || tick >= settleAt) return target;
  if (target === " " && tick > 6) return " ";
  return FLAP_CHARSET[(col * 7 + row * 13 + tick * 5) % FLAP_CHARSET.length] ?? " ";
}

export function easeOutQuart(t: number): number {
  return 1 - Math.pow(1 - clamp01(t), 4);
}

export function easeOutCubic(t: number): number {
  return 1 - Math.pow(1 - clamp01(t), 3);
}

export function clamp01(t: number): number {
  return Math.min(1, Math.max(0, t));
}

/** A count-up's displayed value at progress p (0..1), with thousands separators. */
export function countText(to: number, p: number, suffix = ""): string {
  return Math.round(to * p).toLocaleString("en-US") + suffix;
}

/** Campaign money: $17.9M, $4.23M, $885K. Two decimals under $10M, one above. */
export function formatMoney(x: number): string {
  if (x >= 1e6) return "$" + (x / 1e6).toFixed(x >= 1e7 ? 1 : 2) + "M";
  return "$" + Math.round(x / 1000) + "K";
}

/** A PAC check in whole thousands: $10K, $5K. */
export function formatPac(amount: number): string {
  return "$" + amount / 1000 + "K";
}

/** A PAC may give $5,000 per election (primary and general), so $10,000 is the cycle max. */
export const PAC_CYCLE_MAX = 10_000;

export function isMaxed(amount: number): boolean {
  return amount >= PAC_CYCLE_MAX;
}

export function pct(part: number, whole: number, digits = 1): string {
  return ((100 * part) / whole).toFixed(digits) + "%";
}

/** A reported range drawn on a 0..max track. Width grows from 0 with p; left stays put. */
export function rangeBar(lo: number, hi: number, max: number, p: number): { left: string; width: string } {
  return { left: (100 * lo) / max + "%", width: (p ? (100 * (hi - lo)) / max : 0) + "%" };
}

/** stroke-dasharray for a ring drawn with pathLength=100, filled to `value` percent at progress p. */
export function ringDash(value: number, p: number): string {
  return (value * p).toFixed(1) + " 100";
}

export interface ScoutRingInput {
  unity: number;
  played: number;
  won: number;
  of: number;
}

/** The three scouting rings, as percents: with party, showed up (of 40), winning side. */
export function ringValues(m: ScoutRingInput): [number, number, number] {
  return [m.unity, 2.5 * m.played, (100 * m.won) / m.of];
}

export const DECK_SIZE = 5;

export interface DeckCardPose {
  depth: number;
  transform: string;
  opacity: number;
  z: number;
  hidden: boolean;
}

/** Where card k sits in the stack when card `front` is showing and `leaving` is flying out. */
export function deckPose(k: number, front: number, leaving: number, n = DECK_SIZE): DeckCardPose {
  const depth = (k - front + n) % n;
  if (k === leaving) {
    return { depth, transform: "translateX(-112%) rotate(-10deg)", opacity: 0, z: 30, hidden: depth !== 0 };
  }
  return {
    depth,
    transform: "translateY(" + depth * 14 + "px) scale(" + (1 - depth * 0.04) + ")",
    opacity: depth > 2 ? 0 : 1,
    z: 20 - depth,
    hidden: depth !== 0,
  };
}

export function deckStep(front: number, dir: 1 | -1, n = DECK_SIZE): number {
  return (front + dir + n) % n;
}

/** Yea share of the bar on a final's card, at count-up progress p. */
export function yeaShare(yea: number, nay: number, p: number): string {
  return (((100 * yea) / (yea + nay)) * p).toFixed(1) + "%";
}

/** The drive chart's field runs 6%..94% of the track; `pos` is 0..100 of the way to law. */
export function driveBall(pos: number): { ball: string; fill: string } {
  const ball = 6 + (88 * pos) / 100;
  return { ball: ball.toFixed(1) + "%", fill: (ball - 6).toFixed(1) + "%" };
}

export type VotePos = "Y" | "N" | "P" | "M";

export interface CellLook {
  word: string;
  /** Readout chip background and text token names. */
  chipBg: string;
  chipFg: string;
}

/** A cell's position: a VotePos, or C for a Speaker-election vote for a named candidate (live data only). */
export type CellPos = VotePos | "C";

const CELL: Record<CellPos, CellLook> = {
  Y: { word: "YEA", chipBg: "yea-soft", chipFg: "yea" },
  N: { word: "NAY", chipBg: "nay-soft", chipFg: "nay" },
  P: { word: "PRESENT", chipBg: "line", chipFg: "body" },
  M: { word: "MISSED", chipBg: "line", chipFg: "muted" },
  C: { word: "VOTED", chipBg: "line", chipFg: "ink" },
};

export function cellLook(pos: CellPos): CellLook {
  return CELL[pos];
}

/** The readout names the measure, except when the record only says "Amendment" — then the question. */
export function readoutCite(cite: string, question: string): string {
  return cite === "Amendment" && question !== "Amendment" ? question : cite;
}

export type Outcome = "carried" | "failed";

// The iOS rule (FloorKit `Vote.recordedOutcome`), plus impeachment verdicts. Rejection words are
// checked first: "Not Agreed to" contains "agreed", "Not Guilty" contains "guilty", and "Veto
// Sustained" is a failed override even though "Decision of Chair Sustained" carried.
const FAILED_WORDS = ["rejected", "failed", "not agreed", "not sustained", "not invoked", "defeated", "veto sustained", "not guilty"];
const CARRIED_WORDS = ["passed", "agreed", "confirmed", "sustained", "adopted", "invoked", "concurred", "overridden", "guilty"];

/**
 * What a roll call's recorded result says happened, or null when the wording is missing, truncated
 * by the clerk ("Concurrent Resolution ", "Motion to Discharge Re") or unfamiliar. A null outcome
 * has no winning side, so it is left out of the winning-side count rather than counted as a loss.
 */
export function outcome(result: string | null): Outcome | null {
  const r = (result ?? "").toLowerCase();
  if (FAILED_WORDS.some((w) => r.includes(w))) return "failed";
  if (CARRIED_WORDS.some((w) => r.includes(w))) return "carried";
  return null;
}

/** Winning side over the last calls: yea on what carried, nay on what failed, out of decided yea/nay votes. */
export function winningSide(rows: readonly { readonly 4: string; readonly 7: string }[]): { won: number; of: number } {
  let won = 0;
  let of = 0;
  for (const r of rows) {
    if (r[4] !== "Y" && r[4] !== "N") continue;
    const o = outcome(r[7]);
    if (!o) continue;
    of++;
    if ((r[4] === "Y") === (o === "carried")) won++;
  }
  return { won, of };
}

export interface Tier {
  name: "MAVERICK" | "SWING" | "STARTER";
  badge: string;
  frame: string;
}

/** A card's tier comes only from crossovers: 400+ maverick, 300+ swing, else starter. */
export function tierFor(crossovers: number): Tier {
  if (crossovers >= 400) return { name: "MAVERICK", badge: "accent", frame: "gold" };
  if (crossovers >= 300) return { name: "SWING", badge: "body", frame: "silver" };
  return { name: "STARTER", badge: "yea", frame: "green" };
}

/** The fanned cards: offset from the centre card, raised and straightened when selected. */
export function fanPose(offset: number, selected: boolean): { transform: string; z: number } {
  if (selected) return { transform: "translateX(" + offset * 108 + "px) translateY(-30px) scale(1.06)", z: 20 };
  return {
    transform: "translateX(" + offset * 108 + "px) translateY(" + Math.abs(offset) * 14 + "px) rotate(" + offset * 7 + "deg)",
    z: 10 - Math.abs(offset),
  };
}

export const ISLAND_STEPS = 4;

export function islandNext(step: number, n = ISLAND_STEPS): number {
  return (step + 1) % n;
}

/** Arrow-key movement within a tablist, wrapping; Home and End jump to the ends. */
export function tabKeyTarget(key: string, current: number, count: number): number | null {
  if (key === "ArrowRight" || key === "ArrowDown") return (current + 1) % count;
  if (key === "ArrowLeft" || key === "ArrowUp") return (current - 1 + count) % count;
  if (key === "Home") return 0;
  if (key === "End") return count - 1;
  return null;
}

export interface Split {
  party: string;
  yea: number;
  nay: number;
}

/** "R 53–0 · D 0–45 · I 0–2" */
export function splitText(splits: readonly Split[]): string {
  return splits.map((s) => s.party + " " + s.yea + "–" + s.nay).join(" · ");
}

export function seenLabel(seen: readonly boolean[]): string {
  return seen.filter(Boolean).length + " of " + seen.length + " caught up";
}

const ESC: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

/** Escapes text for interpolation into HTML, text or attribute position. */
export function esc(value: string | number): string {
  return String(value).replace(/[&<>"']/g, (c) => ESC[c] ?? c);
}
