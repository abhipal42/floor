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
      ('H000011', 'Rep', 'Second',  'R', 'TX', 11, 'house',  '2025-01-03', '2099-01-03'),
      ('H000038', 'Rep', 'Ally',    'D', 'TX', 38, 'house',  '2025-01-03', '2099-01-03'),
      ('H000040', 'Rep', 'Third',   'D', 'TX', 40, 'house',  '2025-01-03', '2099-01-03'),
      ('H000041', 'Rep', 'Fourth',  'D', 'TX', 41, 'house',  '2025-01-03', '2099-01-03'),
      ('H000042', 'Rep', 'Fifth',   'D', 'TX', 42, 'house',  '2025-01-03', '2099-01-03'),
      ('H000050', 'Rep', 'Lone',    'I', 'TX', 50, 'house',  '2025-01-03', '2099-01-03'),
      ('S000001', 'Sen', 'Bravo',   'R', 'TX', null, 'senate', '2025-01-03', '2099-01-03'),
      ('S000002', 'Sen', 'Alpha',   'R', 'TX', null, 'senate', '2025-01-03', '2099-01-03'),
      ('S000003', 'Sen', 'Elsewhere', 'D', 'WA', null, 'senate', '2025-01-03', '2099-01-03');
    insert into votes (id, chamber, congress, session, roll_number, question, state, yea, nay, not_voting, result, bill_ref, occurred_at) values
      ('house-119-1-1', 'house', 119, 1, 1, 'On Passage', 'final', 219, 208, 8, 'Passed', 'H R 1', '2025-01-10T15:00:00Z'),
      ('house-119-1-2', 'house', 119, 1, 2, 'On Motion to Recommit', 'final', 200, 225, 10, 'Failed', null, '2025-01-11T15:00:00Z'),
      ('house-119-1-3', 'house', 119, 1, 3, 'On Passage', 'final', 210, 215, 10, 'Failed', null, '2025-01-12T15:00:00Z'),
      ('senate-119-1-90', 'senate', 119, 1, 90, 'On the Nomination', 'final', 66, 28, 6, 'Nomination Confirmed', 'PN12-12', '2025-02-25T16:15:00Z');
    insert into votes (id, chamber, congress, session, roll_number, question, state, kind, candidates, result, occurred_at)
      values ('house-119-1-4', 'house', 119, 1, 4, 'Election of the Speaker', 'final', 'election',
              '[{"name":"Johnson","total":2},{"name":"Jeffries","total":2}]', 'Johnson elected', '2025-01-13T15:00:00Z');
    insert into bills (id, congress, bill_type, number, title, short_title, sponsor_id, introduced_on, origin_chamber,
                       policy_area, summary, summary_stage, latest_action_on, latest_action_text, cbo_estimates)
      values ('119-hr-1', 119, 'hr', 1, 'To provide for reconciliation', 'Example Act', 'H000037', '2025-01-05', 'house',
              'Taxation', 'This bill does things.', 'Introduced in House', '2025-01-10', 'Passed House.',
              '[{"title":"CBO estimate","url":"https://www.cbo.gov/publication/1","pubDate":"2025-01-08T00:00:00Z"}]');
    insert into actions (bill_id, acted_on, chamber, text) values
      ('119-hr-1', '2025-01-05', 'house', 'Introduced in House'),
      ('119-hr-1', '2025-01-10', 'house', 'Passed House.');
    insert into nominations (id, congress, number, part, citation, nominee_name, position_title, organization,
                             description, nominee_count, is_military, received_on, latest_action_on, latest_action_text)
      values ('119-pn-12-12', 119, 12, 12, 'PN12-12', 'Daniel Driscoll', 'Secretary of the Army', 'Department of Defense',
              'Daniel Driscoll, of North Carolina, to be Secretary of the Army, vice Christine Elizabeth Wormuth, resigned.',
              1, false, '2025-01-20', '2025-02-25', 'Confirmed by the Senate by Yea-Nay Vote. 66 - 28.');
    update votes set bill_id = '119-hr-1' where id = 'house-119-1-1';
    update votes set nomination_id = '119-pn-12-12' where id = 'senate-119-1-90';
    -- Five Democrats vote each time, so the bloc is big enough for a majority to mean something.
    -- Hand-checkable majorities for H000037 (D):
    --   vote 1: D votes yea 5-0, they voted yea  -> with party
    --   vote 2: D votes yea 4-1, they voted nay  -> against party
    --   vote 3: D votes nay 3-2, they voted nay  -> with party
    -- H000050 (I) votes on all three, but is the only member of their party, so they are not scored.
    insert into vote_positions (vote_id, member_id, position) values
      ('house-119-1-1', 'H000037', 'yea'),
      ('house-119-1-1', 'H000038', 'yea'),
      ('house-119-1-1', 'H000040', 'yea'),
      ('house-119-1-1', 'H000041', 'yea'),
      ('house-119-1-1', 'H000042', 'yea'),
      ('house-119-1-1', 'H000010', 'nay'),
      ('house-119-1-1', 'H000011', 'nay'),
      ('house-119-1-1', 'H000050', 'yea'),
      ('house-119-1-2', 'H000037', 'nay'),
      ('house-119-1-2', 'H000038', 'yea'),
      ('house-119-1-2', 'H000040', 'yea'),
      ('house-119-1-2', 'H000041', 'yea'),
      ('house-119-1-2', 'H000042', 'yea'),
      ('house-119-1-2', 'H000050', 'nay'),
      ('house-119-1-3', 'H000037', 'nay'),
      ('house-119-1-3', 'H000038', 'nay'),
      ('house-119-1-3', 'H000041', 'nay'),
      ('house-119-1-3', 'H000040', 'yea'),
      ('house-119-1-3', 'H000042', 'yea'),
      ('house-119-1-3', 'H000050', 'nay');
    insert into vote_positions (vote_id, member_id, position, choice) values
      ('house-119-1-4', 'H000038', 'candidate', 'Jeffries'),
      ('house-119-1-4', 'H000040', 'candidate', 'Jeffries'),
      ('house-119-1-4', 'H000010', 'candidate', 'Johnson'),
      ('house-119-1-4', 'H000011', 'candidate', 'Johnson');
    insert into ingest_runs (source, started_at, finished_at, items, error) values
      ('members', '2025-01-01T00:00:00Z', '2025-01-01T00:01:00Z', 700, null),
      ('house_rollcalls', '2025-01-02T00:00:00Z', '2025-01-02T00:05:00Z', 10, null),
      ('house_rollcalls', '2025-01-03T00:00:00Z', '2025-01-03T00:00:05Z', 0, 'HTTP 503'),
      ('house_rollcalls', '2025-01-03T01:00:00Z', null, 0, null);
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
      kind: "question",
      candidates: [],
      chamber: "house",
      congress: 119,
      session: 1,
      rollNumber: 1,
      question: "On Passage",
      billId: "119-hr-1",
      nominationId: null,
      billRef: "H R 1",
      occurredAt: "2025-01-10T15:00:00.000Z",
      state: "final",
      threshold: "majority",
      totals: { yea: 219, nay: 208, present: 0, notVoting: 8 },
      result: "Passed",
    });
    expect(await repos.votes.getVote("house-119-1-999")).toBeNull();
  });

  it("reads a bill with its sponsor, actions newest first, and votes", async () => {
    const bill = await repos.bills.getBill("119-hr-1");
    expect(bill).toMatchObject({
      id: "119-hr-1",
      type: "hr",
      shortTitle: "Example Act",
      sponsor: { bioguideId: "H000037", lastName: "Current", chamber: "house" },
      introducedOn: "2025-01-05",
      latestAction: { on: "2025-01-10", text: "Passed House." },
      cboEstimates: [{ title: "CBO estimate", url: "https://www.cbo.gov/publication/1" }],
      actions: [
        { actedOn: "2025-01-10", chamber: "house", text: "Passed House." },
        { actedOn: "2025-01-05", chamber: "house", text: "Introduced in House" },
      ],
    });
    expect(bill?.votes.map((v) => v.id)).toEqual(["house-119-1-1"]);
    expect(await repos.bills.getBill("119-hr-999")).toBeNull();
  });

  it("reads a nomination with its nominee, position and votes", async () => {
    const nomination = await repos.nominations.getNomination("119-pn-12-12");
    expect(nomination).toMatchObject({
      id: "119-pn-12-12",
      congress: 119,
      number: 12,
      part: 12,
      citation: "PN12-12",
      nomineeName: "Daniel Driscoll",
      positionTitle: "Secretary of the Army",
      organization: "Department of Defense",
      nomineeCount: 1,
      isMilitary: false,
      receivedOn: "2025-01-20",
      latestAction: { on: "2025-02-25", text: "Confirmed by the Senate by Yea-Nay Vote. 66 - 28." },
    });
    expect(nomination?.votes.map((v) => v.id)).toEqual(["senate-119-1-90"]);
    expect(nomination?.votes[0]?.nominationId).toBe("119-pn-12-12");
    expect(await repos.nominations.getNomination("119-pn-9999")).toBeNull();
  });

  it("reports the last successful run and the latest error per source", async () => {
    const runs = (await repos.status.lastRuns()).sort((a, b) => a.source.localeCompare(b.source));
    expect(runs).toEqual([
      { source: "house_rollcalls", lastSuccessAt: new Date("2025-01-02T00:05:00Z"), lastError: "HTTP 503" },
      { source: "members", lastSuccessAt: new Date("2025-01-01T00:01:00Z"), lastError: null },
    ]);
  });

  it("lists a member's votes newest first with their position", async () => {
    const votes = await repos.members.recentVotes("H000037", 10);
    expect(votes.map((v) => [v.vote.id, v.position])).toEqual([
      ["house-119-1-3", "nay"],
      ["house-119-1-2", "nay"],
      ["house-119-1-1", "yea"],
    ]);
    expect(await repos.members.recentVotes("H000037", 1)).toHaveLength(1);
  });

  it("breaks a question vote down by party, largest party first", async () => {
    const { partyTotals, candidateTotals } = await repos.votes.voteBreakdown("house-119-1-1", []);
    expect(partyTotals).toEqual([
      { party: "D", yea: 5, nay: 0, present: 0, notVoting: 0 },
      { party: "R", yea: 0, nay: 2, present: 0, notVoting: 0 },
      { party: "I", yea: 1, nay: 0, present: 0, notVoting: 0 },
    ]);
    expect(candidateTotals).toEqual([]);
  });

  it("breaks a Speaker election down by party and candidate instead of yea/nay", async () => {
    const { partyTotals, candidateTotals } = await repos.votes.voteBreakdown("house-119-1-4", []);
    expect(partyTotals).toEqual([]);
    expect(candidateTotals).toEqual([
      { party: "D", candidate: "Jeffries", total: 2 },
      { party: "R", candidate: "Johnson", total: 2 },
    ]);
  });

  it("returns only the named members' positions, and nothing when none are named", async () => {
    const asked = await repos.votes.voteBreakdown("house-119-1-1", ["H000037", "H000010"]);
    expect(asked.positions.map((p) => [p.member.bioguideId, p.position])).toEqual([
      ["H000037", "yea"],
      ["H000010", "nay"],
    ]);
    expect(asked.positions[0]?.member.lastName).toBe("Current");
    // A senator has no position on a House vote, so asking for one returns nothing for them.
    const mixed = await repos.votes.voteBreakdown("house-119-1-1", ["H000037", "S000001"]);
    expect(mixed.positions.map((p) => p.member.bioguideId)).toEqual(["H000037"]);
    expect((await repos.votes.voteBreakdown("house-119-1-1", [])).positions).toEqual([]);
  });

  it("counts votes with and against a member's own party, skipping votes where the party tied", async () => {
    expect(await repos.members.partyLoyalty("H000037", "D")).toEqual({ votes: 3, withParty: 2, againstParty: 1 });
    // H000038 sided with the Democratic majority all three times. Their candidate vote in the Speaker
    // election is excluded: a candidate vote has no party majority to side with.
    expect(await repos.members.partyLoyalty("H000038", "D")).toEqual({ votes: 3, withParty: 3, againstParty: 0 });
    // A member with no recorded positions has nothing to count, rather than erroring.
    expect(await repos.members.partyLoyalty("S000003", "D")).toEqual({ votes: 0, withParty: 0, againstParty: 0 });
    // H000050 voted on all three, but is their party's only member: there is no majority to side with,
    // so they score no votes at all rather than a meaningless 100%.
    expect(await repos.members.partyLoyalty("H000050", "I")).toEqual({ votes: 0, withParty: 0, againstParty: 0 });
  });

  it("reads one member by Bioguide ID", async () => {
    expect(await repos.members.getMember("H000037")).toMatchObject({ bioguideId: "H000037", party: "D", district: 37 });
    expect(await repos.members.getMember("X000000")).toBeNull();
  });
});
