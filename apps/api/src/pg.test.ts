import { createHash } from "node:crypto";
import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { beforeAll, describe, expect, it } from "vitest";
import { pgRepositories, poolerMode, poolerWarning, type Db } from "./pg.js";

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
    });
    // Military nominations promote officers in bulk and carry no name.
    expect(try0(votes.find((v) => v.vote.id === "senate-119-1-91")).measure).toEqual({
      id: "119-pn-900",
      kind: "nomination",
      citation: "PN900",
      title: "General, Army",
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
