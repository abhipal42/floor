import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { beforeEach, describe, expect, it } from "vitest";
import { checkTranscription, loadTranscription, readTranscriptions, type Transcription } from "./transcriptions.js";

const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "transcriptions");

const nadler: Transcription = {
  filingId: "house-9116165",
  member: "N000002",
  sourceUrl: "https://disclosures-clerk.house.gov/public_disc/financial-pdfs/2025/9116165.pdf",
  transcribedBy: "ai",
  transcribedOn: "2026-11-16",
  assets: [
    { name: "Citizens Bank", owner: "self", value: "$1,001 - $15,000" },
    { name: "NYS Employee Retirement System", owner: "spouse", value: "Undetermined" },
  ],
};

describe("the transcriptions in the repo", () => {
  it("all pass the checks, and Nadler's 2025 report holds the five assets on its Schedule A", () => {
    const all = readTranscriptions(dir);
    const report = all.find((t) => t.filingId === "house-9116165")!;
    expect(report.assets.map((a) => [a.name, a.owner, a.value])).toEqual([
      ["Citizens Bank", "self", "$1,001 - $15,000"],
      ["Cong. Fed Credit Union", "self", "$1,001 - $15,000"],
      ["NYS Employee Retirement System", "self", "Undetermined"],
      ["JPMorgan Chase", "spouse", "$1,001 - $15,000"],
      ["NYS Employee Retirement System", "spouse", "Undetermined"],
    ]);
  });
});

describe("checkTranscription", () => {
  it("refuses an unknown owner, an empty value, and a file named for another filing", () => {
    const bad = (patch: object, file = "house-9116165.json") => () => checkTranscription({ ...nadler, ...patch }, file);
    expect(bad({ assets: [{ name: "X", owner: "partner", value: "$1" }] })).toThrow(/unknown owner/);
    expect(bad({ assets: [{ name: "X", owner: "self", value: " " }] })).toThrow(/no value/);
    expect(bad({}, "house-1.json")).toThrow(/named house-9116165.json/);
    expect(bad({ transcribedBy: "person" })).toThrow(/transcribedBy/);
  });
});

describe("loadTranscription (PGlite)", () => {
  let pg: PGlite;
  beforeEach(async () => {
    pg = new PGlite();
    await pg.exec(`create schema auth; create table auth.users (id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;`);
    for (const m of loadMigrations()) await pg.exec(m.sql);
    await pg.exec(`insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end)
                   values ('N000002', 'Jerrold', 'Nadler', 'D', 'NY', 12, 'house', '2025-01-03', '2027-01-03')`);
  });
  it("fills a paper filing, marks it transcribed by AI, and a reload replaces rather than adds", async () => {
    await pg.query(
      `insert into disclosure_filings (id, chamber, member_id, filer_name, kind, report_year, source_url, format, parse_status)
       values ('house-9116165', 'house', 'N000002', 'Nadler, Jerrold', 'annual', 2025, 'https://example.test', 'paper', 'paper')`,
    );
    expect(await loadTranscription(pg, nadler)).toBe("loaded");
    expect(await loadTranscription(pg, nadler)).toBe("loaded");
    const { rows: f } = await pg.query<{ parse_status: string; transcribed_by: string }>(
      "select parse_status, transcribed_by from disclosure_filings where id = 'house-9116165'",
    );
    expect(f[0]).toEqual({ parse_status: "parsed", transcribed_by: "ai" });
    const { rows: a } = await pg.query("select position, name, owner, value_range from disclosure_assets order by position");
    expect(a).toEqual([
      { position: 1, name: "Citizens Bank", owner: "self", value_range: "$1,001 - $15,000" },
      { position: 2, name: "NYS Employee Retirement System", owner: "spouse", value_range: "Undetermined" },
    ]);
  });

  it("never stands in for an electronic filing, and says when the filing isn't listed yet", async () => {
    await pg.query(
      `insert into disclosure_filings (id, chamber, member_id, filer_name, kind, report_year, source_url, format, parse_status)
       values ('house-9116165', 'house', 'N000002', 'Nadler, Jerrold', 'annual', 2025, 'https://example.test', 'electronic', 'parsed')`,
    );
    expect(await loadTranscription(pg, nadler)).toBe("not-paper");
    expect(await loadTranscription(pg, { ...nadler, filingId: "house-1" })).toBe("not-listed");
  });
});
