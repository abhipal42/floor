import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { strToU8, zipSync } from "fflate";
import { beforeAll, describe, expect, it } from "vitest";
import type { Db } from "./db.js";
import {
  Throttle,
  ingestDisclosures,
  isoDate,
  matchHouseFiler,
  matchSenateFiler,
  memoryCache,
  normName,
  parseDisclosureArgs,
  type DisclosureSource,
  type MatchMember,
} from "./disclosures.js";
import { houseSource, parseHouseDocument, parseHouseIndex, splitAssetName } from "./disclosures-house.js";
import { parseSenateAnnual, parseSenatePtr, parseSenateRow, senateSource } from "./disclosures-senate.js";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = (name: string) => readFileSync(join(here, "../fixtures/disclosures", name));
const text = (name: string) => fixture(name).toString("utf8");
const bytes = (name: string) => new Uint8Array(fixture(name));

describe("House index (real 2025FD rows)", () => {
  const rows = parseHouseIndex(text("house-2025FD-excerpt.txt"));

  it("keeps member reports only: PTRs, annual reports and amendments", () => {
    expect(new Set(rows.map((r) => r.kind))).toEqual(new Set(["annual", "ptr"]));
    // Aderholt's extension (X) and Aaron's candidate notice (D) are not reports we read.
    expect(rows.find((r) => r.id === "house-30028015")).toBeUndefined();
    expect(rows.find((r) => r.id === "house-40003749")).toBeUndefined();
  });

  it("builds the document URL by type and reads the covered year of an annual report", () => {
    expect(rows.find((r) => r.id === "house-10078366")).toEqual({
      id: "house-10078366",
      chamber: "house",
      filerName: "Robert B. Aderholt",
      first: "Robert B.",
      last: "Aderholt",
      stateDistrict: "AL04",
      kind: "annual",
      amendment: false,
      reportYear: 2025,
      filedOn: "2026-08-13",
      sourceUrl: "https://disclosures-clerk.house.gov/public_disc/financial-pdfs/2025/10078366.pdf",
      format: null,
    });
    expect(rows.find((r) => r.id === "house-20032062")).toMatchObject({
      kind: "ptr",
      reportYear: null,
      filedOn: "2025-09-10",
      sourceUrl: "https://disclosures-clerk.house.gov/public_disc/ptr-pdfs/2025/20032062.pdf",
    });
  });

  it("lists a document the index repeats once", () => {
    const ids = rows.map((r) => r.id);
    expect(ids.filter((id) => id === "house-10078188")).toHaveLength(1);
    expect(new Set(ids).size).toBe(ids.length);
  });
});

describe("House PDFs (real filings)", () => {
  it("reads an electronic PTR: owner, ticker, code, dates and the amount range as filed", async () => {
    const r = await parseHouseDocument("ptr", bytes("house-ptr-20032062.pdf"));
    expect(r).toEqual({
      format: "electronic",
      assets: [],
      trades: [
        {
          owner: "self",
          assetName: "GSK plc American Depositary Shares (GSK)",
          ticker: "GSK",
          assetType: "Stocks (including ADRs)",
          assetTypeCode: "ST",
          txType: "sell",
          txTypeFiled: "S",
          amountRange: "$1,001 - $15,000",
          transactedOn: "2025-07-28",
          notifiedOn: "2025-08-11",
          capGainsOver200: null,
          comment: null,
        },
      ],
    });
  });

  it("reads Schedule A of an annual report across pages, with wrapped names and ranges", async () => {
    const r = await parseHouseDocument("annual", bytes("house-annual-10078366.pdf"));
    if (r.format !== "electronic") throw new Error("expected electronic");
    expect(r.trades).toEqual([]);
    // Every Schedule A row in Aderholt's 2025 report: 154 asset codes and 154 value cells in its text layer.
    expect(r.assets).toHaveLength(154);
    expect(r.assets[0]).toEqual({
      name: "abrdn Healthcare Investors Shares of Beneficial Interest (HQH)",
      assetType: "Stocks (including ADRs)",
      assetTypeCode: "ST",
      account: null,
      owner: "self",
      valueRange: "$15,001 - $50,000",
      incomeType: "Capital Gains, Dividends",
      incomeRange: "$2,501 - $5,000",
      description: null,
    });
    // A range split over two lines, a joint owner, and a description line.
    expect(r.assets.find((a) => a.name === "Bankfirst - ****6664 D")).toMatchObject({
      owner: "joint",
      valueRange: "$100,001 - $250,000",
      incomeRange: "$5,001 - $15,000",
    });
    expect(r.assets.find((a) => a.name.startsWith("Bassett Furniture"))).toMatchObject({
      name: "Bassett Furniture Industries, Incorporated - Common Stock (BSET)",
      valueRange: "$100,001 - $250,000",
      description: "Inherited asset",
    });
    expect(r.assets.find((a) => a.name.startsWith("Elko Mains"))).toMatchObject({
      owner: "spouse",
      assetTypeCode: "OL",
      description: "Location: Huntsville, AL, US · Elko Mains LLC 2004 Old Big Cove Road Huntsville, AL 35801",
    });
    expect(r.assets.find((a) => a.name === "Bankfirst - ******2176 S")).toMatchObject({ owner: "dependent", valueRange: "None" });
    // Ranges only: every value is one of the House's printed bands.
    for (const a of r.assets) expect(a.valueRange ?? "None").toMatch(/^(None|Undetermined|(Spouse\/DC )?Over \$[\d,]+|\$[\d,]+ - \$[\d,]+)$/);
  });

  it("calls a scan with no text layer paper, and reads nothing from it", async () => {
    expect(await parseHouseDocument("ptr", bytes("house-paper-ptr-8220747.pdf"))).toEqual({ format: "paper" });
  });

  it("splits the code and ticker off an asset name, and refuses two assets run together", () => {
    expect(splitAssetName("GSK plc (GSK) [ST]")).toEqual({ name: "GSK plc (GSK)", account: null, ticker: "GSK", code: "ST" });
    expect(splitAssetName("Farm in Iowa")).toEqual({ name: "Farm in Iowa", account: null, ticker: null, code: null });
    // Real rows: a holding inside an account (nested twice), and a code the filer also typed into the name.
    expect(
      splitAssetName("David Taylor Trust ⇒ Schwab Joint Brokerage #2 - (Non- Managed) ⇒ UnitedHealth Group Incorporated Common Stock (UNH) [ST]"),
    ).toEqual({
      name: "UnitedHealth Group Incorporated Common Stock (UNH)",
      account: "David Taylor Trust ⇒ Schwab Joint Brokerage #2 - (Non- Managed)",
      ticker: "UNH",
      code: "ST",
    });
    expect(splitAssetName("Raymond James Brokerage Account ⇒ FIMM Money Market (FNSXX) [BA] [BA]")).toMatchObject({
      name: "FIMM Money Market (FNSXX)",
      account: "Raymond James Brokerage Account",
      code: "BA",
    });
    expect(() => splitAssetName("Apple (AAPL) [ST] Microsoft (MSFT) [ST]")).toThrow(/two assets/);
  });
});

describe("Senate eFD pages (real filings)", () => {
  it("reads an electronic PTR's table", () => {
    const trades = parseSenatePtr(text("senate-ptr-a89c0c6b.html"));
    expect(trades).toHaveLength(4);
    expect(trades[0]).toEqual({
      owner: "spouse",
      assetName: "Zoetis Inc. Class A Common Stock",
      ticker: "ZTS",
      assetType: "Stock",
      assetTypeCode: null,
      txType: "sell",
      txTypeFiled: "Sale (Full)",
      amountRange: "$1,001 - $15,000",
      transactedOn: "2026-10-21",
      notifiedOn: null,
      capGainsOver200: null,
      comment: null,
    });
    expect(trades.map((t) => t.txTypeFiled)).toContain("Sale (Partial)");
  });

  it("reads Part 3 of an annual report, giving a sub-row its parent as account", () => {
    const assets = parseSenateAnnual(text("senate-annual-5a069df5.html"));
    // The page's own count: 171 rows in the report, 150 of them in Part 3 (the rest are Parts 7–9).
    expect(assets).toHaveLength(150);
    expect(assets[3]).toEqual({
      name: "Bank of Monroe",
      assetType: "Bank Deposit",
      assetTypeCode: null,
      account: null,
      owner: "self",
      valueRange: "$1,001 - $15,000",
      incomeType: "None",
      incomeRange: "None (or less than $201)",
      description: "(Lewisburg, WV) Type: Checking",
    });
    const land = assets.find((a) => a.name === "Midelburg Land");
    expect(land).toMatchObject({ assetType: "Real Estate / Unimproved Land", valueRange: "$1,000,001 - $5,000,000" });
    expect(land?.account).toBeTruthy();
  });

  it("reads search rows: kind, year, amendment, and paper reports from the link", () => {
    const page = JSON.parse(text("senate-search-annual.json")) as { data: unknown[][] };
    const rows = page.data.map(parseSenateRow);
    expect(rows[0]).toMatchObject({
      id: "senate-c6b1e74d-4cc1-4411-bb78-b22e8fa01e8e",
      first: "Tim",
      last: "Scott",
      kind: "annual",
      amendment: true,
      reportYear: 2025,
      filedOn: "2026-10-06",
      sourceUrl: "https://efdsearch.senate.gov/search/view/annual/c6b1e74d-4cc1-4411-bb78-b22e8fa01e8e/",
      format: null,
    });
    expect(rows.at(-1)).toMatchObject({ last: "BLUMENTHAL", kind: "annual", format: "paper", reportYear: null });
  });
});

const members: MatchMember[] = [
  { bioguide_id: "A000055", first_name: "Robert", last_name: "Aderholt", state: "AL", district: 4, chamber: "house" },
  { bioguide_id: "A000372", first_name: "Rick", last_name: "Allen", state: "GA", district: 12, chamber: "house" },
  { bioguide_id: "S001184", first_name: "Tim", last_name: "Scott", state: "SC", district: null, chamber: "senate" },
  { bioguide_id: "S001217", first_name: "Rick", last_name: "Scott", state: "FL", district: null, chamber: "senate" },
  { bioguide_id: "J000312", first_name: "Jim", last_name: "Justice", state: "WV", district: null, chamber: "senate" },
  { bioguide_id: "S000510", first_name: "Adam", last_name: "Smith", state: "WA", district: 9, chamber: "house" },
  { bioguide_id: "S001172", first_name: "Adrian", last_name: "Smith", state: "NE", district: 3, chamber: "house" },
  { bioguide_id: "S001195", first_name: "Jason", last_name: "Smith", state: "MO", district: 8, chamber: "house" },
];

describe("matching filers to members", () => {
  it("normalizes accents, suffixes and punctuation", () => {
    expect(normName("Sánchez")).toBe("sanchez");
    expect(normName("Justice, II")).toBe("justice");
    expect(normName("Ocasio-Cortez")).toBe("ocasiocortez");
  });

  it("matches a House filer by seat and surname, and leaves a stranger in the seat unmatched", () => {
    // Real index rows whose surname is split differently from congress-legislators'.
    const split: MatchMember[] = [
      { bioguide_id: "M001232", first_name: "April", last_name: "McClain Delaney", state: "MD", district: 6, chamber: "house" },
      { bioguide_id: "H001091", first_name: "Ashley", last_name: "Hinson", state: "IA", district: 2, chamber: "house" },
      { bioguide_id: "R000600", first_name: "Aumua Amata", last_name: "Radewagen", state: "AS", district: 0, chamber: "house" },
    ];
    expect(matchHouseFiler(split, { last: "Delaney", first: "April McClain", stateDistrict: "MD06" })).toBe("M001232");
    expect(matchHouseFiler(split, { last: "Arenholz", first: "Ashley Hinson", stateDistrict: "IA02" })).toBe("H001091");
    expect(matchHouseFiler(split, { last: "Amata", first: "Aumua", stateDistrict: "AS00" })).toBe("R000600");
    // A real candidate for FL-27: "Arias" is a substring of "Maria Salazar", not one of her names.
    const salazar: MatchMember = { bioguide_id: "S000168", first_name: "Maria", last_name: "Salazar", state: "FL", district: 27, chamber: "house" };
    expect(matchHouseFiler([salazar], { last: "Arias", first: "Vincent Michael", stateDistrict: "FL27" })).toBeNull();
    expect(matchHouseFiler(members, { last: "Aderholt", first: "Robert B.", stateDistrict: "AL04" })).toBe("A000055");
    expect(matchHouseFiler(members, { last: "Allen", first: "Richard W.", stateDistrict: "GA12" })).toBe("A000372");
    // A candidate filing for Aderholt's seat is not Aderholt.
    expect(matchHouseFiler(members, { last: "Jones", first: "Pat", stateDistrict: "AL04" })).toBeNull();
    // A renumbered district: the surname is unique in the state.
    expect(matchHouseFiler(members, { last: "Smith", first: "Adrian", stateDistrict: "NE01" })).toBe("S001172");
    expect(matchHouseFiler(members, { last: "Aderholt", first: "Robert", stateDistrict: "" })).toBeNull();
    // Off the seat a candidate sharing a member's surname but not their first name is not them.
    expect(matchHouseFiler(members, { last: "Smith", first: "Joe", stateDistrict: "NE01" })).toBeNull();
    // Nor is a House candidate who shares a senator's surname.
    expect(matchHouseFiler(members, { last: "Scott", first: "Tim", stateDistrict: "SC01" })).toBeNull();
  });

  it("matches a senator by surname, and by first name only when two share it", () => {
    expect(matchSenateFiler(members, { last: "Justice, II", first: "James Conley" })).toBe("J000312");
    expect(matchSenateFiler(members, { last: "Scott", first: "Tim" })).toBe("S001184");
    expect(matchSenateFiler(members, { last: "Scott", first: "Rick" })).toBe("S001217");
    // "Richard" is not compatible with "Rick" or "Tim": two candidates, no guess.
    expect(matchSenateFiler(members, { last: "Scott", first: "Richard L" })).toBeNull();
    expect(matchSenateFiler(members, { last: "Nobody", first: "Al" })).toBeNull();
  });
});

describe("helpers and options", () => {
  it("reads only real dates", () => {
    expect(isoDate("8/13/2026")).toBe("2026-08-13");
    expect(isoDate("02/30/2026")).toBeNull();
    expect(isoDate("")).toBeNull();
  });

  it("defaults to the last three indexes and 13 months of PTRs", () => {
    expect(parseDisclosureArgs(["house"], new Date("2026-11-14T00:00:00Z"))).toEqual({
      chamber: "house",
      years: [2026, 2025, 2024],
      annualSince: "2024-01-01",
      ptrSince: "2025-10-14",
      budget: 150,
    });
    expect(parseDisclosureArgs(["senate", "--year", "2025", "--budget", "20"], new Date("2026-11-14T00:00:00Z"))).toMatchObject({
      years: [2025],
      ptrSince: "2025-01-01",
      budget: 20,
    });
    expect(() => parseDisclosureArgs(["both"], new Date())).toThrow(/house or senate/);
    expect(() => parseDisclosureArgs(["house", "--budget", "0"], new Date())).toThrow(/positive/);
  });

  it("spaces requests and counts them against the budget", async () => {
    let t = 0;
    const slept: number[] = [];
    const throttle = new Throttle(1500, 2, async (ms) => void slept.push(ms), () => t);
    await throttle.wait();
    t = 500;
    await throttle.wait();
    expect(slept).toEqual([1000]);
    expect(throttle.exhausted).toBe(true);
  });
});

/** A fetch that answers from a table of URL → response and records what was asked. */
function fakeFetch(routes: Record<string, () => Response>) {
  const calls: { url: string; init?: RequestInit }[] = [];
  const impl = (async (url: string, init?: RequestInit) => {
    calls.push({ url, init });
    const route = routes[url];
    return route ? route() : new Response("not found", { status: 404 });
  }) as unknown as typeof fetch;
  return { impl, calls };
}

const noSleep = async () => {};

describe("houseSource", () => {
  it("reads the index from the yearly zip and downloads each document once", async () => {
    const zip = zipSync({ "2025FD.txt": strToU8(text("house-2025FD-excerpt.txt")), "2025FD.xml": strToU8("<x/>") });
    const ptr = "https://disclosures-clerk.house.gov/public_disc/ptr-pdfs/2025/20032062.pdf";
    const { impl, calls } = fakeFetch({
      "https://disclosures-clerk.house.gov/public_disc/financial-pdfs/2025FD.zip": () => new Response(zip),
      [ptr]: () => new Response(bytes("house-ptr-20032062.pdf")),
    });
    const cache = memoryCache();
    const source = houseSource({ years: [2025], ptrSince: "2025-09-01", cache, throttle: new Throttle(0, 10, noSleep), fetchImpl: impl });
    const listed = await source.list();
    // PTRs before ptrSince are dropped; annual reports are kept whatever their date.
    expect(listed.filter((f) => f.kind === "ptr").every((f) => f.filedOn! >= "2025-09-01")).toBe(true);
    expect(listed.some((f) => f.id === "house-10078366")).toBe(true);
    const first = await source.parse({ id: "house-20032062", kind: "ptr", sourceUrl: ptr });
    const again = await source.parse({ id: "house-20032062", kind: "ptr", sourceUrl: ptr });
    expect(again).toEqual(first);
    expect(calls.filter((c) => c.url === ptr)).toHaveLength(1);
    // A generic client name, no personal detail.
    expect((calls[0]!.init!.headers as Record<string, string>)["user-agent"]).toBe("Mozilla/5.0 (compatible; floor-ingest/0.1)");
  });
});

describe("senateSource", () => {
  it("accepts the agreement, then searches with the session's CSRF token", async () => {
    const base = "https://efdsearch.senate.gov";
    const search = JSON.parse(text("senate-search-annual.json"));
    const { impl, calls } = fakeFetch({
      [`${base}/search/home/`]: () =>
        calls.at(-1)!.init?.method === "POST"
          ? new Response(null, { status: 302, headers: [["set-cookie", "sessionid=s1; Path=/"], ["location", "/search/"]] })
          : new Response('<form><input type="hidden" name="csrfmiddlewaretoken" value="formtoken"></form>', {
              headers: [["set-cookie", "csrftoken=cookietoken; Path=/"]],
            }),
      [`${base}/search/report/data/`]: () => new Response(JSON.stringify({ ...search, recordsFiltered: search.data.length })),
      [`${base}/search/view/ptr/a89c0c6b-4c12-4955-98f9-3a54ca52d8a3/`]: () => new Response(text("senate-ptr-a89c0c6b.html")),
    });
    const source = senateSource({
      annualSince: "2024-01-01",
      ptrSince: "2025-10-14",
      cache: memoryCache(),
      throttle: new Throttle(0, 20, noSleep),
      fetchImpl: impl,
    });
    const listed = await source.list();
    expect(listed.length).toBeGreaterThan(0);
    const agree = calls[1]!;
    expect(agree.init?.method).toBe("POST");
    expect(String(agree.init?.body)).toBe("prohibition_agreement=1&csrfmiddlewaretoken=formtoken");
    const data = calls.find((c) => c.url.endsWith("/search/report/data/"))!;
    const headers = data.init!.headers as Record<string, string>;
    expect(headers["x-csrftoken"]).toBe("cookietoken");
    expect(headers.cookie).toContain("sessionid=s1");
    expect(String(data.init!.body)).toContain("report_types=%5B7%5D");
    expect(String(data.init!.body)).toContain("filer_types=%5B1%5D");
    // Paper reports are never fetched.
    expect(await source.parse({ id: "senate-x", kind: "annual", sourceUrl: `${base}/search/view/paper/x/` })).toEqual({ format: "paper" });
    const ptr = await source.parse({
      id: "senate-a89c0c6b-4c12-4955-98f9-3a54ca52d8a3",
      kind: "ptr",
      sourceUrl: `${base}/search/view/ptr/a89c0c6b-4c12-4955-98f9-3a54ca52d8a3/`,
    });
    expect(ptr.format === "electronic" && ptr.trades).toHaveLength(4);
  });
});

describe("ingestDisclosures (PGlite)", () => {
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
      insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end) values
        ('A000055', 'Robert', 'Aderholt', 'R', 'AL', 4, 'house', '2025-01-03', '2027-01-03'),
        ('A000372', 'Rick', 'Allen', 'R', 'GA', 12, 'house', '2025-01-03', '2027-01-03');
    `);
    db = pg as unknown as Db;
  });

  it("stores every listed filing, reads the matched ones newest first within budget, and records the run", async () => {
    const listed = parseHouseIndex(text("house-2025FD-excerpt.txt"));
    const read: string[] = [];
    const throttle = new Throttle(0, 2, noSleep);
    const source: DisclosureSource = {
      chamber: "house",
      throttle,
      list: async () => [...listed, listed[0]!],
      parse: async (f) => {
        await throttle.wait();
        read.push(f.id);
        if (f.id === "house-10078366") return parseHouseDocument("annual", bytes("house-annual-10078366.pdf"));
        if (f.id === "house-20032062") return parseHouseDocument("ptr", bytes("house-ptr-20032062.pdf"));
        if (f.id === "house-20033589") throw new Error("unreadable");
        return { format: "paper" };
      },
    };
    const result = await ingestDisclosures(db, source);
    // Newest first: Aderholt's annual (2026-08-13) and Allen's annual (2026-08-11).
    expect(read).toEqual(["house-10078366", "house-10074380"]);
    expect(result).toMatchObject({ parsed: 1, paper: 1, failed: 0, assets: 154, trades: 0, requests: 2 });
    expect(result.stillDue).toBeGreaterThan(0);
    // Candidates and the reports of people who are not members stay unmatched and are named.
    expect(result.unmatched).toEqual(expect.arrayContaining(["Yassamin Ansari (AZ03)"]));
    const { rows: unmatched } = await pg.query<{ n: number }>(
      "select count(*)::int as n from disclosure_filings where member_id is null and parse_status = 'pending'",
    );
    expect(unmatched[0]!.n).toBeGreaterThan(0);
    const { rows: runs } = await pg.query<{ source: string; items: number; error: string | null }>(
      "select source, items, error from ingest_runs order by id desc limit 1",
    );
    expect(runs[0]).toEqual({ source: "house_disclosures", items: 2, error: null });

    // The next run picks up where the budget stopped, and a failure is stored and counted, not thrown.
    const next = new Throttle(0, 100, noSleep);
    const again = await ingestDisclosures(db, { ...source, throttle: next, parse: async (f) => (await next.wait(), source.parse(f)) });
    expect(again.failed).toBe(1);
    const { rows: failed } = await pg.query<{ parse_status: string; parse_error: string }>(
      "select parse_status, parse_error from disclosure_filings where id = 'house-20033589'",
    );
    expect(failed[0]).toEqual({ parse_status: "failed", parse_error: "unreadable" });
    const { rows: trades } = await pg.query<{ asset_name: string; transacted_on: string }>(
      "select asset_name, to_char(transacted_on, 'YYYY-MM-DD') as transacted_on from disclosure_transactions",
    );
    expect(trades).toEqual([{ asset_name: "GSK plc American Depositary Shares (GSK)", transacted_on: "2025-07-28" }]);
  });

  it("replaces a filing's rows when it is read again", async () => {
    await pg.exec("update disclosure_filings set parse_status = 'pending' where id = 'house-10078366'");
    const throttle = new Throttle(0, 1, noSleep);
    await ingestDisclosures(db, {
      chamber: "house",
      throttle,
      list: async () => parseHouseIndex(text("house-2025FD-excerpt.txt")).filter((f) => f.id === "house-10078366"),
      parse: async () => (await throttle.wait(), parseHouseDocument("annual", bytes("house-annual-10078366.pdf"))),
    });
    const { rows } = await pg.query<{ n: number }>("select count(*)::int as n from disclosure_assets where filing_id = 'house-10078366'");
    expect(rows[0]!.n).toBe(154);
  });
});
