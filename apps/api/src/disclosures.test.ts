import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { beforeAll, describe, expect, it } from "vitest";
import {
  DISCLOSURES_OFF_REASON,
  NO_CONTACT,
  createApp,
  type AppDeps,
  type DisclosureRepository,
  type Member,
} from "./app.js";
import { pgDisclosures, type Db } from "./pg.js";

const member: Member = {
  bioguideId: "A000055",
  firstName: "Robert",
  lastName: "Aderholt",
  party: "R",
  state: "AL",
  district: 4,
  chamber: "house",
} as Member;

function deps(over: Partial<AppDeps>): AppDeps {
  return {
    votes: {
      getVote: async () => null,
      recentVotes: async () => [],
      voteBreakdown: async () => ({
        partyTotals: [],
        candidateTotals: [],
        positions: [],
        measure: null,
      }),
    },
    members: {
      membersFor: async () => [],
      recentVotes: async () => [],
      getMember: async (id) => (id === member.bioguideId ? member : null),
      search: async () => [],
      partyLoyalty: async () => ({ votes: 0, withParty: 0, againstParty: 0 }),
      funding: async () => null,
      contact: async () => NO_CONTACT,
    },
    bills: { getBill: async () => null, getAnalysis: async () => null },
    nominations: { getNomination: async () => null },
    status: { lastRuns: async () => [] },
    live: { chambers: async () => [], liveVotes: async () => [] },
    locate: async () => null,
    ...over,
  };
}

describe("GET /v1/members/{id}/disclosures", () => {
  const calls: string[] = [];
  const repo: DisclosureRepository = {
    disclosures: async (id) => {
      calls.push(id);
      return { deadlineDays: 45, annual: null, trades: [], paperFilings: [] };
    },
  };

  it("is off by default: says why, carries no data and reads nothing", async () => {
    calls.length = 0;
    const res = await createApp(deps({ disclosures: repo })).request(
      "/v1/members/A000055/disclosures",
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      enabled: false,
      reason: DISCLOSURES_OFF_REASON,
    });
    expect(calls).toEqual([]);
  });

  it("stays off with the flag set but no repository", async () => {
    const res = await createApp(deps({ disclosuresEnabled: true })).request(
      "/v1/members/A000055/disclosures",
    );
    expect((await res.json()).enabled).toBe(false);
  });

  it("serves the repository's answer once enabled, and 404s an unknown member", async () => {
    const app = createApp(
      deps({ disclosures: repo, disclosuresEnabled: true }),
    );
    const res = await app.request("/v1/members/A000055/disclosures");
    expect(await res.json()).toEqual({
      enabled: true,
      deadlineDays: 45,
      annual: null,
      trades: [],
      paperFilings: [],
    });
    expect((await app.request("/v1/members/Z999999/disclosures")).status).toBe(
      404,
    );
  });

  it("is in the OpenAPI document", async () => {
    const doc = await (
      await createApp(deps({})).request("/openapi.json")
    ).json();
    expect(doc.paths["/v1/members/{id}/disclosures"]).toBeDefined();
    expect(doc.components.schemas.Disclosures.properties.trades).toBeDefined();
  });
});

describe("pgDisclosures", () => {
  let repo: DisclosureRepository;
  const now = new Date("2026-11-14T12:00:00Z");

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
        ('A000055', 'Robert', 'Aderholt', 'R', 'AL', 4, 'house', '2025-01-03', '2027-01-03'),
        ('P000001', 'Paper', 'Filer', 'D', 'NY', 1, 'house', '2025-01-03', '2027-01-03'),
        ('T000001', 'Trans', 'Cribed', 'D', 'NY', 12, 'house', '2025-01-03', '2027-01-03');
      insert into disclosure_filings (id, chamber, member_id, filer_name, kind, amendment, report_year, filed_on, source_url, format, parse_status) values
        ('house-1', 'house', 'A000055', 'Robert B. Aderholt', 'annual', false, 2024, '2025-05-15', 'https://x/1.pdf', 'electronic', 'parsed'),
        ('house-2', 'house', 'A000055', 'Robert B. Aderholt', 'annual', false, 2025, '2026-08-13', 'https://x/2.pdf', 'electronic', 'parsed'),
        ('house-3', 'house', 'A000055', 'Robert B. Aderholt', 'ptr', false, null, '2025-09-10', 'https://x/3.pdf', 'electronic', 'parsed'),
        ('house-4', 'house', 'A000055', 'Robert B. Aderholt', 'ptr', false, null, '2025-06-01', 'https://x/4.pdf', 'electronic', 'parsed'),
        ('house-5', 'house', 'A000055', 'Robert B. Aderholt', 'ptr', false, null, '2026-02-01', 'https://x/5.pdf', 'paper', 'paper'),
        ('house-6', 'house', 'P000001', 'Paper Filer', 'annual', false, 2024, '2025-05-15', 'https://x/6.pdf', 'electronic', 'parsed'),
        ('house-7', 'house', 'P000001', 'Paper Filer', 'annual', false, 2025, '2026-05-15', 'https://x/7.pdf', 'paper', 'paper'),
        ('house-8', 'house', 'T000001', 'Trans Cribed', 'annual', false, 2025, '2026-05-14', 'https://x/8.pdf', 'paper', 'parsed');
      update disclosure_filings set transcribed_by = 'ai' where id = 'house-8';
      insert into disclosure_assets (filing_id, position, name, owner, value_range) values
        ('house-8', 1, 'Citizens Bank', 'self', '$1,001 - $15,000');
      insert into disclosure_assets (filing_id, position, name, asset_type, asset_type_code, owner, value_range) values
        ('house-1', 1, 'Old Report Asset', 'Stocks (including ADRs)', 'ST', 'self', '$1,001 - $15,000'),
        ('house-2', 2, 'Bank Independent - ***0165D', 'Bank Accounts, Money Market Accounts and CDs', 'BA', 'self', '$15,001 - $50,000'),
        ('house-2', 1, 'abrdn Healthcare Investors (HQH)', 'Stocks (including ADRs)', 'ST', 'self', '$15,001 - $50,000'),
        ('house-6', 1, 'Older Electronic Asset', null, null, 'self', '$1,001 - $15,000');
      insert into disclosure_transactions (filing_id, position, owner, asset_name, ticker, tx_type, tx_type_filed, amount_range, transacted_on, notified_on) values
        ('house-3', 1, 'self', 'GSK plc American Depositary Shares (GSK)', 'GSK', 'sell', 'S', '$1,001 - $15,000', '2025-07-28', '2025-08-11'),
        ('house-3', 2, 'spouse', 'Late Trade', null, 'buy', 'P', '$15,001 - $50,000', '2025-01-02', null),
        ('house-4', 1, 'self', 'Too Old', null, 'buy', 'P', '$1,001 - $15,000', '2025-05-01', null);
    `);
    repo = pgDisclosures(pg as unknown as Db);
  });

  it("serves the latest annual report's assets in filing order, ranges as filed", async () => {
    const d = await repo.disclosures("A000055", now);
    expect(d.annual).toMatchObject({
      year: 2025,
      filedAt: "2026-08-13",
      amendment: false,
      sourceUrl: "https://x/2.pdf",
      transcribed: false,
    });
    expect(d.annual?.assets.map((a) => [a.name, a.value, a.typeCode])).toEqual([
      ["abrdn Healthcare Investors (HQH)", "$15,001 - $50,000", "ST"],
      ["Bank Independent - ***0165D", "$15,001 - $50,000", "BA"],
    ]);
  });

  it("marks an annual report Floor's AI transcribed from paper, and serves its rows like any other", async () => {
    const d = await repo.disclosures("T000001", now);
    expect(d.annual).toMatchObject({ year: 2025, transcribed: true, sourceUrl: "https://x/8.pdf" });
    expect(d.annual?.assets.map((a) => [a.name, a.value, a.type])).toEqual([["Citizens Bank", "$1,001 - $15,000", null]]);
    expect(d.paperFilings).toEqual([]);
  });

  it("serves a year of trades with the days to file against the 45-day limit", async () => {
    const d = await repo.disclosures(
      "A000055",
      new Date("2026-07-01T00:00:00Z"),
    );
    // "Late Trade" (2025-01-02) and "Too Old" (2025-05-01) are more than 12 months before 2026-07-01.
    expect(
      d.trades.map((t) => [
        t.asset,
        t.transactedAt,
        t.filedAt,
        t.daysToFile,
        t.pastDeadline,
      ]),
    ).toEqual([
      [
        "GSK plc American Depositary Shares (GSK)",
        "2025-07-28",
        "2025-09-10",
        44,
        false,
      ],
    ]);
    expect(d.trades[0]).toMatchObject({
      type: "sell",
      typeFiled: "S",
      notifiedAt: "2025-08-11",
      owner: "self",
    });
    const later = await repo.disclosures(
      "A000055",
      new Date("2025-09-30T00:00:00Z"),
    );
    expect(
      later.trades.map((t) => [t.asset, t.daysToFile, t.pastDeadline]),
    ).toEqual([
      ["GSK plc American Depositary Shares (GSK)", 44, false],
      ["Too Old", 31, false],
      ["Late Trade", 251, true],
    ]);
  });

  it("lists scans in the window as paper filings", async () => {
    const d = await repo.disclosures("A000055", now);
    expect(d.paperFilings).toEqual([
      {
        kind: "ptr",
        reportYear: null,
        filedAt: "2026-02-01",
        sourceUrl: "https://x/5.pdf",
        status: "paper",
      },
    ]);
  });

  it("does not stand an older report in for a latest one that is a scan", async () => {
    const d = await repo.disclosures("P000001", now);
    expect(d.annual).toBeNull();
    expect(d.paperFilings).toEqual([
      {
        kind: "annual",
        reportYear: 2025,
        filedAt: "2026-05-15",
        sourceUrl: "https://x/7.pdf",
        status: "paper",
      },
    ]);
  });

  it("answers empty for a member with no filings", async () => {
    expect(await repo.disclosures("Z000000", now)).toEqual({
      deadlineDays: 45,
      annual: null,
      trades: [],
      paperFilings: [],
    });
  });
});
