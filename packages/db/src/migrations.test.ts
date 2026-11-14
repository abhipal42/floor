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
      "bill_analysis_runs",
      "bill_versions",
      "bills",
      "campaign_finance",
      "chamber_status",
      "device_signups",
      "device_subscriptions",
      "devices",
      "floor_events",
      "follows",
      "ingest_runs",
      "live_activity_tokens",
      "members",
      "nominations",
      "pac_contributions",
      "profiles",
      "projections",
      "push_log",
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

  it("keep AI run bookkeeping private: no policy on bill_analysis_runs, and no stats on the public table", async () => {
    // bill_analysis_runs holds the claims the verifier rejected and the cost of each run. With RLS
    // on and no policy, PostgREST's anon and authenticated roles see nothing; only the service role
    // (the worker) can read it.
    const { rows: policies } = await db.query("select policyname from pg_policies where tablename = 'bill_analysis_runs'");
    expect(policies).toEqual([]);
    const { rows: columns } = await db.query<{ column_name: string }>(
      "select column_name from information_schema.columns where table_name = 'bill_analyses' and column_name = 'stats'",
    );
    expect(columns).toEqual([]);
  });

  it("keep device registrations private: RLS on and no policy on any alert table, and no account column", async () => {
    // Push tokens and what a phone follows are read only by the API's and the worker's service
    // connection. A policy here (even a select one) would expose them through PostgREST.
    const tables = ["devices", "device_subscriptions", "device_signups", "live_activity_tokens", "push_log"];
    const { rows: policies } = await db.query("select tablename, policyname from pg_policies where tablename = any($1)", [tables]);
    expect(policies).toEqual([]);
    const { rows: secured } = await db.query<{ relname: string }>(
      "select relname from pg_class where relname = any($1) and relrowsecurity order by 1",
      [tables],
    );
    expect(secured.map((r) => r.relname)).toEqual([...tables].sort());
    const { rows: columns } = await db.query<{ column_name: string }>(
      "select column_name from information_schema.columns where table_name = 'devices' order by ordinal_position",
    );
    expect(columns.map((c) => c.column_name)).toEqual([
      "id",
      "key_hash",
      "apns_token",
      "apns_env",
      "push_to_start_token",
      "vote_opened",
      "live_activities",
      "created_at",
      "updated_at",
    ]);
  });

  it("refuse a malformed key hash or token, and a subscription to something that is not a member or bill", async () => {
    await expect(db.exec("insert into devices (key_hash) values ('not-a-hash')")).rejects.toThrow();
    await expect(
      db.exec(`insert into devices (key_hash, apns_token) values ('${"a".repeat(64)}', 'zz')`),
    ).rejects.toThrow();
    const { rows } = await db.query<{ id: string }>(`insert into devices (key_hash) values ('${"b".repeat(64)}') returning id`);
    await expect(
      db.query("insert into device_subscriptions values ($1, 'topic', 'Health', true)", [rows[0]!.id]),
    ).rejects.toThrow();
    await db.query("delete from devices where id = $1", [rows[0]!.id]);
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
