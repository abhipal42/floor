import { createHash } from "node:crypto";
import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { beforeAll, describe, expect, it } from "vitest";
import { pgRepositories, poolerMode, poolerWarning, type Db } from "./pg.js";
import { DEVICE_SIGNUPS_PER_DAY } from "./app.js";
import { parseMemberQuery } from "./search.js";

describe("poolerMode", () => {
  // Shapes only: the hosts are Supabase's, the credentials are placeholders.
  it("tells the transaction pooler from the session pooler by port", () => {
    expect(poolerMode("postgresql://postgres.ref:pw@aws-1-us-east-1.pooler.supabase.com:6543/postgres")).toBe("transaction");
    expect(poolerMode("postgresql://postgres.ref:pw@aws-1-us-east-1.pooler.supabase.com:5432/postgres")).toBe("session");
    expect(poolerMode("postgresql://postgres.ref:pw@aws-1-us-east-1.pooler.supabase.com/postgres")).toBe("session");
  });

  it("recognizes the direct host and anything else", () => {
    expect(poolerMode("postgresql://postgres:pw@db.ref.supabase.co:5432/postgres")).toBe("direct");
    expect(poolerMode("postgresql://localhost:5432/floor")).toBe("unknown");
    expect(poolerMode("not a url")).toBe("unknown");
  });

  it("reads port 6543 as the transaction pooler whatever the host", () => {
    expect(poolerMode("postgresql://postgres.ref:pw@db.example.com:6543/postgres")).toBe("transaction");
    expect(poolerMode("postgresql://postgres.ref:pw@aws-0-eu-west-2.pooler.supabase.com:6543/postgres")).toBe("transaction");
  });

  it("warns, in English, about anything but the transaction pooler", () => {
    expect(poolerWarning("postgresql://postgres.ref:pw@aws-1-us-east-1.pooler.supabase.com:6543/postgres")).toBeNull();
    expect(poolerWarning("postgresql://postgres.ref:pw@aws-1-us-east-1.pooler.supabase.com:5432/postgres")).toBe(
      "DATABASE_URL is a session connection; use Supabase's transaction pooler (port 6543)",
    );
    expect(poolerWarning("postgresql://localhost:5432/floor")).toBe(
      "DATABASE_URL is an unknown connection; use Supabase's transaction pooler (port 6543)",
    );
  });
});

let repos: ReturnType<typeof pgRepositories>;
let pg: PGlite;

beforeAll(async () => {
  pg = new PGlite();
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
    insert into votes (id, chamber, congress, session, roll_number, question, state, yea, nay, result, bill_ref, occurred_at)
      values ('senate-119-1-91', 'senate', 119, 1, 91, 'On the Nomination', 'final', 80, 10, 'Confirmed', 'PN900', '2025-02-26T16:15:00Z');
    insert into nominations (id, congress, number, part, citation, nominee_name, position_title, organization,
                             description, nominee_count, is_military, received_on, latest_action_on, latest_action_text)
      values ('119-pn-900', 119, 900, 0, 'PN900', null, 'General', 'Army', null, 1, true, '2025-01-05', '2025-02-26', 'Confirmed.');
    update votes set nomination_id = '119-pn-900' where id = 'senate-119-1-91';
    update votes set bill_id = '119-hr-1' where id = 'house-119-1-1';
    update votes set nomination_id = '119-pn-12-12' where id = 'senate-119-1-90';

    -- Campaign finance. H000010 deliberately has no row: FEC has no current-campaign totals for
    -- some members, and the route must say so rather than invent zeroes.
    insert into campaign_finance (member_id, fec_candidate_id, cycle, coverage_start, coverage_end, receipts,
                                  individual_unitemized, individual_itemized, pac, party, other, cash_on_hand) values
      ('H000037', 'H0TX37001', 2026, '2025-01-01', '2026-10-14', 2412880.50, 402118, 1204902, 611500, 5000, 189360, 884398),
      ('H000011', 'H0TX11001', 2026, '2025-01-01', '2026-10-14', 500000, 100000, 200000, 150000, 0, 50000, null),
      ('H000040', 'H0TX40001', 2026, '2025-01-01', '2026-10-14', 100000, 10000, 20000, 60000, 0, 10000, 5000),
      -- A senator elected in 2022: their campaign is for 2028, but the committee filings we hold
      -- are the 2026 cycle. The two columns are not the same thing (lesson 33).
      ('S000001', 'S0TX00001', 2028, '2023-01-01', '2026-10-14', 900000, 100000, 300000, 400000, 0, 100000, 250000);
    -- Direct and earmarked are different money, so the order is by direct alone: Small Company PAC
    -- passed through far more than it gave and still comes last.
    insert into pac_contributions (member_id, cycle, committee_id, committee_name, committee_designation,
                                   committee_type, org_type, connected_org, direct_amount, earmarked_amount) values
      ('H000037', 2026, 'C00000001', 'Big Trade PAC',      'U', 'Q', 'T',  'Big Trade Association', 15000, 0),
      ('H000037', 2026, 'C00000002', 'Midsize Union PAC',  'U', 'Q', 'L',  'Midsize Union',          7500, 1200),
      ('H000037', 2026, 'C00000003', 'Small Company PAC',  'U', 'Q', 'C',  'Small Company Inc',      2500, 48000),
      -- Excluded by the PAC rule, though both gave more than any of the above.
      ('H000037', 2026, 'C00000004', 'State Party Committee', 'U', 'X', null, null,                 40000, 0),
      ('H000037', 2026, 'C00000005', 'Joint Fundraising Cmte', 'J', 'N', null, null,               250000, 0),
      -- A different cycle entirely; the totals above cover 2026.
      ('H000037', 2024, 'C00000006', 'Old Cycle PAC',      'U', 'Q', 'T',  'Old Trade Group',       99000, 0),
      -- FEC classifies neither of these by organization; one is a leadership PAC by designation,
      -- the other is nothing at all and must come back without a label.
      ('H000011', 2026, 'C00000007', 'A Leadership PAC',   'D', 'Q', null, null,                     5000, 0),
      ('H000011', 2026, 'C00000008', 'Unclassified PAC',   'U', 'Q', null, null,                     1000, 0),
      -- Another candidate's own campaign committee (CMTE_TP H): labelled as such, not as a PAC.
      ('H000011', 2026, 'C00000010', 'SMITH FOR CONGRESS', 'P', 'H', null, null,                     2000, 0),
      ('S000001', 2026, 'C00000009', 'Senate Giver PAC',   'U', 'Q', 'T',  'Some Trade Group',      9000, 0);
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
    insert into vote_positions (vote_id, member_id, position) values
      ('senate-119-1-90', 'S000001', 'yea'),
      ('senate-119-1-91', 'S000001', 'yea');
    insert into ingest_runs (source, started_at, finished_at, items, error) values
      ('members', '2025-01-01T00:00:00Z', '2025-01-01T00:01:00Z', 700, null),
      ('house_rollcalls', '2025-01-02T00:00:00Z', '2025-01-02T00:05:00Z', 10, null),
      ('house_rollcalls', '2025-01-03T00:00:00Z', '2025-01-03T00:00:05Z', 0, 'HTTP 503'),
      ('house_rollcalls', '2025-01-03T01:00:00Z', null, 0, null),
      ('senate_rollcalls', '2025-01-02T00:00:00Z', '2025-01-02T00:01:00Z', 5, 'deadlock detected'),
      ('senate_rollcalls', '2025-01-02T00:02:00Z', '2025-01-02T00:03:00Z', 9, null),
      ('bills', '2025-01-01T00:00:00Z', '2025-01-01T00:02:00Z', 4, null),
      ('bills', '2025-01-02T00:00:00Z', '2025-01-02T00:00:01Z', 0, null),
      ('nominations', '2025-01-01T00:00:00Z', '2025-01-01T00:10:00Z', 3, null),
      ('nominations', now(), null, 0, null);
  `);
  repos = pgRepositories(pg as unknown as Db);
});

/** Narrows an optional lookup in a test, failing loudly rather than silently skipping. */
function try0<T>(value: T | undefined): T {
  if (value === undefined) throw new Error("expected a row, found none");
  return value;
}

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
    // The label a bill list would give it, and its stage (unstaged here: null, not an error).
    expect(bill?.label).toBe("Example Act");
    expect(bill?.stage).toBeNull();
    expect(await repos.bills.getBill("119-hr-999")).toBeNull();
  });

  it("reads the analysis of a bill's current summary, and says when the summary has moved on", async () => {
    expect(await repos.bills.getAnalysis("119-hr-1")).toBeNull();
    const stored = {
      purpose: { text: "The bill does things.", citations: [{ paragraph: 1, quote: "This bill does things.", section: null }] },
      provisions: [{ text: "Section 2 does a thing.", citations: [{ paragraph: 1, quote: "This bill does things.", section: "Sec. 2" }] }],
      affectedGroups: [],
      impact: [],
      sourceParagraphs: ["This bill does things."],
    };
    // Hash as the worker computes it: sha256(stage || '\n' || summary).
    const hash = createHash("sha256").update("Introduced in House\nThis bill does things.").digest("hex");
    await pg.query(
      `insert into bill_analyses (bill_id, source_stage, source_hash, prompt_version, analysis, model, verifier_model, generated_at)
       values ('119-hr-1', 'Older stage', 'x', 'bill-analysis/1', $1, 'claude-sonnet-5-5', null, '2026-11-14T00:00:00Z'),
              ('119-hr-1', 'Introduced in House', $2, 'bill-analysis/1', $1, 'claude-sonnet-5-5', 'claude-sonnet-5-5', '2026-11-13T00:00:00Z')`,
      [JSON.stringify(stored), hash],
    );
    const a = await repos.bills.getAnalysis("119-hr-1");
    expect(a).toMatchObject({
      billId: "119-hr-1",
      ai: true,
      label: "AI-generated",
      source: { kind: "crs_summary", stage: "Introduced in House", paragraphs: ["This bill does things."], stale: false },
      verifierModel: "claude-sonnet-5-5",
      promptVersion: "bill-analysis/1",
      generatedAt: "2026-11-13T00:00:00.000Z",
      purpose: { ai: true, text: "The bill does things." },
      provisions: [{ ai: true, citations: [{ paragraph: 1, section: "Sec. 2" }] }],
    });
    expect(a?.disclaimer).toMatch(/may contain errors/);

    await pg.query("update bills set summary = 'This bill does more things.' where id = '119-hr-1'");
    expect((await repos.bills.getAnalysis("119-hr-1"))?.source.stale).toBe(true);
    await pg.query("update bills set summary = 'This bill does things.' where id = '119-hr-1'");
    await pg.query("delete from bill_analyses");
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

  it("leaves open votes off bill and nomination pages: their tallies are the floor's, not the roll call's", async () => {
    await pg.exec(`
      insert into votes (id, chamber, congress, session, roll_number, question, state, yea, nay, bill_id, nomination_id, occurred_at)
      values ('house-119-1-500', 'house', 119, 1, 500, 'On passage', 'open', 0, 0, '119-hr-1', null, '2026-01-01T00:00:00Z'),
             ('senate-119-1-500', 'senate', 119, 1, 500, 'On the Nomination', 'open', 0, 0, null, '119-pn-12-12', '2026-01-01T00:00:00Z');
    `);
    try {
      // Without the filter each would come first: occurred_at is newer than every final vote's.
      expect((await repos.bills.getBill("119-hr-1"))?.votes.map((v) => v.id)).toEqual(["house-119-1-1"]);
      expect((await repos.nominations.getNomination("119-pn-12-12"))?.votes.map((v) => v.id)).toEqual(["senate-119-1-90"]);
    } finally {
      await pg.exec("delete from votes where id in ('house-119-1-500', 'senate-119-1-500')");
    }
  });

  it("reports the last successful run, the last that stored anything, and the latest outcome's error", async () => {
    const runs = (await repos.status.lastRuns()).sort((a, b) => a.source.localeCompare(b.source));
    expect(runs).toEqual([
      // A run that stored nothing still counts as a success, but not as new data.
      {
        source: "bills",
        lastSuccessAt: new Date("2025-01-02T00:00:01Z"),
        lastNewDataAt: new Date("2025-01-01T00:02:00Z"),
        lastError: null,
      },
      // The run started 2025-01-03 01:00 never recorded an outcome and is long past the hour, so it
      // counts as failed. It came after the HTTP 503, so it is the error that stands.
      {
        source: "house_rollcalls",
        lastSuccessAt: new Date("2025-01-02T00:05:00Z"),
        lastNewDataAt: new Date("2025-01-02T00:05:00Z"),
        lastError: "abandoned run: it never recorded an outcome",
      },
      {
        source: "members",
        lastSuccessAt: new Date("2025-01-01T00:01:00Z"),
        lastNewDataAt: new Date("2025-01-01T00:01:00Z"),
        lastError: null,
      },
      // A run that started just now is in progress, not failed.
      {
        source: "nominations",
        lastSuccessAt: new Date("2025-01-01T00:10:00Z"),
        lastNewDataAt: new Date("2025-01-01T00:10:00Z"),
        lastError: null,
      },
      // A run that succeeded after the failure clears it: the error is history, not the current state.
      {
        source: "senate_rollcalls",
        lastSuccessAt: new Date("2025-01-02T00:03:00Z"),
        lastNewDataAt: new Date("2025-01-02T00:03:00Z"),
        lastError: null,
      },
    ]);
  });

  it("lets a finished success after an abandoned run clear it", async () => {
    await pg.exec(
      "insert into ingest_runs (source, started_at, finished_at, items, error) " +
        "values ('house_rollcalls', '2025-01-04T00:00:00Z', '2025-01-04T00:01:00Z', 2, null)",
    );
    const house = (await repos.status.lastRuns()).find((r) => r.source === "house_rollcalls");
    expect(house?.lastError).toBeNull();
    await pg.exec("delete from ingest_runs where started_at = '2025-01-04T00:00:00Z'");
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

  it("names the measure on each row of a member's record, so a feed needs no extra request", async () => {
    const votes = await repos.members.recentVotes("H000037", 10);
    const onTheBill = try0(votes.find((v) => v.vote.id === "house-119-1-1"));
    expect(onTheBill.measure).toEqual({
      id: "119-hr-1",
      kind: "bill",
      citation: "H.R. 1",
      // The short title, since this bill has one; otherwise the full title.
      title: "Example Act",
      // Its topic, so the Following feed can say a vote is in one you follow.
      policyArea: "Taxation",
    });
    // A procedural vote refers to no measure at all.
    expect(try0(votes.find((v) => v.vote.id === "house-119-1-2")).measure).toBeNull();
  });

  it("names what the vote screen's vote was on, so it needs no second request", async () => {
    const onABill = await repos.votes.voteBreakdown("house-119-1-1", []);
    expect(onABill.measure).toEqual({
      id: "119-hr-1",
      kind: "bill",
      citation: "H.R. 1",
      title: "Example Act",
      policyArea: "Taxation",
    });
    // The same builder as the feed, so the two can never describe one measure differently.
    const inTheFeed = (await repos.members.recentVotes("H000037", 10))
      .find((v) => v.vote.id === "house-119-1-1")?.measure;
    expect(inTheFeed).toEqual(onABill.measure);
    // A procedural vote refers to nothing.
    expect((await repos.votes.voteBreakdown("house-119-1-2", [])).measure).toBeNull();
  });

  it("names a nomination by its nominee, or by the post when it names nobody", async () => {
    const votes = await repos.members.recentVotes("S000001", 10);
    expect(try0(votes.find((v) => v.vote.id === "senate-119-1-90")).measure).toEqual({
      id: "119-pn-12-12",
      kind: "nomination",
      citation: "PN12-12",
      title: "Daniel Driscoll",
      policyArea: null,
    });
    // Military nominations promote officers in bulk and carry no name.
    expect(try0(votes.find((v) => v.vote.id === "senate-119-1-91")).measure).toEqual({
      id: "119-pn-900",
      kind: "nomination",
      citation: "PN900",
      title: "General, Army",
      policyArea: null,
    });
  });

  it("cites a bill the way its chamber does", async () => {
    expect((await repos.bills.getBill("119-hr-1"))?.citation).toBe("H.R. 1");
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

  describe("funding", () => {
    it("reads a campaign's totals, with the figures as numbers rather than numeric strings", async () => {
      const f = await repos.members.funding("H000037", 10);
      expect(f).toMatchObject({
        cycle: 2026,
        coverageStart: "2025-01-01",
        coverageEnd: "2026-10-14",
        receipts: 2412880.5,
        smallDollar: 402118,
        itemized: 1204902,
        pac: 611500,
        party: 5000,
        other: 189360,
        cashOnHand: 884398,
      });
      // numeric columns come back as strings from node-postgres; a client doing arithmetic on
      // "2412880.50" would concatenate instead of adding.
      for (const k of ["receipts", "smallDollar", "pac", "cashOnHand"] as const) expect(typeof f![k]).toBe("number");
    });

    it("returns null for a member FEC has no totals for, rather than an empty shell", async () => {
      expect(await repos.members.funding("H000010", 10)).toBeNull();
    });

    it("lists the biggest direct givers first and keeps earmarked money apart from direct", async () => {
      const f = await repos.members.funding("H000037", 10);
      expect(f!.committees.map((c) => c.name)).toEqual(["Big Trade PAC", "Midsize Union PAC", "Small Company PAC"]);
      // Pass-through money is not the committee's own check: a committee can be third by its own
      // giving while passing through the most (lesson 23).
      expect(f!.committees.find((c) => c.name === "Small Company PAC")).toMatchObject({ direct: 2500, earmarked: 48000 });
    });

    it("labels a committee from FEC's own classification, and leaves it null when FEC says nothing", async () => {
      const f = await repos.members.funding("H000037", 10);
      const kinds = Object.fromEntries(f!.committees.map((c) => [c.name, c.kind]));
      expect(kinds).toEqual({ "Big Trade PAC": "Trade group", "Midsize Union PAC": "Union", "Small Company PAC": "Company" });
      // An unclassified committee is shown without a label rather than guessed into a category.
      // A candidate's committee is labelled from its committee type, which FEC fills where ORG_TP is empty.
      expect((await repos.members.funding("H000011", 10))!.committees.map((c) => c.kind)).toEqual([
        "Leadership PAC",
        "Candidate committee",
        null,
      ]);
    });

    it("caps the list at the limit it was given", async () => {
      expect((await repos.members.funding("H000037", 2))!.committees).toHaveLength(2);
      expect((await repos.members.funding("H000037", 0))!.committees).toEqual([]);
    });

    it("takes the most recent filing cycle, not older ones", async () => {
      // H000037 has a 2024 row too. Mixing cycles would double-count a committee that gave in both.
      const f = await repos.members.funding("H000037", 10);
      expect(f!.committees.map((c) => c.name)).not.toContain("Old Cycle PAC");
      expect(f!.committeesCycle).toBe(2026);
    });

    it("finds a senator's committees, whose filing cycle is not the cycle their campaign is for", async () => {
      // Regression: matching pac_contributions.cycle to campaign_finance.cycle returned nothing
      // for every senator, because a senator up in 2028 still takes PAC money in the 2026 cycle.
      // Real data caught it — Schumer, Gillibrand and Murkowski all came back with no committees
      // while plainly having them (lesson 33).
      const f = await repos.members.funding("S000001", 10);
      expect(f!.cycle).toBe(2028);
      expect(f!.committeesCycle).toBe(2026);
      expect(f!.committees.map((c) => c.name)).toEqual(["Senate Giver PAC"]);
    });

    it("reports no committee cycle when we hold no committee rows for them", async () => {
      const f = await repos.members.funding("H000042", 10);
      expect(f).toBeNull();
    });

    /**
     * The SQL filter must agree with `isPac` in apps/worker/src/fec.ts for every designation and
     * type FEC uses. The rule is written out twice — apps/api has no workspace dependencies, see
     * the comment on the query — so this walks the whole grid rather than trusting that the two
     * copies were changed together.
     */
    it("excludes exactly the committees isPac excludes: party committees and joint fundraisers", async () => {
      const designations = ["A", "B", "D", "J", "P", "U", ""];
      const types = ["N", "Q", "O", "X", "Y", "Z", "H", ""];
      const isPac = (designation: string, type: string) => designation !== "J" && !["X", "Y", "Z"].includes(type);

      let i = 0;
      const expected: string[] = [];
      for (const designation of designations) {
        for (const type of types) {
          const id = `C${String(i).padStart(8, "0")}`;
          const name = `Grid ${designation || "-"}${type || "-"}`;
          await pg.query(
            `insert into pac_contributions (member_id, cycle, committee_id, committee_name, committee_designation,
                                            committee_type, direct_amount) values ('H000040', 2026, $1, $2, $3, $4, $5)`,
            [id, name, designation || null, type || null, 1000 - i],
          );
          if (isPac(designation, type)) expected.push(name);
          i++;
        }
      }
      const f = await repos.members.funding("H000040", 100);
      expect(f!.committees.map((c) => c.name).sort()).toEqual(expected.sort());
      // And the grid genuinely exercises both outcomes, so a filter that dropped everything,
      // or nothing, could not pass by accident.
      expect(expected.length).toBeGreaterThan(0);
      expect(expected.length).toBeLessThan(designations.length * types.length);
    });
  });
});

describe("member search", () => {
  beforeAll(async () => {
    // Shapes taken from staging: accents, hyphens and apostrophes in surnames; an at-large seat
    // (district 0); D.C.'s delegate and Puerto Rico's resident commissioner (district 0, no
    // senators); a former member who must not come back.
    await pg.exec(`
      insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end) values
        ('J000294', 'Hakeem', 'Jeffries', 'D', 'NY', 8, 'house', '2025-01-03', '2099-01-03'),
        ('V000081', 'Nydia', 'Velázquez', 'D', 'NY', 7, 'house', '2025-01-03', '2099-01-03'),
        ('O000172', 'Alexandria', 'Ocasio-Cortez', 'D', 'NY', 14, 'house', '2025-01-03', '2099-01-03'),
        ('S000148', 'Charles', 'Schumer', 'D', 'NY', null, 'senate', '2025-01-03', '2099-01-03'),
        ('G000555', 'Kirsten', 'Gillibrand', 'D', 'NY', null, 'senate', '2025-01-03', '2099-01-03'),
        ('Z000001', 'Old', 'Jefferson', 'R', 'NY', 9, 'house', '2021-01-03', '2023-01-03'),
        ('H001096', 'Harriet', 'Hageman', 'R', 'WY', 0, 'house', '2025-01-03', '2099-01-03'),
        ('N000147', 'Eleanor', 'Norton', 'D', 'DC', 0, 'house', '2025-01-03', '2099-01-03'),
        ('H001103', 'Pablo José', 'Hernández', 'D', 'PR', 0, 'house', '2025-01-03', '2099-01-03'),
        ('O000171', 'Tom', 'O''Halleran', 'D', 'AZ', 2, 'house', '2025-01-03', '2099-01-03'),
        -- Letters NFD cannot decompose: the SQL fold must come from the same table as the typed one.
        ('L000001', 'Łukasz', 'Søren', 'D', 'MN', 9, 'house', '2025-01-03', '2099-01-03');
    `);
  });

  const ids = (ms: { bioguideId: string }[]) => ms.map((m) => m.bioguideId);
  const search = (q: string, chamber?: "house" | "senate", limit = 60) =>
    repos.members.search(parseMemberQuery(q), chamber, limit).then(ids);

  it("lists a state's senators before its House members, and the House by district", async () => {
    expect(await search("New York")).toEqual(["G000555", "S000148", "V000081", "J000294", "O000172"]);
    expect(await search("NY")).toEqual(await search("new york"));
  });

  it("finds one seat, including at large", async () => {
    expect(await search("NY-8")).toEqual(["J000294"]);
    expect(await search("WY-AL")).toEqual(["H001096"]);
    expect(await search("NY-99")).toEqual([]);
  });

  it("finds a delegate jurisdiction's one member whatever seat is typed, and no senators", async () => {
    expect(await search("DC")).toEqual(["N000147"]);
    expect(await search("DC-AL")).toEqual(["N000147"]);
    expect(await search("dc-1")).toEqual(["N000147"]);
    expect(await search("Puerto Rico")).toEqual(["H001103"]);
  });

  it("finds a name without its accents, hyphen or apostrophe, and in either order", async () => {
    expect(await search("velazquez")).toEqual(["V000081"]);
    expect(await search("Velázquez")).toEqual(["V000081"]);
    expect(await search("ocasio cortez")).toEqual(["O000172"]);
    expect(await search("alexandria ocasio")).toEqual(["O000172"]);
    expect(await search("ohalleran")).toEqual(["O000171"]);
    expect(await search("hernandez pablo")).toEqual(["H001103"]);
  });

  it("puts a surname that starts with the text ahead of one that merely contains it", async () => {
    // "Jeffries" starts with "jeff"; the former "Jefferson" is not sitting and never appears.
    expect(await search("jeff")).toEqual(["J000294"]);
    // "Schumer" contains "hum"; nobody's surname starts with it.
    expect(await search("hum")).toEqual(["S000148"]);
    expect(await search("hage")).toEqual(["H001096"]);
  });

  it("filters by chamber and caps at the limit", async () => {
    expect(await search("NY", "house")).toEqual(["V000081", "J000294", "O000172"]);
    expect(await search("NY", "senate")).toEqual(["G000555", "S000148"]);
    expect(await search("NY", undefined, 2)).toEqual(["G000555", "S000148"]);
  });

  it("folds letters with no decomposition the way a typed name folds", async () => {
    expect(await search("soren")).toEqual(["L000001"]);
    expect(await search("Søren Łukasz")).toEqual(["L000001"]);
  });

  // Two letters that are a code still start names: Alabama has nobody here, so "AL" is names alone,
  // Senate first, then surnames that start with it, then names that do, then names containing it.
  it("searches a state as a name too, after the state's own members", async () => {
    expect(await search("AL")).toEqual(["S000002", "H000038", "O000172", "O000171"]);
    expect((await search("N.Y.")).slice(0, 5)).toEqual(["G000555", "S000148", "V000081", "J000294", "O000172"]);
  });

  it("treats a typed % or _ as itself, not a wildcard", async () => {
    expect(await search("%%")).toEqual([]);
    expect(await search("__")).toEqual([]);
  });
});

describe("recent votes", () => {
  it("lists final votes newest first with what each was on, and filters by chamber", async () => {
    const all = await repos.votes.recentVotes(undefined, 10);
    expect(all.map((r) => r.vote.id)).toEqual([
      "senate-119-1-91", "senate-119-1-90", "house-119-1-4", "house-119-1-3", "house-119-1-2", "house-119-1-1",
    ]);
    expect(all[1]!.measure).toEqual({
      id: "119-pn-12-12", kind: "nomination", citation: "PN12-12", title: "Daniel Driscoll", policyArea: null,
    });
    expect(all.find((r) => r.vote.id === "house-119-1-2")!.measure).toBeNull();
    expect((await repos.votes.recentVotes("house", 2)).map((r) => r.vote.id)).toEqual(["house-119-1-4", "house-119-1-3"]);
    // The next page: before the last one shown.
    const next = await repos.votes.recentVotes(undefined, 2, new Date("2025-01-12T15:00:00Z"));
    expect(next.map((r) => r.vote.id)).toEqual(["house-119-1-2", "house-119-1-1"]);
  });

  it("narrows to votes on bills in the topics asked for, and to nothing for a topic with none", async () => {
    const taxation = await repos.votes.recentVotes(undefined, 10, undefined, ["Taxation"]);
    expect(taxation.map((r) => r.vote.id)).toEqual(["house-119-1-1"]);
    expect(taxation[0]!.measure?.policyArea).toBe("Taxation");
    expect(await repos.votes.recentVotes(undefined, 10, undefined, ["Health"])).toEqual([]);
    expect((await repos.votes.recentVotes("senate", 10, undefined, ["Taxation", "Health"]))).toEqual([]);
    expect((await repos.votes.recentVotes(undefined, 10, undefined, ["Health", "Taxation"])).map((r) => r.vote.id))
      .toEqual(["house-119-1-1"]);
  });
});

describe("who is sitting", () => {
  beforeAll(async () => {
    // Florida on 2026-11-13, relative to today: an appointed senator whose term "ended" on the
    // special election's date and who has voted since; a House member who resigned (last vote on
    // their last day); and Ohio, whose appointee's successor has since been sworn in.
    await pg.exec(`
      insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end) values
        ('F000001', 'Rick', 'Regular', 'R', 'FL', null, 'senate', '2025-01-03', '2099-01-03'),
        ('F000002', 'Ashley', 'Appointee', 'R', 'FL', null, 'senate', '2025-01-21', current_date - 10),
        ('F000011', 'Rhea', 'Resigned', 'D', 'FL', 11, 'house', '2025-01-03', current_date - 20),
        ('O000001', 'Otto', 'Appointed', 'R', 'OH', null, 'senate', '2025-01-21', current_date - 30),
        ('O000002', 'Olive', 'Elected', 'D', 'OH', null, 'senate', current_date - 5, '2031-01-03'),
        ('O000003', 'Oscar', 'Regular', 'R', 'OH', null, 'senate', '2025-01-03', '2029-01-03');
      insert into votes (id, chamber, congress, session, roll_number, question, state, yea, nay, result, occurred_at) values
        ('senate-119-2-900', 'senate', 119, 2, 900, 'On the Cloture Motion', 'final', 60, 38, 'Agreed to', now() - interval '2 days'),
        ('house-119-2-900', 'house', 119, 2, 900, 'On Passage', 'final', 300, 100, 'Passed',
         -- 8:30 p.m. Eastern on their last day: 01:30 UTC the next day, which a UTC comparison
         -- would read as a vote after the term ended.
         ((current_date - 20) + time '20:30') at time zone 'America/New_York');
      insert into vote_positions (vote_id, member_id, position) values
        ('senate-119-2-900', 'F000001', 'yea'),
        ('senate-119-2-900', 'F000002', 'yea'),
        ('senate-119-2-900', 'O000001', 'yea'),
        ('house-119-2-900', 'F000011', 'yea');
    `);
  });

  it("keeps an appointed senator who is still voting after the special election date", async () => {
    expect((await repos.members.membersFor("FL", 11)).map((m) => m.bioguideId)).toEqual(["F000002", "F000001"]);
    const found = await repos.members.search(parseMemberQuery("FL"), "senate", 10);
    expect(found.map((m) => m.bioguideId)).toEqual(["F000002", "F000001"]);
  });

  it("drops a member who resigned, whose last vote was the evening of their last day (Eastern)", async () => {
    expect((await repos.members.search(parseMemberQuery("FL-11"), undefined, 10))).toEqual([]);
  });

  it("drops an appointee once someone has taken a seat since, even though they voted after", async () => {
    expect((await repos.members.membersFor("OH", 1)).map((m) => m.bioguideId)).toEqual(["O000002", "O000003"]);
  });
});

describe("live repository", () => {
  it("reports each chamber as the worker last wrote it", async () => {
    expect(await repos.live.chambers()).toEqual([]);
    await pg.exec(`
      insert into chamber_status (chamber, in_session, convenes_at, legislative_day, source, checked_at) values
        ('senate', false, '2026-11-16T20:00:00Z', '2026-11-16', 'senate_schedule', '2026-11-13T22:00:00Z'),
        ('house', true, null, '2026-11-10', 'house_floor', '2026-11-10T23:33:00Z');
    `);
    expect(await repos.live.chambers()).toEqual([
      { chamber: "house", inSession: true, convenesAt: null, legislativeDay: "2026-11-10", checkedAt: "2026-11-10T23:33:00.000Z" },
      {
        chamber: "senate",
        inSession: false,
        convenesAt: "2026-11-16T20:00:00.000Z",
        legislativeDay: "2026-11-16",
        checkedAt: "2026-11-13T22:00:00.000Z",
      },
    ]);
  });

  it("lists open votes from the last day and votes the worker published as final within the window, newest first", async () => {
    await pg.exec(`
      insert into votes (id, chamber, congress, session, roll_number, question, state, yea, nay, result, bill_ref,
                         opened_at, occurred_at, announced_at, posted_at, broadcast_at) values
        ('house-119-2-319', 'house', 119, 2, 319, 'On agreeing to the resolution', 'open', 215, 209, 'Agreed to',
         'H. Res. 1650', '2026-11-10T23:20:53Z', '2026-11-10T23:20:53Z', '2026-11-10T23:33:00Z', null, null),
        ('house-119-2-318', 'house', 119, 2, 318, 'On Ordering the Previous Question', 'final', 213, 207, 'Passed',
         'H RES 1650', '2026-11-10T23:10:37Z', '2026-11-10T23:10:00Z', '2026-11-10T23:32:00Z', '2026-11-10T23:32:10Z',
         '2026-11-10T23:32:10Z'),
        -- Stored by the hourly workflow while the worker was down: no posted_at, but broadcast once the worker came back.
        ('house-119-2-310', 'house', 119, 2, 310, 'On Passage', 'final', 5, 4, 'Passed', null, null, '2026-11-10T21:00:00Z',
         null, null, '2026-11-10T23:30:00Z'),
        -- Published before the window.
        ('house-119-2-300', 'house', 119, 2, 300, 'On Passage', 'final', 1, 1, 'Passed', null, null, '2026-11-10T19:00:00Z',
         null, '2026-11-10T20:00:00Z', '2026-11-10T20:00:00Z'),
        -- A backfill of an old vote, marked in the window without being announced.
        ('senate-119-1-50', 'senate', 119, 1, 50, 'On Passage', 'final', 1, 1, 'Passed', null, null, '2025-05-01T12:00:00Z',
         null, null, '2026-11-10T23:31:00Z'),
        -- Final but never broadcast (the worker has not seen it yet): not "just final" until it is published.
        ('house-119-2-320', 'house', 119, 2, 320, 'On Passage', 'final', 1, 1, 'Passed', null, null, '2026-11-10T23:30:00Z',
         null, '2026-11-10T23:33:30Z', null),
        ('house-119-2-200', 'house', 119, 2, 200, 'On Passage', 'open', 0, 0, null, null, null, null, '2026-11-08T20:00:00Z', null, null);
    `);
    const votes = await repos.live.liveVotes(new Date("2026-11-10T22:00:00Z"), new Date("2026-11-10T23:34:00Z"));
    // 300 was published before the window; 50 is an old vote; 320 is not published yet; 200 has sat
    // open for two days, which means its XML never parsed.
    expect(votes.map((v) => `${v.id}:${v.state}`)).toEqual([
      "house-119-2-319:open",
      "house-119-2-318:final",
      "house-119-2-310:final",
    ]);
    expect(votes[0]).toMatchObject({
      totals: { yea: 215, nay: 209, present: 0, notVoting: 0 },
      openedAt: "2026-11-10T23:20:53.000Z",
      announcedAt: "2026-11-10T23:33:00.000Z",
      postedAt: null,
    });
    expect(votes[1]!.postedAt).toBe("2026-11-10T23:32:10.000Z");
    expect(votes[2]!.postedAt).toBeNull();
  });

  it("answers empty, not an error, on a database without the M3 migration", async () => {
    const failing = (code: string): Db => ({
      query: async () => {
        throw Object.assign(new Error(`simulated ${code}`), { code });
      },
    });
    for (const code of ["42P01", "42703"]) {
      const live = pgRepositories(failing(code)).live;
      expect(await live.chambers()).toEqual([]);
      expect(await live.liveVotes(new Date(0), new Date())).toEqual([]);
    }
    // Anything else is a real failure and still throws.
    await expect(pgRepositories(failing("57P01")).live.chambers()).rejects.toThrow("simulated 57P01");
  });

  it("really meets 42P01 and 42703 on a database that has not had the M3 migration", async () => {
    const old = new PGlite();
    await old.exec(`
      create schema auth;
      create table auth.users (id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
    `);
    for (const m of loadMigrations().filter((m) => !m.name.endsWith("_live_layer.sql"))) await old.exec(m.sql);
    const live = pgRepositories(old as unknown as Db).live;
    expect(await live.chambers()).toEqual([]); // chamber_status: 42P01
    expect(await live.liveVotes(new Date(0), new Date())).toEqual([]); // votes.broadcast_at: 42703
    await old.close();
  });
});

describe("catalog", () => {
  // Real bills from production (2026-11-13), summaries trimmed; stages as the worker derives them.
  // H.R. 6 and 118th S. 2 are stand-ins for an old untouched bill and a same-numbered older one.
  let catalog: ReturnType<typeof pgRepositories>["catalog"];
  let db: PGlite;
  const now = new Date("2026-11-13T17:00:00Z");

  beforeAll(async () => {
    db = new PGlite();
    await db.exec(`
      create schema auth;
      create table auth.users (id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
    `);
    for (const m of loadMigrations()) await db.exec(m.sql);
    await db.exec(`
      insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end) values
        ('D000399', 'Lloyd', 'Doggett', 'D', 'TX', 37, 'house', '2025-01-03', '2027-01-03'),
        ('C001098', 'Ted', 'Cruz', 'R', 'TX', null, 'senate', '2025-01-03', '2031-01-03'),
        ('H001096', 'Harriet', 'Hageman', 'R', 'WY', 0, 'house', '2025-01-03', '2027-01-03'),
        ('V000131', 'Marc', 'Veasey', 'D', 'TX', 33, 'house', '2023-01-03', '2025-01-03'),
        ('G000594', 'Tony', 'Gonzales', 'R', 'TX', 23, 'house', '2025-01-03', '2027-01-03'),
        ('C001063', 'Henry', 'Cuellar', 'D', 'TX', 28, 'house', '2025-01-03', '2027-01-03');
      insert into bills (id, congress, bill_type, number, title, short_title, policy_area, stage, summary,
                         latest_action_on, latest_action_text) values
        ('119-hr-2493', 119, 'hr', 2493, 'To reauthorize certain programs relating to rural health care.',
         'Improving Care in Rural America Reauthorization Act of 2025', 'Health', 'passed_house',
         'This bill reauthorizes through FY2030 grant programs administered by the Health Resources and Services Administration that provide funding for rural health care.',
         '2026-04-22', 'Received in the Senate.'),
        ('119-hr-4541', 119, 'hr', 4541, 'To reauthorize the EARLY Act.', 'EARLY Act Reauthorization of 2025', 'Health', 'passed_house',
         'This bill reauthorizes and revises programs of the Centers for Disease Control and Prevention that support services addressing breast and cervical cancer.',
         '2026-07-27', 'Read twice and referred to the Committee on Health, Education, Labor, and Pensions.'),
        ('119-sjres-197', 119, 'sjres', 197,
         'A joint resolution providing for congressional disapproval under chapter 8 of title 5, United States Code, of the rule submitted by the Centers for Medicare & Medicaid Services relating to "Medicare and Medicaid Programs; Contract Year 2027 Policy and Technical Changes".',
         null, 'Health', 'introduced', null, '2026-09-29', 'Motion to proceed to consideration of measure not agreed to in Senate by Yea-Nay Vote. 48 - 51.'),
        ('119-hr-6', 119, 'hr', 6, 'An old idea Act', null, 'Health', 'introduced', null, '2025-03-01', 'Referred to the House Committee on Energy and Commerce.'),
        ('119-s-2', 119, 's', 2, 'Secure America Act', 'Secure America Act', 'Immigration', 'law', null, '2026-06-10', 'Became Public Law No: 119-98.'),
        ('118-s-2', 118, 's', 2, 'An older Senate bill', null, 'Immigration', 'introduced', null, '2023-02-01', 'Referred.'),
        ('119-hr-1013', 119, 'hr', 1013, 'To amend the Internal Revenue Code of 1986 to allow 403(b) plans to invest in collective investment trusts.',
         'Retirement Fairness for Charities and Educational Institutions Act of 2025', 'Finance and Financial Sector', 'passed_house', null,
         '2026-11-11', 'Passed/agreed to in House: On passage Passed by the Yeas and Nays: 295 - 128 (Roll no. 321).');
      insert into votes (id, chamber, congress, session, roll_number, question, state, bill_id) values
        ('senate-119-2-500', 'senate', 119, 2, 500, 'On the Motion to Proceed', 'final', '119-sjres-197'),
        ('house-119-2-321', 'house', 119, 2, 321, 'On Passage', 'final', '119-hr-1013');
    `);
    catalog = pgRepositories(db as unknown as Db).catalog;
  });

  it("counts bills per topic, and those with a floor vote, for one Congress", async () => {
    const counts = await catalog.topicCounts(119);
    expect(counts.sort((a, b) => a.name.localeCompare(b.name))).toEqual([
      { name: "Finance and Financial Sector", bills: 1, billsWithFloorVote: 1, latestActionOn: "2026-11-11" },
      { name: "Health", bills: 4, billsWithFloorVote: 1, latestActionOn: "2026-09-29" },
      { name: "Immigration", bills: 1, billsWithFloorVote: 0, latestActionOn: "2026-06-10" },
    ]);
  });

  it("lists a topic newest action first, with label, stage and stalled", async () => {
    const bills = (await catalog.topicBills(119, "Health", "all", null, 10, now)).map((r) => r.bill);
    expect(bills.map((b) => b.id)).toEqual(["119-sjres-197", "119-hr-4541", "119-hr-2493", "119-hr-6"]);
    expect(bills[0]).toMatchObject({
      citation: "S.J.Res. 197",
      label:
        "Disapproving the Centers for Medicare & Medicaid Services' rule: Medicare and Medicaid Programs; Contract Year 2027 Policy and Technical Changes",
      stage: "introduced",
      stalled: false,
      hasFloorVote: true,
      latestAction: { on: "2026-09-29", text: expect.stringContaining("48 - 51") },
    });
    // 90 days before 2026-11-13 is 2026-08-15: the EARLY Act's referral on 2026-07-27 is older.
    expect(bills.map((b) => b.stalled)).toEqual([false, true, true, true]);
  });

  it("filters moving, law and stalled", async () => {
    const ids = async (topic: string, filter: "moving" | "law" | "stalled") =>
      (await catalog.topicBills(119, topic, filter, null, 10, now)).map((r) => r.bill.id);
    expect(await ids("Health", "moving")).toEqual(["119-sjres-197"]);
    expect(await ids("Health", "stalled")).toEqual(["119-hr-4541", "119-hr-2493", "119-hr-6"]);
    expect(await ids("Immigration", "law")).toEqual(["119-s-2"]);
    // A law is settled: never stalled however long ago it was signed.
    expect(await ids("Immigration", "stalled")).toEqual([]);
  });

  it("pages with a keyset cursor, without skipping or repeating", async () => {
    const first = await catalog.topicBills(119, "Health", "all", null, 2, now);
    const second = await catalog.topicBills(119, "Health", "all", first.at(-1)!.at, 2, now);
    expect([...first, ...second].map((r) => r.bill.id)).toEqual(["119-sjres-197", "119-hr-4541", "119-hr-2493", "119-hr-6"]);
  });

  it("pages past a bill with an action date but no action text", async () => {
    await db.exec(`insert into bills (id, congress, bill_type, number, title, policy_area, latest_action_on)
                   values ('119-hr-9', 119, 'hr', 9, 'A dated, textless Act', 'Health', '2026-08-01')`);
    try {
      const walk: string[] = [];
      let after: { on: string | null; id: string } | null = null;
      for (let i = 0; i < 6; i++) {
        const page = await catalog.topicBills(119, "Health", "all", after, 1, now);
        if (page.length === 0) break;
        walk.push(page[0]!.bill.id);
        after = page[0]!.at;
      }
      expect(walk).toEqual(["119-sjres-197", "119-hr-9", "119-hr-4541", "119-hr-2493", "119-hr-6"]);
      expect((await catalog.topicBills(119, "Health", "all", null, 2, now))[1]).toMatchObject({
        bill: { id: "119-hr-9", latestAction: null, stage: null },
        at: { on: "2026-08-01", id: "119-hr-9" },
      });
    } finally {
      await db.exec("delete from bills where id = '119-hr-9'");
    }
  });

  it("finds bills by number in every Congress, newest first", async () => {
    expect((await catalog.billsByNumber("s", 2, null, now)).map((b) => b.id)).toEqual(["119-s-2", "118-s-2"]);
    expect((await catalog.billsByNumber("s", 2, 118, now)).map((b) => b.id)).toEqual(["118-s-2"]);
    expect(await catalog.billsByNumber("hr", 99999, null, now)).toEqual([]);
  });

  it("matches words in short titles, titles and summaries", async () => {
    expect((await catalog.searchBills("rural health", 119, 10, now)).map((b) => b.id)).toEqual(["119-hr-2493"]);
    // Stemming: "cancers" finds "cancer" in the EARLY Act's summary.
    expect((await catalog.searchBills("cervical cancers", 119, 10, now)).map((b) => b.id)).toEqual(["119-hr-4541"]);
    expect((await catalog.searchBills("medicare", 119, 10, now)).map((b) => b.id)).toEqual(["119-sjres-197"]);
    // Stray punctuation and stop words never throw.
    expect(await catalog.searchBills("the & of ) (", 119, 10, now)).toEqual([]);
  });

  it("answers empty, not 500, on a database without the catalog migration", async () => {
    // The API deploys on merge; the migration is applied by hand after review.
    const old = new PGlite();
    await old.exec(`
      create schema auth;
      create table auth.users (id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
    `);
    for (const m of loadMigrations().filter((m) => !m.name.endsWith("_bill_catalog.sql"))) await old.exec(m.sql);
    const before = pgRepositories(old as unknown as Db).catalog;
    expect(await before.searchBills("health", 119, 10, now)).toEqual([]); // bills.search: 42703
    expect(await before.topicBills(119, "Health", "all", null, 10, now)).toEqual([]); // bills.stage: 42703
    expect(await before.billsByNumber("hr", 1, null, now)).toEqual([]);
    // A bill page still opens there: its stage is read through to_jsonb and comes back null.
    await old.exec(`insert into bills (id, congress, bill_type, number, title) values ('119-hr-5', 119, 'hr', 5, 'To do a thing')`);
    const bill = await pgRepositories(old as unknown as Db).bills.getBill("119-hr-5");
    expect(bill?.stage).toBeNull();
    expect(bill?.label).toBe("To do a thing");
    await old.close();
  });
});

describe("live votes name their measure", () => {
  it("finds an open vote's bill from its roll call reference, before the vote is linked", async () => {
    await pg.exec(`
      insert into votes (id, chamber, congress, session, roll_number, question, state, bill_ref, opened_at, announced_at)
        values ('house-119-3-7900', 'house', 119, 3, 7900, 'On Passage', 'open', 'H R 1', '2026-12-01T19:43:00Z', '2026-12-01T19:43:30Z'),
               ('house-119-3-7901', 'house', 119, 3, 7901, 'On Motion to Adjourn', 'open', 'QUORUM', '2026-12-01T19:44:00Z', '2026-12-01T19:44:30Z');
    `);
    const votes = await repos.live.liveVotes(new Date("2026-12-01T19:00:00Z"), new Date("2026-12-01T19:45:00Z"));
    const byId = Object.fromEntries(votes.map((v) => [v.id, v]));
    expect(byId["house-119-3-7900"]!.billId).toBeNull();
    expect(byId["house-119-3-7900"]!.measure).toEqual({
      id: "119-hr-1",
      kind: "bill",
      citation: "H.R. 1",
      title: "Example Act",
      policyArea: "Taxation",
    });
    expect(byId["house-119-3-7901"]!.measure).toBeNull();
    await pg.exec("delete from votes where id in ('house-119-3-7900', 'house-119-3-7901')");
  });
});

describe("device repository", () => {
  const hash = (c: string) => c.repeat(64);
  const token = (c: string) => c.repeat(64);
  const reg = {
    apnsToken: token("a"),
    apnsEnvironment: "production" as const,
    pushToStartToken: token("b"),
    voteOpened: false,
    liveActivities: true,
    subscriptions: [
      { kind: "member" as const, id: "H000037", howVoted: true },
      { kind: "bill" as const, id: "119-hr-1", howVoted: false },
    ],
  };
  const subs = async (keyHash: string) =>
    (
      await pg.query<{ target_kind: string; target_id: string; how_voted: boolean }>(
        `select s.target_kind, s.target_id, s.how_voted from device_subscriptions s join devices d on d.id = s.device_id
          where d.key_hash = $1 order by 1, 2`,
        [keyHash],
      )
    ).rows;

  it("registers a device with its whole subscription list, and replaces it on the next registration", async () => {
    await repos.devices.register(hash("1"), reg, new Date("2026-11-13T12:00:00Z"), "203.0.113.7");
    expect(await subs(hash("1"))).toEqual([
      { target_kind: "bill", target_id: "119-hr-1", how_voted: false },
      { target_kind: "member", target_id: "H000037", how_voted: true },
    ]);
    await repos.devices.register(
      hash("1"),
      {
        ...reg,
        voteOpened: true,
        subscriptions: [
          { kind: "member", id: "H000037", howVoted: false },
          { kind: "member", id: "S000001", howVoted: true },
        ],
      },
      new Date("2026-11-13T12:05:00Z"),
      "203.0.113.7",
    );
    expect(await subs(hash("1"))).toEqual([
      { target_kind: "member", target_id: "H000037", how_voted: false },
      { target_kind: "member", target_id: "S000001", how_voted: true },
    ]);
    const { rows } = await pg.query<{ vote_opened: boolean; apns_token: string; n: number }>(
      "select vote_opened, apns_token, (select count(*)::int from devices) as n from devices where key_hash = $1",
      [hash("1")],
    );
    expect(rows[0]).toEqual({ vote_opened: true, apns_token: token("a"), n: 1 });
  });

  it("counts only new keys against a caller's daily allowance, kept hashed in Postgres", async () => {
    const day = new Date("2026-11-20T12:00:00Z");
    const results: string[] = [];
    for (let i = 0; i < DEVICE_SIGNUPS_PER_DAY + 1; i++) {
      results.push(await repos.devices.register(`${i.toString(16).padStart(2, "0")}`.repeat(32), { ...reg, apnsToken: null, pushToStartToken: null }, day, "198.51.100.9"));
    }
    expect(results.slice(0, DEVICE_SIGNUPS_PER_DAY).every((r) => r === "ok")).toBe(true);
    expect(results.at(-1)).toBe("limited");
    // A key it already has is never limited; another caller, or the next day, starts afresh.
    expect(await repos.devices.register("00".repeat(32), { ...reg, apnsToken: null, pushToStartToken: null }, day, "198.51.100.9")).toBe("ok");
    expect(await repos.devices.register("ee".repeat(32), { ...reg, apnsToken: null, pushToStartToken: null }, day, "198.51.100.10")).toBe("ok");
    const { rows } = await pg.query<{ ip_hash: string }>("select ip_hash from device_signups");
    expect(rows.every((r) => /^[0-9a-f]{64}$/.test(r.ip_hash) && !r.ip_hash.includes("198"))).toBe(true);
    await pg.exec("delete from devices where key_hash not in (repeat('1', 64))");
  });

  it("moves a token to the registration that sends it now (a reinstall makes a new key)", async () => {
    await repos.devices.register(hash("2"), { ...reg, pushToStartToken: null }, new Date(), "203.0.113.7");
    const { rows } = await pg.query<{ key_hash: string; apns_token: string | null; push_to_start_token: string | null }>(
      "select key_hash, apns_token, push_to_start_token from devices order by key_hash",
    );
    expect(rows).toEqual([
      { key_hash: hash("1"), apns_token: null, push_to_start_token: token("b") },
      { key_hash: hash("2"), apns_token: token("a"), push_to_start_token: null },
    ]);
  });

  it("keeps a Live Activity's token per vote, refuses an unknown device or vote, and forgets everything on unregister", async () => {
    await pg.exec(`insert into votes (id, chamber, congress, session, roll_number, question, state)
                   values ('house-119-3-950', 'house', 119, 3, 950, 'On Passage', 'open')`);
    expect(await repos.devices.setActivityToken(hash("9"), "house-119-3-950", token("c"), new Date())).toBe("no_device");
    expect(await repos.devices.setActivityToken(hash("1"), "house-119-3-999", token("c"), new Date())).toBe("no_vote");
    expect(await repos.devices.setActivityToken(hash("1"), "house-119-3-950", token("c"), new Date())).toBe("ok");
    expect(await repos.devices.setActivityToken(hash("1"), "house-119-3-950", token("d"), new Date())).toBe("ok");
    const tokens = async () => (await pg.query<{ token: string }>("select token from live_activity_tokens")).rows;
    expect(await tokens()).toEqual([{ token: token("d") }]);
    await repos.devices.removeActivityToken(hash("1"), "house-119-3-950");
    expect(await tokens()).toEqual([]);
    await repos.devices.setActivityToken(hash("1"), "house-119-3-950", token("c"), new Date());
    expect(await repos.devices.unregister(hash("1"))).toBe(true);
    expect(await repos.devices.unregister(hash("1"))).toBe(false);
    expect(await tokens()).toEqual([]);
    expect(await subs(hash("1"))).toEqual([]);
    await repos.devices.unregister(hash("2"));
    await pg.exec("delete from votes where id = 'house-119-3-950'");
  });
});
