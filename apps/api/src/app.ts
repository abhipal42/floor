import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { cors } from "hono/cors";
import type { DistrictMatch, Place } from "./district.js";
import { POLICY_AREAS, matchTopics, parseBillNumber, topicNamed } from "./bills.js";
import { rateLimit, type LimitStore } from "./limit.js";

/*
 * The enums below are registered as their own components so the OpenAPI document refers to each by
 * $ref instead of inlining a fresh copy per schema. Inlined, a generator emits one Swift type per
 * occurrence — Vote.chamber and Member.chamber would be different, incompatible enums — so these
 * stay shared even though each is only a handful of strings.
 */
export const ChamberSchema = z.enum(["house", "senate"]).openapi("Chamber");

export const VoteKindSchema = z
  .enum(["question", "election"])
  .openapi("VoteKind", { description: "election = Speaker election (candidate votes)" });

export const VoteStateSchema = z.enum(["scheduled", "open", "final"]).openapi("VoteState");

export const VoteThresholdSchema = z
  .enum(["majority", "three_fifths_sworn", "two_thirds"])
  .openapi("VoteThreshold");

export const PositionSchema = z
  .enum(["yea", "nay", "present", "not_voting", "candidate"])
  .openapi("Position", { description: "candidate is only used on Speaker elections" });

export type Chamber = z.infer<typeof ChamberSchema>;
export type Position = z.infer<typeof PositionSchema>;

/*
 * Likewise the object shapes below. Inline, a generator names them after where they appear —
 * Bill.actions became `Bill.ActionsPayloadPayload` — and a shape used twice (latestAction, on both
 * Bill and Nomination) becomes two unrelated types.
 */
export const VoteTotalsSchema = z
  .object({
    yea: z.number().int(),
    nay: z.number().int(),
    present: z.number().int(),
    notVoting: z.number().int(),
  })
  .openapi("VoteTotals");

export const CandidateSchema = z
  .object({ name: z.string().openapi({ example: "Jeffries" }), total: z.number().int() })
  .openapi("Candidate");

export const LatestActionSchema = z
  .object({ on: z.string().openapi({ example: "2025-05-20" }), text: z.string() })
  .openapi("LatestAction");

export const CboEstimateSchema = z
  .object({ title: z.string(), url: z.string(), pubDate: z.string() })
  .openapi("CboEstimate");

export const DistrictSchema = z
  .object({
    congress: z.number().int(),
    state: z.string().openapi({ example: "TX" }),
    district: z.number().int(),
    countyFips: z.string().nullable().openapi({ example: "48453" }),
  })
  .openapi("District");

export const VoteSchema = z
  .object({
    id: z.string().openapi({ example: "house-119-1-100" }),
    kind: VoteKindSchema,
    chamber: ChamberSchema,
    congress: z.number().int(),
    session: z.number().int(),
    rollNumber: z.number().int().nullable(),
    question: z.string(),
    billId: z.string().nullable(),
    nominationId: z.string().nullable().openapi({ example: "119-pn-1093-3" }),
    billRef: z.string().nullable().openapi({ example: "H CON RES 14" }),
    occurredAt: z.string().nullable().openapi({ example: "2025-04-10T15:08:00.000Z" }),
    state: VoteStateSchema,
    threshold: VoteThresholdSchema,
    totals: VoteTotalsSchema,
    candidates: z.array(CandidateSchema),
    result: z.string().nullable(),
  })
  .openapi("Vote");

export type Vote = z.infer<typeof VoteSchema>;

export const MemberSchema = z
  .object({
    bioguideId: z.string().openapi({ example: "A000370" }),
    firstName: z.string(),
    lastName: z.string(),
    party: z.string().openapi({ example: "D" }),
    state: z.string().openapi({ example: "NC" }),
    district: z.number().int().nullable(),
    chamber: ChamberSchema,
  })
  .openapi("Member");

export type Member = z.infer<typeof MemberSchema>;

export const PartyTotalsSchema = z
  .object({
    party: z.string().openapi({ example: "D" }),
    yea: z.number().int(),
    nay: z.number().int(),
    present: z.number().int(),
    notVoting: z.number().int(),
  })
  .openapi("PartyTotals");

export type PartyTotals = z.infer<typeof PartyTotalsSchema>;

export const CandidateTotalSchema = z
  .object({
    party: z.string().openapi({ example: "D" }),
    candidate: z.string().openapi({ example: "Jeffries" }),
    total: z.number().int(),
  })
  .openapi("CandidateTotal");

export type CandidateTotal = z.infer<typeof CandidateTotalSchema>;

export const MemberPositionSchema = z
  .object({
    member: MemberSchema,
    position: PositionSchema,
    choice: z.string().nullable().openapi({ description: "Candidate named in a Speaker election" }),
  })
  .openapi("MemberPosition");

export type MemberPosition = z.infer<typeof MemberPositionSchema>;

/** How often a member voted with the majority of their own party. */
export const PartyLoyaltySchema = z
  .object({
    votes: z
      .number()
      .int()
      .openapi({ description: "Yea/nay votes counted: those where the member voted yea or nay and their party was not itself tied" }),
    withParty: z.number().int(),
    againstParty: z.number().int(),
  })
  .openapi("PartyLoyalty");

export type PartyLoyalty = z.infer<typeof PartyLoyaltySchema>;

const MemberDetailSchema = z
  .object({ member: MemberSchema, partyLoyalty: PartyLoyaltySchema })
  .openapi("MemberDetail");

/**
 * One committee's giving to a member over a cycle.
 *
 * `direct` and `earmarked` are kept apart because they are different money: direct is the
 * committee's own check, earmarked is individuals' money it passed through (lesson 23). Neither
 * is comparable to a contribution limit — the cap is per election and a cycle can hold several,
 * so a client must not present either figure as "the maximum".
 */
export const PacCheckSchema = z
  .object({
    committeeId: z.string().openapi({ example: "C00002550" }),
    name: z.string().openapi({ example: "American Trucking Associations PAC" }),
    kind: z
      .string()
      .nullable()
      .openapi({ example: "Trade group", description: "From FEC's committee type for another candidate's own committee ('Candidate committee'), else its organization type or leadership-PAC designation; null when FEC classifies the committee as nothing" }),
    orgType: z.string().nullable().openapi({ example: "T", description: "Raw FEC ORG_TP, so a client can classify differently" }),
    connectedOrg: z.string().nullable().openapi({ example: "American Trucking Associations" }),
    direct: z.number().openapi({ description: "The committee's own contributions" }),
    earmarked: z.number().openapi({ description: "Individuals' money passed through it" }),
  })
  .openapi("PacCheck");

export type PacCheck = z.infer<typeof PacCheckSchema>;

/**
 * What a member's campaign reported receiving, plus which committees reported giving to it.
 *
 * The two halves come from different FEC sources and do not agree (lesson 24): `totals` is the
 * campaign's own report of what it received, `committees` is what committees reported giving.
 * They are labelled separately here so a client never presents one as a breakdown of the other.
 */
export const FundingSchema = z
  .object({
    cycle: z.number().int().openapi({ example: 2026, description: "The election this campaign is for" }),
    coverageStart: z.string().nullable().openapi({ example: "2025-01-01" }),
    coverageEnd: z.string().nullable().openapi({ example: "2026-10-14", description: "Through which the figures run" }),
    receipts: z.number().openapi({ description: "Total raised this campaign to date, as the campaign reported it" }),
    smallDollar: z.number().openapi({ description: "Individual contributions under $200 per donor (unitemized)" }),
    itemized: z.number().openapi({ description: "Individual contributions itemized by FEC" }),
    pac: z.number().openapi({ description: "From other political committees" }),
    party: z.number().openapi({ description: "From party committees" }),
    other: z.number().openapi({ description: "Transfers, the candidate's own money, refunds and other receipts" }),
    cashOnHand: z.number().nullable(),
    committeesCycle: z.number().int().nullable().openapi({
      example: 2026,
      description:
        "The two-year FEC cycle `committees` covers, which is NOT `cycle`: a senator's campaign may be for 2028 " +
        "while the committee filings are the 2026 cycle. Null when we hold no committee rows for them.",
    }),
    committees: z
      .array(PacCheckSchema)
      .openapi({ description: "Biggest PAC givers by direct amount. Party and joint fundraising committees are excluded — neither is a PAC check (lesson 23)" }),
  })
  .openapi("Funding");

export type Funding = z.infer<typeof FundingSchema>;

const MemberFundingSchema = z
  .object({ member: MemberSchema, funding: FundingSchema.nullable() })
  .openapi("MemberFunding", { description: "funding is null for a member FEC has no current-campaign totals for" });

/**
 * Just enough about the bill or nomination a vote was on to label it in a list.
 *
 * Carried on each row so a feed of votes can name what they were about without a request per row:
 * the Home screen shows a member's recent votes, and one round trip per card is not viable.
 */
export const MeasureSummarySchema = z
  .object({
    id: z.string().openapi({ example: "119-hr-1013" }),
    kind: z.enum(["bill", "nomination"]),
    citation: z.string().openapi({ example: "H.R. 1013", description: "As the chamber cites it" }),
    title: z.string().openapi({
      description:
        "A bill's short title where it has one, else its full title; a nomination's nominee, or the post for a military nomination that names nobody",
    }),
  })
  .openapi("MeasureSummary");

export type MeasureSummary = z.infer<typeof MeasureSummarySchema>;

/**
 * `GET /v1/votes/{id}`. The vote plus what the vote screen needs beyond the headline totals.
 * Built from `VoteSchema.shape` rather than `.extend()` so it registers under its own name.
 */
export const VoteDetailSchema = z
  .object({
    ...VoteSchema.shape,
    partyTotals: z
      .array(PartyTotalsSchema)
      .openapi({ description: "Per-party counts. An election reports its party split in candidateTotals instead." }),
    candidateTotals: z
      .array(CandidateTotalSchema)
      .openapi({ description: "Which candidate each party voted for. Only populated when kind = election." }),
    positions: z
      .array(MemberPositionSchema)
      .openapi({ description: "How the members named in ?members= voted. Empty when the query names none." }),
    measure: MeasureSummarySchema.nullable().openapi({
      description: "What was voted on, or null for a procedural vote that refers to no measure",
    }),
  })
  .openapi("VoteDetail");

export type VoteDetail = z.infer<typeof VoteDetailSchema>;

const RepsSchema = z
  .object({
    district: DistrictSchema,
    members: z.array(MemberSchema),
  })
  .openapi("Reps");

export const MemberVoteSchema = z
  .object({
    vote: VoteSchema,
    position: PositionSchema,
    choice: z.string().nullable().openapi({ description: "Candidate named in a Speaker election" }),
    measure: MeasureSummarySchema.nullable().openapi({
      description: "null for a procedural vote that refers to no measure, e.g. a motion to adjourn",
    }),
  })
  .openapi("MemberVote");

export type MemberVote = z.infer<typeof MemberVoteSchema>;

const ErrorSchema = z.object({ error: z.string() }).openapi("Error");

/** Where the API reads votes from. Postgres in production, in-memory in tests. */
export interface VoteRepository {
  getVote(id: string): Promise<Vote | null>;
  /** Per-party counts for the vote, plus how each of `memberIds` voted. */
  voteBreakdown(
    id: string,
    memberIds: string[],
  ): Promise<{
    partyTotals: PartyTotals[];
    candidateTotals: CandidateTotal[];
    positions: MemberPosition[];
    measure: MeasureSummary | null;
  }>;
}

export interface MemberRepository {
  /** The House member for the district plus the state's senators. */
  membersFor(state: string, district: number): Promise<Member[]>;
  /** A member's most recent recorded votes, newest first. */
  recentVotes(bioguideId: string, limit: number): Promise<MemberVote[]>;
  /** One member, or null when we have no record of them. */
  getMember(bioguideId: string): Promise<Member | null>;
  /** How often they sided with their own party. `party` comes from the member row. */
  partyLoyalty(bioguideId: string, party: string): Promise<PartyLoyalty>;
  /**
   * Their current campaign's money, or null when FEC has no totals for them.
   * `committees` is capped at `limit` rows, biggest direct giver first.
   */
  funding(bioguideId: string, limit: number): Promise<Funding | null>;
}

export const BillActionSchema = z
  .object({
    actedOn: z.string().openapi({ example: "2025-05-20" }),
    chamber: ChamberSchema.nullable(),
    text: z.string(),
  })
  .openapi("BillAction");

export const BillSchema = z
  .object({
    id: z.string().openapi({ example: "119-hconres-14" }),
    congress: z.number().int(),
    type: z.string().openapi({ example: "hconres" }),
    number: z.number().int(),
    citation: z.string().openapi({ example: "H.Con.Res. 14", description: "As the chamber cites it" }),
    title: z.string(),
    shortTitle: z.string().nullable(),
    sponsor: MemberSchema.nullable(),
    introducedOn: z.string().nullable(),
    originChamber: ChamberSchema.nullable(),
    policyArea: z.string().nullable(),
    summary: z.string().nullable().openapi({ description: "Latest Congressional Research Service summary, plain text" }),
    summaryStage: z.string().nullable(),
    latestAction: LatestActionSchema.nullable(),
    cboEstimates: z.array(CboEstimateSchema),
    actions: z.array(BillActionSchema),
    votes: z.array(VoteSchema),
  })
  .openapi("Bill");

export type Bill = z.infer<typeof BillSchema>;

/** Shown with every AI analysis. The app shows it too; it is in the response so no client can omit it by accident. */
export const AI_DISCLAIMER =
  "Written by AI from the Congressional Research Service summary, and checked against it by a second AI pass. " +
  "It may contain errors. Each line links to the paragraph it came from; read that before relying on it.";

export const AnalysisCitationSchema = z
  .object({
    paragraph: z.number().int().openapi({ description: "1-based index into source.paragraphs", example: 3 }),
    quote: z.string().openapi({ description: "Verbatim excerpt of that paragraph", example: "extends several expiring programs and authorities" }),
    section: z
      .string()
      .nullable()
      .openapi({ description: "The bill section, as CRS labels the paragraph; null when it names none", example: "Sec. 101" }),
  })
  .openapi("AnalysisCitation");

export const AnalysisClaimSchema = z
  .object({
    text: z.string(),
    ai: z.literal(true).openapi({ description: "Always true: this line was written by AI" }),
    citations: z.array(AnalysisCitationSchema).openapi({ description: "At least one" }),
  })
  .openapi("AnalysisClaim");

export const BillAnalysisSchema = z
  .object({
    billId: z.string().openapi({ example: "118-hr-6363" }),
    ai: z.literal(true),
    label: z.literal("AI-generated"),
    disclaimer: z.string(),
    source: z
      .object({
        kind: z.literal("crs_summary"),
        stage: z.string().openapi({ example: "Public Law", description: "The CRS summary version analysed" }),
        paragraphs: z.array(z.string()).openapi({ description: "The summary as analysed; citations index into this" }),
        stale: z
          .boolean()
          .openapi({ description: "The bill's summary has changed since; a new analysis is pending. Citations still resolve against paragraphs." }),
      })
      .openapi("AnalysisSource"),
    model: z.string().openapi({ example: "claude-sonnet-5-5" }),
    verifierModel: z.string().nullable(),
    promptVersion: z.string().openapi({ example: "bill-analysis/1" }),
    generatedAt: z.string(),
    // The non-nullable uses come first on purpose: registered after them, `purpose`'s nullable stays
    // on this property instead of being hoisted onto the shared AnalysisClaim component.
    provisions: z.array(AnalysisClaimSchema),
    affectedGroups: z.array(AnalysisClaimSchema),
    impact: z.array(AnalysisClaimSchema),
    purpose: AnalysisClaimSchema.nullable().openapi({ description: "null when no purpose line survived verification" }),
  })
  .openapi("BillAnalysis");

export type BillAnalysis = z.infer<typeof BillAnalysisSchema>;

export interface BillRepository {
  getBill(id: string): Promise<Bill | null>;
  /** The analysis of the bill's current summary stage, else its most recent one; null when there is none. */
  getAnalysis(id: string): Promise<BillAnalysis | null>;
}

export const NominationSchema = z
  .object({
    id: z.string().openapi({ example: "119-pn-1093-3" }),
    congress: z.number().int(),
    number: z.number().int(),
    part: z.number().int().openapi({ description: "0 unless the Senate split the nomination into parts" }),
    citation: z.string().openapi({ example: "PN1093-3", description: "As the Senate cites it on the roll call" }),
    nomineeName: z
      .string()
      .nullable()
      .openapi({ description: "null for military nominations, which promote officers in bulk; show the position instead" }),
    positionTitle: z.string().nullable().openapi({ example: "United States District Judge for the Southern District of Ohio" }),
    organization: z.string().nullable().openapi({ example: "The Judiciary" }),
    description: z.string().nullable().openapi({ description: "Congress.gov's full sentence, including the \"vice ...\" clause" }),
    nomineeCount: z.number().int().nullable(),
    isMilitary: z.boolean(),
    receivedOn: z.string().nullable(),
    latestAction: LatestActionSchema.nullable(),
    votes: z.array(VoteSchema),
  })
  .openapi("Nomination");

export type Nomination = z.infer<typeof NominationSchema>;

export interface NominationRepository {
  getNomination(id: string): Promise<Nomination | null>;
}

export const SourceStatusSchema = z
  .object({
    source: z.string().openapi({ example: "house_rollcalls" }),
    lastSuccessAt: z.string().nullable(),
    lastNewDataAt: z.string().nullable().openapi({
      description:
        "When a successful run last stored anything. A scheduled job keeps lastSuccessAt fresh even when " +
        "upstream stops publishing or nothing is found, so a long gap here, not `stale`, is what shows that",
    }),
    lastError: z.string().nullable().openapi({
      description:
        "The error of the latest run with an outcome, if it failed; null once a later run succeeds. A run " +
        "that never recorded an outcome within an hour reads as \"abandoned run\"",
    }),
    stale: z.boolean(),
  })
  .openapi("SourceStatus");

export type SourceStatus = z.infer<typeof SourceStatusSchema>;

/** How long each source may go without a successful run before it counts as stale. */
export const MAX_AGE_HOURS: Record<string, number> = {
  members: 48,
  house_rollcalls: 24,
  senate_rollcalls: 24,
  bills: 48,
  nominations: 48,
};

/**
 * One chamber as the live worker last saw it. Written by the worker every poll (10 s in session,
 * 5 min otherwise), so a `checkedAt` minutes old means the worker is down, not that nothing happened.
 */
export const ChamberStatusSchema = z
  .object({
    chamber: ChamberSchema,
    inSession: z.boolean().openapi({ description: "Sitting now, or within 15 minutes of convening" }),
    convenesAt: z.string().nullable().openapi({ description: "Next (or current) convening, when the chamber has published it" }),
    legislativeDay: z.string().nullable().openapi({ example: "2026-11-10" }),
    checkedAt: z.string().openapi({ description: "When the live worker last polled this chamber" }),
  })
  .openapi("ChamberStatus");

export type ChamberStatus = z.infer<typeof ChamberStatusSchema>;

/**
 * A vote with the live layer's timestamps. `state` is `open` from the moment a floor source names the
 * roll call until its official XML is stored, then `final`. Our sources only name a roll call once it
 * is called, so "open" means "on the record, details not yet posted", not "members are voting now".
 */
export const LiveVoteSchema = z
  .object({
    ...VoteSchema.shape,
    openedAt: z.string().nullable().openapi({ description: "The floor's own time for the vote (House only)" }),
    announcedAt: z.string().nullable().openapi({ description: "When the worker first saw a floor source name it" }),
    postedAt: z
      .string()
      .nullable()
      .openapi({ description: "When the worker first saw the roll call XML, polling live; null if it was backfilled" }),
  })
  .openapi("LiveVote");

export type LiveVote = z.infer<typeof LiveVoteSchema>;

export const LiveSchema = z
  .object({
    chambers: z.array(ChamberStatusSchema).openapi({ description: "Empty until the live worker has run" }),
    votes: z
      .array(LiveVoteSchema)
      .openapi({ description: "Open votes named in the last 24 hours, then votes that went final within `since`; newest first" }),
  })
  .openapi("Live");

export interface LiveRepository {
  chambers(): Promise<ChamberStatus[]>;
  /** Open votes announced in the last day, plus votes the live worker published as final after `finalAfter`. */
  liveVotes(finalAfter: Date, now: Date): Promise<LiveVote[]>;
}

/** Edge cache for /v1/live: every phone polling on vote night costs one function call per 5 s, not one each. */
export const LIVE_CACHE_CONTROL = "public, max-age=5, s-maxage=5, stale-while-revalidate=5";

export interface StatusRepository {
  /**
   * Per ingest source: the latest successful run, the latest successful run that stored anything, and
   * the error of the latest run with an outcome if that run failed.
   */
  lastRuns(): Promise<
    { source: string; lastSuccessAt: Date | null; lastNewDataAt?: Date | null; lastError: string | null }[]
  >;
}

/*
 * Round 10: following bills and topics. A topic is one of the CRS policy areas (`POLICY_AREAS` in
 * bills.ts); a bill's stage is derived by the worker (apps/worker/src/stage.ts) and stored, so a
 * list never fetches actions per row.
 */
export const BillStageSchema = z
  .enum(["introduced", "passed_house", "passed_senate", "passed_both", "to_president", "law", "vetoed", "failed", "adopted"])
  .openapi("BillStage");

export type BillStage = z.infer<typeof BillStageSchema>;

export const BillListItemSchema = z
  .object({
    id: z.string().openapi({ example: "119-hr-2493" }),
    congress: z.number().int(),
    type: z.string().openapi({ example: "hr" }),
    number: z.number().int(),
    citation: z.string().openapi({ example: "H.R. 2493" }),
    label: z.string().openapi({
      example: "Improving Care in Rural America Reauthorization Act of 2025",
      description: "A plain short label: the short title, or a deterministic rewrite of a long CRS title. The full title is `title`.",
    }),
    title: z.string(),
    policyArea: z.string().nullable(),
    // Nullable at its only use, so zod-openapi hoists `nullable` (and this description) onto the
    // BillStage component; app.test.ts lists it among the components where that is correct.
    stage: BillStageSchema.nullable().openapi({
      description:
        "Where the measure stands on the road to law; null until the worker has staged it. adopted = a resolution " +
        "agreed to by every chamber it needs (it never goes to the President); failed = a chamber voted it down " +
        "(Congress.gov's own marker); vetoed = vetoed and not overridden.",
    }),
    stalled: z.boolean().openapi({ description: "Not settled (law, adopted, vetoed, failed) and no action in 90 days" }),
    latestAction: LatestActionSchema.nullable(),
    hasFloorVote: z.boolean().openapi({ description: "At least one recorded roll call on it" }),
  })
  .openapi("BillListItem");

export type BillListItem = z.infer<typeof BillListItemSchema>;

export const TopicSchema = z
  .object({
    name: z.string().openapi({ example: "Health" }),
    bills: z.number().int().openapi({ description: "Bills in this topic in the Congress" }),
    billsWithFloorVote: z.number().int(),
    latestActionOn: z.string().nullable().openapi({ example: "2026-09-29" }),
  })
  .openapi("Topic");

export type Topic = z.infer<typeof TopicSchema>;

export const TopicListSchema = z
  .object({ congress: z.number().int(), topics: z.array(TopicSchema) })
  .openapi("TopicList");

export const TOPIC_FILTERS = ["all", "moving", "law", "stalled"] as const;
export type TopicFilter = (typeof TOPIC_FILTERS)[number];
export const TopicFilterSchema = z.enum(TOPIC_FILTERS).openapi("TopicFilter");

export const TopicBillsSchema = z
  .object({
    congress: z.number().int(),
    topic: TopicSchema,
    filter: TopicFilterSchema,
    bills: z.array(BillListItemSchema),
    nextCursor: z.string().nullable().openapi({ description: "Pass as `cursor` for the next page; null on the last" }),
  })
  .openapi("TopicBills");

export const SearchResultsSchema = z
  .object({
    query: z.string(),
    billNumber: z
      .boolean()
      .openapi({ description: "The query read as a bill number (\"hr 1013\"), so `bills` holds exact matches only" }),
    members: z.array(MemberSchema),
    bills: z.array(BillListItemSchema),
    topics: z.array(TopicSchema),
  })
  .openapi("SearchResults");

export type SearchResults = z.infer<typeof SearchResultsSchema>;

/** Where the last row of a page sat in (latest action desc, id desc) order. */
export interface BillCursor {
  on: string | null;
  id: string;
}

/**
 * One row of a topic page with where it sits in the page order. The position is the stored
 * `latest_action_on`, not `latestAction.on`: a bill with an action date but no action text has
 * `latestAction: null`, and a cursor read from that would restart the page at the undated bills.
 */
export interface TopicPageRow {
  bill: BillListItem;
  at: BillCursor;
}

export interface CatalogRepository {
  /** Bill counts per policy area in one Congress; areas with no bills are absent. */
  topicCounts(congress: number): Promise<Topic[]>;
  /** One page of a topic's bills, newest action first. `after` is the decoded cursor. */
  topicBills(
    congress: number,
    topic: string,
    filter: TopicFilter,
    after: BillCursor | null,
    limit: number,
    now: Date,
  ): Promise<TopicPageRow[]>;
  /** Bills by type and number, newest Congress first; `congress` narrows it. */
  billsByNumber(type: string, number: number, congress: number | null, now: Date): Promise<BillListItem[]>;
  /** Full-text match on short title, title and CRS summary, best first, current Congress favoured. */
  searchBills(q: string, congress: number, limit: number, now: Date): Promise<BillListItem[]>;
  /** Serving members by name, state or district (see `memberQuery` in pg.ts). */
  searchMembers(q: string, limit: number, now: Date): Promise<Member[]>;
}

export const encodeCursor = (c: BillCursor) => Buffer.from(JSON.stringify([c.on, c.id])).toString("base64url");

export function decodeCursor(raw: string): BillCursor | null {
  try {
    const value: unknown = JSON.parse(Buffer.from(raw, "base64url").toString("utf8"));
    if (
      Array.isArray(value) &&
      value.length === 2 &&
      (value[0] === null || (typeof value[0] === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value[0]))) &&
      typeof value[1] === "string" &&
      value[1].length <= 40
    ) {
      return { on: value[0] as string | null, id: value[1] };
    }
  } catch {
    // Not base64 or not JSON: the caller answers 400.
  }
  return null;
}

/** Serves an empty catalog; the default when no repository is given (tests of other routes, a database-less dev server). */
export const EMPTY_CATALOG: CatalogRepository = {
  topicCounts: async () => [],
  topicBills: async () => [],
  billsByNumber: async () => [],
  searchBills: async () => [],
  searchMembers: async () => [],
};

/**
 * The Congress in session on a day: the 119th from 2025-01-03 to 2027-01-03. A new Congress starts
 * at noon on January 3 of an odd year; the day is close enough here.
 */
export function congressOn(now: Date): number {
  const [year, month, day] = now
    .toLocaleDateString("en-CA", { timeZone: "America/New_York" })
    .split("-")
    .map(Number) as [number, number, number];
  const beforeStart = year % 2 === 1 && month === 1 && day < 3;
  return Math.floor((year - (beforeStart ? 2 : 0) - 1789) / 2) + 1;
}

/** Topic lists and pages change at most hourly (the ingest schedule): let the edge answer repeats. */
const emptyTopic = (name: string): Topic => ({ name, bills: 0, billsWithFloorVote: 0, latestActionOn: null });

export const TOPICS_CACHE_CONTROL = "public, max-age=300, s-maxage=900, stale-while-revalidate=3600";
/** Search is per query; repeats of a popular query still come from the edge. */
export const SEARCH_CACHE_CONTROL = "public, max-age=60, s-maxage=300, stale-while-revalidate=600";

/** Per caller: these read our own database, but search runs full-text queries, so it gets a tighter cap. */
export const SEARCH_RATE_LIMIT = { limit: 60, windowMs: 60 * 1000 };
export const TOPICS_RATE_LIMIT = { limit: 120, windowMs: 60 * 1000 };


export interface AppDeps {
  votes: VoteRepository;
  members: MemberRepository;
  bills: BillRepository;
  nominations: NominationRepository;
  status: StatusRepository;
  live: LiveRepository;
  /** Topics, topic pages and search. Defaults to `EMPTY_CATALOG`. */
  catalog?: CatalogRepository;
  now?: () => Date;
  /** Resolves an address or coordinates to a district (the Census geocoder in production). */
  locate: (place: Place) => Promise<DistrictMatch | null>;
  /**
   * Browser origins allowed to call the API. The iOS app is not a browser and is unaffected either
   * way; this is for a future web client and for anyone poking at the docs. Omitted or empty means
   * no cross-origin browser may read a response.
   */
  allowedOrigins?: string[];
  /** Swapped in tests, and for a shared store once there is more than one instance. */
  limitStore?: LimitStore;
}

/** How many address lookups one caller gets per hour. See the note in `limit.ts`. */
export const REPS_RATE_LIMIT = { limit: 30, windowMs: 60 * 60 * 1000 };

const getVoteRoute = createRoute({
  method: "get",
  path: "/v1/votes/{id}",
  summary: "Get a vote with its totals, party breakdown and named members' positions",
  request: {
    params: z.object({
      id: z
        .string()
        .regex(/^(house|senate)-\d+-\d-\d+$/, "Vote IDs look like house-119-1-100")
        .openapi({ param: { name: "id", in: "path" }, example: "house-119-1-100" }),
    }),
    query: z.object({
      members: z
        .string()
        .regex(
          /^[A-Z]\d{6}(,[A-Z]\d{6})*$/,
          "members is a comma-separated list of Bioguide IDs like D000399,C001098",
        )
        .refine((s) => s.split(",").length <= 10, "Name at most 10 members")
        .optional()
        .openapi({
          param: { name: "members", in: "query" },
          example: "D000399,C001098",
          description: "Return these members' own positions on the vote — your delegation, for the vote screen.",
        }),
    }),
  },
  responses: {
    200: { content: { "application/json": { schema: VoteDetailSchema } }, description: "The vote" },
    404: { content: { "application/json": { schema: ErrorSchema } }, description: "No vote with that ID" },
  },
});

const getRepsRoute = createRoute({
  method: "get",
  path: "/v1/reps",
  summary: "Find your district and members of Congress from an address or your location",
  description:
    "Send either `address`, or `lat` and `lng` (for example from the browser's location). Coordinates are " +
    "rounded to 4 decimal places (about 11 m). Either is sent to the U.S. Census geocoder and is not stored or logged.",
  request: {
    query: z.object({
      address: z
        .string()
        .min(5, "Enter a street address, city and state")
        .max(200)
        .optional()
        .openapi({ example: "1100 Congress Ave, Austin, TX 78701" }),
      lat: z.coerce
        .number()
        .min(-90, "lat must be between -90 and 90")
        .max(90, "lat must be between -90 and 90")
        .optional()
        .openapi({ example: 30.2747 }),
      lng: z.coerce
        .number()
        .min(-180, "lng must be between -180 and 180")
        .max(180, "lng must be between -180 and 180")
        .optional()
        .openapi({ example: -97.7404 }),
    }),
  },
  responses: {
    200: { content: { "application/json": { schema: RepsSchema } }, description: "Your district and members" },
    400: {
      content: { "application/json": { schema: ErrorSchema } },
      description: "Neither or both of an address and coordinates, or values out of range",
    },
    404: { content: { "application/json": { schema: ErrorSchema } }, description: "Place not in a U.S. congressional district" },
  },
});

const getMemberRoute = createRoute({
  method: "get",
  path: "/v1/members/{id}",
  summary: "A member and how often they vote with their own party",
  request: {
    params: z.object({
      id: z
        .string()
        .regex(/^[A-Z]\d{6}$/, "Member IDs are Bioguide IDs like A000370")
        .openapi({ param: { name: "id", in: "path" }, example: "A000370" }),
    }),
  },
  responses: {
    200: { content: { "application/json": { schema: MemberDetailSchema } }, description: "The member" },
    404: { content: { "application/json": { schema: ErrorSchema } }, description: "No member with that ID" },
  },
});

const getMemberFundingRoute = createRoute({
  method: "get",
  path: "/v1/members/{id}/funding",
  summary: "Who funds a member's current campaign",
  description:
    "Totals the campaign reported receiving, and the committees that reported giving to it. The two come from " +
    "different FEC sources and will not reconcile. No individual donor is named: FEC publishes them, Floor does not store them.",
  request: {
    params: z.object({
      id: z
        .string()
        .regex(/^[A-Z]\d{6}$/, "Member IDs are Bioguide IDs like A000370")
        .openapi({ param: { name: "id", in: "path" }, example: "A000370" }),
    }),
    query: z.object({
      committees: z.coerce
        .number()
        .int()
        .min(0)
        .max(50)
        .default(10)
        .openapi({ param: { name: "committees", in: "query" }, description: "How many giving committees to return" }),
    }),
  },
  responses: {
    200: { content: { "application/json": { schema: MemberFundingSchema } }, description: "The member and their campaign's money" },
    404: { content: { "application/json": { schema: ErrorSchema } }, description: "No member with that ID" },
  },
});

const getMemberVotesRoute = createRoute({
  method: "get",
  path: "/v1/members/{id}/votes",
  summary: "A member's most recent votes and how they voted",
  request: {
    params: z.object({
      id: z
        .string()
        .regex(/^[A-Z]\d{6}$/, "Member IDs are Bioguide IDs like A000370")
        .openapi({ param: { name: "id", in: "path" }, example: "A000370" }),
    }),
    query: z.object({
      limit: z.coerce.number().int().min(1).max(100).default(20),
    }),
  },
  responses: {
    200: {
      content: { "application/json": { schema: z.object({ votes: z.array(MemberVoteSchema) }) } },
      description: "Votes, newest first",
    },
  },
});

const getBillRoute = createRoute({
  method: "get",
  path: "/v1/bills/{id}",
  summary: "A bill with its summary, sponsor, recent actions and every vote on it",
  request: {
    params: z.object({
      id: z
        .string()
        .regex(/^\d{2,3}-(hr|hres|hjres|hconres|s|sres|sjres|sconres)-\d+$/, "Bill IDs look like 119-hr-2207")
        .openapi({ param: { name: "id", in: "path" }, example: "119-hconres-14" }),
    }),
  },
  responses: {
    200: { content: { "application/json": { schema: BillSchema } }, description: "The bill" },
    404: { content: { "application/json": { schema: ErrorSchema } }, description: "No bill with that ID" },
  },
});

const getBillAnalysisRoute = createRoute({
  method: "get",
  path: "/v1/bills/{id}/analysis",
  summary: "AI analysis of a bill's CRS summary: purpose, provisions, affected groups and impact, each line cited",
  description:
    "Every line is AI-written (`ai: true`) and cites the summary paragraph it came from, quoted verbatim. " +
    "Lines whose citation didn't check out, or that a second AI pass found unsupported, have been removed. " +
    "Show `disclaimer` with it.",
  request: {
    params: z.object({
      id: z
        .string()
        .regex(/^\d{2,3}-(hr|hres|hjres|hconres|s|sres|sjres|sconres)-\d+$/, "Bill IDs look like 119-hr-2207")
        .openapi({ param: { name: "id", in: "path" }, example: "118-hr-6363" }),
    }),
  },
  responses: {
    200: { content: { "application/json": { schema: BillAnalysisSchema } }, description: "The analysis" },
    404: { content: { "application/json": { schema: ErrorSchema } }, description: "No analysis for that bill yet" },
  },
});

const getNominationRoute = createRoute({
  method: "get",
  path: "/v1/nominations/{id}",
  summary: "A presidential nomination with every Senate vote on it",
  request: {
    params: z.object({
      id: z
        .string()
        .regex(/^\d{2,3}-pn-\d+(-\d+)?$/, "Nomination IDs look like 119-pn-1093-3")
        .openapi({ param: { name: "id", in: "path" }, example: "119-pn-1093-3" }),
    }),
  },
  responses: {
    200: { content: { "application/json": { schema: NominationSchema } }, description: "The nomination" },
    404: { content: { "application/json": { schema: ErrorSchema } }, description: "No nomination with that ID" },
  },
});

const getStatusRoute = createRoute({
  method: "get",
  path: "/v1/status",
  summary: "Data freshness for each ingest source",
  responses: {
    200: {
      content: { "application/json": { schema: z.object({ ok: z.boolean(), sources: z.array(SourceStatusSchema) }) } },
      description: "ok is false when any source is stale",
    },
  },
});

const getLiveRoute = createRoute({
  method: "get",
  path: "/v1/live",
  summary: "What is happening on the floor: each chamber's session state and the votes open or just final",
  request: {
    query: z.object({
      since: z.coerce.number().int().min(1).max(1440).default(120).openapi({
        param: { name: "since", in: "query" },
        example: 120,
        description: "Include votes that went final within this many minutes",
      }),
    }),
  },
  responses: {
    200: {
      content: { "application/json": { schema: LiveSchema } },
      description: `Cached at the edge for 5 seconds (${LIVE_CACHE_CONTROL})`,
    },
  },
});

const congressQuery = z.coerce.number().int().min(93).max(200).optional().openapi({
  param: { name: "congress", in: "query" },
  example: 119,
  description: "Defaults to the Congress in session",
});

const getTopicsRoute = createRoute({
  method: "get",
  path: "/v1/topics",
  summary: "The CRS policy areas, with how many bills each holds in a Congress",
  description: "All 32 areas, in a fixed order, including ones with no bills yet.",
  request: { query: z.object({ congress: congressQuery }) },
  responses: {
    200: { content: { "application/json": { schema: TopicListSchema } }, description: `The topics (${TOPICS_CACHE_CONTROL})` },
  },
});

const getTopicBillsRoute = createRoute({
  method: "get",
  path: "/v1/topics/{name}/bills",
  summary: "A topic's bills, newest action first, with where each stands",
  description:
    "filter: all; moving (not settled, acted on in the last 90 days); law; stalled (not settled, no action in 90 days). " +
    "Settled = law, adopted, vetoed or failed. A bill not yet fetched in detail has stage null and counts as unsettled. " +
    "Companion bills (the House and Senate versions of one measure) are separate rows and are not linked to each other.",
  request: {
    params: z.object({
      name: z.string().min(1).max(80).openapi({ param: { name: "name", in: "path" }, example: "Health" }),
    }),
    query: z.object({
      filter: TopicFilterSchema.default("all").openapi({ param: { name: "filter", in: "query" } }),
      cursor: z.string().max(200).optional().openapi({ param: { name: "cursor", in: "query" } }),
      limit: z.coerce.number().int().min(1).max(50).default(25).openapi({ param: { name: "limit", in: "query" } }),
      congress: congressQuery,
    }),
  },
  responses: {
    200: { content: { "application/json": { schema: TopicBillsSchema } }, description: `One page (${TOPICS_CACHE_CONTROL})` },
    400: { content: { "application/json": { schema: ErrorSchema } }, description: "A cursor this route did not issue" },
    404: { content: { "application/json": { schema: ErrorSchema } }, description: "Not one of the policy areas" },
  },
});

const searchRoute = createRoute({
  method: "get",
  path: "/v1/search",
  summary: "Members, bills and topics in one search",
  description:
    "A bill number in any spelling (\"hr 1013\", \"H.R.1013\", \"s.j.res.197\") returns that bill and nothing else. " +
    "Otherwise words match bill short titles, titles and CRS summaries (Postgres full-text), topic names, and " +
    "serving members by name, state (\"TX\", \"Texas\") or district (\"TX-35\"). " +
    "Companion bills (the House and Senate versions of one measure) are separate results and are not linked to each other.",
  request: {
    query: z.object({
      q: z.string().trim().min(2).max(100).openapi({ param: { name: "q", in: "query" }, example: "rural health" }),
    }),
  },
  responses: {
    200: { content: { "application/json": { schema: SearchResultsSchema } }, description: `Grouped results (${SEARCH_CACHE_CONTROL})` },
  },
});

export function createApp(deps: AppDeps) {
  const app = new OpenAPIHono({
    defaultHook: (result, c) => {
      if (!result.success) {
        return c.json({ error: result.error.issues.map((i) => i.message).join("; ") }, 400);
      }
    },
  });

  // Reads only, and every route is a GET. Credentials are never involved, so there is nothing for
  // a cross-origin caller to steal by being allowed to read a response; the allow-list exists so a
  // browser client has to be named rather than assumed.
  const origins = deps.allowedOrigins ?? [];
  app.use(
    "/v1/*",
    cors({
      origin: (origin) => (origins.includes(origin) ? origin : null),
      allowMethods: ["GET", "OPTIONS"],
      maxAge: 86_400,
    }),
  );
  app.use("/openapi.json", cors({ origin: (origin) => (origins.includes(origin) ? origin : null) }));

  // The only route that reaches a third party: each lookup is a request to the Census geocoder.
  app.use(
    "/v1/reps",
    rateLimit({ ...REPS_RATE_LIMIT, store: deps.limitStore, now: () => (deps.now ?? (() => new Date()))().getTime() }),
  );

  const clock = () => (deps.now ?? (() => new Date()))();
  const LIMITED = [
    ["/v1/search", SEARCH_RATE_LIMIT, "search"],
    // Hono's "/v1/topics/*" matches "/v1/topics" itself too; registering both counted it twice.
    ["/v1/topics/*", TOPICS_RATE_LIMIT, "topics"],
  ] as const;
  for (const [path, limits, scope] of LIMITED) {
    app.use(
      path,
      rateLimit({
        ...limits,
        store: deps.limitStore,
        now: () => clock().getTime(),
        scope,
        message: "Too many requests. Please wait a moment and try again.",
      }),
    );
  }
  const catalog = deps.catalog ?? EMPTY_CATALOG;

  app.get("/health", (c) => c.json({ ok: true }));

  app.openapi(getVoteRoute, async (c) => {
    const { id } = c.req.valid("param");
    const { members } = c.req.valid("query");
    const vote = await deps.votes.getVote(id);
    if (!vote) return c.json({ error: `No vote with ID ${id}` }, 404);
    const breakdown = await deps.votes.voteBreakdown(id, members ? members.split(",") : []);
    return c.json({ ...vote, ...breakdown }, 200);
  });

  app.openapi(getMemberRoute, async (c) => {
    const { id } = c.req.valid("param");
    const member = await deps.members.getMember(id);
    if (!member) return c.json({ error: `No member with ID ${id}` }, 404);
    return c.json({ member, partyLoyalty: await deps.members.partyLoyalty(id, member.party) }, 200);
  });

  app.openapi(getMemberFundingRoute, async (c) => {
    const { id } = c.req.valid("param");
    const { committees } = c.req.valid("query");
    const member = await deps.members.getMember(id);
    if (!member) return c.json({ error: `No member with ID ${id}` }, 404);
    return c.json({ member, funding: await deps.members.funding(id, committees) }, 200);
  });

  app.openapi(getRepsRoute, async (c) => {
    const { address, lat, lng } = c.req.valid("query");
    const hasCoordinates = lat !== undefined || lng !== undefined;
    if (address !== undefined && hasCoordinates) {
      return c.json({ error: "Send either an address or lat and lng, not both." }, 400);
    }
    if (address === undefined && (lat === undefined || lng === undefined)) {
      return c.json({ error: "Send an address, or both lat and lng." }, 400);
    }
    const place: Place = address !== undefined ? { address } : { lat: lat!, lng: lng! };
    const match = await deps.locate(place);
    if (!match) {
      return c.json(
        {
          error:
            "address" in place
              ? "We couldn't find that address. Try adding the city, state and ZIP code."
              : "That location isn't in a U.S. congressional district. Try entering an address instead.",
        },
        404,
      );
    }
    const members = await deps.members.membersFor(match.state, match.district);
    return c.json(
      {
        district: { congress: match.congress, state: match.state, district: match.district, countyFips: match.countyFips },
        members,
      },
      200,
    );
  });

  app.openapi(getMemberVotesRoute, async (c) => {
    const { id } = c.req.valid("param");
    const { limit } = c.req.valid("query");
    return c.json({ votes: await deps.members.recentVotes(id, limit) }, 200);
  });

  app.openapi(getBillRoute, async (c) => {
    const { id } = c.req.valid("param");
    const bill = await deps.bills.getBill(id);
    if (!bill) return c.json({ error: `No bill with ID ${id}` }, 404);
    return c.json(bill, 200);
  });

  app.openapi(getBillAnalysisRoute, async (c) => {
    const { id } = c.req.valid("param");
    const analysis = await deps.bills.getAnalysis(id);
    if (!analysis) return c.json({ error: `No AI analysis for bill ${id} yet` }, 404);
    return c.json(analysis, 200);
  });

  app.openapi(getNominationRoute, async (c) => {
    const { id } = c.req.valid("param");
    const nomination = await deps.nominations.getNomination(id);
    if (!nomination) return c.json({ error: `No nomination with ID ${id}` }, 404);
    return c.json(nomination, 200);
  });

  app.openapi(getLiveRoute, async (c) => {
    const { since } = c.req.valid("query");
    const now = (deps.now ?? (() => new Date()))();
    const [chambers, votes] = await Promise.all([
      deps.live.chambers(),
      deps.live.liveVotes(new Date(now.getTime() - since * 60_000), now),
    ]);
    c.header("Cache-Control", LIVE_CACHE_CONTROL);
    return c.json({ chambers, votes }, 200);
  });

  app.openapi(getStatusRoute, async (c) => {
    const now = (deps.now ?? (() => new Date()))().getTime();
    // This route's whole job is to say whether the data is healthy, so it must answer even when the
    // database is the thing that is unwell. 500ing here would tell a monitor only that something
    // broke; `ok: false` with the reason on every source says what.
    let lastRuns: Awaited<ReturnType<StatusRepository["lastRuns"]>>;
    let unreachable: string | null = null;
    try {
      lastRuns = await deps.status.lastRuns();
    } catch (error) {
      lastRuns = [];
      unreachable = error instanceof Error ? error.message : "The database could not be reached";
    }
    const runs = new Map(lastRuns.map((r) => [r.source, r]));
    const sources: SourceStatus[] = Object.entries(MAX_AGE_HOURS).map(([source, hours]) => {
      const run = runs.get(source);
      const last = run?.lastSuccessAt ?? null;
      return {
        source,
        lastSuccessAt: last ? last.toISOString() : null,
        lastNewDataAt: run?.lastNewDataAt ? run.lastNewDataAt.toISOString() : null,
        lastError: unreachable ?? run?.lastError ?? null,
        stale: !last || now - last.getTime() > hours * 3_600_000,
      };
    });
    return c.json({ ok: sources.every((s) => !s.stale), sources }, 200);
  });

  app.openapi(getTopicsRoute, async (c) => {
    const congress = c.req.valid("query").congress ?? congressOn(clock());
    const counts = new Map((await catalog.topicCounts(congress)).map((t) => [t.name, t]));
    const topics = POLICY_AREAS.map((name) => counts.get(name) ?? emptyTopic(name));
    c.header("Cache-Control", TOPICS_CACHE_CONTROL);
    return c.json({ congress, topics }, 200);
  });

  app.openapi(getTopicBillsRoute, async (c) => {
    const { name } = c.req.valid("param");
    const { filter, cursor, limit, congress: asked } = c.req.valid("query");
    const topic = topicNamed(name);
    if (!topic) return c.json({ error: `No topic named ${name}. Topics are the CRS policy areas; see /v1/topics.` }, 404);
    const after = cursor === undefined ? null : decodeCursor(cursor);
    if (cursor !== undefined && !after) return c.json({ error: "That cursor is not one this route issued." }, 400);
    const now = clock();
    const congress = asked ?? congressOn(now);
    const [counts, rows] = await Promise.all([
      catalog.topicCounts(congress),
      // One extra row says whether there is another page.
      catalog.topicBills(congress, topic, filter, after, limit + 1, now),
    ]);
    const page = rows.slice(0, limit);
    const last = page.at(-1);
    c.header("Cache-Control", TOPICS_CACHE_CONTROL);
    return c.json(
      {
        congress,
        topic: counts.find((t) => t.name === topic) ?? emptyTopic(topic),
        filter,
        bills: page.map((r) => r.bill),
        nextCursor: rows.length > limit && last ? encodeCursor(last.at) : null,
      },
      200,
    );
  });

  app.openapi(searchRoute, async (c) => {
    const { q } = c.req.valid("query");
    const now = clock();
    const congress = congressOn(now);
    c.header("Cache-Control", SEARCH_CACHE_CONTROL);
    const number = parseBillNumber(q);
    if (number) {
      const bills = await catalog.billsByNumber(number.type, number.number, number.congress, now);
      return c.json({ query: q, billNumber: true, members: [], bills, topics: [] }, 200);
    }
    const names = matchTopics(q);
    const [members, bills, counts] = await Promise.all([
      catalog.searchMembers(q, 10, now),
      catalog.searchBills(q, congress, 20, now),
      names.length > 0 ? catalog.topicCounts(congress) : Promise.resolve([]),
    ]);
    const topics = names.map((name) => counts.find((t) => t.name === name) ?? emptyTopic(name));
    return c.json({ query: q, billNumber: false, members, bills, topics }, 200);
  });

  app.doc("/openapi.json", {
    openapi: "3.0.0",
    info: { title: "Floor API", version: "0.1.0" },
  });

  return app;
}
