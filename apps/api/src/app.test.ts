import { describe, expect, it } from "vitest";
import { createApp, type Member, type Vote, type VoteRepository } from "./app.js";

const sample: Vote = {
  id: "house-119-1-100",
  chamber: "house",
  congress: 119,
  session: 1,
  rollNumber: 100,
  question: "On Motion to Concur in the Senate Amendment",
  billId: "119-hconres-14",
  billRef: "H CON RES 14",
  occurredAt: "2025-04-10T15:08:00.000Z",
  state: "final",
  threshold: "majority",
  totals: { yea: 216, nay: 214, present: 0, notVoting: 3 },
  result: "Passed",
};

const repo: VoteRepository = {
  getVote: async (id) => (id === sample.id ? sample : null),
};

const members: Member[] = [
  { bioguideId: "D000399", firstName: "Lloyd", lastName: "Doggett", party: "D", state: "TX", district: 37, chamber: "house" },
  { bioguideId: "C001098", firstName: "Ted", lastName: "Cruz", party: "R", state: "TX", district: null, chamber: "senate" },
];

const geocoded: string[] = [];
const app = createApp({
  votes: repo,
  members: {
    membersFor: async (state, district) =>
      members.filter((m) => m.state === state && (m.chamber === "senate" || m.district === district)),
    recentVotes: async (id, limit) =>
      id === "D000399" ? [{ vote: sample, position: "yea" as const }].slice(0, limit) : [],
  },
  geocode: async (address) => {
    geocoded.push(address);
    return address.includes("Austin")
      ? { congress: 119, state: "TX", stateFips: "48", district: 37, countyFips: "48453" }
      : null;
  },
});

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

  it("returns the district, House member and senators for an address", async () => {
    const res = await app.request(`/v1/reps?address=${encodeURIComponent("1100 Congress Ave, Austin, TX 78701")}`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.district).toEqual({ congress: 119, state: "TX", district: 37, countyFips: "48453" });
    expect(body.members.map((m: Member) => m.bioguideId)).toEqual(["D000399", "C001098"]);
  });

  it("returns 404 with guidance when the address can't be matched", async () => {
    const res = await app.request("/v1/reps?address=nowhere%20at%20all");
    expect(res.status).toBe(404);
    expect((await res.json()).error).toMatch(/city, state and ZIP/);
  });

  it("rejects a too-short address without calling the geocoder", async () => {
    const before = geocoded.length;
    const res = await app.request("/v1/reps?address=TX");
    expect(res.status).toBe(400);
    expect(geocoded.length).toBe(before);
  });

  it("lists a member's recent votes", async () => {
    const res = await app.request("/v1/members/D000399/votes?limit=5");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ votes: [{ vote: sample, position: "yea" }] });
  });

  it("rejects malformed member IDs and limits", async () => {
    expect((await app.request("/v1/members/doggett/votes")).status).toBe(400);
    expect((await app.request("/v1/members/D000399/votes?limit=500")).status).toBe(400);
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
