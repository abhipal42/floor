import { describe, expect, it } from "vitest";
import {
  FLAP_CHARSET,
  FLAP_TEXT_MAX,
  FLAP_TICKS,
  FLAP_WIDTH,
  HEAD_DOCK_AT,
  HEAD_FLOAT_AT,
  activeLevel,
  activeStep,
  headFloats,
  scrollStep,
  stepLength,
  stickTop,
  outcome,
  winningSide,
  cellLook,
  countText,
  deckPose,
  deckJump,
  deckStep,
  easeOutCubic,
  easeOutQuart,
  esc,
  fanPose,
  flapChar,
  flapSettle,
  formatMoney,
  formatPac,
  isMaxed,
  islandNext,
  padFlap,
  pct,
  rangeBar,
  readoutCite,
  ringDash,
  ringValues,
  seenLabel,
  splitText,
  tabKeyTarget,
  tierFor,
  yeaShare,
} from "./logic.js";

describe("deck jumps", () => {
  it("deals the next card, cuts to any other, and stays put on the front card", () => {
    expect(deckJump(2, 2, false)).toBe("stay");
    expect(deckJump(2, 3, false)).toBe("deal");
    expect(deckJump(4, 0, false)).toBe("deal");
    expect(deckJump(2, 1, false)).toBe("cut");
    expect(deckJump(0, 3, false)).toBe("cut");
  });

  it("cuts while a deal is still in flight, even to the front card", () => {
    expect(deckJump(2, 3, true)).toBe("cut");
    expect(deckJump(2, 2, true)).toBe("cut");
  });
});

describe("pinned sections", () => {
  it("centres the stage under the header, or pins it right under the header", () => {
    expect(stickTop(65, 900, 625)).toBe(65 + 105);
    expect(stickTop(65, 900, 835)).toBe(65);
    expect(stickTop(65, 900, 1000)).toBe(65);
  });

  it("a step is a little over half a screen, never under 280px", () => {
    expect(stepLength(900)).toBe(495);
    expect(stepLength(400)).toBe(280);
  });

  it("steps advance one per step length and hold the last step to the end", () => {
    expect(scrollStep(-300, 500, 5)).toBe(0);
    expect(scrollStep(0, 500, 5)).toBe(0);
    expect(scrollStep(499, 500, 5)).toBe(0);
    expect(scrollStep(500, 500, 5)).toBe(1);
    expect(scrollStep(2400, 500, 5)).toBe(4);
    expect(scrollStep(9000, 500, 5)).toBe(4);
    expect(scrollStep(700, 500, 1)).toBe(0);
  });
});

describe("road to law", () => {
  it("the last box (the drive chart) counts once it is fully in view at the page's end", () => {
    // Reader mid-road: the last box is still below the fold, so the reading line decides.
    expect(activeStep([-400, 100, 500, 1100], 400, 1500, 900)).toBe(1);
    // End of the page: the last box sits wholly on screen but below the reading line.
    expect(activeStep([-900, -500, 100, 520], 400, 880, 900)).toBe(3);
    // Fully in view but only just peeking in at the bottom fifth: not yet.
    expect(activeStep([-200, 100, 300, 760], 400, 890, 900)).toBe(2);
    expect(activeStep([], 400, 0, 900)).toBe(0);
  });

  it("is on the last card whose top has passed the reading line", () => {
    expect(activeLevel([500, 900, 1300], 400)).toBe(0);
    expect(activeLevel([300, 700, 1100], 400)).toBe(0);
    expect(activeLevel([-200, 350, 750], 400)).toBe(1);
    expect(activeLevel([-900, -500, -100], 400)).toBe(2);
    expect(activeLevel([], 400)).toBe(0);
  });
});

describe("split-flap", () => {
  it("centres, upper-cases and pads to the 24-flap board", () => {
    expect(FLAP_WIDTH).toBe(24);
    expect(padFlap("abc")).toBe("          ABC           ");
    expect(padFlap("HOUSE  ROLL 321")).toBe("    HOUSE  ROLL 321     ");
    expect(padFlap("x".repeat(30))).toBe("X".repeat(24));
    expect(padFlap("abc", 20)).toBe("        ABC         ");
  });

  it("a longest line keeps two blank padding flaps on each side", () => {
    const line = padFlap("R".repeat(FLAP_TEXT_MAX));
    expect(line.slice(0, 2)).toBe("  ");
    expect(line.slice(-2)).toBe("  ");
    expect(line.trim()).toHaveLength(FLAP_TEXT_MAX);
  });

  it("settle ticks grow left to right and finish within the scramble", () => {
    const zero = flapSettle(() => 0);
    expect(zero).toHaveLength(72);
    expect(zero[0]).toBe(3);
    expect(zero[23]).toBe(3 + Math.floor(23 * 0.55));
    expect(zero[24]).toBe(3 + Math.floor(1.5));
    const max = flapSettle(() => 0.9999);
    expect(Math.max(...max)).toBeLessThanOrEqual(FLAP_TICKS);
  });

  it("a cell spins until it settles", () => {
    expect(flapChar("A", 0, 0, 10, 10)).toBe("A");
    expect(flapChar("A", 0, 0, 0, 10)).toBe(FLAP_CHARSET[0]);
    expect(flapChar("A", 1, 2, 3, 10)).toBe(FLAP_CHARSET[(14 + 13 + 15) % FLAP_CHARSET.length]);
    expect(flapChar(" ", 0, 0, 7, 20)).toBe(" ");
    expect(flapChar(" ", 0, 1, 6, 20)).not.toBe(" ");
    expect(flapChar("Q", 0, 0, 0, undefined)).toBe("Q");
  });
});

describe("easing and count-up", () => {
  it("eases from 0 to 1 and clamps", () => {
    expect(easeOutQuart(0)).toBe(0);
    expect(easeOutQuart(1)).toBe(1);
    expect(easeOutQuart(2)).toBe(1);
    expect(easeOutQuart(0.5)).toBeCloseTo(0.9375);
    expect(easeOutCubic(0.5)).toBeCloseTo(0.875);
  });

  it("formats the count with separators", () => {
    expect(countText(995806, 1)).toBe("995,806");
    expect(countText(3532, 0)).toBe("0");
    expect(countText(3532, 0.5)).toBe("1,766");
    expect(countText(10, 1, "%")).toBe("10%");
  });
});

describe("money", () => {
  it("formats as the mock does", () => {
    expect(formatMoney(17893352)).toBe("$17.9M");
    expect(formatMoney(4234848)).toBe("$4.23M");
    expect(formatMoney(41884545)).toBe("$41.9M");
    expect(formatMoney(884398)).toBe("$884K");
    expect(formatMoney(1000000)).toBe("$1.00M");
    expect(formatPac(10000)).toBe("$10K");
    expect(formatPac(7000)).toBe("$7K");
  });

  it("maxed means the $10,000 cycle max", () => {
    expect(isMaxed(10000)).toBe(true);
    expect(isMaxed(9999)).toBe(false);
    expect(isMaxed(5000)).toBe(false);
  });

  it("percent to one decimal", () => {
    expect(pct(8147893, 17893352)).toBe("45.5%");
    expect(pct(1311, 1743)).toBe("75.2%");
  });
});

describe("bars and rings", () => {
  it("a range bar keeps its left edge and grows its width", () => {
    expect(rangeBar(300000, 900000, 1200000, 0)).toEqual({ left: "25%", width: "0%" });
    expect(rangeBar(300000, 900000, 1200000, 1)).toEqual({ left: "25%", width: "50%" });
  });

  it("ring dashes on a 100-unit path", () => {
    expect(ringDash(98.7, 1)).toBe("98.7 100");
    expect(ringDash(98.7, 0)).toBe("0.0 100");
    expect(ringValues({ unity: 98.7, played: 39, won: 21, of: 39 })).toEqual([98.7, 97.5, (100 * 21) / 39]);
  });

  it("yea share of a final", () => {
    expect(yeaShare(53, 47, 1)).toBe("53.0%");
    expect(yeaShare(53, 47, 0)).toBe("0.0%");
  });
});

describe("deck", () => {
  it("stacks by depth from the front card", () => {
    expect(deckPose(0, 0, -1)).toMatchObject({ depth: 0, opacity: 1, z: 20, hidden: false, transform: "translateY(0px) scale(1)" });
    expect(deckPose(2, 0, -1)).toMatchObject({ depth: 2, opacity: 1, z: 18, hidden: true });
    expect(deckPose(3, 0, -1).opacity).toBe(0);
    expect(deckPose(0, 1, -1).depth).toBe(4);
  });

  it("the leaving card flies out on top", () => {
    expect(deckPose(1, 1, 1)).toMatchObject({ transform: "translateX(-112%) rotate(-10deg)", opacity: 0, z: 30 });
  });

  it("steps wrap both ways", () => {
    expect(deckStep(4, 1)).toBe(0);
    expect(deckStep(0, -1)).toBe(4);
  });

  it("counts what has been seen", () => {
    expect(seenLabel([true, false, true, false, false])).toBe("2 of 5 caught up");
  });

  it("writes party splits", () => {
    expect(splitText([{ party: "R", yea: 53, nay: 0 }, { party: "D", yea: 0, nay: 45 }])).toBe("R 53–0 · D 0–45");
  });
});

describe("scouting grid", () => {
  it("styles each position", () => {
    expect(cellLook("Y")).toEqual({ word: "YEA", chipBg: "yea-soft", chipFg: "yea" });
    expect(cellLook("M")).toEqual({ word: "MISSED", chipBg: "line", chipFg: "muted" });
    expect(cellLook("P").word).toBe("PRESENT");
    expect(cellLook("C").word).toBe("VOTED");
  });

  it("names the question when the measure is a bare amendment", () => {
    expect(readoutCite("Amendment", "Cloture")).toBe("Cloture");
    expect(readoutCite("Amendment", "Amendment")).toBe("Amendment");
    expect(readoutCite("H.R. 1013", "Passage")).toBe("H.R. 1013");
  });

  it("reads recorded results", () => {
    expect(outcome("Passed")).toBe("carried");
    expect(outcome("Cloture Agreed to")).toBe("carried");
    expect(outcome("Motion to Table Agreed")).toBe("carried");
    expect(outcome("Nomination Confirmed")).toBe("carried");
    expect(outcome("Failed")).toBe("failed");
    expect(outcome("Cloture Rejected")).toBe("failed");
  });

  it("reads live Senate wording, rejection first", () => {
    expect(outcome("Veto Overridden")).toBe("carried");
    expect(outcome("Veto Sustained")).toBe("failed");
    expect(outcome("Decision of Chair Sustained")).toBe("carried");
    expect(outcome("Guilty")).toBe("carried");
    expect(outcome("Not Guilty")).toBe("failed");
    expect(outcome("Amendment Not Agreed to")).toBe("failed");
    expect(outcome("Cloture Motion Agreed to")).toBe("carried");
    expect(outcome("Cloture on the Motion to Proceed Rejected")).toBe("failed");
    expect(outcome("Concurred in")).toBe("carried");
    expect(outcome("Joint Resolution Defeated")).toBe("failed");
  });

  it("truncated, unknown or missing results have no outcome", () => {
    expect(outcome("Concurrent Resolution ")).toBeNull();
    expect(outcome("Motion to Discharge Re")).toBeNull();
    expect(outcome("Johnson")).toBeNull();
    expect(outcome("")).toBeNull();
    expect(outcome(null)).toBeNull();
  });

  it("winning side leaves undecided results and non-votes out of the denominator", () => {
    const rows = [
      [1, "", "", "", "Y", 0, 0, "Passed"],
      [2, "", "", "", "N", 0, 0, "Passed"],
      [3, "", "", "", "N", 0, 0, "Amendment Not Agreed to"],
      [4, "", "", "", "Y", 0, 0, "Motion to Discharge Re"],
      [5, "", "", "", "P", 0, 0, "Passed"],
      [6, "", "", "", "M", 0, 0, "Failed"],
      [7, "", "", "", "C", 0, 0, "Johnson"],
    ] as const;
    expect(winningSide(rows)).toEqual({ won: 2, of: 3 });
  });
});

describe("player cards", () => {
  it("tiers by crossovers", () => {
    expect(tierFor(400).name).toBe("MAVERICK");
    expect(tierFor(399).name).toBe("SWING");
    expect(tierFor(300).name).toBe("SWING");
    expect(tierFor(172).name).toBe("STARTER");
  });

  it("fans out and raises the selected card", () => {
    expect(fanPose(-2, false)).toEqual({ transform: "translateX(-216px) translateY(28px) rotate(-14deg)", z: 8 });
    expect(fanPose(1, true)).toEqual({ transform: "translateX(108px) translateY(-30px) scale(1.06)", z: 20 });
  });
});

describe("misc", () => {
  it("cycles the island", () => {
    expect(islandNext(0)).toBe(1);
    expect(islandNext(3)).toBe(0);
  });

  it("moves between tabs with the keyboard", () => {
    expect(tabKeyTarget("ArrowRight", 2, 3)).toBe(0);
    expect(tabKeyTarget("ArrowLeft", 0, 3)).toBe(2);
    expect(tabKeyTarget("Home", 2, 3)).toBe(0);
    expect(tabKeyTarget("End", 0, 3)).toBe(2);
    expect(tabKeyTarget("a", 0, 3)).toBeNull();
  });

  it("escapes HTML", () => {
    expect(esc(`<a href="x">Tom & Jerry's</a>`)).toBe("&lt;a href=&quot;x&quot;&gt;Tom &amp; Jerry&#39;s&lt;/a&gt;");
    expect(esc(5)).toBe("5");
  });
});

describe("headFloats", () => {
  it("stays a full-width bar at the top of the page", () => {
    expect(headFloats(0, false)).toBe(false);
    expect(headFloats(HEAD_FLOAT_AT, false)).toBe(false);
  });

  it("floats once the reader scrolls past the float line", () => {
    expect(headFloats(HEAD_FLOAT_AT + 1, false)).toBe(true);
    expect(headFloats(2000, false)).toBe(true);
  });

  it("keeps floating between the two lines, so it cannot flicker on one", () => {
    // Coming back up: still floating anywhere above the dock line.
    for (const y of [HEAD_FLOAT_AT, 30, HEAD_DOCK_AT + 1]) expect(headFloats(y, true)).toBe(true);
    // Going down from the top: still docked anywhere below the float line.
    for (const y of [HEAD_DOCK_AT + 1, 30, HEAD_FLOAT_AT]) expect(headFloats(y, false)).toBe(false);
  });

  it("docks again once back near the top", () => {
    expect(headFloats(HEAD_DOCK_AT, true)).toBe(false);
    expect(headFloats(0, true)).toBe(false);
  });

  it("settles on one answer when a trackpad jitters across a single line", () => {
    // Without the gap, 47-49-47-49 around one threshold toggles every frame.
    let floating = false;
    const flips: boolean[] = [];
    for (const y of [40, 49, 47, 49, 47, 49, 40, 30, 20, 17]) {
      const next = headFloats(y, floating);
      if (next !== floating) flips.push(next);
      floating = next;
    }
    expect(flips).toEqual([true]);
  });

  it("leaves a real gap between the two lines", () => {
    expect(HEAD_FLOAT_AT - HEAD_DOCK_AT).toBeGreaterThanOrEqual(24);
  });
});
