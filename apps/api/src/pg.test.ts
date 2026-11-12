import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { beforeAll, describe, expect, it } from "vitest";
import { pgRepositories, type Db } from "./pg.js";

let repos: ReturnType<typeof pgRepositories>;

beforeAll(async () => {
  const pg = new PGlite();
  await pg.exec(`
    create schema auth;
    create table auth.users (id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
  `);
  for (const m of loadMigrations()) await pg.exec(m.sql);
  await pg.exec(`
    insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end) values
      ('H000037', 'Rep', 'Current', 'D', 'TX', 37, 'house',  '2025-01-03', '2099-01-03'),
      ('H000099', 'Rep', 'Former',  'D', 'TX', 37, 'house',  '2023-01-03', '2025-01-03'),
      ('H000010', 'Rep', 'Other',   'R', 'TX', 10, 'house',  '2025-01-03', '2099-01-03'),
      ('S000001', 'Sen', 'Bravo',   'R', 'TX', null, 'senate', '2025-01-03', '2099-01-03'),
      ('S000002', 'Sen', 'Alpha',   'R', 'TX', null, 'senate', '2025-01-03', '2099-01-03'),
      ('S000003', 'Sen', 'Elsewhere', 'D', 'WA', null, 'senate', '2025-01-03', '2099-01-03');
    insert into votes (id, chamber, congress, session, roll_number, question, state, yea, nay, not_voting, result, bill_ref, occurred_at) values
      ('house-119-1-1', 'house', 119, 1, 1, 'On Passage', 'final', 219, 208, 8, 'Passed', 'H R 1', '2025-01-10T15:00:00Z'),
      ('house-119-1-2', 'house', 119, 1, 2, 'On Motion to Recommit', 'final', 200, 225, 10, 'Failed', null, '2025-01-11T15:00:00Z');
    insert into vote_positions values
      ('house-119-1-1', 'H000037', 'yea'),
      ('house-119-1-2', 'H000037', 'nay');
  `);
  repos = pgRepositories(pg as unknown as Db);
});

describe("Postgres repositories", () => {
  it("returns the current House member and both senators for a district", async () => {
    const members = await repos.members.membersFor("TX", 37);
    expect(members.map((m) => m.bioguideId)).toEqual(["H000037", "S000002", "S000001"]);
  });

  it("reads a vote with its totals and timestamp", async () => {
    expect(await repos.votes.getVote("house-119-1-1")).toEqual({
      id: "house-119-1-1",
      chamber: "house",
      congress: 119,
      session: 1,
      rollNumber: 1,
      question: "On Passage",
      billId: null,
      billRef: "H R 1",
      occurredAt: "2025-01-10T15:00:00.000Z",
      state: "final",
      threshold: "majority",
      totals: { yea: 219, nay: 208, present: 0, notVoting: 8 },
      result: "Passed",
    });
    expect(await repos.votes.getVote("house-119-1-999")).toBeNull();
  });

  it("lists a member's votes newest first with their position", async () => {
    const votes = await repos.members.recentVotes("H000037", 10);
    expect(votes.map((v) => [v.vote.id, v.position])).toEqual([
      ["house-119-1-2", "nay"],
      ["house-119-1-1", "yea"],
    ]);
    expect(await repos.members.recentVotes("H000037", 1)).toHaveLength(1);
  });
});
