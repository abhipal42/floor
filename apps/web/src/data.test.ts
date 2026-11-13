import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { districtLabel } from "./locate.js";
import {
  YOUR_THREE,
  sampleReps,
  contextNone,
  donorContext,
  drives,
  explainers,
  finals,
  flap,
  funding,
  hero,
  levels,
  live,
  mavericks,
  portfolio,
  scouting,
  ticker,
  type Sourced,
} from "./data.js";
import { isMaxed, pct, tierFor, winningSide } from "./logic.js";

const blocks: [string, Sourced][] = [
  ["hero", hero],
  ["flap", flap],
  ["ticker", ticker],
  ["finals", finals],
  ["levels", levels],
  ["drives", drives],
  ["explainers", explainers],
  ["scouting", scouting],
  ["mavericks", mavericks],
  ["funding", funding],
  ["donorContext", donorContext],
  ["portfolio", portfolio],
  ["live", live],
  ["sampleReps", sampleReps],
];

describe("every block is sourced and dated", () => {
  it.each(blocks)("%s", (_name, block) => {
    expect(block.source.length).toBeGreaterThan(10);
    expect(block.asOf).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });
});

describe("finals", () => {
  it("has five cards", () => expect(finals.cards).toHaveLength(5));

  it.each(finals.cards.map((c) => [c.cite, c] as const))("%s: party splits sum to the totals", (_cite, c) => {
    expect(c.splits.reduce((n, s) => n + s.yea, 0)).toBe(c.yea);
    expect(c.splits.reduce((n, s) => n + s.nay, 0)).toBe(c.nay);
  });

  it("result agrees with passed", () => {
    for (const c of finals.cards) expect(c.result).toBe(c.passed ? "PASSED" : "FAILED");
  });

  it("each card's reps are among your three and match their scouting grid", () => {
    for (const c of finals.cards) {
      for (const r of c.reps) {
        expect(YOUR_THREE).toContain(r.member);
        const scout = scouting.members.find((m) => m.id === r.member)!;
        const [measure, question] = c.cite.split(" · ");
        const row = scout.grid.find((g) => g[2] === measure && g[3] === question && g[5] === c.yea && g[6] === c.nay);
        expect(row, c.cite + " in " + r.member).toBeDefined();
        expect(row![4]).toBe(r.pos === "Yea" ? "Y" : "N");
      }
    }
  });

  it("the twist's arithmetic holds", () => {
    // "seven short of the sixty", "three votes short of sixty", "fell 67 votes short of two-thirds".
    expect(60 - finals.cards[0]!.yea).toBe(7);
    expect(60 - finals.cards[4]!.yea).toBe(3);
    const hjres = finals.cards[1]!;
    expect(Math.ceil(((hjres.yea + hjres.nay) * 2) / 3) - hjres.yea).toBe(67);
    expect(hjres.yea - hjres.nay).toBe(6);
  });
});

describe("ticker and flap", () => {
  it("ticker scores match the scouting grids where both list the roll", () => {
    const rows = scouting.members.flatMap((m) => m.grid);
    for (const t of ticker.items) {
      const measure = t.title.split(" ")[0] === "PN1129" ? "PN1129" : t.title;
      expect(rows.some((r) => r[2] === measure && r[5] === t.yea && r[6] === t.nay), t.title).toBe(true);
    }
  });

  it("flap rows fit the 20-character board", () => {
    for (const m of flap.messages) for (const r of m.rows) expect(r.length).toBeLessThanOrEqual(20);
  });
});

describe("levels", () => {
  it("six levels, three of them boss fights", () => {
    expect(levels.items).toHaveLength(6);
    expect(levels.items.filter((l) => l.boss).map((l) => l.name)).toEqual(["House floor", "Senate floor", "Signed"]);
  });
});

describe("drive chart", () => {
  it("only a signed bill reaches the end zone", () => {
    for (const d of drives.items) expect(d.pos === 100).toBe(d.status === "TOUCHDOWN");
  });
});

describe("explainers", () => {
  it.each(explainers.bills.map((b) => [b.cite, b] as const))("%s: every ¶ citation exists", (_cite, b) => {
    for (const p of b.points) {
      expect(Number.isInteger(p.src)).toBe(true);
      expect(p.src).toBeGreaterThanOrEqual(1);
      expect(p.src).toBeLessThanOrEqual(b.paras.length);
    }
    for (const m of b.not.matchAll(/¶(\d+)/g)) expect(Number(m[1])).toBeLessThanOrEqual(b.paras.length);
  });
});

describe("scouting grids", () => {
  const byId = Object.fromEntries(scouting.members.map((m) => [m.id, m]));
  const tally = (id: string) => {
    const t = { Y: 0, N: 0, P: 0, M: 0 };
    for (const r of byId[id]!.grid) t[r[4]]++;
    return t;
  };

  it("each grid has 40 consecutive roll calls", () => {
    for (const m of scouting.members) {
      expect(m.grid).toHaveLength(40);
      m.grid.forEach((r, i) => expect(r[0]).toBe(m.grid[0]![0] + i));
    }
  });

  it("Jeffries: 21 yea, 18 nay, 1 present", () => expect(tally("J000294")).toEqual({ Y: 21, N: 18, P: 1, M: 0 }));
  it("Schumer: none missed", () => expect(tally("S000148").M).toBe(0));
  it("Gillibrand: one missed, the Sonderling confirmation on Oct 1", () => {
    expect(tally("G000555").M).toBe(1);
    const missed = byId.G000555!.grid.find((r) => r[4] === "M")!;
    expect([missed[1], missed[2], missed[3]]).toEqual(["Oct 1", "PN1129", "Nomination"]);
  });

  it("played, of and won match the grid", () => {
    for (const m of scouting.members) {
      const t = tally(m.id);
      expect(t.Y + t.N + t.P, m.id).toBe(m.played);
      // Two Senate results are truncated by the clerk and say nothing about the outcome; they are
      // left out of the winning-side count rather than counted as losses.
      const truncated = m.grid.filter((r) => (r[4] === "Y" || r[4] === "N") && /^(Concurrent Resolution |Motion to Discharge Re)$/.test(r[7])).length;
      expect(t.Y + t.N - truncated, m.id).toBe(m.of);
      expect(winningSide(m.grid), m.id).toEqual({ won: m.won, of: m.of });
    }
  });

  it("winning side, as stated: Jeffries 21/39, Schumer 14/38, Gillibrand 12/37", () => {
    expect(scouting.members.map((m) => m.won + "/" + m.of)).toEqual(["21/39", "14/38", "12/37"]);
  });

  it("unity and crossovers follow from the party-vote counts", () => {
    for (const m of scouting.members) {
      expect(pct(m.withParty, m.partyVotes)).toBe(m.unity.toFixed(1) + "%");
      expect(m.partyVotes - m.withParty).toBe(m.cross);
      expect(m.note).toContain(m.partyVotes.toLocaleString("en-US"));
    }
  });

  it("Jeffries' fact: 16 suspensions, yea on 15, the exception H.J.Res. 1", () => {
    const sus = byId.J000294!.grid.filter((r) => r[3] === "Suspension");
    expect(sus).toHaveLength(16);
    expect(sus.filter((r) => r[4] === "Y")).toHaveLength(15);
    expect(sus.filter((r) => r[4] !== "Y").map((r) => r[2])).toEqual(["H.J.Res. 1"]);
  });

  it("senators' fact: same way on 35 of the 39 calls both cast, split on S. 4668 twice and two in August", () => {
    const s = byId.S000148!.grid;
    const g = byId.G000555!.grid;
    const both = s.map((r, i) => [r, g[i]!] as const).filter(([a, b]) => a[0] === b[0] && a[4] !== "M" && b[4] !== "M");
    expect(both).toHaveLength(39);
    const split = both.filter(([a, b]) => a[4] !== b[4]).map(([a]) => a);
    expect(split).toHaveLength(4);
    expect(split.filter((r) => r[2] === "S. 4668")).toHaveLength(2);
    expect(split.filter((r) => r[1].startsWith("Aug"))).toHaveLength(2);
  });
});

describe("mavericks", () => {
  it("crossovers = votes − with party, and the board is ranked by crossovers", () => {
    for (const m of mavericks.members) expect(m.votes - m.withParty, m.full).toBe(m.crossovers);
    const xs = mavericks.members.map((m) => m.crossovers);
    expect([...xs].sort((a, b) => b - a)).toEqual(xs);
  });

  it("the fanned cards are on the board, and the raised one is in the fan", () => {
    const ids = mavericks.members.map((m) => m.id);
    for (const id of mavericks.fan) expect(ids).toContain(id);
    expect(mavericks.fan).toContain(mavericks.fanDefault);
  });

  it("tiers come from crossovers alone", () => {
    expect(mavericks.members.map((m) => tierFor(m.crossovers).name)).toEqual([
      "MAVERICK",
      "MAVERICK",
      "MAVERICK",
      "MAVERICK",
      "SWING",
      "SWING",
      "STARTER",
    ]);
  });
});

describe("funding", () => {
  it.each(funding.members.map((f) => [f.member, f] as const))("%s: the four segments sum to the total", (_id, f) => {
    expect(f.small + f.itemized + f.pac + f.other).toBe(f.total);
  });

  it("five of Jeffries' biggest PAC checks are the $10,000 cycle max", () => {
    const j = funding.members[0]!;
    expect(j.pacs.filter((p) => isMaxed(p.amount))).toHaveLength(5);
    expect(j.pacs.every((p) => p.amount === 10000 || p.amount === 5000)).toBe(true);
    const amounts = j.pacs.map((p) => p.amount);
    expect([...amounts].sort((a, b) => b - a)).toEqual(amounts);
  });
});

describe("donor context", () => {
  it("is about one member, and the default donor exists", () => {
    expect(donorContext.member).toBe("J000294");
    expect(donorContext.donors[donorContext.defaultIndex]).toBeDefined();
  });

  it("'cycle max' appears iff the amount is the max", () => {
    for (const d of donorContext.donors) expect(d.how.includes("cycle max"), d.name).toBe(isMaxed(d.amount));
  });

  it("amounts agree with the PAC checks list where a donor is on both", () => {
    const pacs = funding.members[0]!.pacs;
    for (const d of donorContext.donors) {
      const p = pacs.find((x) => x.name === d.name);
      if (p) expect(d.amount, d.name).toBe(p.amount);
    }
  });

  it("a related vote is a real roll on his record, with the score it shows", () => {
    const grid = scouting.members[0]!.grid;
    for (const d of donorContext.donors) {
      if (!d.vote) continue;
      const row = grid.find((r) => d.vote!.title.startsWith(r[2] + " ") && d.vote!.score === r[5] + "–" + r[6]);
      expect(row, d.name).toBeDefined();
      expect(row![4]).toBe(d.vote.pos === "YEA" ? "Y" : "N");
      expect(d.vote.why).toMatch(/not because/);
    }
  });

  it("never names a person: every donor is a committee or organisation", () => {
    for (const d of donorContext.donors) expect(d.name).toMatch(/PAC|Union|Fund|Committee/);
    expect(contextNone).toMatch(/Floor checks his whole record/);
  });
});

describe("portfolio", () => {
  it("the ranges are low ≤ high and fit the scale", () => {
    for (const y of portfolio.years) {
      expect(y.low).toBeLessThan(y.high);
      expect(y.high).toBeLessThanOrEqual(portfolio.scaleMax);
    }
  });

  it("+$119K is the change in the top of the range, 2024 → 2025", () => {
    const [a, b] = portfolio.years;
    expect(b!.high - a!.high).toBe(119000);
    expect(portfolio.stats[0]!.big).toBe("+$119K");
  });

  it("seven 2025 trades, five in his child's accounts, all funds or plans", () => {
    expect(portfolio.trades).toHaveLength(7);
    expect(portfolio.trades.filter((t) => t.who === "Child")).toHaveLength(5);
    for (const t of portfolio.trades) expect(t.asset).toMatch(/Fund|ETF|529/);
  });

  it("the report up close is 8 buys and 5 sells", () => {
    const tape = portfolio.report.tape;
    expect(tape.filter((t) => t.side === "P")).toHaveLength(portfolio.report.buys);
    expect(tape.filter((t) => t.side === "S")).toHaveLength(portfolio.report.sells);
    expect(tape).toHaveLength(13);
  });

  it("the traders board is ranked, and the report's filer is on it", () => {
    const counts = portfolio.board.map((b) => b.reports);
    expect([...counts].sort((a, b) => b - a)).toEqual(counts);
    expect(portfolio.board.some((b) => portfolio.report.filer.startsWith(b.name))).toBe(true);
  });
});

describe("live replay", () => {
  it("replays the same final as the flap board and ticker", () => {
    const t = ticker.items[0]!;
    expect([t.title, t.yea, t.nay]).toEqual(["H.R. 1013", live.vote.yea, live.vote.nay]);
    const row = scouting.members[0]!.grid.at(-1)!;
    expect(row[4]).toBe(live.vote.repPos === "NAY" ? "N" : "Y");
    expect(live.steps).toHaveLength(4);
  });
});

describe("sample district", () => {
  it("is the API's answer for Brooklyn, in the page's tab order", () => {
    const here = dirname(fileURLToPath(import.meta.url));
    const captured = JSON.parse(readFileSync(join(here, "../fixtures/reps-brooklyn.json"), "utf8"));
    const byId = (a: { bioguideId: string }, b: { bioguideId: string }) => a.bioguideId.localeCompare(b.bioguideId);
    expect([...sampleReps.members].sort(byId)).toEqual([...captured.members].sort(byId));
    expect(sampleReps.members.map((m) => m.bioguideId)).toEqual([...YOUR_THREE]);
    expect(districtLabel(captured.district)).toBe(sampleReps.label);
  });
});
