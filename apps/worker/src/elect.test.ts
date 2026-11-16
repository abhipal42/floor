import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { strToU8, zipSync } from "fflate";
import { beforeEach, describe, expect, it } from "vitest";
import type { Db } from "./db.js";
import { memoryCache, Throttle } from "./disclosures.js";
import { parseHouseIndex } from "./disclosures-house.js";
import { CANDIDATE_KINDS } from "./disclosures-house.js";
import {
  checkElections,
  clerkElectUrl,
  cycleOf,
  electId,
  electionDay,
  ingestElectDisclosures,
  ingestHouseMembersElect,
  loadElections,
  matchCandidateReport,
  matchIncumbent,
  parseClerkMembers,
  readElections,
  sameFirstName,
  type Elections,
} from "./elect.js";
import { ingestFecElect } from "./fec.js";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = (path: string) => readFileSync(join(here, "../fixtures", path));
const clerk119 = fixture("elect/clerk-119-excerpt.xml").toString("utf8");

const SOURCE =
  "https://www.wsbtv.com/news/trending/election-2026-abdul-el-sayed-prevails-win-us-senate-seat-michigan/DGWW7OLFAVCKBH3ZXXU5Y46YVE/";
const michigan = {
  state: "MI",
  special: false,
  incumbent: { name: "Gary Peters", party: "D", running: false },
  status: "called",
  winner: { firstName: "Abdul", lastName: "El-Sayed", party: "D", isIncumbent: false, fecCandidateId: "S6MI00418" },
  calledBy: "AP",
  calledOn: "2026-11-04",
  runoffOn: null,
  sourceUrl: SOURCE,
  note: null,
};

async function freshDb() {
  const pg = new PGlite();
  await pg.exec(`create schema auth; create table auth.users (id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;`);
  for (const m of loadMigrations()) await pg.exec(m.sql);
  return pg;
}

describe("the elections files in the repo", () => {
  it("pass the checks, and Michigan is El-Sayed as the AP called it", () => {
    const [e] = readElections(join(here, "../elections"));
    expect(e!.cycle).toBe(2026);
    expect(e!.takesOffice).toBe("2027-01-03");
    const mi = e!.races.find((r) => r.state === "MI")!;
    expect(mi.winner).toEqual(michigan.winner);
    expect([mi.status, mi.calledBy, mi.calledOn]).toEqual(["called", "AP", "2026-11-04"]);
    expect(mi.sourceUrl).toBe("https://apnews.com/projects/elections-2026/michigan-us-senate-results");
    // The whole 2026 Senate map: 33 Class II seats and the Ohio and Florida specials, every one sourced.
    expect(e!.races).toHaveLength(35);
    expect(e!.races.filter((r) => r.status === "called" && !r.winner!.isIncumbent)).toHaveLength(18);
    expect(e!.races.filter((r) => r.status !== "called").map((r) => r.state)).toEqual(["AK"]);
  });
});

describe("checkElections", () => {
  const file = (races: object[], extra: object = {}) => ({ ...extra, races });
  it("allows string notes at the top, and nothing else", () => {
    expect(checkElections(file([michigan], { calledOnBasis: "Eastern Time" }), "2026-senate.json").races).toHaveLength(1);
    expect(() => checkElections(file([michigan], { cycle: 2026 }), "2026-senate.json")).toThrow(/top-level "cycle"/);
    expect(() => checkElections(file([michigan]), "senate.json")).toThrow(/<cycle>-senate.json/);
  });

  it("is strict on race fields", () => {
    const bad = (patch: object) => () => checkElections(file([{ ...michigan, ...patch }]), "2026-senate.json");
    expect(bad({ calledby: "AP" })).toThrow(/unknown calledby/);
    expect(bad({ status: "projected" })).toThrow(/status/);
    expect(bad({ calledBy: "NYT" })).toThrow(/calledBy/);
    expect(bad({ calledOn: "2026-11-31" })).toThrow(/calledOn/);
    expect(bad({ sourceUrl: "http://x" })).toThrow(/https/);
    expect(bad({ winner: { ...michigan.winner, fecCandidateId: "S6OH00418" } })).toThrow(/fecCandidateId/);
    expect(bad({ winner: { ...michigan.winner, middle: "M" } })).toThrow(/unknown middle/);
    expect(bad({ status: "uncalled" })).toThrow(/only a called race/);
    expect(bad({ status: "runoff", winner: null, calledBy: null, calledOn: null })).toThrow(/runoffOn/);
    expect(bad({ winner: { ...michigan.winner, isIncumbent: true } })).toThrow(/no incumbent is running/);
    expect(() => checkElections(file([michigan, michigan]), "2026-senate.json")).toThrow(/second race/);
  });
});

describe("matchIncumbent", () => {
  const senators = [
    { bioguide_id: "P000595", first_name: "Gary", last_name: "Peters", state: "MI", district: null, term_end: "2027-01-03" },
  ];
  it("matches the full name, or a surname that ends it, in the state only", () => {
    expect(matchIncumbent(senators, "MI", "Gary Peters")).toBe("P000595");
    expect(matchIncumbent(senators, "MI", "Gary C. Peters")).toBe("P000595");
    expect(matchIncumbent(senators, "OH", "Gary Peters")).toBeNull();
    expect(matchIncumbent(senators, "MI", "Debbie Stabenow")).toBeNull();
  });
});

describe("loadElections (PGlite)", () => {
  let pg: PGlite;
  let e: Elections;
  beforeEach(async () => {
    pg = await freshDb();
    await pg.exec(`insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end)
                   values ('P000595', 'Gary', 'Peters', 'D', 'MI', null, 'senate', '2021-01-03', '2027-01-03')`);
    e = checkElections({ races: [michigan] }, "2026-senate.json");
  });

  it("stores the AP call replacing the outgoing senator, and a reload replaces rather than adds", async () => {
    expect(await loadElections(pg as unknown as Db, e)).toEqual({ elect: 1, pending: 0, unmatched: [] });
    await pg.exec("update members_elect set receipts = 53830872 where id = 'elect-2026-mi-sen'");
    await loadElections(pg as unknown as Db, e);
    const { rows } = await pg.query(
      `select id, first_name, last_name, party, state, district, chamber, replaces, to_char(takes_office, 'YYYY-MM-DD') as takes_office,
              called_by, to_char(called_on, 'YYYY-MM-DD') as called_on, source_url, fec_candidate_id, receipts from members_elect`,
    );
    expect(rows).toEqual([
      {
        id: "elect-2026-mi-sen", first_name: "Abdul", last_name: "El-Sayed", party: "D", state: "MI", district: null, chamber: "senate",
        replaces: "P000595", takes_office: "2027-01-03", called_by: "AP", called_on: "2026-11-04", source_url: SOURCE,
        fec_candidate_id: "S6MI00418", receipts: "53830872",
      },
    ]);
  });

  it("marks a special election's non-incumbent winner as taking office on certification", async () => {
    const ohio = { ...michigan, state: "OH", special: true, incumbent: { name: "Jon Husted", party: "R", running: true },
      winner: { firstName: "Sherrod", lastName: "Brown", party: "D", isIncumbent: false, fecCandidateId: "S6OH00163" } };
    await loadElections(pg as unknown as Db, checkElections({ races: [michigan, ohio] }, "2026-senate.json"));
    const { rows } = await pg.query("select id, on_certification from members_elect order by id");
    expect(rows).toEqual([{ id: "elect-2026-mi-sen", on_certification: false }, { id: "elect-2026-oh-sen", on_certification: true }]);
  });

  it("keeps an uncalled seat as pending, never with a name, and drops a call taken out of the file", async () => {
    await loadElections(pg as unknown as Db, e);
    const uncalled = { ...michigan, status: "uncalled", winner: null, calledBy: null, calledOn: null };
    const r = await loadElections(pg as unknown as Db, checkElections({ races: [uncalled] }, "2026-senate.json"));
    expect(r).toEqual({ elect: 0, pending: 1, unmatched: [] });
    expect((await pg.query("select id from members_elect")).rows).toEqual([]);
    expect((await pg.query("select id, status, incumbent, runoff_on from seats_pending")).rows).toEqual([
      { id: "elect-2026-mi-sen", status: "uncalled", incumbent: "P000595", runoff_on: null },
    ]);
  });

  it("adds nothing for a seat the incumbent kept", async () => {
    const kept = { ...michigan, incumbent: { ...michigan.incumbent, running: true }, winner: { ...michigan.winner, isIncumbent: true } };
    expect(await loadElections(pg as unknown as Db, checkElections({ races: [kept] }, "2026-senate.json"))).toEqual({ elect: 0, pending: 0, unmatched: [] });
  });
});

describe("the House Clerk's member-elect list (real 119th Congress excerpt)", () => {
  it("parses every seat, at large as district 0 and American Samoa as AS", () => {
    const { congress, members } = parseClerkMembers(clerk119);
    expect(congress).toBe(119);
    expect(members.map((m) => `${m.state}-${m.district} ${m.bioguideId} ${m.lastName}`)).toEqual([
      "AK-0 B001323 Begich",
      "AL-1 M001212 Moore",
      "AL-2 F000481 Figures",
      "AS-0 R000600 Radewagen",
      "CA-47 M001241 Min",
      "NY-12 N000002 Nadler",
    ]);
    expect(members[0]).toMatchObject({ firstName: "Nicholas", party: "R", electedOn: "2024-11-05" });
    expect(cycleOf(119)).toBe(2024);
    expect(cycleOf(120)).toBe(2026);
    expect(electId(2024, "AK", 0)).toBe("elect-2024-ak-al");
  });

  it("stores who is new to their seat, replacing its holder, and skips the re-elected", async () => {
    const pg = await freshDb();
    // The 118th Congress holders of those seats.
    await pg.exec(`insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end) values
      ('P000619', 'Mary', 'Peltola', 'D', 'AK', 0, 'house', '2023-01-03', '2025-01-03'),
      ('C001054', 'Jerry', 'Carl', 'R', 'AL', 1, 'house', '2023-01-03', '2025-01-03'),
      ('M001212', 'Barry', 'Moore', 'R', 'AL', 2, 'house', '2023-01-03', '2025-01-03'),
      ('R000600', 'Aumua Amata', 'Radewagen', 'R', 'AS', 0, 'house', '2023-01-03', '2025-01-03'),
      ('P000618', 'Katie', 'Porter', 'D', 'CA', 47, 'house', '2023-01-03', '2025-01-03'),
      ('N000002', 'Jerrold', 'Nadler', 'D', 'NY', 12, 'house', '2023-01-03', '2025-01-03')`);
    const fetchImpl = (async (url: string) =>
      url === clerkElectUrl(119) ? new Response(clerk119) : new Response("", { status: 404 })) as unknown as typeof fetch;
    const r = await ingestHouseMembersElect(pg as unknown as Db, 119, { fetchImpl });
    expect(r).toEqual({ published: true, listed: 6, reElected: 2, elect: 4 });
    const { rows } = await pg.query(
      "select id, bioguide_id, replaces, called_by, to_char(called_on, 'YYYY-MM-DD') as called_on, source_url from members_elect order by id",
    );
    const url = "https://clerk.house.gov/xml/lists/unofficial-119-member-elect-data.xml";
    expect(rows).toEqual([
      { id: "elect-2024-ak-al", bioguide_id: "B001323", replaces: "P000619", called_by: "House Clerk", called_on: "2024-11-05", source_url: url },
      // Moore moved seats in the 2024 map: he is new to AL-1, and Figures replaces him in AL-2.
      { id: "elect-2024-al-1", bioguide_id: "M001212", replaces: "C001054", called_by: "House Clerk", called_on: "2024-11-05", source_url: url },
      { id: "elect-2024-al-2", bioguide_id: "F000481", replaces: "M001212", called_by: "House Clerk", called_on: "2024-11-05", source_url: url },
      { id: "elect-2024-ca-47", bioguide_id: "M001241", replaces: "P000618", called_by: "House Clerk", called_on: "2024-11-05", source_url: url },
    ]);
    // Idempotent.
    await ingestHouseMembersElect(pg as unknown as Db, 119, { fetchImpl });
    expect((await pg.query("select count(*)::int as n from members_elect")).rows).toEqual([{ n: 4 }]);
  });

  it("says the list is not published yet on a 404, and stores nothing", async () => {
    const pg = await freshDb();
    const logs: string[] = [];
    const fetchImpl = (async () => new Response("", { status: 404 })) as unknown as typeof fetch;
    const r = await ingestHouseMembersElect(pg as unknown as Db, 120, { fetchImpl, log: (m) => logs.push(m) });
    expect(r.published).toBe(false);
    expect(logs).toEqual(["The Clerk's member-elect list for the 120th Congress is not published yet"]);
  });
});

describe("ingestFecElect (PGlite, recorded client)", () => {
  it("fills raised, spent and coverage for elects with an FEC ID, and skips them for a day after", async () => {
    const pg = await freshDb();
    await pg.exec(`insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end)
                   values ('P000595', 'Gary', 'Peters', 'D', 'MI', null, 'senate', '2021-01-03', '2099-01-03')`);
    // takes_office in the future so the test does not expire: the loader only refreshes elects not yet seated.
    await loadElections(pg as unknown as Db, { ...checkElections({ races: [michigan] }, "2026-senate.json"), takesOffice: "2099-01-03" });
    const paths: string[] = [];
    // The figures the FEC reported for El-Sayed's campaign through 2026-10-14.
    const get = async (path: string) => {
      paths.push(path);
      return { results: [{ receipts: 53830872, disbursements: 51096843, coverage_end_date: "2026-10-14T00:00:00" }] };
    };
    expect(await ingestFecElect(pg as unknown as Db, get)).toEqual({ loaded: 1, noTotals: 0, failed: 0 });
    expect(paths).toEqual(["/candidate/S6MI00418/totals/?cycle=2026"]);
    const { rows } = await pg.query(
      "select receipts, disbursements, to_char(coverage_end, 'YYYY-MM-DD') as coverage_end, finance_cycle from members_elect",
    );
    expect(rows).toEqual([{ receipts: "53830872", disbursements: "51096843", coverage_end: "2026-10-14", finance_cycle: 2026 }]);
    expect(await ingestFecElect(pg as unknown as Db, get)).toEqual({ loaded: 0, noTotals: 0, failed: 0 });
  });
});

describe("candidate reports for House members-elect", () => {
  // The real 2025 index excerpt; the seats asked about are inputs to the matcher, not claims about any race.
  const listed = parseHouseIndex(fixture("disclosures/house-2025FD-excerpt.txt").toString("utf8"), CANDIDATE_KINDS);
  const seat = { id: "elect-x-az-1", first_name: "David", last_name: "Redkey", state: "AZ", district: 1 };

  it("lists only candidate reports, once per DocID", () => {
    expect(listed.every((f) => f.kind === "annual" && !f.amendment)).toBe(true);
    expect(listed.filter((f) => f.id === "house-10072224")).toHaveLength(1);
  });

  it("needs the exact surname and the seat; anything else is no match", () => {
    expect(matchCandidateReport(seat, listed)?.id).toBe("house-10072224");
    expect(matchCandidateReport({ ...seat, district: 2 }, listed)).toBeNull();
    expect(matchCandidateReport({ ...seat, state: "NV" }, listed)).toBeNull();
    expect(matchCandidateReport({ ...seat, last_name: "Redke" }, listed)).toBeNull();
  });

  it("stores the report under the elect with no member, and parses it", async () => {
    const pg = await freshDb();
    // A stand-in elect row for the plumbing, and a real electronic House report standing in for the
    // candidate template (both have the same Schedule A).
    await pg.exec(`insert into members_elect (id, cycle, first_name, last_name, party, state, district, chamber, takes_office, called_by, source_url)
      values ('elect-x-az-1', 2026, 'David', 'Redkey', 'R', 'AZ', 1, 'house', '2099-01-03', 'House Clerk', 'https://clerk.house.gov/')`);
    const zip = zipSync({ "2025FD.txt": strToU8(fixture("disclosures/house-2025FD-excerpt.txt").toString("utf8")) });
    const pdf = "https://disclosures-clerk.house.gov/public_disc/financial-pdfs/2025/10072224.pdf";
    const fetchImpl = (async (url: string) =>
      url.endsWith("2025FD.zip")
        ? new Response(zip)
        : url === pdf
          ? new Response(fixture("disclosures/house-annual-10078366.pdf"))
          : new Response("", { status: 404 })) as unknown as typeof fetch;
    const r = await ingestElectDisclosures(pg as unknown as Db, {
      years: [2025],
      budget: 10,
      cache: memoryCache(),
      throttle: new Throttle(0, 10, async () => {}),
      fetchImpl,
    });
    expect(r).toMatchObject({ elects: 1, matched: 1, parsed: 1, failed: 0 });
    const { rows } = await pg.query<{ member_id: string | null; elect_id: string; parse_status: string; n: number }>(
      `select member_id, elect_id, parse_status, (select count(*)::int from disclosure_assets a where a.filing_id = f.id) as n
         from disclosure_filings f`,
    );
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ member_id: null, elect_id: "elect-x-az-1", parse_status: "parsed" });
    expect(rows[0]!.n).toBeGreaterThan(0);
  });

  it("downloads nothing when there is no House member-elect", async () => {
    const pg = await freshDb();
    const fetchImpl = (async () => {
      throw new Error("should not fetch");
    }) as unknown as typeof fetch;
    expect(await ingestElectDisclosures(pg as unknown as Db, { years: [2025], budget: 10, fetchImpl })).toMatchObject({ elects: 0, requests: 0 });
  });
});

// ---------------------------------------------------------------------------------------------
// Review fixes (each failed before its fix)

const senators2026: { bioguide_id: string; first_name: string; last_name: string; party: string; state: string; term_start: string; term_end: string }[] =
  JSON.parse(fixture("elect/senators-2026.json").toString("utf8"));
async function seedSenators(pg: PGlite, states?: string[]) {
  const rows = senators2026.filter((r) => !states || states.includes(r.state));
  await pg.query(
    `insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end)
     select bioguide_id, first_name, last_name, party, state, null, 'senate', term_start, term_end
       from jsonb_to_recordset($1::jsonb) as x(bioguide_id text, first_name text, last_name text, party text, state text, term_start date, term_end date)`,
    [JSON.stringify(rows)],
  );
}
const replacesOf = async (pg: PGlite) =>
  Object.fromEntries((await pg.query<{ state: string; replaces: string | null }>("select state, replaces from members_elect")).rows.map((r) => [r.state, r.replaces]));

describe("incumbents are senators sitting on election day (prod's members rows)", () => {
  it("election day is the Tuesday after the first Monday in November", () => {
    expect([electionDay(2024), electionDay(2026), electionDay(2028)]).toEqual(["2024-11-05", "2026-11-03", "2028-11-07"]);
  });

  it("South Carolina: Darline Graham is the appointee Graham Nordone, not Lindsey Graham who resigned", async () => {
    const pg = await freshDb();
    await seedSenators(pg, ["SC", "OK"]);
    const race = (state: string, incumbent: string) => ({ ...michigan, state, incumbent: { name: incumbent, party: "R", running: false }, winner: { ...michigan.winner, fecCandidateId: null } });
    const r = await loadElections(pg as unknown as Db, checkElections({ races: [race("SC", "Darline Graham"), race("OK", "Alan Armstrong")] }, "2026-senate.json"));
    expect(r.unmatched).toEqual([]);
    expect(await replacesOf(pg)).toEqual({ SC: "G000608", OK: "A000383" });
  });

  it("every senator-elect in 2026-senate.json replaces a senator sitting on election day", async () => {
    const pg = await freshDb();
    await seedSenators(pg);
    const [e] = readElections(join(here, "../elections"));
    const r = await loadElections(pg as unknown as Db, e!);
    expect(r).toMatchObject({ elect: 18, unmatched: [] });
    const sitting = new Set(senators2026.filter((m) => m.term_start <= "2026-11-03" && m.term_end >= "2026-11-03").map((m) => m.bioguide_id));
    const replaces = await replacesOf(pg);
    expect(Object.keys(replaces)).toHaveLength(18);
    for (const [state, id] of Object.entries(replaces)) expect(id !== null && sitting.has(id), state).toBe(true);
    expect([replaces["OH"], replaces["IL"], replaces["SC"], replaces["OK"]]).toEqual(["H001104", "D000563", "G000608", "A000383"]);
  });
});

describe("a seat's elect changing person", () => {
  it("drops the old person's FEC totals when the FEC ID or name changes, and keeps them otherwise", async () => {
    const pg = await freshDb();
    await seedSenators(pg, ["MI"]);
    const e = checkElections({ races: [michigan] }, "2026-senate.json");
    await loadElections(pg as unknown as Db, e);
    await pg.exec("update members_elect set receipts = 53830872, finance_cycle = 2026, finance_fetched_at = now()");
    await loadElections(pg as unknown as Db, e);
    expect((await pg.query("select receipts from members_elect")).rows).toEqual([{ receipts: "53830872" }]);
    // The same seat now naming a different FEC candidate (a corrected file): the old totals are not theirs.
    const other = checkElections({ races: [{ ...michigan, winner: { ...michigan.winner, fecCandidateId: "S6MI00001" } }] }, "2026-senate.json");
    await loadElections(pg as unknown as Db, other);
    expect((await pg.query("select receipts, finance_cycle, finance_fetched_at from members_elect")).rows).toEqual([
      { receipts: null, finance_cycle: null, finance_fetched_at: null },
    ]);
  });

  it("detaches the old person's candidate report when the Clerk lists someone else for the seat", async () => {
    const pg = await freshDb();
    // A stand-in earlier row for AK-AL naming someone other than Begich, with a report and totals attached.
    await pg.exec(`
      insert into members_elect (id, cycle, bioguide_id, first_name, last_name, party, state, district, chamber, takes_office, called_by,
                                 source_url, receipts, finance_cycle)
        values ('elect-2024-ak-al', 2024, 'X000009', 'Someone', 'Else', 'D', 'AK', 0, 'house', '2025-01-03', 'House Clerk', 'https://clerk.house.gov/', 1, 2024);
      insert into disclosure_filings (id, chamber, filer_name, kind, source_url, elect_id)
        values ('house-test-1', 'house', 'Someone Else', 'annual', 'https://example.test/1.pdf', 'elect-2024-ak-al');`);
    const fetchImpl = (async () => new Response(clerk119)) as unknown as typeof fetch;
    await ingestHouseMembersElect(pg as unknown as Db, 119, { fetchImpl });
    expect((await pg.query("select bioguide_id, receipts from members_elect where id = 'elect-2024-ak-al'")).rows).toEqual([{ bioguide_id: "B001323", receipts: null }]);
    expect((await pg.query("select elect_id from disclosure_filings")).rows).toEqual([{ elect_id: null }]);
  });

  it("detaches a report when the seat's elect no longer matches any candidate report", async () => {
    const pg = await freshDb();
    await pg.exec(`
      insert into members_elect (id, cycle, first_name, last_name, party, state, district, chamber, takes_office, called_by, source_url)
        values ('elect-x-az-1', 2026, 'Someone', 'Else', 'R', 'AZ', 1, 'house', '2099-01-03', 'House Clerk', 'https://clerk.house.gov/');
      insert into disclosure_filings (id, chamber, filer_name, kind, source_url, elect_id)
        values ('house-10072224', 'house', 'David Wayne Redkey', 'annual', 'https://example.test/1.pdf', 'elect-x-az-1');`);
    const zip = zipSync({ "2025FD.txt": strToU8(fixture("disclosures/house-2025FD-excerpt.txt").toString("utf8")) });
    const fetchImpl = (async (url: string) => (url.endsWith("2025FD.zip") ? new Response(zip) : new Response("", { status: 404 }))) as unknown as typeof fetch;
    const r = await ingestElectDisclosures(pg as unknown as Db, { years: [2025], budget: 10, cache: memoryCache(), throttle: new Throttle(0, 10, async () => {}), fetchImpl });
    expect(r.matched).toBe(0);
    expect((await pg.query("select elect_id from disclosure_filings")).rows).toEqual([{ elect_id: null }]);
  });
});

describe("candidate reports need the first name too", () => {
  const listed = parseHouseIndex(fixture("disclosures/house-2025FD-excerpt.txt").toString("utf8"), CANDIDATE_KINDS);
  const seat = { id: "elect-x-az-1", first_name: "David", last_name: "Redkey", state: "AZ", district: 1 };
  it("skips a surname-only match, and accepts an initial only where one side gives just that", () => {
    expect(matchCandidateReport({ ...seat, first_name: "Daniel" }, listed)).toBeNull();
    expect(matchCandidateReport({ ...seat, first_name: "D." }, listed)?.id).toBe("house-10072224");
    expect(sameFirstName("David Wayne", "David")).toBe(true);
    expect(sameFirstName("Dave", "David")).toBe(false);
    expect(sameFirstName("D", "David")).toBe(true);
    expect(sameFirstName("", "David")).toBe(false);
  });
});

describe("a Clerk entry with no bioguide ID", () => {
  it("is skipped and named, and the rest of the list loads", async () => {
    const vacant = clerk119.replace("<bioguideID>B001323</bioguideID>", "<bioguideID/>");
    const parsed = parseClerkMembers(vacant);
    expect(parsed.members.map((m) => m.bioguideId)).not.toContain("B001323");
    expect(parsed.members).toHaveLength(5);
    expect(parsed.skipped).toEqual(["AK00 Begich, Nicholas"]);
    const pg = await freshDb();
    const logs: string[] = [];
    const r = await ingestHouseMembersElect(pg as unknown as Db, 119, { fetchImpl: (async () => new Response(vacant)) as unknown as typeof fetch, log: (m) => logs.push(m) });
    expect(r.listed).toBe(5);
    expect(logs).toContain("AK00 Begich, Nicholas: no bioguide ID in the Clerk's list; skipped");
  });
});
