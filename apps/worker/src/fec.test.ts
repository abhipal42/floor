import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { strToU8, zipSync } from "fflate";
import { beforeAll, describe, expect, it } from "vitest";
import type { Db } from "./db.js";
import {
  aggregatePacContributions,
  bulkUrl,
  campaignCycle,
  fecClient,
  ingestFecTotals,
  ingestPacContributions,
  isPac,
  parseCommitteeMaster,
  pickCandidateId,
  toFinanceRow,
} from "./fec.js";

const here = dirname(fileURLToPath(import.meta.url));
const read = (name: string) => readFileSync(join(here, "../fixtures/fec", name), "utf8");
const jeffries = JSON.parse(read("totals-jeffries-2026.json"));
const schumer = JSON.parse(read("totals-schumer-2028.json"));
const pas2 = read("itpas2-excerpt.txt");
const cm = read("cm-excerpt.txt");
const candidates = new Map([
  ["H2NY10092", "J000294"],
  ["S8NY00082", "S000148"],
  ["H0NY16010", "S000148"],
]);

describe("candidate IDs and cycles", () => {
  it("picks the ID for the seat held now, in the member's state", () => {
    expect(pickCandidateId({ chamber: "senate", state: "WA", fec: ["S8WA00194", "H2WA01054"] })).toBe("S8WA00194");
    expect(pickCandidateId({ chamber: "house", state: "WA", fec: ["S8WA00194", "H2WA01054"] })).toBe("H2WA01054");
    expect(pickCandidateId({ chamber: "senate", state: "NY", fec: ["H2NY10092"] })).toBeNull();
  });

  it("uses the election the current term ends with", () => {
    expect(campaignCycle("2027-01-03")).toBe(2026);
    expect(campaignCycle("2029-01-03")).toBe(2028);
  });
});

describe("toFinanceRow (real OpenFEC totals)", () => {
  it("matches Jeffries' published 2026 figures", () => {
    expect(toFinanceRow("J000294", "H2NY10092", 2026, jeffries)).toEqual({
      member_id: "J000294",
      fec_candidate_id: "H2NY10092",
      cycle: 2026,
      coverage_start: "2025-01-01",
      coverage_end: "2026-10-14",
      receipts: 17893352.11,
      individual_unitemized: 8147893.38,
      individual_itemized: 4542828.45,
      pac: 2765400,
      party: 0,
      other: 2437230.28,
      cash_on_hand: 4234848.33,
    });
  });

  it("reads a senator's campaign to date with current cash on hand", () => {
    const row = toFinanceRow("S000148", "S8NY00082", 2028, schumer)!;
    expect(row).toMatchObject({ coverage_start: "2023-01-01", coverage_end: "2026-09-30", cash_on_hand: 7853430.04 });
    expect(row.individual_unitemized + row.individual_itemized + row.pac + row.party + row.other).toBeCloseTo(row.receipts, 2);
  });

  it("returns null when the FEC has no totals", () => {
    expect(toFinanceRow("X", "H0XX00000", 2026, { results: [] })).toBeNull();
  });
});

describe("committee-to-candidate contributions (real FEC bulk excerpt)", () => {
  const totals = aggregatePacContributions(pas2, candidates);
  const committees = parseCommitteeMaster(cm);

  it("reads the committee master", () => {
    expect(committees.get("C00027342")).toEqual({
      name: "INTERNATIONAL BROTHERHOOD OF ELECTRICAL WORKERS POLITICAL ACTION COMMITTEE",
      designation: "B",
      type: "Q",
      orgType: "L",
      connectedOrg: "INTERNATIONAL BROTHERHOOD OF ELECTRICAL WORKERS",
    });
  });

  it("separates earmarked pass-throughs from a committee's own contributions", () => {
    // MORPAC's own checks reach the $10,000 cycle maximum; the rest is individuals' money it forwarded.
    expect(totals.get("J000294")?.get("C00004812")).toEqual({ direct: 10000, earmarked: 30747 });
  });

  // Not a legal invariant: the limit is $5,000 per election, and a cycle can hold a primary, a runoff,
  // the general and old debt (lesson 20). In this excerpt, once earmarks are split out, none exceeds it.
  it("separates earmarks so no PAC in this excerpt shows more than $10,000 direct", () => {
    for (const byCommittee of totals.values()) {
      for (const [id, t] of byCommittee) {
        const c = committees.get(id);
        if (c && isPac(c)) expect(t.direct, id).toBeLessThanOrEqual(10000);
      }
    }
  });

  it("tells PACs apart from party and joint fundraising committees", () => {
    expect(isPac({ designation: "B", type: "Q" })).toBe(true);
    expect(isPac({ designation: "J", type: "N" })).toBe(false);
    expect(isPac({ designation: "U", type: "Y" })).toBe(false);
  });

  it("totals both members and nets voided checks", () => {
    const sum = (m: string) => [...totals.get(m)!.values()].reduce((s, t) => s + t.direct, 0);
    expect(totals.get("J000294")?.size).toBe(435);
    expect(sum("J000294")).toBe(2534100);
    expect(sum("S000148")).toBe(160375);
  });

  it("keeps nothing but amounts: no memo text, so no donor names", () => {
    for (const byCommittee of totals.values()) {
      for (const t of byCommittee.values()) expect(Object.keys(t).sort()).toEqual(["direct", "earmarked"]);
    }
  });
});

describe("fecClient", () => {
  it("waits on a 429 and keeps the key out of errors", async () => {
    const urls: string[] = [];
    const fake = (async (url: string) => {
      urls.push(url);
      if (urls.length === 1) return new Response("slow down", { status: 429 });
      if (url.includes("missing")) return new Response("no", { status: 404 });
      return Response.json({ results: [] });
    }) as unknown as typeof fetch;
    const get = fecClient("SECRET-KEY", fake, 0);
    expect(await get("/candidate/H2NY10092/totals/?cycle=2026")).toEqual({ results: [] });
    expect(urls[0]).toBe("https://api.open.fec.gov/v1/candidate/H2NY10092/totals/?cycle=2026&api_key=SECRET-KEY");
    const err = await get("/missing").catch((e: Error) => e);
    expect((err as Error).message).toBe("OpenFEC /missing returned HTTP 404");
    expect((err as Error).message).not.toContain("SECRET-KEY");
  });
});

describe("ingest into Postgres", () => {
  let pg: PGlite;
  let db: Db;

  beforeAll(async () => {
    pg = new PGlite();
    await pg.exec(`
      create schema auth;
      create table auth.users (id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
    `);
    for (const m of loadMigrations()) await pg.exec(m.sql);
    await pg.exec(`
      insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end, ids) values
        ('J000294', 'Hakeem', 'Jeffries', 'D', 'NY', 8, 'house', '2025-01-03', '2099-01-03', '{"fec":["H2NY10092"]}'),
        ('S000148', 'Chuck', 'Schumer', 'D', 'NY', null, 'senate', '2023-01-03', '2099-01-03', '{"fec":["S8NY00082","H0NY16010"]}'),
        ('X000001', 'No', 'Filings', 'D', 'NY', 9, 'house', '2025-01-03', '2099-01-03', '{}');
    `);
    db = pg as unknown as Db;
  });

  it("loads totals for current members and skips ones without an FEC ID", async () => {
    const paths: string[] = [];
    const result = await ingestFecTotals(db, async (path) => {
      paths.push(path);
      return path.includes("H2NY10092") ? jeffries : schumer;
    });
    expect(result).toEqual({ loaded: 2, noTotals: 0, noCandidateId: 1, failed: 0 });
    expect(paths).toEqual([
      "/candidate/H2NY10092/totals/?cycle=2098&election_full=true",
      "/candidate/S8NY00082/totals/?cycle=2098&election_full=true",
    ]);
    const { rows } = await pg.query<{ member_id: string; pac: string }>("select member_id, pac from campaign_finance order by 1");
    expect(rows).toEqual([
      { member_id: "J000294", pac: "2765400.00" },
      { member_id: "S000148", pac: "365675.00" },
    ]);
  });

  it("skips members refreshed recently", async () => {
    const result = await ingestFecTotals(db, async () => {
      throw new Error("should not be called");
    });
    expect(result.loaded).toBe(0);
  });

  it("loads committee totals from the zipped bulk files", async () => {
    const zip = (name: string, text: string) => zipSync({ [name]: strToU8(text) });
    const urls: string[] = [];
    const result = await ingestPacContributions(db, 2026, {
      fetchBytes: async (url) => {
        urls.push(url);
        return url.includes("pas2") ? zip("itpas2.txt", pas2) : zip("cm.txt", cm);
      },
    });
    expect(urls.sort()).toEqual([bulkUrl(2026, "cm"), bulkUrl(2026, "pas2")].sort());
    expect(result).toEqual({ members: 2, rows: 435 + 44 });
    const { rows } = await pg.query<{ committee_name: string; org_type: string; direct_amount: string }>(
      "select committee_name, org_type, direct_amount from pac_contributions where member_id = 'J000294' and committee_id = 'C00027342'",
    );
    expect(rows).toEqual([
      { committee_name: "INTERNATIONAL BROTHERHOOD OF ELECTRICAL WORKERS POLITICAL ACTION COMMITTEE", org_type: "L", direct_amount: "10000.00" },
    ]);
    // Re-running replaces the cycle's rows rather than adding to them.
    await ingestPacContributions(db, 2026, { fetchBytes: async (url) => (url.includes("pas2") ? zip("itpas2.txt", pas2) : zip("cm.txt", cm)) });
    const { rows: count } = await pg.query<{ n: number }>("select count(*)::int as n from pac_contributions");
    expect(count[0]?.n).toBe(479);
  });
});
