import { describe, expect, it } from "vitest";
import {
  FLAP_CHARSET,
  FLAP_TICKS,
  carried,
  cellLook,
  countText,
  deckPose,
  deckStep,
  driveBall,
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

describe("split-flap", () => {
  it("centres, upper-cases and pads to 20", () => {
    expect(padFlap("abc")).toBe("        ABC         ");
    expect(padFlap("HOUSE  ROLL 321")).toBe("  HOUSE  ROLL 321   ");
    expect(padFlap("x".repeat(25))).toBe("X".repeat(20));
    expect(padFlap("RATEPAYER PROTECTION")).toHaveLength(20);
  });

  it("settle ticks grow left to right and finish within the scramble", () => {
    const zero = flapSettle(() => 0);
    expect(zero).toHaveLength(60);
    expect(zero[0]).toBe(3);
    expect(zero[19]).toBe(3 + Math.floor(19 * 0.55));
    expect(zero[20]).toBe(3 + Math.floor(1.5));
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

describe("drive chart", () => {
  it("places the ball between the 6% and 94% lines", () => {
    expect(driveBall(0)).toEqual({ ball: "6.0%", fill: "0.0%" });
    expect(driveBall(50)).toEqual({ ball: "50.0%", fill: "44.0%" });
    expect(driveBall(100)).toEqual({ ball: "94.0%", fill: "88.0%" });
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
    expect(carried("Passed")).toBe(true);
    expect(carried("Cloture Agreed to")).toBe(true);
    expect(carried("Motion to Table Agreed")).toBe(true);
    expect(carried("Nomination Confirmed")).toBe(true);
    expect(carried("Failed")).toBe(false);
    expect(carried("Cloture Rejected")).toBe(false);
    expect(carried("Concurrent Resolution ")).toBe(false);
    expect(carried("Motion to Discharge Re")).toBe(false);
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
