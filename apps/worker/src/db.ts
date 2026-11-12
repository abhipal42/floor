import type { RollCall } from "@floor/shared";
import type { MemberRow } from "./members.js";

/** The slice of a Postgres client we use. Satisfied by `pg.Pool` and by PGlite in tests. */
export interface Db {
  query<T = Record<string, unknown>>(text: string, params?: unknown[]): Promise<{ rows: T[] }>;
}

export async function upsertMembers(db: Db, rows: MemberRow[]): Promise<number> {
  if (rows.length === 0) return 0;
  await db.query(
    `insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end, ids)
     select bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end, ids
       from jsonb_to_recordset($1::jsonb) as x(
         bioguide_id text, first_name text, last_name text, party text, state text,
         district smallint, chamber chamber, term_start date, term_end date, ids jsonb)
     on conflict (bioguide_id) do update set
       first_name = excluded.first_name, last_name = excluded.last_name, party = excluded.party,
       state = excluded.state, district = excluded.district, chamber = excluded.chamber,
       term_start = excluded.term_start, term_end = excluded.term_end, ids = excluded.ids`,
    [JSON.stringify(rows)],
  );
  return rows.length;
}

export const voteId = (rc: Pick<RollCall, "chamber" | "congress" | "session" | "rollNumber">) =>
  `${rc.chamber}-${rc.congress}-${rc.session}-${rc.rollNumber}`;

/**
 * Stores a finished roll call and its member positions. Positions for members we don't
 * know are skipped and counted, so a missing member never blocks a vote from landing.
 */
export async function upsertRollCall(db: Db, rc: RollCall): Promise<{ id: string; stored: number; skipped: number }> {
  const id = voteId(rc);
  const joinOn = rc.chamber === "house" ? "m.bioguide_id = p.member_id" : "m.ids->>'lis' = p.member_id";
  const positions = rc.positions.map((p) => ({ member_id: p.memberId, position: p.position, choice: p.choice ?? null }));

  // One statement, so a vote and its positions land together or not at all.
  const { rows } = await db.query<{ stored: number }>(
    `with v as (
       insert into votes (id, chamber, congress, session, roll_number, question, threshold, state,
                          yea, nay, present, not_voting, result, bill_ref, occurred_at, closed_at, kind, candidates)
       values ($1, $2, $3, $4, $5, $6, $7, 'final', $8, $9, $10, $11, $12, $13,
               ($14::timestamp at time zone 'America/New_York'), ($14::timestamp at time zone 'America/New_York'),
               $15, $16::jsonb)
       on conflict (id) do update set
         question = excluded.question, threshold = excluded.threshold, state = 'final',
         yea = excluded.yea, nay = excluded.nay, present = excluded.present, not_voting = excluded.not_voting,
         result = excluded.result, bill_ref = excluded.bill_ref,
         occurred_at = excluded.occurred_at, closed_at = excluded.closed_at,
         kind = excluded.kind, candidates = excluded.candidates
       returning id
     ), input as (
       select * from jsonb_to_recordset($17::jsonb) as p(member_id text, position text, choice text)
     ), ins as (
       insert into vote_positions (vote_id, member_id, position, choice)
       select v.id, m.bioguide_id, p.position::vote_position, p.choice
         from v cross join input p join members m on ${joinOn}
       on conflict (vote_id, member_id) do update set position = excluded.position, choice = excluded.choice
       returning 1
     )
     select count(*)::int as stored from ins`,
    [
      id, rc.chamber, rc.congress, rc.session, rc.rollNumber, rc.question, rc.threshold,
      rc.totals.yea, rc.totals.nay, rc.totals.present, rc.totals.notVoting, rc.result,
      rc.billRef, rc.occurredAtEastern, rc.kind, JSON.stringify(rc.candidates), JSON.stringify(positions),
    ],
  );
  const stored = rows[0]?.stored ?? 0;
  return { id, stored, skipped: positions.length - stored };
}

/** Roll numbers in a session whose vote row exists but has no member positions. */
export async function rollsMissingPositions(db: Db, chamber: string, congress: number, session: number): Promise<number[]> {
  const { rows } = await db.query<{ roll_number: number }>(
    `select v.roll_number from votes v
      where v.chamber = $1 and v.congress = $2 and v.session = $3 and v.state = 'final'
        and not exists (select 1 from vote_positions p where p.vote_id = v.id)
      order by v.roll_number`,
    [chamber, congress, session],
  );
  return rows.map((r) => r.roll_number);
}

/** Highest roll number already stored for a chamber session, or 0. */
export async function lastRollNumber(db: Db, chamber: string, congress: number, session: number): Promise<number> {
  const { rows } = await db.query<{ max: number | null }>(
    "select max(roll_number)::int as max from votes where chamber = $1 and congress = $2 and session = $3",
    [chamber, congress, session],
  );
  return rows[0]?.max ?? 0;
}

/** Records an ingest run for freshness monitoring and returns a function that closes it. */
export async function startRun(db: Db, source: string) {
  const { rows } = await db.query<{ id: number }>(
    "insert into ingest_runs (source) values ($1) returning id",
    [source],
  );
  const runId = rows[0]?.id;
  return async (items: number, error?: string) => {
    await db.query("update ingest_runs set finished_at = now(), items = $2, error = $3 where id = $1", [
      runId, items, error ?? null,
    ]);
  };
}
