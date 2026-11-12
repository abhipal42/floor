import { describe, expect, it } from "vitest";
import { createApp, type Member, type Vote, type VoteRepository } from "./app.js";

const sample: Vote = {
  id: "house-119-1-100",
  kind: "question",
  candidates: [],
  chamber: "house",
  congress: 119,
  session: 1,
  rollNumber: 100,
  question: "On Motion to Concur in the Senate Amendment",
  billId: "119-hconres-14",
  nominationId: null,
  billRef: "H CON RES 14",
  occurredAt: "2025-04-10T15:08:00.000Z",
  state: "final",
  threshold: "majority",
  totals: { yea: 216, nay: 214, present: 0, notVoting: 3 },
  result: "Passed",
};

/** A Senate vote on a nomination rather than a bill, so `nominationId` is set and `billId` is not. */
const nominationVote: Vote = {
  ...sample,
  id: "senate-119-2-233",
  chamber: "senate",
  session: 2,
  rollNumber: 233,
  question: "On the Nomination",
  billId: null,
  nominationId: "119-pn-1093-3",
  billRef: "PN1093-3",
  totals: { yea: 52, nay: 45, present: 0, notVoting: 3 },
  result: "Nomination Confirmed",
};

const members: Member[] = [
  { bioguideId: "D000399", firstName: "Lloyd", lastName: "Doggett", party: "D", state: "TX", district: 37, chamber: "house" },
  { bioguideId: "C001098", firstName: "Ted", lastName: "Cruz", party: "R", state: "TX", district: null, chamber: "senate" },
];

const partyTotals = [
  { party: "R", yea: 214, nay: 2, present: 0, notVoting: 2 },
  { party: "D", yea: 2, nay: 212, present: 0, notVoting: 1 },
];

const repo: VoteRepository = {
  getVote: async (id) => (id === sample.id ? sample : id === nominationVote.id ? nominationVote : null),
  voteBreakdown: async (_id, memberIds) => ({
    partyTotals,
    candidateTotals: [],
    positions: memberIds.flatMap((id) => {
      const member = members.find((m) => m.bioguideId === id);
      return member ? [{ member, position: "yea" as const, choice: null }] : [];
    }),
  }),
};

/** Records how `partyLoyalty` was called, so we can check the party came off the member row. */
const loyaltyCalls: string[] = [];

const geocoded: string[] = [];
const app = createApp({
  votes: repo,
  members: {
    membersFor: async (state, district) =>
      members.filter((m) => m.state === state && (m.chamber === "senate" || m.district === district)),
    recentVotes: async (id, limit) =>
      id === "D000399" ? [{ vote: sample, position: "yea" as const, choice: null }].slice(0, limit) : [],
    getMember: async (id) => members.find((m) => m.bioguideId === id) ?? null,
    partyLoyalty: async (id, party) => {
      loyaltyCalls.push(`${id}/${party}`);
      return { votes: 120, withParty: 111, againstParty: 9 };
    },
  },
  bills: {
    getBill: async (id) =>
      id === "119-hconres-14"
        ? {
            id, congress: 119, type: "hconres", number: 14, title: "Establishing the congressional budget", shortTitle: null,
            sponsor: null, introducedOn: "2025-02-18", originChamber: "house", policyArea: "Economics and Public Finance",
            summary: "This concurrent resolution establishes the budget.", summaryStage: "Introduced in House",
            latestAction: { on: "2025-05-20", text: "Star Print ordered." }, cboEstimates: [], actions: [], votes: [sample],
          }
        : null,
  },
  nominations: {
    getNomination: async (id) =>
      id === "119-pn-1093-3"
        ? {
            id, congress: 119, number: 1093, part: 3, citation: "PN1093-3", nomineeName: "Matthew R. Byrne",
            positionTitle: "United States District Judge for the Southern District of Ohio",
            organization: "The Judiciary", description: "Matthew R. Byrne, of Ohio, to be United States District Judge.",
            nomineeCount: 1, isMilitary: false, receivedOn: "2026-06-15",
            latestAction: { on: "2026-09-15", text: "Confirmed by the Senate by Yea-Nay Vote. 52 - 45." },
            votes: [nominationVote],
          }
        : null,
  },
  status: {
    lastRuns: async () => [
      { source: "members", lastSuccessAt: new Date("2026-11-11T00:00:00Z"), lastError: null },
      { source: "house_rollcalls", lastSuccessAt: new Date("2026-11-11T20:00:00Z"), lastError: null },
      { source: "senate_rollcalls", lastSuccessAt: new Date("2026-11-09T00:00:00Z"), lastError: "HTTP 503" },
    ],
  },
  now: () => new Date("2026-11-12T00:00:00Z"),
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

  it("returns a vote by ID, with its party breakdown and no positions unless asked", async () => {
    const res = await app.request("/v1/votes/house-119-1-100");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toMatchObject(sample);
    expect(body.partyTotals).toEqual(partyTotals);
    expect(body.candidateTotals).toEqual([]);
    expect(body.positions).toEqual([]);
  });

  it("returns your delegation's own positions when ?members= names them", async () => {
    const res = await app.request("/v1/votes/house-119-1-100?members=D000399,C001098");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.positions.map((p: { member: Member }) => p.member.bioguideId)).toEqual(["D000399", "C001098"]);
    expect(body.positions[0].position).toBe("yea");
  });

  it("rejects a members list that isn't Bioguide IDs, or names more than ten", async () => {
    expect((await app.request("/v1/votes/house-119-1-100?members=doggett")).status).toBe(400);
    expect((await app.request("/v1/votes/house-119-1-100?members=D000399,")).status).toBe(400);
    const eleven = Array.from({ length: 11 }, (_, i) => `D${String(i).padStart(6, "0")}`).join(",");
    const res = await app.request(`/v1/votes/house-119-1-100?members=${eleven}`);
    expect(res.status).toBe(400);
    expect((await res.json()).error).toMatch(/at most 10/i);
  });

  it("returns a member with how often they side with their own party", async () => {
    const res = await app.request("/v1/members/D000399");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      member: members[0],
      partyLoyalty: { votes: 120, withParty: 111, againstParty: 9 },
    });
    // The party used for the comparison comes from the member row, not from the client.
    expect(loyaltyCalls).toContain("D000399/D");
  });

  it("returns 404 for an unknown member and 400 for a malformed ID", async () => {
    const res = await app.request("/v1/members/Z000000");
    expect(res.status).toBe(404);
    expect((await res.json()).error).toMatch(/Z000000/);
    expect((await app.request("/v1/members/doggett")).status).toBe(400);
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
    expect(await res.json()).toEqual({ votes: [{ vote: sample, position: "yea", choice: null }] });
  });

  it("rejects malformed member IDs and limits", async () => {
    expect((await app.request("/v1/members/doggett/votes")).status).toBe(400);
    expect((await app.request("/v1/members/D000399/votes?limit=500")).status).toBe(400);
  });

  it("returns a bill with its votes, and validates bill IDs", async () => {
    const res = await app.request("/v1/bills/119-hconres-14");
    expect(res.status).toBe(200);
    const bill = await res.json();
    expect(bill.policyArea).toBe("Economics and Public Finance");
    expect(bill.votes).toEqual([sample]);
    expect((await app.request("/v1/bills/119-hr-404")).status).toBe(404);
    expect((await app.request("/v1/bills/HR2207")).status).toBe(400);
  });

  it("returns a nomination with its votes, and validates nomination IDs", async () => {
    const res = await app.request("/v1/nominations/119-pn-1093-3");
    expect(res.status).toBe(200);
    const nomination = await res.json();
    expect(nomination.nomineeName).toBe("Matthew R. Byrne");
    expect(nomination.organization).toBe("The Judiciary");
    expect(nomination.votes).toEqual([nominationVote]);
    // An unpartitioned nomination ID is valid too; a bill ID or a bare citation is not.
    expect((await app.request("/v1/nominations/118-pn-1905")).status).toBe(404);
    expect((await app.request("/v1/nominations/119-hr-1")).status).toBe(400);
    expect((await app.request("/v1/nominations/PN1093-3")).status).toBe(400);
  });

  it("links a nomination vote to its nomination rather than a bill", async () => {
    const res = await app.request("/v1/votes/senate-119-2-233");
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ billId: null, nominationId: "119-pn-1093-3", billRef: "PN1093-3" });
  });

  it("flags sources that haven't loaded successfully within their window", async () => {
    const res = await app.request("/v1/status");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      ok: false,
      sources: [
        { source: "members", lastSuccessAt: "2026-11-11T00:00:00.000Z", lastError: null, stale: false },
        { source: "house_rollcalls", lastSuccessAt: "2026-11-11T20:00:00.000Z", lastError: null, stale: false },
        { source: "senate_rollcalls", lastSuccessAt: "2026-11-09T00:00:00.000Z", lastError: "HTTP 503", stale: true },
        { source: "bills", lastSuccessAt: null, lastError: null, stale: true },
        { source: "nominations", lastSuccessAt: null, lastError: null, stale: true },
      ],
    });
  });

  it("publishes an OpenAPI document that describes the vote route and schema", async () => {
    const res = await app.request("/openapi.json");
    expect(res.status).toBe(200);
    const doc = await res.json();
    expect(doc.info.title).toBe("Floor API");
    expect(Object.keys(doc.paths)).toContain("/v1/votes/{id}");
    expect(Object.keys(doc.paths)).toContain("/v1/nominations/{id}");
    expect(Object.keys(doc.paths)).toContain("/v1/members/{id}");
    expect(doc.components.schemas.VoteDetail.required).toContain("partyTotals");
    expect(doc.components.schemas.VoteDetail.required).toContain("positions");
    expect(doc.components.schemas.MemberDetail.required).toContain("partyLoyalty");
    expect(doc.components.schemas.Vote.required).toContain("totals");
    expect(doc.components.schemas.Vote.required).toContain("nominationId");
    expect(doc.components.schemas.Nomination.required).toContain("citation");
  });

  it("keeps nullability off the shared components, except where every use is nullable", async () => {
    // zod-openapi hoists `nullable` onto a registered component when a nullable use is registered
    // before a non-nullable one, which would quietly make the component nullable everywhere it is
    // referenced — including at uses that are not supposed to accept null. LatestAction is nullable
    // at both of its uses, so carrying it on the component is correct there. Anything else showing
    // up here needs checking against how it is actually used before the list is widened.
    const doc = await (await app.request("/openapi.json")).json();
    const schemas: Record<string, { nullable?: boolean }> = doc.components.schemas;
    const hoisted = Object.entries(schemas)
      .filter(([, schema]) => schema.nullable)
      .map(([name]) => name);
    expect(hoisted).toEqual(["LatestAction"]);
  });
});
