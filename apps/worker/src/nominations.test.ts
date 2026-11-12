import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { beforeAll, describe, expect, it } from "vitest";
import type { CongressGet } from "./bills.js";
import type { Db } from "./db.js";
import {
  ingestVotedNominations,
  nominationId,
  nominationPath,
  parseNomineeName,
  toNominationRow,
} from "./nominations.js";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = (name: string) =>
  JSON.parse(readFileSync(join(here, "../fixtures/congress", name), "utf8")) as Record<string, unknown>;
// Real /nomination responses: a part of a split judicial nomination, an unpartitioned one,
// and a military promotion, which carries no description.
const pn1093part3 = fixture("pn1093-3-119-nomination.json");
const pn1905 = fixture("pn1905-118-nomination.json");
const pn28military = fixture("pn28-119-nomination.json");

describe("nomination ids and paths", () => {
  it.each([
    [119, 1905, null, "119-pn-1905", "/nomination/119/1905"],
    [119, 1093, 3, "119-pn-1093-3", "/nomination/119/1093-3"],
    // Part 0 means the nomination was never split, so neither the id nor the path carries a part.
    [118, 12, 0, "118-pn-12", "/nomination/118/12"],
  ])("builds %s-%s-%s", (congress, number, part, id, path) => {
    expect(nominationId(congress, number, part)).toBe(id);
    expect(nominationPath(congress, number, part)).toBe(path);
  });
});

describe("parseNomineeName", () => {
  it.each([
    [
      "Matthew R. Byrne, of Ohio, to be United States District Judge for the Southern District of Ohio, vice Michael H. Watson, retired.",
      "Matthew R. Byrne",
    ],
    ["Daniel Driscoll, of North Carolina, to be Secretary of the Army, vice Christine Elizabeth Wormuth, resigned.", "Daniel Driscoll"],
    ["Jane Q. Doe, to be a Member of the Board of Directors", "Jane Q. Doe"],
  ])("reads the nominee out of %s", (description, name) => {
    expect(parseNomineeName(description)).toBe(name);
  });

  it.each([
    null,
    "",
    "The following named officer for appointment to the permanent grade indicated in the Regular Air Force, to be Major General",
  ])("has no single nominee for %s", (description) => {
    expect(parseNomineeName(description)).toBeNull();
  });
});

describe("Congress.gov mapping (real /nomination responses)", () => {
  it("maps a part of a split nomination, keeping the part in the id and citation", () => {
    expect(toNominationRow(pn1093part3)).toEqual({
      id: "119-pn-1093-3",
      congress: 119,
      number: 1093,
      part: 3,
      citation: "PN1093-3",
      nominee_name: "Matthew R. Byrne",
      position_title: "United States District Judge for the Southern District of Ohio",
      organization: "The Judiciary",
      description:
        "Matthew R. Byrne, of Ohio, to be United States District Judge for the Southern District of Ohio, vice Michael H. Watson, retired.",
      nominee_count: 1,
      is_military: false,
      received_on: "2026-06-15",
      latest_action_on: "2026-09-15",
      latest_action_text: "Confirmed by the Senate by Yea-Nay Vote. 52 - 45. Record Vote Number: 233.",
      source_updated_at: "2026-09-16T11:00:47Z",
    });
  });

  it("maps an unpartitioned nomination with part 0", () => {
    expect(toNominationRow(pn1905)).toMatchObject({
      id: "118-pn-1905",
      congress: 118,
      number: 1905,
      part: 0,
      citation: "PN1905",
      nominee_name: "Gail A. Weilheimer",
      position_title: "United States District Judge for the Eastern District of Pennsylvania",
      organization: "The Judiciary",
      is_military: false,
      received_on: "2024-07-08",
      latest_action_on: "2024-12-03",
    });
  });

  it("maps a military promotion, which names no nominee but has a grade and a service", () => {
    expect(toNominationRow(pn28military)).toMatchObject({
      id: "119-pn-28",
      citation: "PN28",
      nominee_name: null,
      description: null,
      position_title: "Major General",
      organization: "Air Force",
      nominee_count: 1,
      is_military: true,
    });
  });

  it("survives a response whose sub-resources are links rather than arrays", () => {
    const row = toNominationRow({
      nomination: {
        congress: 119,
        number: 7,
        partNumber: "00",
        citation: "PN7",
        nominees: { count: 1, url: "https://api.congress.gov/v3/nomination/119/7/1?format=json" },
      },
    });
    expect(row).toMatchObject({ id: "119-pn-7", position_title: null, organization: null, nominee_count: null });
  });
});

describe("ingestVotedNominations", () => {
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
      insert into votes (id, chamber, congress, session, roll_number, question, bill_ref) values
        ('senate-119-2-232', 'senate', 119, 2, 232, 'On the Cloture Motion', 'PN1093-3'),
        ('senate-119-2-233', 'senate', 119, 2, 233, 'On the Nomination', 'PN1093-3'),
        ('senate-119-1-211', 'senate', 119, 1, 211, 'On the Nomination', 'PN28'),
        ('senate-119-1-212', 'senate', 119, 1, 212, 'On the Nomination', 'PN9999'),
        ('senate-119-1-213', 'senate', 119, 1, 213, 'On the Motion to Proceed', 'S.J.Res. 10'),
        ('house-119-1-5', 'house', 119, 1, 5, 'On Motion to Adjourn', 'ADJOURN');
    `);
  });

  it("loads each voted nomination once and links every vote that cites it", async () => {
    const requested: string[] = [];
    const get: CongressGet = async (path) => {
      requested.push(path);
      if (path === "/nomination/119/1093-3") return pn1093part3;
      if (path === "/nomination/119/28") return pn28military;
      throw new Error(`Congress.gov ${path} returned HTTP 404`);
    };
    const result = await ingestVotedNominations(pg as unknown as Db, get);
    expect(result).toEqual({ nominations: 2, linkedVotes: 3, failed: 1 });
    // One request per nomination, and nothing for the bill or the procedural vote.
    expect(requested).toEqual(["/nomination/119/1093-3", "/nomination/119/28", "/nomination/119/9999"]);

    const { rows: votes } = await pg.query<{ id: string; nomination_id: string | null }>(
      "select id, nomination_id from votes order by id",
    );
    expect(votes).toEqual([
      { id: "house-119-1-5", nomination_id: null },
      { id: "senate-119-1-211", nomination_id: "119-pn-28" },
      { id: "senate-119-1-212", nomination_id: null },
      { id: "senate-119-1-213", nomination_id: null },
      { id: "senate-119-2-232", nomination_id: "119-pn-1093-3" },
      { id: "senate-119-2-233", nomination_id: "119-pn-1093-3" },
    ]);

    const { rows: stored } = await pg.query<{ id: string; nominee_name: string | null; part: number }>(
      "select id, nominee_name, part from nominations order by id",
    );
    expect(stored).toEqual([
      { id: "119-pn-1093-3", nominee_name: "Matthew R. Byrne", part: 3 },
      { id: "119-pn-28", nominee_name: null, part: 0 },
    ]);

    const { rows: run } = await pg.query<{ items: number; error: string }>(
      "select items, error from ingest_runs where source = 'nominations'",
    );
    expect(run).toEqual([{ items: 2, error: "1 nominations failed" }]);
  });

  it("refresh re-fetches stored nominations and leaves the vote links alone", async () => {
    const requested: string[] = [];
    const get: CongressGet = async (path) => {
      requested.push(path);
      return path === "/nomination/119/28" ? pn28military : pn1093part3;
    };
    const before = await pg.query<{ id: string; nomination_id: string | null }>(
      "select id, nomination_id from votes order by id",
    );
    const result = await ingestVotedNominations(pg as unknown as Db, get, { refresh: true });

    // Both stored nominations are re-fetched; PN9999, which never loaded, is not.
    expect(result).toEqual({ nominations: 2, linkedVotes: 0, failed: 0 });
    expect(requested.sort()).toEqual(["/nomination/119/1093-3", "/nomination/119/28"]);
    const after = await pg.query<{ id: string; nomination_id: string | null }>(
      "select id, nomination_id from votes order by id",
    );
    expect(after.rows).toEqual(before.rows);
  });

  it("is idempotent: a second run only retries the nomination that failed", async () => {
    const requested: string[] = [];
    const get: CongressGet = async (path) => {
      requested.push(path);
      throw new Error("Congress.gov returned HTTP 404");
    };
    await ingestVotedNominations(pg as unknown as Db, get);
    expect(requested).toEqual(["/nomination/119/9999"]);
  });
});
