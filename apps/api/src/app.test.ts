import { describe, expect, it } from "vitest";
import { AI_DISCLAIMER, createApp, type Member, type Vote, type VoteRepository } from "./app.js";

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
    measure: { id: "119-hconres-14", kind: "bill" as const, citation: "H.Con.Res. 14", title: "FY2025 Budget" },
  }),
};

/** Records how `partyLoyalty` was called, so we can check the party came off the member row. */
const loyaltyCalls: string[] = [];
const fundingCalls: string[] = [];

const geocoded: string[] = [];
const app = createApp({
  votes: repo,
  members: {
    membersFor: async (state, district) =>
      members.filter((m) => m.state === state && (m.chamber === "senate" || m.district === district)),
    recentVotes: async (id, limit) =>
      id === "D000399"
        ? [{
            vote: sample,
            position: "yea" as const,
            choice: null,
            measure: { id: "119-hconres-14", kind: "bill" as const, citation: "H.Con.Res. 14", title: "FY2025 Budget" },
          }].slice(0, limit)
        : [],
    getMember: async (id) => members.find((m) => m.bioguideId === id) ?? null,
    partyLoyalty: async (id, party) => {
      loyaltyCalls.push(`${id}/${party}`);
      return { votes: 120, withParty: 111, againstParty: 9 };
    },
    funding: async (id, limit) => {
      fundingCalls.push(`${id}/${limit}`);
      if (id !== "D000399") return null;
      return {
        cycle: 2026,
        coverageStart: "2025-01-01",
        coverageEnd: "2026-10-14",
        receipts: 2_412_880,
        smallDollar: 402_118,
        itemized: 1_204_902,
        pac: 611_500,
        party: 5_000,
        other: 189_360,
        cashOnHand: 884_398,
        committeesCycle: 2026,
        committees: [
          {
            committeeId: "C00002550",
            name: "American Trucking Associations PAC",
            kind: "Trade group",
            orgType: "T",
            connectedOrg: "American Trucking Associations",
            direct: 10_000,
            earmarked: 0,
          },
        ].slice(0, limit),
      };
    },
  },
  bills: {
    getBill: async (id) =>
      id === "119-hconres-14"
        ? {
            id, congress: 119, type: "hconres", number: 14, citation: "H.Con.Res. 14",
            title: "Establishing the congressional budget", shortTitle: null,
            sponsor: null, introducedOn: "2025-02-18", originChamber: "house", policyArea: "Economics and Public Finance",
            summary: "This concurrent resolution establishes the budget.", summaryStage: "Introduced in House",
            latestAction: { on: "2025-05-20", text: "Star Print ordered." }, cboEstimates: [], actions: [], votes: [sample],
          }
        : null,
    getAnalysis: async (id) =>
      id === "119-hconres-14"
        ? {
            billId: id, ai: true, label: "AI-generated", disclaimer: AI_DISCLAIMER,
            source: { kind: "crs_summary", stage: "Introduced in House", paragraphs: ["This concurrent resolution establishes the budget."], stale: false },
            model: "claude-sonnet-5-5", verifierModel: "claude-sonnet-5-5", promptVersion: "bill-analysis/1",
            generatedAt: "2026-11-13T12:00:00.000Z",
            purpose: {
              text: "The resolution sets out the congressional budget.", ai: true,
              citations: [{ paragraph: 1, quote: "establishes the budget", section: null }],
            },
            provisions: [], affectedGroups: [], impact: [],
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
      {
        source: "house_rollcalls",
        lastSuccessAt: new Date("2026-11-11T20:00:00Z"),
        lastNewDataAt: new Date("2026-11-10T20:00:00Z"),
        lastError: null,
      },
      { source: "senate_rollcalls", lastSuccessAt: new Date("2026-11-09T00:00:00Z"), lastError: "HTTP 503" },
    ],
  },
  now: () => new Date("2026-11-12T00:00:00Z"),
  locate: async (place) => {
    const austin = { congress: 119, state: "TX", stateFips: "48", district: 37, countyFips: "48453" };
    if ("address" in place) {
      geocoded.push(place.address);
      return place.address.includes("Austin") ? austin : null;
    }
    geocoded.push(`${place.lat},${place.lng}`);
    // Inside the continental US resolves to TX-37 here; anywhere else is outside every district.
    return place.lat > 24 && place.lat < 50 && place.lng > -125 && place.lng < -66 ? austin : null;
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

  it("returns a member's campaign money, with the two FEC sources kept apart", async () => {
    const res = await app.request("/v1/members/D000399/funding");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.member).toEqual(members[0]);
    expect(body.funding).toMatchObject({ cycle: 2026, receipts: 2_412_880, cashOnHand: 884_398 });
    // What the campaign reported receiving is not a breakdown of what committees reported giving:
    // the PAC total and the listed committees come from different filings and need not agree.
    expect(body.funding.pac).toBe(611_500);
    expect(body.funding.committees[0]).toMatchObject({ name: "American Trucking Associations PAC", direct: 10_000, earmarked: 0 });
  });

  it("names no individual donor anywhere in a funding response", async () => {
    const res = await app.request("/v1/members/D000399/funding");
    const body = await res.json();
    // Earmark memos are where FEC names individuals, and the importer drops them (lesson 23).
    // The response shape has nowhere to put one either: a committee carries exactly these keys,
    // so a memo field added later fails here rather than reaching a client.
    expect(Object.keys(body.funding.committees[0]).sort()).toEqual([
      "committeeId", "connectedOrg", "direct", "earmarked", "kind", "name", "orgType",
    ]);
    // `earmarked` is an amount, not a memo: a number, never text.
    for (const c of body.funding.committees) {
      expect(typeof c.earmarked).toBe("number");
      expect(c.name).toMatch(/PAC|Association|Committee|Fund|Inc|Corp|Union|Company|Group/i);
    }
  });

  it("caps the committee list at what ?committees= asked for, and defaults to ten", async () => {
    await app.request("/v1/members/D000399/funding");
    expect(fundingCalls).toContain("D000399/10");
    await app.request("/v1/members/D000399/funding?committees=3");
    expect(fundingCalls).toContain("D000399/3");
    expect((await app.request("/v1/members/D000399/funding?committees=51")).status).toBe(400);
    expect((await app.request("/v1/members/D000399/funding?committees=-1")).status).toBe(400);
  });

  it("returns the member with null funding when FEC has no totals for them", async () => {
    const res = await app.request("/v1/members/C001098/funding");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.member.bioguideId).toBe("C001098");
    expect(body.funding).toBeNull();
  });

  it("returns 404 for funding of an unknown member and 400 for a malformed ID", async () => {
    expect((await app.request("/v1/members/Z000000/funding")).status).toBe(404);
    expect((await app.request("/v1/members/doggett/funding")).status).toBe(400);
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

  it("finds members from the browser's coordinates", async () => {
    const res = await app.request("/v1/reps?lat=30.2747&lng=-97.7404");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.district).toEqual({ congress: 119, state: "TX", district: 37, countyFips: "48453" });
    expect(body.members.map((m: Member) => m.bioguideId)).toEqual(["D000399", "C001098"]);
    expect(geocoded.at(-1)).toBe("30.2747,-97.7404");
  });

  it("says when coordinates fall outside every U.S. district", async () => {
    const res = await app.request("/v1/reps?lat=51.5072&lng=-0.1276");
    expect(res.status).toBe(404);
    expect((await res.json()).error).toMatch(/isn't in a U.S. congressional district/);
  });

  it("asks for exactly one of an address or a full pair of coordinates", async () => {
    const before = geocoded.length;
    for (const [query, message] of [
      ["", /Send an address, or both lat and lng/],
      ["lat=30.27", /Send an address, or both lat and lng/],
      ["lng=-97.74", /Send an address, or both lat and lng/],
      ["address=1100%20Congress%20Ave%2C%20Austin%2C%20TX&lat=30.27&lng=-97.74", /not both/],
      ["lat=91&lng=0", /lat must be between -90 and 90/],
      ["lat=0&lng=181", /lng must be between -180 and 180/],
      ["lat=north&lng=west", /./],
    ] as const) {
      const res = await app.request(`/v1/reps?${query}`);
      expect(res.status, query).toBe(400);
      expect((await res.json()).error, query).toMatch(message);
    }
    expect(geocoded.length).toBe(before);
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
    expect(await res.json()).toEqual({
      votes: [{
        vote: sample,
        position: "yea",
        choice: null,
        measure: { id: "119-hconres-14", kind: "bill", citation: "H.Con.Res. 14", title: "FY2025 Budget" },
      }],
    });
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

  it("returns a bill's AI analysis labelled, cited and with its disclaimer", async () => {
    const res = await app.request("/v1/bills/119-hconres-14/analysis");
    expect(res.status).toBe(200);
    const a = await res.json();
    expect(a).toMatchObject({ ai: true, label: "AI-generated", disclaimer: AI_DISCLAIMER });
    expect(a.disclaimer).toMatch(/may contain errors/);
    expect(a.purpose).toMatchObject({ ai: true, citations: [{ paragraph: 1, quote: "establishes the budget" }] });
    expect(a.source.paragraphs[a.purpose.citations[0].paragraph - 1]).toContain(a.purpose.citations[0].quote);
    const missing = await app.request("/v1/bills/119-hr-404/analysis");
    expect(missing.status).toBe(404);
    expect(await missing.json()).toEqual({ error: "No AI analysis for bill 119-hr-404 yet" });
    expect((await app.request("/v1/bills/HR2207/analysis")).status).toBe(400);
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
        { source: "members", lastSuccessAt: "2026-11-11T00:00:00.000Z", lastNewDataAt: null, lastError: null, stale: false },
        {
          source: "house_rollcalls",
          lastSuccessAt: "2026-11-11T20:00:00.000Z",
          lastNewDataAt: "2026-11-10T20:00:00.000Z",
          lastError: null,
          stale: false,
        },
        { source: "senate_rollcalls", lastSuccessAt: "2026-11-09T00:00:00.000Z", lastNewDataAt: null, lastError: "HTTP 503", stale: true },
        { source: "bills", lastSuccessAt: null, lastNewDataAt: null, lastError: null, stale: true },
        { source: "nominations", lastSuccessAt: null, lastNewDataAt: null, lastError: null, stale: true },
      ],
    });
  });

  it("still answers when the database itself is unreachable", async () => {
    // The route exists to report data health, so a database failure is the case it must handle,
    // not the case that takes it down. A monitor needs `ok: false` and a reason, not a 500.
    const broken = createApp({
      votes: repo,
      members: {
        membersFor: async () => [],
        recentVotes: async () => [],
        getMember: async () => null,
        partyLoyalty: async () => ({ votes: 0, withParty: 0, againstParty: 0 }),
        funding: async () => null,
      },
      bills: { getBill: async () => null, getAnalysis: async () => null },
      nominations: { getNomination: async () => null },
      status: {
        lastRuns: async () => {
          throw new Error("getaddrinfo ENOTFOUND db.example.supabase.co");
        },
      },
      locate: async () => null,
    });
    const res = await broken.request("/v1/status");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.ok).toBe(false);
    expect(body.sources).toHaveLength(5);
    expect(body.sources.every((s: { stale: boolean }) => s.stale)).toBe(true);
    expect(body.sources[0].lastError).toMatch(/ENOTFOUND/);
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
    // referenced — including at uses that are not supposed to accept null. All three of these are
    // nullable at every use they have, so carrying it on the component is correct for them:
    // LatestAction on Bill and Nomination, MeasureSummary on MemberVote (a procedural vote refers
    // to no measure), and Funding on MemberFunding, its only use, null when FEC has no totals for
    // the member. Anything else showing up here needs checking against how it is actually used
    // before the list is widened — and if Funding ever gains a use that must not accept null, it
    // has to come off this list and out of the component, not be left here.
    const doc = await (await app.request("/openapi.json")).json();
    const schemas: Record<string, { nullable?: boolean }> = doc.components.schemas;
    const hoisted = Object.entries(schemas)
      .filter(([, schema]) => schema.nullable)
      .map(([name]) => name);
    expect(hoisted.sort()).toEqual(["Funding", "LatestAction", "MeasureSummary"]);
  });
});
