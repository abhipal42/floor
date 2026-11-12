import { describe, expect, it } from "vitest";
import { createApp, type Vote, type VoteRepository } from "./app.js";

const sample: Vote = {
  id: "house-119-1-100",
  chamber: "house",
  congress: 119,
  session: 1,
  rollNumber: 100,
  question: "On Motion to Concur in the Senate Amendment",
  billId: "119-hconres-14",
  state: "final",
  threshold: "majority",
  totals: { yea: 216, nay: 214, present: 0, notVoting: 3 },
  result: "Passed",
};

const repo: VoteRepository = {
  getVote: async (id) => (id === sample.id ? sample : null),
};

const app = createApp(repo);

describe("API", () => {
  it("reports health", async () => {
    const res = await app.request("/health");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
  });

  it("returns a vote by ID", async () => {
    const res = await app.request("/v1/votes/house-119-1-100");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual(sample);
  });

  it("returns 404 for a vote that doesn't exist", async () => {
    const res = await app.request("/v1/votes/senate-119-1-9999");
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "No vote with ID senate-119-1-9999" });
  });

  it("returns 400 for a malformed vote ID", async () => {
    const res = await app.request("/v1/votes/not-a-vote");
    expect(res.status).toBe(400);
    expect((await res.json()).error).toMatch(/house-119-1-100/);
  });

  it("publishes an OpenAPI document that describes the vote route and schema", async () => {
    const res = await app.request("/openapi.json");
    expect(res.status).toBe(200);
    const doc = await res.json();
    expect(doc.info.title).toBe("Floor API");
    expect(Object.keys(doc.paths)).toContain("/v1/votes/{id}");
    expect(doc.components.schemas.Vote.required).toContain("totals");
  });
});
