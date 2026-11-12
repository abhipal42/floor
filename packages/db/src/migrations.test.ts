import { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";
import { loadMigrations } from "./index.js";

// Minimal stand-in for the Supabase auth schema so migrations apply outside Supabase.
const AUTH_STUB = `
  create schema auth;
  create table auth.users (id uuid primary key);
  create function auth.uid() returns uuid language sql stable
    as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
`;

let db: PGlite;

beforeAll(async () => {
  db = new PGlite();
  await db.exec(AUTH_STUB);
  for (const m of loadMigrations()) await db.exec(m.sql);
});

describe("migrations", () => {
  it("create every core table", async () => {
    const { rows } = await db.query<{ table_name: string }>(
      "select table_name from information_schema.tables where table_schema = 'public' order by 1",
    );
    expect(rows.map((r) => r.table_name)).toEqual([
      "actions",
      "bill_analyses",
      "bill_versions",
      "bills",
      "devices",
      "floor_events",
      "follows",
      "ingest_runs",
      "members",
      "profiles",
      "projections",
      "statements",
      "tally_snapshots",
      "vote_positions",
      "votes",
    ]);
  });

  it("store a vote with member positions", async () => {
    await db.exec(`
      insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end)
        values ('T000001', 'Test', 'Member', 'D', 'TX', 4, 'house', '2025-01-03', '2027-01-03');
      insert into votes (id, chamber, congress, session, roll_number, question, state, yea, nay)
        values ('house-119-1-1', 'house', 119, 1, 1, 'On Passage', 'final', 219, 208);
      insert into vote_positions values ('house-119-1-1', 'T000001', 'yea');
    `);
    const { rows } = await db.query<{ position: string }>(
      "select position from vote_positions where member_id = 'T000001'",
    );
    expect(rows[0]?.position).toBe("yea");
  });

  it("reject negative tallies and out-of-range projections", async () => {
    await expect(
      db.exec(
        "insert into votes (id, chamber, congress, session, question, yea) values ('x', 'house', 119, 1, 'q', -1)",
      ),
    ).rejects.toThrow();
    await expect(
      db.exec(
        "insert into projections (vote_id, p_pass, projected_yea, projected_nay, model_version) values ('house-119-1-1', 1.5, 1, 1, 'v1')",
      ),
    ).rejects.toThrow();
  });

  it("enable row level security on every public table, with read-only policies on shared data", async () => {
    const { rows: off } = await db.query<{ relname: string }>(
      `select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity`,
    );
    expect(off).toEqual([]);
    const { rows: writable } = await db.query<{ tablename: string }>(
      `select tablename from pg_policies
        where schemaname = 'public' and policyname = 'public read' and cmd <> 'SELECT'`,
    );
    expect(writable).toEqual([]);
  });

  it("enable row level security on every per-user table", async () => {
    const { rows } = await db.query<{ relname: string; relrowsecurity: boolean }>(
      "select relname, relrowsecurity from pg_class where relname in ('profiles', 'follows', 'devices') order by 1",
    );
    expect(rows).toEqual([
      { relname: "devices", relrowsecurity: true },
      { relname: "follows", relrowsecurity: true },
      { relname: "profiles", relrowsecurity: true },
    ]);
  });
});
