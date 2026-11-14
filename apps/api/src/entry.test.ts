/**
 * The card libraries cannot take the API down (lesson 64).
 *
 * v0.2.32 imported satori at the top of share.ts. satori imports `harfbuzzjs`, whose module value is
 * a promise that compiles `hb.wasm`; on Vercel that file was not in the function, the promise
 * rejected before anything awaited it, and the instance died at boot, so every route answered 500.
 * These mocks make both card libraries fail the moment they are evaluated. Imported at the top of
 * the entry, as in v0.2.32, the entry cannot load and this file fails; imported only by the card
 * route, they cost that route a 500. (The unhandled-rejection shape itself is checked against the
 * real traced function by `scripts/function-smoke.mjs`.)
 */
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { EMPTY_SCHEDULE, NO_CONTACT, createApp, type Bill } from "./app.js";

vi.mock("satori", () => {
  throw new Error("ENOENT: no such file or directory, open 'hb.wasm'");
});
vi.mock("@resvg/resvg-wasm", () => {
  throw new Error("@resvg/resvg-wasm is not in this function");
});

describe("the deployed entry, with the card libraries broken", () => {
  let server: Server;
  let base: string;

  beforeAll(async () => {
    // The entry's own fallback: no database, empty data. It must boot, which is the whole point.
    delete process.env.DATABASE_URL;
    const { default: handler } = await import("../api/index.js");
    server = createServer(handler as Parameters<typeof createServer>[1]);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });

  afterAll(() => new Promise<void>((resolve) => server.close(() => resolve())));

  it("still answers /v1/status", async () => {
    const res = await fetch(`${base}/v1/status`);
    expect(res.status).toBe(200);
    expect(await res.json()).toHaveProperty("ok");
  });

  it("still answers the share page (no such bill in an empty database: its 404 page)", async () => {
    const res = await fetch(`${base}/bill/119/hr/5267`);
    expect(res.status).toBe(404);
    expect(await res.text()).toContain("No such bill");
  });
});

describe("the share routes, with the card libraries broken", () => {
  const bill = {
    id: "119-hr-5267",
    congress: 119,
    type: "hr",
    number: 5267,
    citation: "H.R. 5267",
    title: "To amend the National Labor Relations Act to clarify the standard for determining joint employer status.",
    shortTitle: "American Franchise Act",
    label: "American Franchise Act",
    stage: "introduced",
    sponsor: null,
    introducedOn: "2025-09-10",
    originChamber: "house",
    policyArea: "Labor and Employment",
    summary: "This bill specifies the circumstances under which an employer is a joint employer.",
    summaryStage: "Introduced in House",
    latestAction: { on: "2026-11-10", text: "Placed on the Union Calendar, Calendar No. 412." },
    cboEstimates: [],
    actions: [{ actedOn: "2025-09-10", chamber: "house", text: "Introduced in House" }],
    votes: [],
  } satisfies Bill;

  const app = createApp({
    votes: { getVote: async () => null, recentVotes: async () => [], voteBreakdown: async () => ({ partyTotals: [], candidateTotals: [], positions: [], measure: null }) },
    members: {
      membersFor: async () => [],
      recentVotes: async () => [],
      getMember: async () => null,
      search: async () => [],
      partyLoyalty: async () => ({ votes: 0, withParty: 0, againstParty: 0 }),
      funding: async () => null,
      contact: async () => NO_CONTACT,
    },
    bills: { getBill: async (id) => (id === bill.id ? bill : null), getAnalysis: async () => null },
    nominations: { getNomination: async () => null },
    status: { lastRuns: async () => [] },
    live: { chambers: async () => [], liveVotes: async () => [] },
    locate: async () => null,
    schedule: EMPTY_SCHEDULE,
    now: () => new Date("2026-11-12T17:00:00Z"),
  });

  it("renders the page without them", async () => {
    const res = await app.request("/bill/119/hr/5267");
    expect(res.status).toBe(200);
    expect(await res.text()).toContain("American Franchise Act");
  });

  it("fails the card alone, uncached, and keeps failing it cleanly", async () => {
    const quiet = vi.spyOn(console, "error").mockImplementation(() => {});
    for (let i = 0; i < 2; i++) {
      const res = await app.request("/bill/119/hr/5267/card.png");
      expect(res.status).toBe(500);
      expect(res.headers.get("cache-control")).toBe("no-store");
    }
    quiet.mockRestore();
    expect((await app.request("/v1/status")).status).toBe(200);
  });
});
