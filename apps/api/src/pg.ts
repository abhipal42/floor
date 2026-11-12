import type {
  Bill,
  BillRepository,
  Member,
  MemberRepository,
  MemberVote,
  StatusRepository,
  Vote,
  VoteRepository,
} from "./app.js";

/** The slice of a Postgres client we use. Satisfied by `pg.Pool` and by PGlite in tests. */
export interface Db {
  query<T = Record<string, unknown>>(text: string, params?: unknown[]): Promise<{ rows: T[] }>;
}

interface VoteRow {
  id: string;
  kind: "question" | "election";
  candidates: { name: string; total: number }[];
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
  kind: r.kind,
  candidates: r.candidates,
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

const VOTE_COLUMNS = `v.id, v.kind, v.candidates, v.chamber, v.congress, v.session, v.roll_number, v.bill_id, v.bill_ref, v.question,
  v.state, v.threshold, v.yea, v.nay, v.present, v.not_voting, v.result, v.occurred_at`;

interface BillRow {
  id: string;
  congress: number;
  bill_type: string;
  number: number;
  title: string;
  short_title: string | null;
  introduced_on: Date | string | null;
  origin_chamber: "house" | "senate" | null;
  policy_area: string | null;
  summary: string | null;
  summary_stage: string | null;
  latest_action_on: Date | string | null;
  latest_action_text: string | null;
  cbo_estimates: Bill["cboEstimates"];
  sponsor: MemberRow | null;
}

/** Dates from a `date` column, as YYYY-MM-DD regardless of driver. */
const day = (d: Date | string | null): string | null =>
  d == null ? null : typeof d === "string" ? d.slice(0, 10) : d.toISOString().slice(0, 10);

export function pgRepositories(db: Db): {
  votes: VoteRepository;
  members: MemberRepository;
  bills: BillRepository;
  status: StatusRepository;
} {
  return {
    bills: {
      async getBill(id) {
        const { rows } = await db.query<BillRow>(
          `select b.id, b.congress, b.bill_type, b.number, b.title, b.short_title, b.introduced_on, b.origin_chamber,
                  b.policy_area, b.summary, b.summary_stage, b.latest_action_on, b.latest_action_text, b.cbo_estimates,
                  case when m.bioguide_id is null then null else jsonb_build_object(
                    'bioguide_id', m.bioguide_id, 'first_name', m.first_name, 'last_name', m.last_name,
                    'party', m.party, 'state', m.state, 'district', m.district, 'chamber', m.chamber) end as sponsor
             from bills b left join members m on m.bioguide_id = b.sponsor_id
            where b.id = $1`,
          [id],
        );
        const b = rows[0];
        if (!b) return null;
        const [{ rows: actions }, { rows: votes }] = await Promise.all([
          db.query<{ acted_on: Date | string; chamber: "house" | "senate" | null; text: string }>(
            "select acted_on, chamber, text from actions where bill_id = $1 order by acted_on desc, id limit 30",
            [id],
          ),
          db.query<VoteRow>(
            `select ${VOTE_COLUMNS} from votes v where v.bill_id = $1 order by v.occurred_at desc nulls last`,
            [id],
          ),
        ]);
        return {
          id: b.id,
          congress: b.congress,
          type: b.bill_type,
          number: b.number,
          title: b.title,
          shortTitle: b.short_title,
          sponsor: b.sponsor ? toMember(b.sponsor) : null,
          introducedOn: day(b.introduced_on),
          originChamber: b.origin_chamber,
          policyArea: b.policy_area,
          summary: b.summary,
          summaryStage: b.summary_stage,
          latestAction:
            b.latest_action_on && b.latest_action_text ? { on: day(b.latest_action_on)!, text: b.latest_action_text } : null,
          cboEstimates: b.cbo_estimates,
          actions: actions.map((a) => ({ actedOn: day(a.acted_on)!, chamber: a.chamber, text: a.text })),
          votes: votes.map(toVote),
        };
      },
    },
    status: {
      async lastRuns() {
        const { rows } = await db.query<{ source: string; last_success_at: Date | null; last_error: string | null }>(
          `select source,
                  max(finished_at) filter (where error is null) as last_success_at,
                  (array_agg(error order by started_at desc) filter (where error is not null))[1] as last_error
             from ingest_runs group by source`,
        );
        return rows.map((r) => ({
          source: r.source,
          lastSuccessAt: r.last_success_at ? new Date(r.last_success_at) : null,
          lastError: r.last_error,
        }));
      },
    },
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
        const { rows } = await db.query<VoteRow & { position: MemberVote["position"]; choice: string | null }>(
          `select ${VOTE_COLUMNS}, p.position, p.choice
             from vote_positions p join votes v on v.id = p.vote_id
            where p.member_id = $1
            order by v.occurred_at desc nulls last, v.roll_number desc
            limit $2`,
          [bioguideId, limit],
        );
        return rows.map((r) => ({ vote: toVote(r), position: r.position, choice: r.choice }));
      },
    },
  };
}
