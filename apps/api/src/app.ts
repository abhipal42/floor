import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";

export const VoteSchema = z
  .object({
    id: z.string().openapi({ example: "house-119-1-100" }),
    chamber: z.enum(["house", "senate"]),
    congress: z.number().int(),
    session: z.number().int(),
    rollNumber: z.number().int().nullable(),
    question: z.string(),
    billId: z.string().nullable(),
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

const ErrorSchema = z.object({ error: z.string() }).openapi("Error");

/** Where the API reads votes from. Postgres in production, in-memory in tests. */
export interface VoteRepository {
  getVote(id: string): Promise<Vote | null>;
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

export function createApp(repo: VoteRepository) {
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
    const vote = await repo.getVote(id);
    if (!vote) return c.json({ error: `No vote with ID ${id}` }, 404);
    return c.json(vote, 200);
  });

  app.doc("/openapi.json", {
    openapi: "3.0.0",
    info: { title: "Floor API", version: "0.1.0" },
  });

  return app;
}
