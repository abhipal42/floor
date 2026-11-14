import { describe, expect, it } from "vitest";
import {
  AI_DISCLAIMER,
  SEARCH_CACHE_CONTROL,
  SEARCH_RATE_LIMIT,
  VOTES_CACHE_CONTROL,
  TOPICS_CACHE_CONTROL,
  TOPICS_RATE_LIMIT,
  DEVICES_RATE_LIMIT,
  DEVICE_SUBSCRIPTION_MAX,
  DEVICE_BODY_LIMIT,
  congressOn,
  deviceKeyHash,
  type DeviceRepository,
  decodeCursor,
  createApp,
  type BillListItem,
  type CatalogRepository,
  type ChamberStatus,
  type LiveVote,
  type Member,
  type Vote,
  type VoteRepository,
} from "./app.js";
import { MemoryLimitStore } from "./limit.js";
import type { MemberQuery } from "./search.js";

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
    measure: { id: "119-hconres-14", kind: "bill" as const, citation: "H.Con.Res. 14", title: "FY2025 Budget", policyArea: "Economics and Public Finance" },
  }),
  recentVotes: async (chamber, limit, before, topics) => {
    topicCalls.push(topics);
    return [
      { vote: nominationVote, measure: null },
      { vote: sample, measure: { id: "119-hconres-14", kind: "bill" as const, citation: "H.Con.Res. 14", title: "FY2025 Budget", policyArea: "Economics and Public Finance" } },
    ]
      .filter((r) => !chamber || r.vote.chamber === chamber)
      .filter((r) => !before || new Date(r.vote.occurredAt!) < before)
      .filter((r) => !topics || (r.measure?.policyArea != null && topics.includes(r.measure.policyArea)))
      .slice(0, limit);
  },
};

/** The `topics` each call to the recent-votes repository was handed. */
const topicCalls: (string[] | undefined)[] = [];

/** Each parsed search the member repository was asked, so the route's parsing can be checked. */
const searches: { query: MemberQuery; chamber: string | undefined; limit: number }[] = [];

/** Records how `partyLoyalty` was called, so we can check the party came off the member row. */
const loyaltyCalls: string[] = [];
const fundingCalls: string[] = [];

const geocoded: string[] = [];

/** House roll 319 of 2026 as the live worker stores it between the floor summary and the XML. */
const openVote: LiveVote = {
  ...sample,
  id: "house-119-2-319",
  session: 2,
  rollNumber: 319,
  question: "On agreeing to the resolution",
  billId: null,
  billRef: "H. Res. 1650",
  occurredAt: "2026-11-10T23:20:53.000Z",
  state: "open",
  totals: { yea: 215, nay: 209, present: 0, notVoting: 0 },
  result: "Agreed to",
  openedAt: "2026-11-10T23:20:53.000Z",
  announcedAt: "2026-11-10T23:33:00.000Z",
  postedAt: null,
  measure: { id: "119-hres-1650", kind: "bill", citation: "H.Res. 1650", title: "Providing for consideration", policyArea: null },
};
const houseStatus: ChamberStatus = {
  chamber: "house",
  inSession: true,
  convenesAt: null,
  legislativeDay: "2026-11-10",
  checkedAt: "2026-11-10T23:33:00.000Z",
};
const liveCalls: string[] = [];

/** Repositories with nothing in them, for tests that exercise one route. */
const emptyDeps = {
  votes: repo,
  members: {
    membersFor: async () => [],
    recentVotes: async () => [],
    getMember: async () => null,
    search: async () => [],
    partyLoyalty: async () => ({ votes: 0, withParty: 0, againstParty: 0 }),
    funding: async () => null,
  },
  bills: { getBill: async () => null, getAnalysis: async () => null },
  nominations: { getNomination: async () => null },
  status: { lastRuns: async () => [] },
  live: { chambers: async () => [], liveVotes: async () => [] },
};

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
            measure: { id: "119-hconres-14", kind: "bill" as const, citation: "H.Con.Res. 14", title: "FY2025 Budget", policyArea: "Economics and Public Finance" },
          }].slice(0, limit)
        : [],
    getMember: async (id) => members.find((m) => m.bioguideId === id) ?? null,
    search: async (query, chamber, limit) => {
      searches.push({ query, chamber, limit });
      return members.filter((m) => !chamber || m.chamber === chamber).slice(0, limit);
    },
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
            title: "Establishing the congressional budget", shortTitle: null, label: "Establishing the congressional budget", stage: "passed_house",
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
  live: {
    chambers: async () => [houseStatus],
    liveVotes: async (postedAfter) => {
      liveCalls.push(postedAfter.toISOString());
      return [openVote];
    },
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
        measure: { id: "119-hconres-14", kind: "bill", citation: "H.Con.Res. 14", title: "FY2025 Budget", policyArea: "Economics and Public Finance" },
      }],
    });
  });

  it("searches members, handing the repository the parsed query, chamber and limit", async () => {
    searches.length = 0;
    const res = await app.request("/v1/members?q=New%20York");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ members });
    await app.request("/v1/members?q=ny-8&chamber=house&limit=5");
    await app.request("/v1/members?q=%20Doggett%20");
    expect(searches).toEqual([
      { query: { kind: "state", state: "NY", name: "new york" }, chamber: undefined, limit: 60 },
      { query: { kind: "seat", state: "NY", district: 8 }, chamber: "house", limit: 5 },
      { query: { kind: "name", text: "doggett" }, chamber: undefined, limit: 60 },
    ]);
  });

  it("filters a search by chamber", async () => {
    const res = await app.request("/v1/members?q=tx&chamber=senate");
    expect((await res.json()).members.map((m: Member) => m.bioguideId)).toEqual(["C001098"]);
  });

  it("refuses an empty or one-letter search, a bad chamber, and an out-of-range limit", async () => {
    for (const q of ["", "q=", "q=%20%20", "q=a", "q=ny&chamber=both", "q=ny&limit=0", "q=ny&limit=101"]) {
      const res = await app.request(`/v1/members?${q}`);
      expect(res.status, q).toBe(400);
    }
    expect((await (await app.request("/v1/members?q=a")).json()).error).toBe("Type at least two characters");
  });

  it("lists recent final votes with what each was on, by chamber", async () => {
    const all = await (await app.request("/v1/votes")).json();
    expect(all.votes.map((r: { vote: Vote }) => r.vote.id)).toEqual([nominationVote.id, sample.id]);
    expect(all.votes[1].measure.citation).toBe("H.Con.Res. 14");
    const house = await (await app.request("/v1/votes?chamber=house&limit=10")).json();
    expect(house.votes.map((r: { vote: Vote }) => r.vote.id)).toEqual([sample.id]);
    expect((await app.request("/v1/votes?limit=101")).status).toBe(400);
    expect((await app.request("/v1/votes?before=yesterday")).status).toBe(400);
    // Strictly before: both fakes share this occurredAt, so the page after them is empty.
    const next = await (await app.request(`/v1/votes?before=${encodeURIComponent(nominationVote.occurredAt!)}`)).json();
    expect(next.votes.map((r: { vote: Vote }) => r.vote.id)).toEqual([]);
    const page = await app.request("/v1/votes?before=2030-01-01T00:00:00Z");
    expect(page.headers.get("cache-control")).toBe(VOTES_CACHE_CONTROL);
    // The list route and the one-vote route are different paths; a vote ID still reaches the latter.
    expect((await app.request(`/v1/votes/${sample.id}`)).status).toBe(200);
  });

  it("narrows recent votes to topics, repeated because topic names hold commas, in their canonical spelling", async () => {
    topicCalls.length = 0;
    const one = await (await app.request("/v1/votes?topic=economics%20and%20public%20finance")).json();
    expect(one.votes.map((r: { vote: Vote }) => r.vote.id)).toEqual([sample.id]);
    expect(one.votes[0].measure.policyArea).toBe("Economics and Public Finance");
    await app.request("/v1/votes?topic=Health&topic=Arts%2C%20Culture%2C%20Religion&topic=Nonsense");
    expect(topicCalls).toEqual([["Economics and Public Finance"], ["Health", "Arts, Culture, Religion"]]);
    // Only names that are not topics: nothing, not every vote, and the repository is not asked.
    const none = await (await app.request("/v1/votes?topic=Nonsense")).json();
    expect(none.votes).toEqual([]);
    expect(topicCalls).toHaveLength(2);
    // No topic at all is the plain list.
    await app.request("/v1/votes");
    expect(topicCalls[2]).toBeUndefined();
    expect((await app.request(`/v1/votes?${Array.from({ length: 33 }, () => "topic=Health").join("&")}`)).status).toBe(400);
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
    expect(bill.label).toBe("Establishing the congressional budget");
    expect(bill.stage).toBe("passed_house");
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
        search: async () => [],
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
      live: { chambers: async () => [], liveVotes: async () => [] },
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

  it("serves the live view: chamber state and votes, cached at the edge for 5 s", async () => {
    const res = await app.request("/v1/live?since=30");
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("public, max-age=5, s-maxage=5, stale-while-revalidate=5");
    expect(await res.json()).toEqual({ chambers: [houseStatus], votes: [openVote] });
    // `since` minutes back from the injected clock (2026-11-12T00:00Z).
    expect(liveCalls).toEqual(["2026-11-11T23:30:00.000Z"]);
  });

  it("defaults the live window to two hours and bounds it to a day", async () => {
    liveCalls.length = 0;
    await app.request("/v1/live");
    expect(liveCalls).toEqual(["2026-11-11T22:00:00.000Z"]);
    expect((await app.request("/v1/live?since=0")).status).toBe(400);
    expect((await app.request("/v1/live?since=1441")).status).toBe(400);
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
    // the member; and BillStage on BillListItem and Bill, both null until the worker has staged the
    // bill. Anything else showing up here needs checking against how it is actually used
    // before the list is widened — and if Funding ever gains a use that must not accept null, it
    // has to come off this list and out of the component, not be left here.
    const doc = await (await app.request("/openapi.json")).json();
    const schemas: Record<string, { nullable?: boolean }> = doc.components.schemas;
    const hoisted = Object.entries(schemas)
      .filter(([, schema]) => schema.nullable)
      .map(([name]) => name);
    expect(hoisted.sort()).toEqual(["BillStage", "Funding", "LatestAction", "MeasureSummary"]);
  });
});

describe("topics and search", () => {
  const item = (id: string, on: string | null): BillListItem => {
    const [congress, type, number] = id.split("-");
    return {
      id,
      congress: Number(congress),
      type: type!,
      number: Number(number),
      citation: `${type!.toUpperCase()} ${number}`,
      label: id,
      title: id,
      policyArea: "Health",
      stage: "introduced",
      stalled: false,
      latestAction: on ? { on, text: "Referred." } : null,
      hasFloorVote: false,
    };
  };
  const health = [item("119-sjres-197", "2026-09-29"), item("119-hr-4541", "2026-07-27"), item("119-hr-2493", "2026-04-22")];
  const calls: string[] = [];
  const catalog: CatalogRepository = {
    topicCounts: async (congress) => {
      calls.push(`counts ${congress}`);
      return [{ name: "Health", bills: 3, billsWithFloorVote: 1, latestActionOn: "2026-09-29" }];
    },
    topicBills: async (congress, topic, filter, after, limit) => {
      calls.push(`bills ${congress} ${topic} ${filter} ${after ? `${after.on}|${after.id}` : "-"} ${limit}`);
      const start = after ? health.findIndex((b) => b.id === after.id) + 1 : 0;
      return health.slice(start, start + limit).map((bill) => ({ bill, at: { on: bill.latestAction?.on ?? null, id: bill.id } }));
    },
    billsByNumber: async (type, number, congress) => {
      calls.push(`number ${type} ${number} ${congress}`);
      return type === "hr" && number === 1013 ? [item("119-hr-1013", "2026-11-11")] : [];
    },
    searchBills: async (q, congress, limit) => {
      calls.push(`words ${q} ${congress} ${limit}`);
      return q.includes("rural") ? [health[2]!] : [];
    },
  };
  // Texas's delegation as it sits: 2 senators and 38 House seats, 40 in all.
  const texas: Member[] = [
    members[1]!,
    { bioguideId: "C001056", firstName: "John", lastName: "Cornyn", party: "R", state: "TX", district: null, chamber: "senate" },
    ...Array.from({ length: 38 }, (_, i): Member => ({
      bioguideId: `T${String(i + 1).padStart(6, "0")}`, firstName: "Rep", lastName: `District${i + 1}`,
      party: "R", state: "TX", district: i + 1, chamber: "house",
    })),
  ];
  const velazquez: Member = { bioguideId: "V000081", firstName: "Nydia", lastName: "Velázquez", party: "D", state: "NY", district: 7, chamber: "house" };
  const aoc: Member = { bioguideId: "O000172", firstName: "Alexandria", lastName: "Ocasio-Cortez", party: "D", state: "NY", district: 14, chamber: "house" };
  const norton: Member = { bioguideId: "N000147", firstName: "Eleanor", lastName: "Norton", party: "D", state: "DC", district: 0, chamber: "house" };
  /** Each parsed search `/v1/search` handed the member repository: the same reader as `/v1/members?q=`. */
  const memberSearches: { query: MemberQuery; chamber: string | undefined; limit: number }[] = [];
  /** A stand-in for the SQL (tested on its own in pg.test.ts), answering the parsed shape it is given. */
  const memberRepo = {
    ...emptyDeps.members,
    search: async (query: MemberQuery, chamber: "house" | "senate" | undefined, limit: number) => {
      memberSearches.push({ query, chamber, limit });
      const found =
        query.kind === "state"
          ? query.state === "TX" ? texas : query.state === "NY" ? [velazquez, aoc] : []
          : query.kind === "seat"
            ? query.state === "DC" ? [norton] : []
            : ({ doggett: [members[0]!], velazquez: [velazquez], "ocasio cortez": [aoc] } as Record<string, Member[]>)[query.text] ?? [];
      return found.filter((m) => !chamber || m.chamber === chamber).slice(0, limit);
    },
  };
  const now = () => new Date("2026-11-13T17:00:00Z");
  const topicsApp = () =>
    createApp({ ...emptyDeps, members: memberRepo, catalog, now, limitStore: new MemoryLimitStore(), locate: async () => null });

  it("lists all 32 topics, filling in the empty ones, cached at the edge", async () => {
    const res = await topicsApp().request("/v1/topics");
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe(TOPICS_CACHE_CONTROL);
    const body = await res.json();
    expect(body.congress).toBe(119);
    expect(body.topics).toHaveLength(32);
    expect(body.topics.find((t: { name: string }) => t.name === "Health")).toEqual({
      name: "Health",
      bills: 3,
      billsWithFloorVote: 1,
      latestActionOn: "2026-09-29",
    });
    expect(body.topics.find((t: { name: string }) => t.name === "Taxation")).toEqual({
      name: "Taxation",
      bills: 0,
      billsWithFloorVote: 0,
      latestActionOn: null,
    });
  });

  it("pages a topic with a cursor, and reads an encoded name", async () => {
    calls.length = 0;
    const app = topicsApp();
    const first = await (await app.request("/v1/topics/health/bills?limit=2&filter=moving")).json();
    expect(first.topic.name).toBe("Health");
    expect(first.filter).toBe("moving");
    expect(first.bills.map((b: BillListItem) => b.id)).toEqual(["119-sjres-197", "119-hr-4541"]);
    expect(first.nextCursor).toEqual(expect.any(String));
    const second = await (
      await app.request(`/v1/topics/Health/bills?limit=2&filter=moving&cursor=${first.nextCursor}`)
    ).json();
    expect(second.bills.map((b: BillListItem) => b.id)).toEqual(["119-hr-2493"]);
    expect(second.nextCursor).toBeNull();
    // One extra row is asked for, to know whether there is another page.
    expect(calls).toContain("bills 119 Health moving 2026-07-27|119-hr-4541 3");

    const encoded = await app.request("/v1/topics/Arts%2C%20Culture%2C%20Religion/bills");
    expect(encoded.status).toBe(200);
    expect((await encoded.json()).topic.name).toBe("Arts, Culture, Religion");
  });

  it("refuses a topic that is not a policy area, and a forged cursor", async () => {
    const app = topicsApp();
    expect((await app.request("/v1/topics/Healthcare/bills")).status).toBe(404);
    expect((await app.request("/v1/topics/Health/bills?cursor=not-a-cursor")).status).toBe(400);
    const forged = Buffer.from(JSON.stringify(["2026-01-01'; drop table bills;--", "x"])).toString("base64url");
    expect((await app.request(`/v1/topics/Health/bills?cursor=${forged}`)).status).toBe(400);
    expect((await app.request("/v1/topics/Health/bills?filter=everything")).status).toBe(400);
  });

  it("resolves a bill number exactly and searches nothing else", async () => {
    calls.length = 0;
    const res = await topicsApp().request("/v1/search?q=H.R.1013");
    expect(res.headers.get("cache-control")).toBe(SEARCH_CACHE_CONTROL);
    const body = await res.json();
    expect(body).toMatchObject({ query: "H.R.1013", billNumber: true, members: [], topics: [] });
    expect(body.bills.map((b: BillListItem) => b.id)).toEqual(["119-hr-1013"]);
    expect(calls).toEqual(["number hr 1013 null"]);
  });

  it("groups word matches into members, bills and topics", async () => {
    const rural = await (await topicsApp().request("/v1/search?q=rural%20health")).json();
    expect(rural.billNumber).toBe(false);
    expect(rural.bills.map((b: BillListItem) => b.id)).toEqual(["119-hr-2493"]);
    // No topic holds both words, so the one holding "health".
    expect(rural.topics.map((t: { name: string }) => t.name)).toEqual(["Health"]);
    const topic = await (await topicsApp().request("/v1/search?q=health")).json();
    expect(topic.topics).toEqual([{ name: "Health", bills: 3, billsWithFloorVote: 1, latestActionOn: "2026-09-29" }]);
    const member = await (await topicsApp().request("/v1/search?q=doggett")).json();
    expect(member.members.map((m: Member) => m.lastName)).toEqual(["Doggett"]);
    expect((await topicsApp().request("/v1/search?q=a")).status).toBe(400);
  });

  it("reads members with /v1/members?q='s reader: folded names, seats, dotted codes, whole states", async () => {
    memberSearches.length = 0;
    const app = topicsApp();
    const ids = async (q: string, extra = "") =>
      ((await (await app.request(`/v1/search?q=${encodeURIComponent(q)}${extra}`)).json()).members as Member[]).map((m) => m.bioguideId);
    expect(await ids("velazquez")).toEqual(["V000081"]);
    expect(await ids("ocasio cortez")).toEqual(["O000172"]);
    expect(await ids("DC-1")).toEqual(["N000147"]);
    expect(await ids("N.Y.")).toEqual(["V000081", "O000172"]);
    expect(await ids("Washington")).toEqual([]);
    const tx = await ids("Texas");
    expect(tx).toHaveLength(40);
    expect(tx).toEqual(texas.map((m) => m.bioguideId));
    expect(await ids("Texas", "&chamber=senate")).toEqual(["C001098", "C001056"]);
    expect(memberSearches).toEqual([
      { query: { kind: "name", text: "velazquez" }, chamber: undefined, limit: 60 },
      { query: { kind: "name", text: "ocasio cortez" }, chamber: undefined, limit: 60 },
      // A delegate's one seat, whatever number is typed.
      { query: { kind: "seat", state: "DC", district: 1 }, chamber: undefined, limit: 60 },
      { query: { kind: "state", state: "NY", name: "ny" }, chamber: undefined, limit: 60 },
      // A state and a surname at once, not the state alone.
      { query: { kind: "state", state: "WA", name: "washington" }, chamber: undefined, limit: 60 },
      { query: { kind: "state", state: "TX", name: "texas" }, chamber: undefined, limit: 60 },
      { query: { kind: "state", state: "TX", name: "texas" }, chamber: "senate", limit: 60 },
    ]);
    // A bill number asks for no members, and a chamber that is not one is refused.
    memberSearches.length = 0;
    expect(await ids("hr 1013")).toEqual([]);
    expect(memberSearches).toEqual([]);
    expect((await app.request("/v1/search?q=texas&chamber=both")).status).toBe(400);
  });

  it("rate-limits search per caller, apart from the other routes' counts", async () => {
    const app = topicsApp();
    const from = { headers: { "x-forwarded-for": "203.0.113.9" } };
    for (let i = 0; i < SEARCH_RATE_LIMIT.limit; i++) {
      expect((await app.request("/v1/search?q=doggett", from)).status).toBe(200);
    }
    const refused = await app.request("/v1/search?q=doggett", from);
    expect(refused.status).toBe(429);
    expect((await refused.json()).error).toMatch(/Too many requests/);
    // Topics keep their own count.
    expect((await app.request("/v1/topics", from)).status).toBe(200);
  });

  it("counts each topics request once, the list and its pages alike", async () => {
    const app = topicsApp();
    const from = { headers: { "x-forwarded-for": "203.0.113.10" } };
    const first = await app.request("/v1/topics", from);
    expect(first.headers.get("RateLimit-Remaining")).toBe(String(TOPICS_RATE_LIMIT.limit - 1));
    const second = await app.request("/v1/topics/Health/bills", from);
    expect(second.headers.get("RateLimit-Remaining")).toBe(String(TOPICS_RATE_LIMIT.limit - 2));
  });

  it("takes the next cursor from the stored action date, even when the row shows no latest action", async () => {
    // A bill listed with an action date but no action text: latestAction is null on the row.
    const dated: CatalogRepository = {
      ...catalog,
      topicBills: async (_c, _t, _f, after, limit) =>
        [item("119-hr-7", null), item("119-hr-8", null)]
          .map((bill, i) => ({ bill, at: { on: i === 0 ? "2026-10-01" : "2026-09-01", id: bill.id } }))
          .filter((r) => !after || r.at.id < after.id)
          .slice(0, limit),
    };
    const app = createApp({ ...emptyDeps, catalog: dated, now, limitStore: new MemoryLimitStore(), locate: async () => null });
    const first = await (await app.request("/v1/topics/Health/bills?limit=1")).json();
    expect(decodeCursor(first.nextCursor)).toEqual({ on: "2026-10-01", id: "119-hr-7" });
  });

  it("knows which Congress is in session", () => {
    expect(congressOn(new Date("2026-11-13T17:00:00Z"))).toBe(119);
    expect(congressOn(new Date("2025-01-02T17:00:00Z"))).toBe(118);
    expect(congressOn(new Date("2025-01-03T17:00:00Z"))).toBe(119);
    expect(congressOn(new Date("2027-01-04T17:00:00Z"))).toBe(120);
  });
});

describe("device routes", () => {
  const key = "k".repeat(43);
  const auth = { authorization: `Device ${key}` };
  const keyHash = deviceKeyHash(`Device ${key}`)!;
  const limitedKey = "L".repeat(43);
  const limitedHash = deviceKeyHash(`Device ${limitedKey}`)!;
  const registration = {
    apnsToken: "AB".repeat(32),
    apnsEnvironment: "sandbox",
    pushToStartToken: null,
    voteOpened: false,
    liveActivities: true,
    subscriptions: [
      { kind: "member", id: "D000399", howVoted: true },
      { kind: "bill", id: "119-hr-1013", howVoted: false },
    ],
  };
  const calls: unknown[][] = [];
  const devices: DeviceRepository = {
    register: async (...args) => (calls.push(["register", ...args]), args[0] === limitedHash ? "limited" : "ok"),
    unregister: async (h) => (calls.push(["unregister", h]), true),
    setActivityToken: async (h, voteId, token) => {
      calls.push(["activity", h, voteId, token]);
      return voteId === "house-119-2-404" ? "no_vote" : h === keyHash ? "ok" : "no_device";
    },
    removeActivityToken: async (h, voteId) => void calls.push(["end", h, voteId]),
  };
  const deviceApp = () =>
    createApp({ ...emptyDeps, locate: async () => null, devices, limitStore: new MemoryLimitStore(), now: () => new Date("2026-11-13T20:00:00Z") });
  const put = (app: ReturnType<typeof createApp>, body: unknown, headers: Record<string, string> = auth) =>
    app.request("/v1/devices", { method: "PUT", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });

  it("stores the registration under the key's hash, never the key, with tokens lower-cased", async () => {
    calls.length = 0;
    const res = await put(deviceApp(), registration);
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(await res.json()).toEqual({ subscriptions: 2, voteOpened: false });
    expect(keyHash).toMatch(/^[0-9a-f]{64}$/);
    expect(calls).toEqual([
      ["register", keyHash, { ...registration, apnsToken: "ab".repeat(32) }, new Date("2026-11-13T20:00:00Z"), "unknown"],
    ]);
    expect(JSON.stringify(calls)).not.toContain(key);
  });

  it("answers 401 without a well-formed device key", async () => {
    const app = deviceApp();
    for (const headers of [{}, { authorization: `Bearer ${key}` }, { authorization: "Device short" }] as Record<string, string>[]) {
      const res = await put(app, registration, headers);
      expect(res.status).toBe(401);
    }
    expect((await app.request("/v1/devices", { method: "DELETE" })).status).toBe(401);
  });

  it("refuses a malformed token, a topic subscription, a bad id, or too many subscriptions", async () => {
    const app = deviceApp();
    const bad = [
      { ...registration, apnsToken: "not-hex" },
      { ...registration, subscriptions: [{ kind: "topic", id: "Health", howVoted: true }] },
      { ...registration, subscriptions: [{ kind: "member", id: "doggett", howVoted: true }] },
      { ...registration, subscriptions: [{ kind: "bill", id: "H.R. 1013", howVoted: true }] },
      {
        ...registration,
        subscriptions: Array.from({ length: DEVICE_SUBSCRIPTION_MAX + 1 }, (_, i) => ({ kind: "bill", id: `119-hr-${i}`, howVoted: true })),
      },
      { ...registration, apnsEnvironment: "staging" },
    ];
    for (const body of bad) expect((await put(app, body)).status).toBe(400);
  });

  it("unregisters, and keeps and ends a Live Activity's token", async () => {
    calls.length = 0;
    const app = deviceApp();
    expect((await app.request("/v1/devices", { method: "DELETE", headers: auth })).status).toBe(204);
    const activity = (voteId: string, headers: Record<string, string> = auth) =>
      app.request(`/v1/devices/activities/${voteId}`, {
        method: "PUT",
        headers: { "content-type": "application/json", ...headers },
        body: JSON.stringify({ token: "CD".repeat(32) }),
      });
    expect((await activity("house-119-2-321")).status).toBe(204);
    expect((await activity("house-119-2-404")).status).toBe(404);
    expect((await activity("house-119-2-321", { authorization: `Device ${"z".repeat(43)}` })).status).toBe(404);
    expect((await activity("not-a-vote")).status).toBe(400);
    expect((await app.request("/v1/devices/activities/house-119-2-321", { method: "DELETE", headers: auth })).status).toBe(204);
    expect(calls[0]).toEqual(["unregister", keyHash]);
    expect(calls[1]).toEqual(["activity", keyHash, "house-119-2-321", "cd".repeat(32)]);
    expect(calls.at(-1)).toEqual(["end", keyHash, "house-119-2-321"]);
  });

  it("answers 429 for a new key past the caller's daily allowance, and 413 for an oversized body", async () => {
    const app = deviceApp();
    expect((await put(app, registration, { authorization: `Device ${limitedKey}` })).status).toBe(429);
    const body = JSON.stringify({ ...registration, padding: "x".repeat(DEVICE_BODY_LIMIT) });
    const huge = await app.request("/v1/devices", {
      method: "PUT",
      headers: { "content-type": "application/json", "content-length": String(body.length), ...auth },
      body,
    });
    expect(huge.status).toBe(413);
  });

  it("answers 503 where there is no database to keep a registration in", async () => {
    const app = createApp({ ...emptyDeps, locate: async () => null });
    expect((await put(app, registration)).status).toBe(503);
  });

  it("rate limits the device routes together, per caller", async () => {
    const app = deviceApp();
    const statuses: number[] = [];
    for (let i = 0; i < DEVICES_RATE_LIMIT.limit; i++) statuses.push((await put(app, registration)).status);
    expect(new Set(statuses)).toEqual(new Set([200]));
    expect((await app.request("/v1/devices", { method: "DELETE", headers: auth })).status).toBe(429);
  });

  it("documents the device routes and their key in the OpenAPI document", async () => {
    const doc = await (await deviceApp().request("/openapi.json")).json();
    expect(Object.keys(doc.paths)).toEqual(expect.arrayContaining(["/v1/devices", "/v1/devices/activities/{voteId}"]));
    expect(doc.components.securitySchemes.deviceKey).toMatchObject({ type: "apiKey", in: "header", name: "Authorization" });
    expect(doc.components.schemas.LiveVote.properties.measure).toBeDefined();
  });
});
