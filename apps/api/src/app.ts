import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { cors } from "hono/cors";
import type { DistrictMatch } from "./district.js";
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

export interface BillRepository {
  getBill(id: string): Promise<Bill | null>;
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
    lastError: z.string().nullable(),
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

export interface StatusRepository {
  /** Latest successful run and latest error per ingest source. */
  lastRuns(): Promise<{ source: string; lastSuccessAt: Date | null; lastError: string | null }[]>;
}

export interface AppDeps {
  votes: VoteRepository;
  members: MemberRepository;
  bills: BillRepository;
  nominations: NominationRepository;
  status: StatusRepository;
  now?: () => Date;
  geocode: (address: string) => Promise<DistrictMatch | null>;
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
  summary: "Find your district and members of Congress from an address",
  description: "The address is sent to the U.S. Census geocoder and is not stored or logged.",
  request: {
    query: z.object({
      address: z
        .string()
        .min(5, "Enter a street address, city and state")
        .max(200)
        .openapi({ example: "1100 Congress Ave, Austin, TX 78701" }),
    }),
  },
  responses: {
    200: { content: { "application/json": { schema: RepsSchema } }, description: "Your district and members" },
    404: { content: { "application/json": { schema: ErrorSchema } }, description: "Address not found" },
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

  app.openapi(getRepsRoute, async (c) => {
    const { address } = c.req.valid("query");
    const match = await deps.geocode(address);
    if (!match) {
      return c.json({ error: "We couldn't find that address. Try adding the city, state and ZIP code." }, 404);
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

  app.openapi(getNominationRoute, async (c) => {
    const { id } = c.req.valid("param");
    const nomination = await deps.nominations.getNomination(id);
    if (!nomination) return c.json({ error: `No nomination with ID ${id}` }, 404);
    return c.json(nomination, 200);
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
        lastError: unreachable ?? run?.lastError ?? null,
        stale: !last || now - last.getTime() > hours * 3_600_000,
      };
    });
    return c.json({ ok: sources.every((s) => !s.stale), sources }, 200);
  });

  app.doc("/openapi.json", {
    openapi: "3.0.0",
    info: { title: "Floor API", version: "0.1.0" },
  });

  return app;
}
