import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import type { DistrictMatch } from "./district.js";

export const VoteSchema = z
  .object({
    id: z.string().openapi({ example: "house-119-1-100" }),
    chamber: z.enum(["house", "senate"]),
    congress: z.number().int(),
    session: z.number().int(),
    rollNumber: z.number().int().nullable(),
    question: z.string(),
    billId: z.string().nullable(),
    billRef: z.string().nullable().openapi({ example: "H CON RES 14" }),
    occurredAt: z.string().nullable().openapi({ example: "2025-04-10T15:08:00.000Z" }),
    state: z.enum(["scheduled", "open", "final"]),
    threshold: z.enum(["majority", "three_fifths_sworn", "two_thirds"]),
    totals: z.object({
      yea: z.number().int(),
      nay: z.number().int(),
      present: z.number().int(),
      notVoting: z.number().int(),
    }),
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
    chamber: z.enum(["house", "senate"]),
  })
  .openapi("Member");

export type Member = z.infer<typeof MemberSchema>;

const RepsSchema = z
  .object({
    district: z.object({
      congress: z.number().int(),
      state: z.string(),
      district: z.number().int(),
      countyFips: z.string().nullable(),
    }),
    members: z.array(MemberSchema),
  })
  .openapi("Reps");

export const MemberVoteSchema = z
  .object({
    vote: VoteSchema,
    position: z.enum(["yea", "nay", "present", "not_voting"]),
  })
  .openapi("MemberVote");

export type MemberVote = z.infer<typeof MemberVoteSchema>;

const ErrorSchema = z.object({ error: z.string() }).openapi("Error");

/** Where the API reads votes from. Postgres in production, in-memory in tests. */
export interface VoteRepository {
  getVote(id: string): Promise<Vote | null>;
}

export interface MemberRepository {
  /** The House member for the district plus the state's senators. */
  membersFor(state: string, district: number): Promise<Member[]>;
  /** A member's most recent recorded votes, newest first. */
  recentVotes(bioguideId: string, limit: number): Promise<MemberVote[]>;
}

export interface AppDeps {
  votes: VoteRepository;
  members: MemberRepository;
  geocode: (address: string) => Promise<DistrictMatch | null>;
}

const getVoteRoute = createRoute({
  method: "get",
  path: "/v1/votes/{id}",
  summary: "Get a vote with its current totals",
  request: {
    params: z.object({
      id: z
        .string()
        .regex(/^(house|senate)-\d+-\d-\d+$/, "Vote IDs look like house-119-1-100")
        .openapi({ param: { name: "id", in: "path" }, example: "house-119-1-100" }),
    }),
  },
  responses: {
    200: { content: { "application/json": { schema: VoteSchema } }, description: "The vote" },
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

export function createApp(deps: AppDeps) {
  const app = new OpenAPIHono({
    defaultHook: (result, c) => {
      if (!result.success) {
        return c.json({ error: result.error.issues.map((i) => i.message).join("; ") }, 400);
      }
    },
  });

  app.get("/health", (c) => c.json({ ok: true }));

  app.openapi(getVoteRoute, async (c) => {
    const { id } = c.req.valid("param");
    const vote = await deps.votes.getVote(id);
    if (!vote) return c.json({ error: `No vote with ID ${id}` }, 404);
    return c.json(vote, 200);
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

  app.doc("/openapi.json", {
    openapi: "3.0.0",
    info: { title: "Floor API", version: "0.1.0" },
  });

  return app;
}
