import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  congressSessionOn,
  easternToDate,
  easternWallClock,
  parseHouseFloor,
  parseSenateFloorActivity,
  parseSenateSchedule,
  parseSenateVoteMenu,
  plainText,
} from "./floor.js";

const fixture = (name: string) =>
  readFileSync(join(dirname(fileURLToPath(import.meta.url)), "../fixtures", name), "utf8");

describe("parseHouseFloor (real Clerk floor summary, 2026-11-10)", () => {
  const day = parseHouseFloor(fixture("house-floor-20261110.xml"));

  it("reads the legislative day and the Congress", () => {
    expect(day).toMatchObject({ legislativeDay: "2026-11-10", congress: 119, session: 2, finished: true });
    expect(day.nextConvenesEastern).toBe("2026-11-11T11:00");
    expect(day.actions).toHaveLength(32);
  });

  it("finds each recorded vote with its roll number, question, result and tally", () => {
    const votes = day.actions.filter((a) => a.kind === "vote");
    expect(votes.map((v) => v.roll?.rollNumber)).toEqual([319, 318, 317]);
    expect(votes[0]).toMatchObject({
      uniqueId: expect.any(String),
      actId: "H37100",
      occurredAtEastern: "2026-11-10T18:20:53",
      updatedAtEastern: "2026-11-10T18:32",
      item: "H. Res. 1650",
      roll: { year: 2026, rollNumber: 319, question: "On agreeing to the resolution", result: "Agreed to", yea: 215, nay: 209 },
    });
    expect(votes[1]!.roll).toMatchObject({ question: "On ordering the previous question", yea: 213, nay: 207 });
    expect(votes[2]!.roll).toMatchObject({ question: "On motion to refer", result: "Agreed to", yea: 211, nay: 204 });
  });

  it("does not take a voice vote for a roll call", () => {
    const voice = day.actions.find((a) => a.text.startsWith("On motion to adjourn"));
    expect(voice).toMatchObject({ kind: "other", roll: null });
  });

  it("classifies convening, recess and adjournment", () => {
    expect(day.actions.filter((a) => a.kind === "convene")).toHaveLength(3);
    expect(day.actions.filter((a) => a.kind === "recess")).toHaveLength(2);
    expect(day.actions.find((a) => a.kind === "adjourn")?.occurredAtEastern).toBe("2026-11-10T19:55:12");
  });

  it("decodes the Clerk's entities and drops its links", () => {
    const considered = day.actions.find((a) => a.uniqueId && a.text.startsWith("Considered as unfinished business"));
    expect(considered?.text).toContain("H. Res. 1650 — \"Providing for consideration");
    expect(considered?.text).not.toContain("<a");
  });
});

describe("parseHouseFloor (real file, 2026-11-13: a short pro forma-style day)", () => {
  const day = parseHouseFloor(fixture("house-floor-20261113.xml"));
  it("knows when the House meets next", () => {
    expect(day).toMatchObject({ legislativeDay: "2026-11-13", finished: true, nextConvenesEastern: "2026-11-17T12:00" });
    expect(day.actions.some((a) => a.kind === "vote")).toBe(false);
  });

  it("rejects something that is not a floor summary", () => {
    expect(() => parseHouseFloor("<html><body>Not found</body></html>")).toThrow();
  });

  it("rejects a file without its Congress or session, rather than filing votes under Congress 0", () => {
    const real = fixture("house-floor-20261113.xml");
    expect(real).toContain('congress="119"');
    expect(() => parseHouseFloor(real.replace('congress="119"', 'congress="0"'))).toThrow(/no Congress/);
    expect(() => parseHouseFloor(real.replace(/session="2"/, 'session=""'))).toThrow(/no session/);
  });
});

describe("parseHouseFloor roll call wording", () => {
  const withAction = (description: string) =>
    fixture("house-floor-20261110.xml").replace(
      "On agreeing to the resolution Agreed to by recorded vote: 215 - 209",
      description,
    );

  it("does not split a question at a lower-case result word inside it", () => {
    const day = parseHouseFloor(
      withAction("On motion that the bill as passed by the Senate be ordered printed Passed by recorded vote: 300 - 100"),
    );
    expect(day.actions.find((a) => a.roll?.rollNumber === 319)?.roll).toMatchObject({
      question: "On motion that the bill as passed by the Senate be ordered printed",
      result: "Passed",
      yea: 300,
      nay: 100,
    });
  });

  it("does not take a capitalised result word that is not followed by the tally or the roll number", () => {
    const day = parseHouseFloor(withAction("On motion to table the Ordered Business question Failed by the Yeas and Nays: 10 - 400"));
    expect(day.actions.find((a) => a.roll?.rollNumber === 319)?.roll).toMatchObject({
      question: "On motion to table the Ordered Business question",
      result: "Failed",
      yea: 10,
      nay: 400,
    });
  });
});

describe("Senate sources (real senate.gov responses, 2026-11-12)", () => {
  it("reads the next convening from floor_schedule.json", () => {
    expect(parseSenateSchedule(fixture("senate-floor-schedule-20261112.json"))).toEqual({
      convenesEastern: "2026-11-16T15:00",
      offsetMinutes: 15,
      lastUpdated: "2026-11-12T16:54-05:00",
    });
  });

  it("reads the next and previous meetings from the floor activity page", () => {
    expect(parseSenateFloorActivity(fixture("senate-floor-activity-20261112.htm"))).toEqual([
      { date: "2026-11-16", text: "Convene at 3:00 p.m.", convenedAt: null, adjournedAt: null, convenesAt: "15:00" },
      {
        date: "2026-11-12",
        text: "The Senate convened at 12:00 p.m. and adjourned at 4:52 p.m.",
        convenedAt: "12:00",
        adjournedAt: "16:52",
        convenesAt: null,
      },
    ]);
  });

  it("reads the session's votes from the vote menu, newest first", () => {
    const menu = parseSenateVoteMenu(fixture("senate-vote-menu-119-2.xml"));
    expect(menu).toMatchObject({ congress: 119, session: 2, year: 2026 });
    expect(menu.votes).toHaveLength(262);
    expect(menu.votes[0]).toEqual({
      rollNumber: 262,
      date: "2026-11-12",
      issue: "PN1181-7",
      question: "On the Cloture Motion",
      result: "Agreed to",
      yeas: 49,
      nays: 26,
      title: "Motion to Invoke Cloture: Anna St. John to be U.S. Circuit Judge for the Fifth Circuit",
    });
    expect(menu.votes.at(-1)?.rollNumber).toBe(1);
    expect(menu.votes.at(-1)?.date).toBe("2026-01-05");
  });

  it("dates January votes after December ones in the next year (a session that runs to January 3)", () => {
    const real = fixture("senate-vote-menu-119-2.xml");
    // Make the newest vote (262) a January one: it comes after November, so it is 2027's.
    const shifted = real.replace("<vote_date>12-Nov</vote_date>", "<vote_date>02-Jan</vote_date>");
    expect(shifted).not.toBe(real);
    const menu = parseSenateVoteMenu(shifted);
    expect(menu.votes[0]).toMatchObject({ rollNumber: 262, date: "2027-01-02" });
    expect(menu.votes.at(-1)).toMatchObject({ rollNumber: 1, date: "2026-01-05" });
  });

  it("refuses a floor activity page with no meeting blocks (senate.gov's 200 error page)", () => {
    const errorPage = '<html><head><meta name="description" content="404 Error Page"></head><body><table></table></body></html>';
    expect(() => parseSenateFloorActivity(errorPage)).toThrow(/no meeting blocks/);
  });
});

describe("Eastern time", () => {
  it("converts Washington wall-clock times across daylight saving", () => {
    expect(easternToDate("2026-11-10T18:20:53").toISOString()).toBe("2026-11-10T23:20:53.000Z");
    expect(easternToDate("2026-07-01T12:00").toISOString()).toBe("2026-07-01T16:00:00.000Z");
    // 2026-11-01 is the day clocks fall back at 02:00: by 03:00 Washington is on EST again.
    expect(easternToDate("2026-11-01T03:00").toISOString()).toBe("2026-11-01T08:00:00.000Z");
    expect(easternToDate("2026-11-01T00:30").toISOString()).toBe("2026-11-01T04:30:00.000Z");
    expect(easternWallClock(new Date("2026-11-10T23:20:53Z"))).toBe("2026-11-10T18:20:53");
  });

  it("names the Congress and session sitting on a date", () => {
    expect(congressSessionOn(new Date("2026-11-13T12:00:00Z"))).toEqual({ congress: 119, session: 2 });
    expect(congressSessionOn(new Date("2025-03-01T12:00:00Z"))).toEqual({ congress: 119, session: 1 });
    expect(congressSessionOn(new Date("2027-01-02T12:00:00Z"))).toEqual({ congress: 119, session: 2 });
    expect(congressSessionOn(new Date("2027-01-03T18:00:00Z"))).toEqual({ congress: 120, session: 1 });
  });

  it("strips markup and decodes numeric entities", () => {
    expect(plainText("A &#8212; <b>B</b> &amp; C&nbsp;D")).toBe("A — B & C D");
  });
});
