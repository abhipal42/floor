import type {
  Bill,
  BillRepository,
  CandidateTotal,
  MeasureSummary,
  Member,
  MemberRepository,
  MemberPosition,
  MemberVote,
  Nomination,
  NominationRepository,
  PartyLoyalty,
  PartyTotals,
  StatusRepository,
  Vote,
  VoteRepository,
} from "./app.js";

/**
 * Which kind of Supabase connection a `DATABASE_URL` is, from its port and host.
 *
 * The API runs on serverless instances that come and go, so it wants the transaction pooler (port
 * 6543 on `*.pooler.supabase.com`), which shares a few server connections among any number of
 * clients. The session pooler (port 5432 on the same host) pins one of a fixed set of slots to each
 * open connection, and the direct host is IPv6-only and unreachable from Vercel. This code works
 * through the transaction pooler because node-postgres only prepares statements that are given a
 * `name`, and nothing here names one or sets session state.
 */
export function poolerMode(url: string): "transaction" | "session" | "direct" | "unknown" {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return "unknown";
  }
  const port = parsed.port || "5432";
  // 6543 is the transaction pooler's port whatever the host is called (another region, a custom
  // domain), so it is read first; the host only decides what any other port is.
  if (port === "6543") return "transaction";
  if (parsed.hostname.endsWith(".pooler.supabase.com")) return "session";
  if (parsed.hostname.endsWith(".supabase.co")) return "direct";
  return "unknown";
}

/** The boot warning for a `DATABASE_URL` that is not the transaction pooler, or null when it is. */
export function poolerWarning(url: string): string | null {
  const mode = poolerMode(url);
  if (mode === "transaction") return null;
  const kind = mode === "unknown" ? "an unknown" : `a ${mode}`;
  return `DATABASE_URL is ${kind} connection; use Supabase's transaction pooler (port 6543)`;
}

/** How long a run may go without recording an outcome before `/v1/status` counts it as failed. */
export const ABANDONED_AFTER = "1 hour";

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
  nomination_id: string | null;
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
  nominationId: r.nomination_id,
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

/**
 * How each chamber writes a bill number. Defined once because both `getBill` and the vote feed
 * report it: if they formatted it separately, the same bill could appear as "H.R. 1013" on one
 * screen and something else on another.
 */
const BILL_LABEL: Record<string, string> = {
  hr: "H.R.",
  s: "S.",
  hres: "H.Res.",
  sres: "S.Res.",
  hjres: "H.J.Res.",
  sjres: "S.J.Res.",
  hconres: "H.Con.Res.",
  sconres: "S.Con.Res.",
};

const billCitation = (type: string, number: number): string =>
  `${BILL_LABEL[type] ?? type.toUpperCase()} ${number}`;

/** The columns both the feed and the vote route select to describe a vote's measure. */
const MEASURE_COLUMNS = `b.bill_type, b.number as bill_number, b.short_title as bill_short_title,
  b.title as bill_title, n.citation as nomination_citation, n.nominee_name, n.position_title, n.organization`;

/** The joins that go with them. */
const MEASURE_JOINS = `left join bills b on b.id = v.bill_id
  left join nominations n on n.id = v.nomination_id`;

interface MeasureRow {
  bill_id: string | null;
  nomination_id: string | null;
  bill_type: string | null;
  bill_number: number | null;
  bill_short_title: string | null;
  bill_title: string | null;
  nomination_citation: string | null;
  nominee_name: string | null;
  position_title: string | null;
  organization: string | null;
}

/** What to call a nomination when it names no one, which military nominations do not. */
const nominationTitle = (r: {
  nominee_name: string | null;
  position_title: string | null;
  organization: string | null;
}): string =>
  r.nominee_name ?? ([r.position_title, r.organization].filter(Boolean).join(", ") || "Nomination");

/** Builds the measure summary from a row that selected `MEASURE_COLUMNS`, or null for a procedural vote. */
const toMeasure = (r: MeasureRow): MeasureSummary | null => {
  if (r.bill_id && r.bill_type && r.bill_number != null) {
    const citation = billCitation(r.bill_type, r.bill_number);
    return { id: r.bill_id, kind: "bill", citation, title: r.bill_short_title ?? r.bill_title ?? citation };
  }
  if (r.nomination_id && r.nomination_citation) {
    return {
      id: r.nomination_id,
      kind: "nomination",
      citation: r.nomination_citation,
      title: nominationTitle(r),
    };
  }
  return null;
};

/**
 * Smallest party bloc that can have a meaningful majority on a vote, for `partyLoyalty`. Below this
 * the member is effectively being compared with themselves.
 */
const MIN_BLOC = 5;

/** `members` columns in the order the queries below select them, used wherever a position carries its member. */
const MEMBER_COLUMNS = "m.bioguide_id, m.first_name, m.last_name, m.party, m.state, m.district, m.chamber";

type PositionRow = MemberRow & { position: MemberVote["position"]; choice: string | null };

const VOTE_COLUMNS = `v.id, v.kind, v.candidates, v.chamber, v.congress, v.session, v.roll_number, v.bill_id,
  v.nomination_id, v.bill_ref, v.question, v.state, v.threshold, v.yea, v.nay, v.present, v.not_voting, v.result,
  v.occurred_at`;

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

interface NominationRow {
  id: string;
  congress: number;
  number: number;
  part: number;
  citation: string;
  nominee_name: string | null;
  position_title: string | null;
  organization: string | null;
  description: string | null;
  nominee_count: number | null;
  is_military: boolean;
  received_on: Date | string | null;
  latest_action_on: Date | string | null;
  latest_action_text: string | null;
}

/** Dates from a `date` column, as YYYY-MM-DD regardless of driver. */
const day = (d: Date | string | null): string | null =>
  d == null ? null : typeof d === "string" ? d.slice(0, 10) : d.toISOString().slice(0, 10);

interface FundingRow {
  cycle: number;
  coverage_start: Date | string | null;
  coverage_end: Date | string | null;
  receipts: string;
  individual_unitemized: string;
  individual_itemized: string;
  pac: string;
  party: string;
  other: string;
  cash_on_hand: string | null;
}

interface PacRow {
  committee_id: string;
  committee_name: string;
  committee_designation: string | null;
  committee_type: string | null;
  org_type: string | null;
  connected_org: string | null;
  direct_amount: string;
  earmarked_amount: string;
}

/**
 * A plain-English label for a giving committee, from FEC's own classification.
 *
 * Only what FEC actually says: CMTE_TP H, S or P for another candidate's own campaign committee
 * ("SMITH FOR CONGRESS"), ORG_TP for the organization behind the committee, and designation D for
 * a leadership PAC, which ORG_TP does not cover. A committee FEC classifies as nothing comes back
 * null rather than being guessed into a category — the page shows no label instead of an invented
 * one.
 *
 * A candidate committee names a politician, not an individual donor, so listing it is allowed;
 * the label is there so it is not read as an interest group's PAC. Computed here from the stored
 * `committee_type`, so it needs no re-ingest.
 */
export const pacKind = (orgType: string | null, designation: string | null, committeeType: string | null = null): string | null => {
  if (committeeType === "H" || committeeType === "S" || committeeType === "P") return "Candidate committee";
  switch (orgType) {
    case "C":
    case "W":
      return "Company";
    case "L":
      return "Union";
    case "T":
      return "Trade group";
    case "M":
      return "Membership group";
    case "V":
      return "Cooperative";
  }
  return designation === "D" ? "Leadership PAC" : null;
};

export function pgRepositories(db: Db): {
  votes: VoteRepository;
  members: MemberRepository;
  bills: BillRepository;
  nominations: NominationRepository;
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
          citation: billCitation(b.bill_type, b.number),
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
    nominations: {
      async getNomination(id) {
        const { rows } = await db.query<NominationRow>(
          `select id, congress, number, part, citation, nominee_name, position_title, organization, description,
                  nominee_count, is_military, received_on, latest_action_on, latest_action_text
             from nominations where id = $1`,
          [id],
        );
        const n = rows[0];
        if (!n) return null;
        const { rows: votes } = await db.query<VoteRow>(
          `select ${VOTE_COLUMNS} from votes v where v.nomination_id = $1 order by v.occurred_at desc nulls last`,
          [id],
        );
        const nomination: Nomination = {
          id: n.id,
          congress: n.congress,
          number: n.number,
          part: n.part,
          citation: n.citation,
          nomineeName: n.nominee_name,
          positionTitle: n.position_title,
          organization: n.organization,
          description: n.description,
          nomineeCount: n.nominee_count,
          isMilitary: n.is_military,
          receivedOn: day(n.received_on),
          latestAction:
            n.latest_action_on && n.latest_action_text
              ? { on: day(n.latest_action_on)!, text: n.latest_action_text }
              : null,
          votes: votes.map(toVote),
        };
        return nomination;
      },
    },
    status: {
      async lastRuns() {
        // lastError is the error of the latest run that has an outcome, so it is null once a later
        // run succeeds. It used to be the latest error ever recorded, which left two errors from the
        // first backfill on 2026-11-12 — both fixed in code within minutes, and followed by clean
        // runs — reading as the current state of production a day later (lesson 35).
        //
        // A run with no finished_at more than ABANDONED_AFTER after it started is counted as failed
        // ("abandoned run"): the process died or was killed without recording an outcome, and
        // leaving it out would let the success before it stand as the latest word. A run younger
        // than that is still in progress and has no outcome yet.
        //
        // lastNewDataAt is the latest successful run that stored anything. An hourly schedule keeps
        // lastSuccessAt fresh even when upstream stops publishing or a parser silently finds
        // nothing, so a gap here is the signal that `stale` no longer gives on its own (lesson 38).
        const { rows } = await db.query<{
          source: string;
          last_success_at: Date | null;
          last_new_data_at: Date | null;
          last_error: string | null;
        }>(
          `with runs as (
             select source, finished_at, items, error,
                    finished_at is null and started_at < now() - interval '${ABANDONED_AFTER}' as abandoned,
                    coalesce(finished_at,
                             case when started_at < now() - interval '${ABANDONED_AFTER}' then started_at end) as ended_at
               from ingest_runs
           )
           select source,
                  max(finished_at) filter (where error is null) as last_success_at,
                  max(finished_at) filter (where error is null and items > 0) as last_new_data_at,
                  (array_agg(case when abandoned then 'abandoned run: it never recorded an outcome' else error end
                             order by ended_at desc) filter (where ended_at is not null))[1] as last_error
             from runs group by source`,
        );
        return rows.map((r) => ({
          source: r.source,
          lastSuccessAt: r.last_success_at ? new Date(r.last_success_at) : null,
          lastNewDataAt: r.last_new_data_at ? new Date(r.last_new_data_at) : null,
          lastError: r.last_error,
        }));
      },
    },
    votes: {
      async getVote(id) {
        const { rows } = await db.query<VoteRow>(`select ${VOTE_COLUMNS} from votes v where v.id = $1`, [id]);
        return rows[0] ? toVote(rows[0]) : null;
      },
      async voteBreakdown(id, memberIds) {
        const [{ rows: parties }, { rows: candidates }, { rows: positions }, { rows: measures }] = await Promise.all([
          // Elections record every position as 'candidate', so they produce no party rows here; their party
          // split comes back in candidateTotals instead.
          db.query<{ party: string; yea: number; nay: number; present: number; not_voting: number }>(
            `select m.party,
                    count(*) filter (where p.position = 'yea')::int as yea,
                    count(*) filter (where p.position = 'nay')::int as nay,
                    count(*) filter (where p.position = 'present')::int as present,
                    count(*) filter (where p.position = 'not_voting')::int as not_voting
               from vote_positions p join members m on m.bioguide_id = p.member_id
              where p.vote_id = $1 and p.position <> 'candidate'
              group by m.party
              order by count(*) desc, m.party`,
            [id],
          ),
          db.query<CandidateTotal>(
            `select m.party, p.choice as candidate, count(*)::int as total
               from vote_positions p join members m on m.bioguide_id = p.member_id
              where p.vote_id = $1 and p.position = 'candidate' and p.choice is not null
              group by m.party, p.choice
              order by count(*) desc, m.party, p.choice`,
            [id],
          ),
          memberIds.length === 0
            ? Promise.resolve({ rows: [] as PositionRow[] })
            : db.query<PositionRow>(
                `select ${MEMBER_COLUMNS}, p.position, p.choice
                   from vote_positions p join members m on m.bioguide_id = p.member_id
                  where p.vote_id = $1 and p.member_id = any($2)
                  order by m.chamber, m.last_name`,
                [id, memberIds],
              ),
          // The vote screen names what was voted on, so it is joined here rather than left to a
          // second request the caller has to know to make.
          db.query<MeasureRow>(
            `select v.bill_id, v.nomination_id, ${MEASURE_COLUMNS}
               from votes v ${MEASURE_JOINS}
              where v.id = $1`,
            [id],
          ),
        ]);
        const partyTotals: PartyTotals[] = parties.map((r) => ({
          party: r.party,
          yea: r.yea,
          nay: r.nay,
          present: r.present,
          notVoting: r.not_voting,
        }));
        const named: MemberPosition[] = positions.map((r) => ({
          member: toMember(r),
          position: r.position,
          choice: r.choice,
        }));
        return {
          partyTotals,
          candidateTotals: candidates,
          positions: named,
          measure: measures[0] ? toMeasure(measures[0]) : null,
        };
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
        // The measure is joined rather than fetched per row: a feed of votes has to name what each
        // one was about, and one request per card is not viable on the Home screen.
        const { rows } = await db.query<
          VoteRow & MeasureRow & { position: MemberVote["position"]; choice: string | null }
        >(
          `select ${VOTE_COLUMNS}, p.position, p.choice, ${MEASURE_COLUMNS}
             from vote_positions p
             join votes v on v.id = p.vote_id
             ${MEASURE_JOINS}
            where p.member_id = $1
            order by v.occurred_at desc nulls last, v.roll_number desc
            limit $2`,
          [bioguideId, limit],
        );
        return rows.map((r) => ({
          vote: toVote(r),
          position: r.position,
          choice: r.choice,
          measure: toMeasure(r),
        }));
      },
      async getMember(bioguideId) {
        const { rows } = await db.query<MemberRow>(
          `select bioguide_id, first_name, last_name, party, state, district, chamber
             from members where bioguide_id = $1`,
          [bioguideId],
        );
        return rows[0] ? toMember(rows[0]) : null;
      },
      async partyLoyalty(bioguideId, party) {
        // "With party" means siding with the majority of one's own party. Votes where the party itself split
        // evenly have no majority to side with, so they are left out of the denominator entirely.
        // A bloc of fewer than MIN_BLOC voters is left out too: for an independent, "their party's majority"
        // is themselves, which would score a meaningless 100%. Those members come back with votes = 0, and
        // the client shows no loyalty figure rather than a figure that means nothing.
        const { rows } = await db.query<{ votes: number; with_party: number; against_party: number }>(
          `with mine as (
             select p.vote_id, p.position
               from vote_positions p join votes v on v.id = p.vote_id
              where p.member_id = $1 and v.kind = 'question' and p.position in ('yea', 'nay')
           ),
           party_majority as (
             select p.vote_id,
                    count(*) filter (where p.position = 'yea') as yea,
                    count(*) filter (where p.position = 'nay') as nay
               from vote_positions p join members m on m.bioguide_id = p.member_id
              where m.party = $2 and p.position in ('yea', 'nay')
                and p.vote_id in (select vote_id from mine)
              group by p.vote_id
           )
           select count(*)::int as votes,
                  count(*) filter (where (pm.yea > pm.nay) = (mine.position = 'yea'))::int as with_party,
                  count(*) filter (where (pm.yea > pm.nay) <> (mine.position = 'yea'))::int as against_party
             from mine join party_majority pm on pm.vote_id = mine.vote_id
            where pm.yea <> pm.nay and pm.yea + pm.nay >= $3`,
          [bioguideId, party, MIN_BLOC],
        );
        const r = rows[0];
        const loyalty: PartyLoyalty = {
          votes: r?.votes ?? 0,
          withParty: r?.with_party ?? 0,
          againstParty: r?.against_party ?? 0,
        };
        return loyalty;
      },

      async funding(bioguideId, limit) {
        const { rows } = await db.query<FundingRow>(
          `select cycle, coverage_start, coverage_end, receipts, individual_unitemized, individual_itemized,
                  pac, party, other, cash_on_hand
             from campaign_finance where member_id = $1`,
          [bioguideId],
        );
        const f = rows[0];
        if (!f) return null;
        // Biggest PAC givers, for the most recent cycle we hold rows for.
        //
        // NOT `cycle = f.cycle`: the two columns are different things. campaign_finance.cycle is
        // the election the campaign is for — 2028 for a senator elected in 2022 — while
        // pac_contributions.cycle is the two-year FEC bulk file the rows came from, currently
        // 2026. Matching them returned no committees at all for every senator, because a senator
        // up in 2028 is still taking PAC money in the 2026 cycle (lesson 33).
        //
        // The PAC test is `isPac` in apps/worker/src/fec.ts (lesson 23), written out in SQL rather
        // than imported: apps/api deliberately has no workspace dependencies, because its Vercel
        // project builds from apps/api as its root directory. The two copies are pinned together by
        // a test — pg.test.ts walks every designation/type pair against the same truth table that
        // fec.test.ts asserts for isPac, so a change to one that is not made to the other fails.
        const { rows: committees } = await db.query<PacRow & { cycle: number }>(
          `select cycle, committee_id, committee_name, committee_designation, committee_type, org_type, connected_org,
                  direct_amount, earmarked_amount
             from pac_contributions
            where member_id = $1
              and cycle = (select max(cycle) from pac_contributions where member_id = $1)
              and coalesce(committee_designation, '') <> 'J'
              and coalesce(committee_type, '') not in ('X', 'Y', 'Z')
            order by direct_amount desc, committee_id
            limit $2`,
          [bioguideId, limit],
        );
        return {
          cycle: f.cycle,
          coverageStart: day(f.coverage_start),
          coverageEnd: day(f.coverage_end),
          receipts: Number(f.receipts),
          smallDollar: Number(f.individual_unitemized),
          itemized: Number(f.individual_itemized),
          pac: Number(f.pac),
          party: Number(f.party),
          other: Number(f.other),
          cashOnHand: f.cash_on_hand === null ? null : Number(f.cash_on_hand),
          committeesCycle: committees[0]?.cycle ?? null,
          committees: committees.map((c) => ({
            committeeId: c.committee_id,
            name: c.committee_name,
            kind: pacKind(c.org_type, c.committee_designation, c.committee_type),
            orgType: c.org_type,
            connectedOrg: c.connected_org,
            direct: Number(c.direct_amount),
            earmarked: Number(c.earmarked_amount),
          })),
        };
      },
    },
  };
}
