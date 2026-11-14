import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  addWeeks,
  houseWeeklyUrl,
  isHouseWeeklyNotFound,
  parseHouseWeekly,
  parseSenateProgram,
  parseSenateSessionDays,
  scheduleCategory,
  weekOfEastern,
} from "./schedule.js";

const fixture = (name: string) =>
  readFileSync(join(dirname(fileURLToPath(import.meta.url)), "../fixtures", name), "utf8");

describe("parseHouseWeekly (real docs.house.gov weekly schedules)", () => {
  const week = parseHouseWeekly(fixture("house-weekly-20261116.xml"));

  it("reads the week, the Congress and when the Clerk last edited it", () => {
    expect(week).toMatchObject({ weekOf: "2026-11-16", congress: 119, updatedAtEastern: "2026-11-13T17:02:23.730" });
  });

  it("lists every item with its category: 13 under suspension, 2 under a rule", () => {
    expect(week.items).toHaveLength(15);
    expect(week.items.filter((i) => i.category === "suspension")).toHaveLength(13);
    expect(week.items.filter((i) => i.category === "rule").map((i) => i.legisNum)).toEqual(["H.R. 3495", "H.R. 5267"]);
    expect(week.items[0]).toEqual({
      itemId: "409831",
      category: "suspension",
      categoryText: "Items that may be considered under suspension of the rules",
      legisNum: "H.R. 7254",
      floorText:
        "To amend the National Trails System Act to direct the Secretary of the Interior to conduct a study on the feasibility of designating the Bay Area Ridge National Scenic Trail, and for other purposes., as amended",
      addedAtEastern: "2026-11-11T10:29:14.330",
      removedAtEastern: null,
      sortOrder: 1,
    });
  });

  it("keeps a third category and a not-yet-numbered resolution as they are printed", () => {
    const earlier = parseHouseWeekly(fixture("house-weekly-20261109.xml"));
    const other = earlier.items.filter((i) => i.category === "other");
    expect(other.map((i) => i.legisNum)).toEqual(["H. Res. 1650", "H. Res. ___"]);
    expect(other[0]!.categoryText).toBe("Items that may be considered");
  });

  it("reads a remove-date", () => {
    const xml = fixture("house-weekly-20261116.xml").replace(
      'id="409832" add-date="2026-11-11T10:29:34.797" remove-date=""',
      'id="409832" add-date="2026-11-11T10:29:34.797" remove-date="2026-11-13T09:00:00.000"',
    );
    expect(parseHouseWeekly(xml).items[1]).toMatchObject({ itemId: "409832", removedAtEastern: "2026-11-13T09:00:00.000" });
  });

  it("tells the not-found page (served with HTTP 200) apart from a schedule and from garbage", () => {
    expect(isHouseWeeklyNotFound(fixture("house-weekly-not-found.html"))).toBe(true);
    expect(isHouseWeeklyNotFound(fixture("house-weekly-20261116.xml"))).toBe(false);
    expect(isHouseWeeklyNotFound("<html>502 Bad Gateway</html>")).toBe(false);
    expect(() => parseHouseWeekly("<html>502 Bad Gateway</html>")).toThrow(/Not a House floor schedule/);
  });

  it("builds the file URL from the Monday", () => {
    expect(houseWeeklyUrl("2026-11-16")).toBe(
      "https://docs.house.gov/floor/Download.aspx?file=/billsthisweek/20261116/20261116.xml",
    );
  });

  it.each([
    ["Items that may be considered under suspension of the rules", "suspension"],
    ["Items that may be considered pursuant to a rule", "rule"],
    ["Items that may be considered", "other"],
  ] as const)("files %s as %s", (text, category) => {
    expect(scheduleCategory(text)).toBe(category);
  });
});

describe("weeks in Washington", () => {
  it.each([
    ["2026-11-16T15:00:00Z", "2026-11-16"], // Monday
    ["2026-11-14T12:00:00Z", "2026-11-09"], // Saturday
    ["2026-11-16T03:00:00Z", "2026-11-09"], // Sunday 10 p.m. in Washington, Monday in UTC
    ["2026-11-22T23:59:00Z", "2026-11-16"], // Sunday evening
  ])("%s is in the week of %s", (at, monday) => {
    expect(weekOfEastern(new Date(at))).toBe(monday);
  });

  it("steps whole weeks across a month and a year", () => {
    expect(addWeeks("2026-11-30", 1)).toBe("2026-12-07");
    expect(addWeeks("2026-12-28", 1)).toBe("2027-01-04");
  });
});

describe("parseSenateSessionDays (real senate.gov floor_schedule.xml, 119th Congress, 2nd session)", () => {
  it("takes the next convening from the session day edited last", () => {
    expect(parseSenateSessionDays(fixture("senate-session-days-119-2.xml"))).toEqual({
      convenesAt: "2026-11-16T15:00:00-05:00",
      proForma: false,
      updatedAt: "2026-11-12T16:53:03-05:00",
    });
  });

  it("flags a pro forma session", () => {
    const xml = fixture("senate-session-days-119-2.xml").replace(
      "<NextConveneDate>2026-11-16T15:00:00-05:00</NextConveneDate>\n      <IsNextConveneProforma>N",
      "<NextConveneDate>2026-11-16T15:00:00-05:00</NextConveneDate>\n      <IsNextConveneProforma>Y",
    );
    expect(parseSenateSessionDays(xml)?.proForma).toBe(true);
  });

  it("refuses anything that is not the file", () => {
    expect(() => parseSenateSessionDays("<html>Page not found</html>")).toThrow(/Not a Senate session-day file/);
  });
});

describe("parseSenateProgram (real Daily Digest, Congressional Record of 2026-11-12)", () => {
  const program = parseSenateProgram(fixture("digest-next-meeting-20261112.htm"), "2026-11-12");

  it("reads the meeting date, the Digest's heading and the program text", () => {
    expect(program).toMatchObject({ date: "2026-11-16", heading: "3 p.m., Monday, November 16" });
    expect(program?.program).toMatch(/^Senate will resume consideration of the nomination of Daniel Desmond Domenico/);
    expect(program?.program).toMatch(/Act\)\.$/);
    // The House's block that follows is not part of the Senate's program.
    expect(program?.program).not.toMatch(/HOUSE|Pro Forma/);
  });

  it("names the measures the program mentions, and not an amendment number", () => {
    expect(program?.measures).toEqual(["H.R. 2347"]);
  });

  it("puts a January meeting announced in December in the next year", () => {
    const html = "<pre>Next Meeting of the SENATE\n   10 a.m., Monday, January 4\n\nProgram for Monday: Senate will consider S. 12.\n</pre>";
    expect(parseSenateProgram(html, "2026-12-30")).toMatchObject({ date: "2027-01-04", measures: ["S. 12"] });
  });

  it("reads measure spellings without mistaking U.S. for a Senate bill", () => {
    const html =
      "<pre>Next Meeting of the SENATE\n   noon, Tuesday, November 17\n\nProgram for Tuesday: Senate will vote on H.J. Res. 45, " +
      "S.Con.Res. 3 and S. Res. 900, under 5 U.S. 801.\n</pre>";
    expect(parseSenateProgram(html, "2026-11-16")?.measures).toEqual(["H.J. Res. 45", "S.Con.Res. 3", "S. Res. 900"]);
  });

  it("is null for an article with no Senate meeting", () => {
    expect(parseSenateProgram("<pre>Next Meeting of the HOUSE OF REPRESENTATIVES\n 10 a.m.</pre>", "2026-11-12")).toBeNull();
  });
});
