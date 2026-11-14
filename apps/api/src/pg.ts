import { createHash } from "node:crypto";
import { AI_DISCLAIMER, DEVICE_SIGNUPS_PER_DAY } from "./app.js";
import { billCitation, billLabel } from "./bills.js";
import type {
  Bill,
  BillListItem,
  BillRepository,
  BillStage,
  CatalogRepository,
  DeviceRegistration,
  DeviceRepository,
  TopicFilter,
  LiveRepository,
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
import { DELEGATE_JURISDICTIONS, FOLDS, type MemberQuery } from "./search.js";

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

/** Postgres error codes for a table or a column that does not exist. */
const MISSING_SCHEMA = new Set(["42P01", "42703"]);

/**
 * Queries for /v1/live, where a database without the M3 migration (`chamber_status`,
 * `votes.broadcast_at`) answers "nothing live" rather than a 500: the route's documented empty
 * state. Any other error still throws. The bill lists (topic pages, search) use it the same way
 * for `bills.stage` and `bills.search` (20261115000000_bill_catalog.sql): the API deploys on merge,
 * before the migration is applied.
 */
const liveQuery =
  (db: Db) =>
  async <T>(text: string, params?: unknown[]): Promise<{ rows: T[] }> => {
    try {
      return await db.query<T>(text, params);
    } catch (error) {
      if (MISSING_SCHEMA.has((error as { code?: string }).code ?? "")) return { rows: [] };
      throw error;
    }
  };

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

/** A bill row as every bill list reads it. */
const LIST_COLUMNS = `b.id, b.congress, b.bill_type, b.number, b.title, b.short_title, b.policy_area, b.stage,
  b.latest_action_on, b.latest_action_text,
  (b.stage is null or b.stage not in ('law', 'adopted', 'vetoed', 'failed'))
    and (b.latest_action_on is null or b.latest_action_on < ($NOW::timestamptz at time zone 'America/New_York')::date - 90) as stalled,
  exists (select 1 from votes v where v.bill_id = b.id) as has_floor_vote`;

/** `LIST_COLUMNS` with the parameter that carries "now" numbered for the query it goes into. */
const listColumns = (nowParam: number) => LIST_COLUMNS.replaceAll("$NOW", `$${nowParam}`);

interface ListRow {
  id: string;
  congress: number;
  bill_type: string;
  number: number;
  title: string;
  short_title: string | null;
  policy_area: string | null;
  stage: BillStage | null;
  latest_action_on: Date | string | null;
  latest_action_text: string | null;
  stalled: boolean;
  has_floor_vote: boolean;
}

const toListItem = (r: ListRow): BillListItem => ({
  id: r.id,
  congress: r.congress,
  type: r.bill_type,
  number: r.number,
  citation: billCitation(r.bill_type, r.number),
  label: billLabel(r.title, r.short_title),
  title: r.title,
  policyArea: r.policy_area,
  stage: r.stage,
  stalled: r.stalled,
  latestAction:
    r.latest_action_on && r.latest_action_text ? { on: day(r.latest_action_on)!, text: r.latest_action_text } : null,
  hasFloorVote: r.has_floor_vote,
});

/** Filters on a topic page. Settled = nothing more will happen: law, adopted, vetoed, failed. */
const TOPIC_FILTER_SQL: Record<TopicFilter, string> = {
  all: "true",
  moving: `(b.stage is null or b.stage not in ('law', 'adopted', 'vetoed', 'failed'))
           and b.latest_action_on >= ($NOW::timestamptz at time zone 'America/New_York')::date - 90`,
  law: "b.stage = 'law'",
  stalled: `(b.stage is null or b.stage not in ('law', 'adopted', 'vetoed', 'failed'))
            and (b.latest_action_on is null or b.latest_action_on < ($NOW::timestamptz at time zone 'America/New_York')::date - 90)`,
};

/** The columns both the feed and the vote route select to describe a vote's measure. */
const MEASURE_COLUMNS = `b.bill_type, b.number as bill_number, b.short_title as bill_short_title,
  b.title as bill_title, b.policy_area as bill_policy_area, n.citation as nomination_citation, n.nominee_name, n.position_title, n.organization`;

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
  bill_policy_area: string | null;
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
    return {
      id: r.bill_id,
      kind: "bill",
      citation,
      title: r.bill_short_title ?? r.bill_title ?? citation,
      policyArea: r.bill_policy_area,
    };
  }
  if (r.nomination_id && r.nomination_citation) {
    return {
      id: r.nomination_id,
      kind: "nomination",
      citation: r.nomination_citation,
      title: nominationTitle(r),
      policyArea: null,
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

/** bill_analyses.analysis as the worker writes it (apps/worker/src/analysis.ts `Analysis`). */
interface StoredClaim {
  text: string;
  citations: { paragraph: number; quote: string; section?: string | null }[];
}

interface AnalysisRow {
  bill_id: string;
  source_stage: string;
  analysis: {
    purpose: StoredClaim | null;
    provisions?: StoredClaim[];
    affectedGroups?: StoredClaim[];
    impact?: StoredClaim[];
    sourceParagraphs?: string[];
  };
  model: string;
  verifier_model: string | null;
  prompt_version: string;
  generated_at: Date | string;
  stale: boolean;
}

interface BillRow {
  id: string;
  congress: number;
  bill_type: string;
  number: number;
  title: string;
  short_title: string | null;
  stage: BillStage | null;
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

/**
 * Who is serving now, over `members m`.
 *
 * `term_end > current_date` alone is wrong for an appointed senator: congress-legislators ends the
 * appointment on the special election's date, and the appointee serves on until the winner is sworn
 * in. On 2026-11-13 that dropped Moody (FL, term_end 2026-11-03, still voting on 11-12) and left
 * Florida and Ohio with one senator each, in `/v1/reps` as well as search (HANDOFF lesson 52). So a
 * term that ended in the last 90 days still counts when nobody's term in that seat (for a senator:
 * that state's Senate seats) has started since it ended, **and** the member has voted after it
 * ended — which a member who resigned or died cannot have done.
 *
 * Days are Eastern, as Congress keeps them: a vote at 8:30 p.m. ET on the last day is 01:30 UTC the
 * next day, and compared in UTC it would read as a vote after the term ended.
 */
const TODAY_ET = "(now() at time zone 'America/New_York')::date";

export const SITTING = `(m.term_end > ${TODAY_ET}
  or (m.term_end > ${TODAY_ET} - 90
      and not exists (select 1 from members s
                       where s.chamber = m.chamber and s.state = m.state
                         and s.district is not distinct from m.district
                         and s.bioguide_id <> m.bioguide_id and s.term_start >= m.term_end)
      and exists (select 1 from vote_positions p join votes v on v.id = p.vote_id
                   where p.member_id = m.bioguide_id
                     and (v.occurred_at at time zone 'America/New_York')::date > m.term_end)))`;

/**
 * A name column as the search compares it: lower case, accents folded, hyphens read as spaces and
 * apostrophes dropped — the SQL twin of `foldName` in `search.ts`, so "velazquez", "ocasio cortez"
 * and "ohalleran" find their members. The accented letters come from `FOLDS` and map one to one,
 * `-` to a space, and the two apostrophes (past the end of the second list) are deleted.
 */
const FOLD_FROM = FOLDS.map(([from]) => from).join("");
const FOLD_TO = FOLDS.map(([from, to]) => to.repeat([...from].length)).join("");
const folded = (column: string): string =>
  `translate(lower(${column}), '${FOLD_FROM}-''’', '${FOLD_TO} ')`;

/** `%` and `_` are LIKE wildcards; a typed one must match itself. Backslash is LIKE's default escape. */
const likeEscape = (s: string): string => s.replace(/[\\%_]/g, (c) => `\\${c}`);

/**
 * The WHERE clause and ordering for one parsed search, with its parameters numbered from `$3`
 * (`$1` is the chamber and `$2` the limit).
 */
/** A folded name anywhere in "first last" or "last first", ranked surname-first; parameters from `$from`. */
function nameMatch(name: string, from: number): { where: string; order: string; params: unknown[] } {
  const text = likeEscape(name);
  const firstLast = folded("first_name || ' ' || last_name");
  const [anywhere, start] = ["$" + from, "$" + (from + 1)];
  return {
    where: `(${firstLast} like ${anywhere} or ${folded("last_name || ' ' || first_name")} like ${anywhere})`,
    // Surname starts with it, then full name starts with it, then anywhere.
    order: `case when ${folded("last_name")} like ${start} then 0 when ${firstLast} like ${start} then 1 else 2 end`,
    params: [`%${text}%`, `${text}%`],
  };
}

export function searchFilter(query: MemberQuery): { where: string; order: string; params: unknown[] } {
  switch (query.kind) {
    case "seat":
      // A delegate jurisdiction has one seat whatever number was typed ("DC-1", "PR-AL").
      return DELEGATE_JURISDICTIONS.has(query.state)
        ? { where: "state = $3 and chamber = 'house'", order: "district", params: [query.state] }
        : { where: "state = $3 and chamber = 'house' and district = $4", order: "district", params: [query.state, query.district] };
    case "state": {
      // The state's members by district, then anyone whose name matches the same text ("Washington").
      const name = nameMatch(query.name, 4);
      return {
        where: `(state = $3 or ${name.where})`,
        order: `case when state = $3 then 0 else 1 end, case when state = $3 then district end nulls first, ${name.order}`,
        params: [query.state, ...name.params],
      };
    }
    case "name":
      return nameMatch(query.text, 3);
  }
}

export function pgRepositories(db: Db): {
  votes: VoteRepository;
  members: MemberRepository;
  bills: BillRepository;
  nominations: NominationRepository;
  status: StatusRepository;
  live: LiveRepository;
  catalog: CatalogRepository;
  devices: DeviceRepository;
} {
  const registerOnce = async (keyHash: string, reg: DeviceRegistration, now: Date) => {
    // An APNs token belongs to one install. A phone that reinstalled Floor makes a new key and
    // may get its old token back: the token moves to the new registration rather than failing
    // the unique constraint (or alerting twice).
    const { rows: moved } = await db.query(
      `update devices set apns_token = case when apns_token = $2 then null else apns_token end,
                          push_to_start_token = case when push_to_start_token = $3 then null else push_to_start_token end
        where key_hash <> $1 and (apns_token = $2 or push_to_start_token = $3)
        returning id`,
      [keyHash, reg.apnsToken, reg.pushToStartToken],
    );
    // A count only: a token or key in a log line would name a phone.
    if (moved.length) console.info(`device registration: ${moved.length} token(s) moved to a new key`);
    // One statement, so a registration and its subscription list change together. The delete
    // and the upsert touch different rows (those not in the new list, and those in it).
    await db.query(
      `with d as (
         insert into devices (key_hash, apns_token, apns_env, push_to_start_token, vote_opened, live_activities, updated_at)
         values ($1, $2, $3, $4, $5, $8, $6)
         on conflict (key_hash) do update set apns_token = excluded.apns_token, apns_env = excluded.apns_env,
           push_to_start_token = excluded.push_to_start_token, vote_opened = excluded.vote_opened,
           live_activities = excluded.live_activities, updated_at = excluded.updated_at
         returning id
       ), x as (
         select distinct on (kind, id) kind, id, how_voted
           from jsonb_to_recordset($7::jsonb) as r(kind text, id text, how_voted boolean)
       ), gone as (
         delete from device_subscriptions s using d
          where s.device_id = d.id
            and not exists (select 1 from x where x.kind = s.target_kind and x.id = s.target_id)
       )
       insert into device_subscriptions (device_id, target_kind, target_id, how_voted)
       select d.id, x.kind, x.id, x.how_voted from d, x
       on conflict (device_id, target_kind, target_id) do update set how_voted = excluded.how_voted`,
      [
        keyHash,
        reg.apnsToken,
        reg.apnsEnvironment,
        reg.pushToStartToken,
        reg.voteOpened,
        now.toISOString(),
        JSON.stringify(reg.subscriptions.map((x) => ({ kind: x.kind, id: x.id, how_voted: x.howVoted }))),
        reg.liveActivities,
      ],
    );
  };

  /**
   * A key this database has not seen counts against its caller's daily allowance of new
   * registrations (`DEVICE_SIGNUPS_PER_DAY`), kept in Postgres so every serverless instance shares
   * the count. The caller is stored as SHA-256(address, day) only.
   */
  const admitNew = async (keyHash: string, caller: string, now: Date): Promise<boolean> => {
    const { rows: known } = await db.query("select 1 from devices where key_hash = $1", [keyHash]);
    if (known.length) return true;
    const day = now.toISOString().slice(0, 10);
    const ipHash = createHash("sha256").update(`${caller}|${day}`).digest("hex");
    const { rows } = await db.query<{ count: number }>(
      `insert into device_signups (ip_hash, day, count) values ($1, $2::date, 1)
       on conflict (ip_hash, day) do update set count = device_signups.count + 1
       returning count`,
      [ipHash, day],
    );
    return (rows[0]?.count ?? 0) <= DEVICE_SIGNUPS_PER_DAY;
  };

  return {
    devices: {
      async register(keyHash, reg, now, caller) {
        if (!(await admitNew(keyHash, caller, now))) return "limited";
        // Two registrations racing for one token (a reinstall registering twice at once) can both
        // pass the token move and collide on the unique constraint; the second try sees the first.
        try {
          await registerOnce(keyHash, reg, now);
        } catch (error) {
          if ((error as { code?: string }).code !== "23505") throw error;
          await registerOnce(keyHash, reg, now);
        }
        return "ok";
      },
      async unregister(keyHash) {
        const { rows } = await db.query("delete from devices where key_hash = $1 returning id", [keyHash]);
        return rows.length > 0;
      },
      async setActivityToken(keyHash, voteId, token, now) {
        const { rows } = await db.query<{ device: string | null; vote: string | null }>(
          `select (select id from devices where key_hash = $1)::text as device, (select id from votes where id = $2) as vote`,
          [keyHash, voteId],
        );
        if (!rows[0]?.device) return "no_device";
        if (!rows[0].vote) return "no_vote";
        await db.query(
          `insert into live_activity_tokens (device_id, vote_id, token, updated_at) values ($1, $2, $3, $4)
           on conflict (device_id, vote_id) do update set token = excluded.token, updated_at = excluded.updated_at`,
          [rows[0].device, voteId, token, now.toISOString()],
        );
        return "ok";
      },
      async removeActivityToken(keyHash, voteId) {
        await db.query(
          `delete from live_activity_tokens t using devices d where d.id = t.device_id and d.key_hash = $1 and t.vote_id = $2`,
          [keyHash, voteId],
        );
      },
    },
    catalog: {
      async topicCounts(congress) {
        const { rows } = await db.query<{ name: string; bills: number; voted: number; latest: Date | string | null }>(
          `select b.policy_area as name, count(*)::int as bills,
                  count(*) filter (where exists (select 1 from votes v where v.bill_id = b.id))::int as voted,
                  max(b.latest_action_on) as latest
             from bills b
            where b.congress = $1 and b.policy_area is not null
            group by b.policy_area`,
          [congress],
        );
        return rows.map((r) => ({ name: r.name, bills: r.bills, billsWithFloorVote: r.voted, latestActionOn: day(r.latest) }));
      },
      async topicBills(congress, topic, filter, after, limit, now) {
        // Keyset pagination on (latest_action_on desc nulls last, id desc), the bills_topic index's order.
        const params: unknown[] = [congress, topic, now.toISOString(), limit];
        let page = "true";
        if (after) {
          params.push(after.id);
          if (after.on === null) {
            page = `b.latest_action_on is null and b.id < $5`;
          } else {
            params.push(after.on);
            page = `(b.latest_action_on < $6::date or (b.latest_action_on = $6::date and b.id < $5) or b.latest_action_on is null)`;
          }
        }
        const { rows } = await liveQuery(db)<ListRow>(
          `select ${listColumns(3)} from bills b
            where b.congress = $1 and b.policy_area = $2 and ${TOPIC_FILTER_SQL[filter].replaceAll("$NOW", "$3")} and ${page}
            order by b.latest_action_on desc nulls last, b.id desc
            limit $4`,
          params,
        );
        return rows.map((r) => ({ bill: toListItem(r), at: { on: day(r.latest_action_on), id: r.id } }));
      },
      async billsByNumber(type, number, congress, now) {
        const { rows } = await liveQuery(db)<ListRow>(
          `select ${listColumns(4)} from bills b
            where b.bill_type = $1 and b.number = $2 and ($3::int is null or b.congress = $3::int)
            order by b.congress desc`,
          [type, number, congress, now.toISOString()],
        );
        return rows.map(toListItem);
      },
      async searchBills(q, congress, limit, now) {
        // websearch_to_tsquery reads what people type ("rural health", "\"clean water\"", "-tariff")
        // and never throws on stray punctuation. The current Congress ranks ahead of older ones.
        const { rows } = await liveQuery(db)<ListRow>(
          `select ${listColumns(4)} from bills b, websearch_to_tsquery('english', $1) as query
            where b.search @@ query
            order by ts_rank(b.search, query) * (case when b.congress = $2 then 2 else 1 end) desc,
                     b.latest_action_on desc nulls last, b.id desc
            limit $3`,
          [q, congress, limit, now.toISOString()],
        );
        return rows.map(toListItem);
      },
    },
    live: {
      async chambers() {
        const { rows } = await liveQuery(db)<{
          chamber: "house" | "senate";
          in_session: boolean;
          convenes_at: Date | null;
          legislative_day: Date | string | null;
          checked_at: Date;
        }>("select chamber, in_session, convenes_at, legislative_day, checked_at from chamber_status order by chamber");
        return rows.map((r) => ({
          chamber: r.chamber,
          inSession: r.in_session,
          convenesAt: r.convenes_at ? new Date(r.convenes_at).toISOString() : null,
          legislativeDay: day(r.legislative_day),
          checkedAt: new Date(r.checked_at).toISOString(),
        }));
      },
      async liveVotes(finalAfter, now) {
        // Open: named by a floor source in the last day (an older one is stuck: its XML never parsed).
        // Final: published by the live worker since `finalAfter` (`broadcast_at`, which every final
        // vote gets however it was stored), and itself from the last day, so a backfilled old vote
        // the worker marked without announcing is not "just final".
        const { rows } = await liveQuery(db)<
          VoteRow & MeasureRow & { measure_bill_id: string | null; opened_at: Date | null; announced_at: Date | null; posted_at: Date | null }
        >(
          // An open vote is linked to its bill only after it is final (the worker's bill linking), so
          // the bill is also found from the roll call's own reference, "H R 1013" or "H.R. 1013".
          `select ${VOTE_COLUMNS}, ${MEASURE_COLUMNS}, b.id as measure_bill_id, v.opened_at, v.announced_at, v.posted_at
             from votes v
             left join lateral (
               select v.congress || '-' || m[1] || '-' || m[2] as id
                 from regexp_match(regexp_replace(lower(coalesce(v.bill_ref, '')), '[^a-z0-9]', '', 'g'),
                                   '^(hr|s|hres|sres|hjres|sjres|hconres|sconres)([0-9]+)$') as m
             ) ref on true
             left join bills b on b.id = coalesce(v.bill_id, ref.id)
             left join nominations n on n.id = v.nomination_id
            where (v.state = 'open' and v.announced_at > $2::timestamptz - interval '1 day')
               or (v.state = 'final' and v.broadcast_at > $1
                   and coalesce(v.occurred_at, v.broadcast_at) > $2::timestamptz - interval '1 day')
            order by coalesce(v.broadcast_at, v.announced_at) desc, v.id desc
            limit 100`,
          [finalAfter.toISOString(), now.toISOString()],
        );
        const iso = (d: Date | null) => (d ? new Date(d).toISOString() : null);
        return rows.map((r) => ({
          ...toVote(r),
          openedAt: iso(r.opened_at),
          announcedAt: iso(r.announced_at),
          postedAt: iso(r.posted_at),
          measure: toMeasure({ ...r, bill_id: r.measure_bill_id }),
        }));
      },
    },
    bills: {
      async getBill(id) {
        const { rows } = await db.query<BillRow>(
          // The stage through to_jsonb, so this route keeps working on a database without the
          // Round 10 migration (it reads null there) rather than failing every bill page.
          `select b.id, b.congress, b.bill_type, b.number, b.title, b.short_title, b.introduced_on, b.origin_chamber,
                  to_jsonb(b) ->> 'stage' as stage, b.policy_area, b.summary, b.summary_stage, b.latest_action_on, b.latest_action_text, b.cbo_estimates,
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
            `select ${VOTE_COLUMNS} from votes v where v.bill_id = $1 and v.state = 'final' order by v.occurred_at desc nulls last`,
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
          label: billLabel(b.title, b.short_title),
          stage: b.stage,
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
      async getAnalysis(id) {
        // Prefer the analysis of the summary stage the bill is at now; fall back to the newest one.
        // `stale` uses the worker's source hash (stage || '\n' || summary, sha256) to say the
        // summary has changed since this analysis was made.
        const { rows } = await db.query<AnalysisRow>(
          `select a.bill_id, a.source_stage, a.analysis, a.model, a.verifier_model, a.prompt_version, a.generated_at,
                  a.source_hash is distinct from
                    encode(sha256(convert_to(coalesce(b.summary_stage, '') || E'\\n' || coalesce(b.summary, ''), 'UTF8')), 'hex')
                    as stale
             from bill_analyses a join bills b on b.id = a.bill_id
            where a.bill_id = $1 and a.source_kind = 'crs_summary'
            order by (a.source_stage = coalesce(b.summary_stage, '')) desc, a.generated_at desc
            limit 1`,
          [id],
        );
        const a = rows[0];
        if (!a) return null;
        const claim = (c: StoredClaim) => ({
          text: c.text,
          ai: true as const,
          citations: c.citations.map((x) => ({ paragraph: x.paragraph, quote: x.quote, section: x.section ?? null })),
        });
        return {
          billId: a.bill_id,
          ai: true,
          label: "AI-generated",
          disclaimer: AI_DISCLAIMER,
          source: { kind: "crs_summary", stage: a.source_stage, paragraphs: a.analysis.sourceParagraphs ?? [], stale: a.stale },
          model: a.model,
          verifierModel: a.verifier_model,
          promptVersion: a.prompt_version,
          generatedAt: new Date(a.generated_at).toISOString(),
          purpose: a.analysis.purpose ? claim(a.analysis.purpose) : null,
          provisions: (a.analysis.provisions ?? []).map(claim),
          affectedGroups: (a.analysis.affectedGroups ?? []).map(claim),
          impact: (a.analysis.impact ?? []).map(claim),
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
          `select ${VOTE_COLUMNS} from votes v where v.nomination_id = $1 and v.state = 'final' order by v.occurred_at desc nulls last`,
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
      async recentVotes(chamber, limit, before, topics) {
        // Final only: an open vote's tally is the floor's, not the roll call's (as on bill pages).
        // `topics` narrows to votes on bills in those policy areas (the Following feed's topics).
        const { rows } = await db.query<VoteRow & MeasureRow>(
          `select ${VOTE_COLUMNS}, ${MEASURE_COLUMNS}
             from votes v
             ${MEASURE_JOINS}
            where v.state = 'final' and ($1::chamber is null or v.chamber = $1::chamber)
              and ($3::timestamptz is null or v.occurred_at < $3::timestamptz)
              and ($4::text[] is null or b.policy_area = any($4::text[]))
            order by v.occurred_at desc nulls last, v.roll_number desc
            limit $2`,
          [chamber ?? null, limit, before?.toISOString() ?? null, topics ?? null],
        );
        return rows.map((r) => ({ vote: toVote(r), measure: toMeasure(r) }));
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
             from members m
            where state = $1 and ${SITTING}
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
      async search(query, chamber, limit) {
        const { where, order, params } = searchFilter(query);
        const { rows } = await db.query<MemberRow>(
          `select bioguide_id, first_name, last_name, party, state, district, chamber
             from members m
            where ${SITTING}
              and ($1::chamber is null or chamber = $1::chamber)
              and ${where}
            order by case chamber when 'senate' then 0 else 1 end, ${order}, last_name, first_name
            limit $2`,
          [chamber ?? null, limit, ...params],
        );
        return rows.map(toMember);
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
