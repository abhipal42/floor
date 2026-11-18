import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { describe, expect, it } from "vitest";
import type { Db } from "./db.js";
import { checkPoll, loadPolls, readPolls } from "./polls.js";

const dir = new URL("../polls/", import.meta.url).pathname;

const good = {
  members: ["S000148"],
  pollster: "NBC News",
  fieldedFrom: "2026-10-28",
  fieldedTo: "2026-10-30",
  population: "registered voters",
  sampleSize: 1000,
  positive: { label: "positive", pct: 13 },
  negative: { label: "negative", pct: 53 },
  other: { label: "neutral or unsure", pct: 34 },
  url: "https://www.nbcnews.com/x",
};

describe("the poll files", () => {
  it("are the three real Schumer polls, each valid", () => {
    const polls = readPolls(dir);
    expect(polls.map((p) => [p.id, p.pollster, p.positive.pct, p.negative.pct, p.other?.pct ?? null])).toEqual([
      ["2026-10-nbc-news-schumer", "NBC News", 13, 53, 34],
      ["2026-11-data-for-progress-schumer-leader", "Data for Progress", 32, 56, null],
      ["2026-11-economist-yougov-schumer", "Economist/YouGov", 22, 50, 28],
    ]);
    expect(polls.every((p) => p.members.join() === "S000148" && p.url.startsWith("https://"))).toBe(true);
  });
});

describe("checkPoll", () => {
  it("accepts a whole file", () => {
    expect(checkPoll(good, "a-poll.json")).toMatchObject({ id: "a-poll", sampleSize: 1000 });
  });

  it("refuses a file without a url, with shares past 100, or with an unknown field", () => {
    expect(() => checkPoll({ ...good, url: undefined }, "a.json")).toThrow(/url/);
    expect(() => checkPoll({ ...good, url: "http://x" }, "a.json")).toThrow(/url/);
    expect(() => checkPoll({ ...good, other: { label: "rest", pct: 35 } }, "a.json")).toThrow(/more than 100/);
    expect(() => checkPoll({ ...good, margin: 3 }, "a.json")).toThrow(/unknown field/);
  });

  it("refuses bad members, dates, sample sizes and names", () => {
    expect(() => checkPoll({ ...good, members: ["schumer"] }, "a.json")).toThrow(/Bioguide/);
    expect(() => checkPoll({ ...good, fieldedFrom: "2026-11-01" }, "a.json")).toThrow(/in order/);
    expect(() => checkPoll({ ...good, sampleSize: 0 }, "a.json")).toThrow(/sampleSize/);
    expect(() => checkPoll({ ...good, positive: { label: "", pct: 1 } }, "a.json")).toThrow(/positive/);
    expect(() => checkPoll(good, "Bad Name.json")).toThrow(/file name/);
  });
});

describe("loadPolls", () => {
  it("is idempotent, replaces members, deletes polls whose file is gone, and skips unknown members", async () => {
    const pg = new PGlite();
    await pg.exec(`create schema auth; create table auth.users (id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;`);
    for (const m of loadMigrations()) await pg.exec(m.sql);
    await pg.exec(`insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end)
      values ('S000148', 'Chuck', 'Schumer', 'D', 'NY', null, 'senate', '2023-01-03', '2099-01-03')`);
    const db = pg as unknown as Db;
    const polls = readPolls(dir);
    expect(await loadPolls(db, polls)).toEqual({ polls: 3, unknownMembers: [] });
    expect(await loadPolls(db, polls)).toEqual({ polls: 3, unknownMembers: [] });
    const count = async () =>
      (await pg.query<{ p: number; m: number }>("select (select count(*)::int from polls) as p, (select count(*)::int from poll_members) as m")).rows[0];
    expect(await count()).toEqual({ p: 3, m: 3 });
    const { rows } = await pg.query("select other_label, other_pct from polls where id = '2026-11-data-for-progress-schumer-leader'");
    expect(rows).toEqual([{ other_label: null, other_pct: null }]);

    const one = checkPoll({ ...good, members: ["S000148", "G000555"] }, "2026-10-nbc-news-schumer.json");
    expect(await loadPolls(db, [one])).toEqual({ polls: 1, unknownMembers: ["G000555"] });
    expect(await count()).toEqual({ p: 1, m: 1 });
  });
});
