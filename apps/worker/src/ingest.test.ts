import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { beforeAll, describe, expect, it } from "vitest";
import type { Db } from "./db.js";
import { upsertMembers } from "./db.js";
import { toMemberRows, type LegislatorEntry } from "./members.js";
import {
  fetchRollCall,
  houseRollUrl,
  ingestRollCalls,
  senateRollUrl,
  withRetry,
  yearOf,
  type FetchText,
} from "./rollcalls.js";

const here = dirname(fileURLToPath(import.meta.url));
const read = (p: string) => readFileSync(join(here, p), "utf8");
const legislators = JSON.parse(read("../fixtures/legislators-sample.json")) as LegislatorEntry[];
const houseXml = read("../../../packages/shared/fixtures/house-2025-roll100.xml");
const senateXml = read("../../../packages/shared/fixtures/senate-119-1-00100.xml");

/** Serves the two real roll call files and 404s everything else. */
const fakeFetch: FetchText = async (url) => {
  if (url === houseRollUrl(119, 1, 100)) return { status: 200, text: houseXml };
  if (url === senateRollUrl(119, 1, 100)) return { status: 200, text: senateXml };
  return { status: 404, text: "" };
};

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
  db = pg as unknown as Db;
  await upsertMembers(db, toMemberRows(legislators));
});

describe("members", () => {
  it("maps congress-legislators entries to member rows", () => {
    const rows = toMemberRows(legislators);
    expect(rows.find((r) => r.bioguide_id === "A000370")).toMatchObject({
      last_name: "Adams", party: "D", state: "NC", district: 12, chamber: "house",
    });
    expect(rows.find((r) => r.bioguide_id === "S000033")).toMatchObject({
      party: "I", state: "VT", district: null, chamber: "senate", ids: { lis: "S313" },
    });
    expect(rows.find((r) => r.bioguide_id === "N000147")?.district).toBe(0); // DC delegate, at-large
  });

  it("drops members whose last term ended before the backfill window", () => {
    const old = { ...legislators[0]!, terms: [{ ...legislators[0]!.terms.at(-1)!, end: "2021-01-03" }] };
    expect(toMemberRows([old])).toEqual([]);
  });

  it("upserts idempotently", async () => {
    await upsertMembers(db, toMemberRows(legislators));
    const { rows } = await pg.query<{ n: number }>("select count(*)::int as n from members");
    expect(rows[0]?.n).toBe(4);
  });
});

describe("roll call URLs", () => {
  it("builds the official file URLs", () => {
    expect(yearOf(119, 1)).toBe(2025);
    expect(yearOf(118, 2)).toBe(2024);
    expect(houseRollUrl(119, 1, 7)).toBe("https://clerk.house.gov/evs/2025/roll007.xml");
    expect(senateRollUrl(119, 1, 100)).toBe(
      "https://www.senate.gov/legislative/LIS/roll_call_votes/vote1191/vote_119_1_00100.xml",
    );
  });

  it("treats a missing or HTML response as not yet published", async () => {
    expect(await fetchRollCall("house", 119, 1, 9999, fakeFetch)).toBeNull();
    const htmlPage: FetchText = async () => ({ status: 200, text: "<html>Not found</html>" });
    expect(await fetchRollCall("house", 119, 1, 1, htmlPage)).toBeNull();
  });

  it("raises on server errors instead of silently stopping", async () => {
    const down: FetchText = async () => ({ status: 503, text: "" });
    await expect(fetchRollCall("senate", 119, 1, 1, down)).rejects.toThrow(/HTTP 503/);
  });
});

describe("withRetry", () => {
  const pgError = (code: string) => Object.assign(new Error(code), { code });

  it("retries deadlocks and serialization failures", async () => {
    let calls = 0;
    const result = await withRetry(async () => {
      calls++;
      if (calls < 3) throw pgError(calls === 1 ? "40P01" : "40001");
      return "ok";
    }, 4, 1);
    expect(result).toBe("ok");
    expect(calls).toBe(3);
  });

  it("gives up after the last attempt and doesn't retry other errors", async () => {
    let calls = 0;
    await expect(withRetry(async () => { calls++; throw pgError("40P01"); }, 3, 1)).rejects.toThrow("40P01");
    expect(calls).toBe(3);
    calls = 0;
    await expect(withRetry(async () => { calls++; throw pgError("23505"); }, 3, 1)).rejects.toThrow("23505");
    expect(calls).toBe(1);
  });
});

describe("ingestRollCalls", () => {
  it("stores a House vote and joins positions to known members by bioguide ID", async () => {
    const result = await ingestRollCalls(db, "house", 119, 1, { from: 100, fetchText: fakeFetch });
    expect(result).toEqual({ stored: 1, lastRoll: 100, skippedPositions: 432 });

    const { rows: vote } = await pg.query(
      "select yea, nay, not_voting, state, bill_ref, threshold, occurred_at from votes where id = 'house-119-1-100'",
    );
    expect(vote[0]).toMatchObject({ yea: 216, nay: 214, not_voting: 3, state: "final", bill_ref: "H CON RES 14", threshold: "majority" });
    expect((vote[0] as { occurred_at: Date }).occurred_at.toISOString()).toBe("2025-04-10T15:08:00.000Z");

    const { rows: pos } = await pg.query("select member_id, position from vote_positions where vote_id = 'house-119-1-100'");
    expect(pos).toEqual([{ member_id: "A000370", position: "nay" }]);
  });

  it("stores a Senate vote and maps LIS IDs to bioguide IDs", async () => {
    const result = await ingestRollCalls(db, "senate", 119, 1, { from: 100, fetchText: fakeFetch });
    expect(result.stored).toBe(1);
    const { rows } = await pg.query<{ member_id: string; position: string }>(
      "select member_id, position from vote_positions where vote_id = 'senate-119-1-100' order by member_id",
    );
    expect(rows.map((r) => r.member_id)).toEqual(["C000127", "S000033"]);
    const { rows: vote } = await pg.query("select threshold from votes where id = 'senate-119-1-100'");
    expect(vote[0]).toEqual({ threshold: "three_fifths_sworn" });
  });

  it("stores a Speaker election with each member's candidate", async () => {
    const electionXml = read("../../../packages/shared/fixtures/house-2023-roll002.xml");
    const fetchElection: FetchText = async (url) =>
      url === houseRollUrl(118, 1, 2) ? { status: 200, text: electionXml } : { status: 404, text: "" };
    expect((await ingestRollCalls(db, "house", 118, 1, { from: 2, fetchText: fetchElection })).stored).toBe(1);

    const { rows: vote } = await pg.query<{ kind: string; candidates: { name: string; total: number }[] }>(
      "select kind, candidates from votes where id = 'house-118-1-2'",
    );
    expect(vote[0]?.kind).toBe("election");
    expect(vote[0]?.candidates[0]).toEqual({ name: "Jeffries", total: 212 });
    const { rows: pos } = await pg.query("select position, choice from vote_positions where vote_id = 'house-118-1-2'");
    expect(pos).toEqual([{ position: "candidate", choice: "Jeffries" }]);
  });

  it("resumes after the last stored roll and logs the run", async () => {
    const result = await ingestRollCalls(db, "house", 119, 1, { fetchText: fakeFetch });
    expect(result).toEqual({ stored: 0, lastRoll: 100, skippedPositions: 0 });
    const { rows } = await pg.query<{ source: string; items: number; error: string | null }>(
      "select source, items, error from ingest_runs where finished_at is not null order by id",
    );
    expect(rows).toEqual([
      { source: "house_rollcalls", items: 1, error: null },
      { source: "senate_rollcalls", items: 1, error: null },
      { source: "house_rollcalls", items: 1, error: null },
      { source: "house_rollcalls", items: 0, error: null },
    ]);
  });
});
