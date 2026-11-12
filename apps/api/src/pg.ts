import type { Member, MemberRepository, MemberVote, Vote, VoteRepository } from "./app.js";

/** The slice of a Postgres client we use. Satisfied by `pg.Pool` and by PGlite in tests. */
export interface Db {
  query<T = Record<string, unknown>>(text: string, params?: unknown[]): Promise<{ rows: T[] }>;
}

interface VoteRow {
  id: string;
  chamber: "house" | "senate";
  congress: number;
  session: number;
  roll_number: number | null;
  bill_id: string | null;
  bill_ref: string | null;
  question: string;
  state: "scheduled" | "open" | "final";
  threshold: "majority" | "three_fifths_sworn" | "two_thirds";
  yea: number;
  nay: number;
  present: number;
  not_voting: number;
  result: string | null;
  occurred_at: Date | null;
}

interface MemberRow {
  bioguide_id: string;
  first_name: string;
  last_name: string;
  party: string;
  state: string;
  district: number | null;
  chamber: "house" | "senate";
}

const toVote = (r: VoteRow): Vote => ({
  id: r.id,
  chamber: r.chamber,
  congress: r.congress,
  session: r.session,
  rollNumber: r.roll_number,
  question: r.question,
  billId: r.bill_id,
  billRef: r.bill_ref,
  occurredAt: r.occurred_at ? new Date(r.occurred_at).toISOString() : null,
  state: r.state,
  threshold: r.threshold,
  totals: { yea: r.yea, nay: r.nay, present: r.present, notVoting: r.not_voting },
  result: r.result,
});

const toMember = (r: MemberRow): Member => ({
  bioguideId: r.bioguide_id,
  firstName: r.first_name,
  lastName: r.last_name,
  party: r.party,
  state: r.state,
  district: r.district,
  chamber: r.chamber,
});

const VOTE_COLUMNS = `v.id, v.chamber, v.congress, v.session, v.roll_number, v.bill_id, v.bill_ref, v.question,
  v.state, v.threshold, v.yea, v.nay, v.present, v.not_voting, v.result, v.occurred_at`;

export function pgRepositories(db: Db): { votes: VoteRepository; members: MemberRepository } {
  return {
    votes: {
      async getVote(id) {
        const { rows } = await db.query<VoteRow>(`select ${VOTE_COLUMNS} from votes v where v.id = $1`, [id]);
        return rows[0] ? toVote(rows[0]) : null;
      },
    },
    members: {
      async membersFor(state, district) {
        const { rows } = await db.query<MemberRow>(
          `select bioguide_id, first_name, last_name, party, state, district, chamber
             from members
            where state = $1 and term_end > current_date
              and (chamber = 'senate' or district = $2)
            order by chamber, last_name`,
          [state, district],
        );
        return rows.map(toMember);
      },
      async recentVotes(bioguideId, limit) {
        const { rows } = await db.query<VoteRow & { position: MemberVote["position"] }>(
          `select ${VOTE_COLUMNS}, p.position
             from vote_positions p join votes v on v.id = p.vote_id
            where p.member_id = $1
            order by v.occurred_at desc nulls last, v.roll_number desc
            limit $2`,
          [bioguideId, limit],
        );
        return rows.map((r) => ({ vote: toVote(r), position: r.position }));
      },
    },
  };
}
