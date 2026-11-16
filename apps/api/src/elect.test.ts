import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { beforeEach, describe, expect, it } from "vitest";
import { createApp, electFor, NO_CONTACT, type Member, type MemberElect } from "./app.js";
import type { DistrictMatch } from "./district.js";
import { pgElect, type Db } from "./pg.js";
import { parseMemberQuery } from "./search.js";

// The real facts of the first 2026 member-elect: the AP called Michigan's Senate race for Abdul
// El-Sayed at 2:27 a.m. ET on November 4; he replaces Gary Peters, who did not run.
const SOURCE =
  "https://www.wsbtv.com/news/trending/election-2026-abdul-el-sayed-prevails-win-us-senate-seat-michigan/DGWW7OLFAVCKBH3ZXXU5Y46YVE/";
const peters: Member = { bioguideId: "P000595", firstName: "Gary", lastName: "Peters", party: "D", state: "MI", district: null, chamber: "senate" };
const elSayed: MemberElect = {
  id: "elect-2026-mi-sen",
  bioguideId: null,
  firstName: "Abdul",
  lastName: "El-Sayed",
  party: "D",
  state: "MI",
  district: null,
  chamber: "senate",
  takesOffice: "2027-01-03",
  replaces: { bioguideId: "P000595", firstName: "Gary", lastName: "Peters", party: "D" },
  call: { by: "AP", on: "2026-11-04", sourceUrl: SOURCE },
  fecCandidateId: "S6MI00418",
};
// The 119th Congress's at-large Alaska seat, from the House Clerk's 2024 member-elect list.
const CLERK_119 = "https://clerk.house.gov/xml/lists/unofficial-119-member-elect-data.xml";
const peltola: Member = { bioguideId: "P000619", firstName: "Mary", lastName: "Peltola", party: "D", state: "AK", district: 0, chamber: "house" };

let pg: PGlite;

beforeEach(async () => {
  pg = new PGlite();
  await pg.exec(`create schema auth; create table auth.users (id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;`);
  for (const m of loadMigrations()) await pg.exec(m.sql);
  await pg.exec(`
    insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end) values
      ('P000595', 'Gary', 'Peters', 'D', 'MI', null, 'senate', '2021-01-03', '2027-01-03'),
      ('P000619', 'Mary', 'Peltola', 'D', 'AK', 0, 'house', '2023-01-03', '2025-01-03');
    insert into members_elect (id, cycle, first_name, last_name, party, state, chamber, replaces, takes_office, called_by, called_on,
                               source_url, fec_candidate_id, receipts, disbursements, coverage_end, finance_cycle, finance_fetched_at)
      values ('elect-2026-mi-sen', 2026, 'Abdul', 'El-Sayed', 'D', 'MI', 'senate', 'P000595', '2027-01-03', 'AP', '2026-11-04',
              '${SOURCE}', 'S6MI00418', 53830872, 51096843, '2026-10-14', 2026, now());
    insert into members_elect (id, cycle, bioguide_id, first_name, last_name, party, state, district, chamber, replaces, takes_office,
                               called_by, called_on, source_url)
      values ('elect-2024-ak-al', 2024, 'B001323', 'Nicholas', 'Begich', 'R', 'AK', 0, 'house', 'P000619', '2025-01-03',
              'House Clerk', '2024-11-05', '${CLERK_119}');
  `);
});

/** The app on PGlite's elect tables at `now`, with members and districts from plain lists. */
function appAt(now: string, opts: { disclosuresEnabled?: boolean; district?: DistrictMatch } = {}) {
  const members = [peters, peltola];
  return createApp({
    votes: { getVote: async () => null, recentVotes: async () => [], voteBreakdown: async () => ({ partyTotals: [], candidateTotals: [], positions: [], measure: null }) },
    members: {
      membersFor: async (state) => members.filter((m) => m.state === state),
      recentVotes: async () => [],
      getMember: async (id) => members.find((m) => m.bioguideId === id) ?? null,
      search: async (query) => members.filter((m) => (query.kind === "name" ? false : m.state === query.state)),
      partyLoyalty: async () => ({ votes: 0, withParty: 0, againstParty: 0 }),
      funding: async () => null,
      contact: async () => NO_CONTACT,
    },
    bills: { getBill: async () => null, getAnalysis: async () => null },
    nominations: { getNomination: async () => null },
    status: { lastRuns: async () => [] },
    live: { chambers: async () => [], liveVotes: async () => [] },
    locate: async () => opts.district ?? null,
    now: () => new Date(now),
    elect: pgElect(pg as unknown as Db),
    disclosuresEnabled: opts.disclosuresEnabled,
  });
}

const json = async (app: ReturnType<typeof appAt>, path: string) => {
  const res = await app.request(path);
  return { status: res.status, body: await res.json() };
};

describe("GET /v1/members-elect", () => {
  it("lists members-elect still to take office, by state, with who called each race", async () => {
    const app = appAt("2026-11-16T15:00:00Z");
    expect(await json(app, "/v1/members-elect")).toEqual({ status: 200, body: { elect: [elSayed], pending: [] } });
    expect((await json(app, "/v1/members-elect?state=mi")).body).toEqual({ elect: [elSayed], pending: [] });
    expect((await json(app, "/v1/members-elect?state=NY")).body).toEqual({ elect: [], pending: [] });
    expect((await json(app, "/v1/members-elect?state=M1")).status).toBe(400);
  });

  it("lists an uncalled seat with its incumbent and no name", async () => {
    // Michigan before the AP's call.
    await pg.exec(`delete from members_elect where id = 'elect-2026-mi-sen';
      insert into seats_pending (id, cycle, state, chamber, status, incumbent, source_url)
        values ('elect-2026-mi-sen', 2026, 'MI', 'senate', 'uncalled', 'P000595', '${SOURCE}')`);
    expect((await json(appAt("2026-11-03T23:00:00Z"), "/v1/members-elect?state=MI")).body).toEqual({
      elect: [],
      pending: [
        {
          id: "elect-2026-mi-sen", state: "MI", district: null, chamber: "senate", status: "uncalled", runoffOn: null,
          incumbent: { bioguideId: "P000595", firstName: "Gary", lastName: "Peters", party: "D" }, sourceUrl: SOURCE,
        },
      ],
    });
    // And gone with the rest once the new Senate is seated.
    expect((await json(appAt("2027-01-03T12:00:00Z"), "/v1/members-elect")).body).toEqual({ elect: [], pending: [] });
  });

  it("serves nothing from January 3 in Washington", async () => {
    // 04:59 UTC on the 3rd is still January 2 in Washington.
    expect((await json(appAt("2027-01-03T04:59:00Z"), "/v1/members-elect?state=MI")).body.elect).toHaveLength(1);
    expect((await json(appAt("2027-01-03T05:00:00Z"), "/v1/members-elect?state=MI")).body.elect).toEqual([]);
  });
});

describe("GET /v1/members-elect/{id}", () => {
  it("gives the FEC totals with their link, and no disclosure while disclosures are off", async () => {
    expect(await json(appAt("2026-11-16T15:00:00Z"), "/v1/members-elect/elect-2026-mi-sen")).toEqual({
      status: 200,
      body: {
        elect: elSayed,
        funding: { cycle: 2026, receipts: 53830872, disbursements: 51096843, coverageEnd: "2026-10-14", sourceUrl: "https://www.fec.gov/data/candidate/S6MI00418/" },
        disclosure: null,
      },
    });
  });

  it("answers funding null before the FEC totals are fetched, and disclosure null with no candidate report", async () => {
    await pg.exec("update members_elect set receipts = null, disbursements = null, coverage_end = null, finance_cycle = null");
    const { body } = await json(appAt("2026-11-16T15:00:00Z", { disclosuresEnabled: true }), "/v1/members-elect/elect-2026-mi-sen");
    expect(body.funding).toBeNull();
    expect(body.disclosure).toBeNull();
  });

  it("gives a read candidate report's ranges as filed, only when disclosures are on", async () => {
    // A test row, not a real filing: the shape is what is checked.
    await pg.exec(`
      insert into disclosure_filings (id, chamber, filer_name, kind, report_year, filed_on, source_url, format, parse_status, elect_id)
        values ('house-test-1', 'house', 'Test Filer', 'annual', 2024, '2024-05-15', 'https://example.test/report.pdf', 'electronic', 'parsed', 'elect-2024-ak-al');
      insert into disclosure_assets (filing_id, position, name, owner, value_range) values ('house-test-1', 1, 'Test asset', 'self', '$1,001 - $15,000');`);
    const on = await json(appAt("2024-12-31T15:00:00Z", { disclosuresEnabled: true }), "/v1/members-elect/elect-2024-ak-al");
    expect(on.body.disclosure).toEqual({
      filedAt: "2024-05-15",
      sourceUrl: "https://example.test/report.pdf",
      paper: false,
      assets: [{ name: "Test asset", type: null, typeCode: null, account: null, owner: "self", value: "$1,001 - $15,000", incomeType: null, income: null, description: null }],
    });
    expect((await json(appAt("2024-12-31T15:00:00Z"), "/v1/members-elect/elect-2024-ak-al")).body.disclosure).toBeNull();
    // A scan is a link with no rows, and says so.
    await pg.exec("update disclosure_filings set format = 'paper', parse_status = 'paper'; delete from disclosure_assets");
    expect((await json(appAt("2024-12-31T15:00:00Z", { disclosuresEnabled: true }), "/v1/members-elect/elect-2024-ak-al")).body.disclosure).toMatchObject({ paper: true, assets: [] });
  });

  it("is 404 for an unknown ID or once they have taken office, and 400 for a malformed one", async () => {
    expect((await json(appAt("2026-11-16T15:00:00Z"), "/v1/members-elect/elect-2026-oh-sen")).status).toBe(404);
    expect((await json(appAt("2027-01-03T15:00:00Z"), "/v1/members-elect/elect-2026-mi-sen")).status).toBe(404);
    expect((await json(appAt("2026-11-16T15:00:00Z"), "/v1/members-elect/el-sayed")).status).toBe(400);
  });
});

describe("members-elect beside the members they replace", () => {
  const michigan: DistrictMatch = { congress: 119, state: "MI", stateFips: "26", district: 11, countyFips: "26125" };

  it("/v1/reps tags the leaving senator and adds the elect for the caller's seats", async () => {
    const { body } = await json(appAt("2026-11-16T15:00:00Z", { district: michigan }), "/v1/reps?address=1%20Main%20St%2C%20Troy%20MI");
    expect(body.members).toEqual([{ ...peters, leavingOn: "2027-01-03" }]);
    expect(body.elect).toEqual([elSayed]);
    expect(body.pending).toEqual([]);
  });

  it("/v1/reps for an at-large seat shows the Clerk's member-elect", async () => {
    const alaska: DistrictMatch = { congress: 118, state: "AK", stateFips: "02", district: 0, countyFips: "02020" };
    const { body } = await json(appAt("2024-12-31T15:00:00Z", { district: alaska }), "/v1/reps?address=1%20Main%20St%2C%20Anchorage%20AK");
    expect(body.members).toEqual([{ ...peltola, leavingOn: "2025-01-03" }]);
    expect(body.elect.map((e: MemberElect) => [e.id, e.bioguideId, e.call.by, e.call.sourceUrl, e.replaces?.bioguideId])).toEqual([
      ["elect-2024-ak-al", "B001323", "House Clerk", CLERK_119, "P000619"],
    ]);
  });

  it("/v1/members finds elects by state, seat and name, and drops every trace on January 3", async () => {
    const app = appAt("2026-11-16T15:00:00Z");
    const mi = (await json(app, "/v1/members?q=Michigan")).body;
    expect(mi.members).toEqual([{ ...peters, leavingOn: "2027-01-03" }]);
    expect(mi.elect).toEqual([elSayed]);
    expect((await json(app, "/v1/members?q=el%20sayed")).body.elect).toEqual([elSayed]);
    expect((await json(app, "/v1/members?q=MI&chamber=house")).body.elect).toEqual([]);
    const after = (await json(appAt("2027-01-03T15:00:00Z"), "/v1/members?q=Michigan")).body;
    expect(after).toEqual({ members: [{ ...peters, leavingOn: null }], elect: [], pending: [] });
    expect((await json(appAt("2027-01-03T15:00:00Z"), "/v1/members/P000595")).body.member.leavingOn).toBeNull();
    expect((await json(app, "/v1/members/P000595")).body.member.leavingOn).toBe("2027-01-03");
  });
});

describe("pgElect", () => {
  it("answers none, not a 500, on a database without the migration", async () => {
    await pg.exec("alter table disclosure_filings drop column elect_id; drop table members_elect, seats_pending");
    const app = appAt("2026-11-16T15:00:00Z");
    expect((await json(app, "/v1/members-elect")).body).toEqual({ elect: [], pending: [] });
    expect((await json(app, "/v1/members/P000595")).body.member.leavingOn).toBeNull();
  });
});

describe("electFor", () => {
  const begich: MemberElect = { ...elSayed, id: "elect-2024-ak-al", state: "AK", district: 0, chamber: "house", lastName: "Begich", firstName: "Nicholas" };
  const seats = { elect: [elSayed, begich], pending: [] };
  it("reads a seat, a state and a name the way member search does", () => {
    expect(electFor(seats, parseMemberQuery("AK-AL")).elect.map((e) => e.id)).toEqual(["elect-2024-ak-al"]);
    expect(electFor(seats, parseMemberQuery("ak 1")).elect.map((e) => e.id)).toEqual([]);
    expect(electFor(seats, parseMemberQuery("Alaska")).elect.map((e) => e.id)).toEqual(["elect-2024-ak-al"]);
    expect(electFor(seats, parseMemberQuery("abdul")).elect.map((e) => e.id)).toEqual(["elect-2026-mi-sen"]);
    expect(electFor(seats, { kind: "reps", state: "MI", district: 11 }).elect.map((e) => e.id)).toEqual(["elect-2026-mi-sen"]);
    expect(electFor(seats, { kind: "all" }, "house").elect.map((e) => e.id)).toEqual(["elect-2024-ak-al"]);
  });
});
