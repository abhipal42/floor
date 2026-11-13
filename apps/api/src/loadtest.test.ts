import { describe, expect, it } from "vitest";
import { createApp } from "./app.js";
import {
  DEFAULT_IDS,
  assertSafeTarget,
  formatReport,
  parseArgs,
  percentile,
  pickRoute,
  runLoad,
  verdict,
  voteNightRoutes,
} from "./loadtest.js";

describe("load test safety", () => {
  it("never targets production, even when named", () => {
    expect(() => assertSafeTarget("https://floor-api.vercel.app")).toThrow(/production/);
    expect(() => assertSafeTarget("https://floor-api.vercel.app", ["floor-api.vercel.app"])).toThrow(/production/);
  });

  it("allows this machine, and another host only when named", () => {
    expect(assertSafeTarget("http://localhost:8787").port).toBe("8787");
    expect(assertSafeTarget("http://127.0.0.1:8787").hostname).toBe("127.0.0.1");
    expect(() => assertSafeTarget("https://floor-api-git-x.vercel.app")).toThrow(/only this machine/);
    expect(assertSafeTarget("https://floor-api-git-x.vercel.app", ["floor-api-git-x.vercel.app"]).hostname).toBe(
      "floor-api-git-x.vercel.app",
    );
  });
});

describe("load test mix", () => {
  const routes = voteNightRoutes(DEFAULT_IDS);

  it("covers every route the app calls on vote night, weighted toward the live view", () => {
    expect(routes.map((r) => r.path)).toEqual([
      "/v1/live",
      "/v1/votes/house-119-1-100?members=D000399,C001098,C001056",
      "/v1/members/D000399/votes?limit=20",
      "/v1/members/D000399",
      "/v1/bills/119-hconres-14",
      "/v1/status",
    ]);
    expect(pickRoute(routes, 0).name).toBe("live");
    expect(pickRoute(routes, 12 / 21 - 1e-9).name).toBe("live");
    expect(pickRoute(routes, 12 / 21).name).toBe("vote");
    expect(pickRoute(routes, 0.999999).name).toBe("status");
  });

  it("takes nearest-rank percentiles", () => {
    expect(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.95)).toBe(10);
    expect(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.5)).toBe(5);
    expect(percentile([], 0.5)).toBeNull();
  });

  it("parses flags, repeated ones included", () => {
    expect(parseArgs(["--duration", "5", "--allow-host", "a", "--allow-host", "b", "--flag"])).toEqual({
      duration: ["5"],
      "allow-host": ["a", "b"],
      flag: ["true"],
    });
  });
});

describe("runLoad", () => {
  // The real app with empty repositories: every route answers, so this exercises the router and schemas.
  const app = createApp({
    votes: {
      getVote: async () => null,
      voteBreakdown: async () => ({ partyTotals: [], candidateTotals: [], positions: [], measure: null }),
    },
    members: {
      membersFor: async () => [],
      recentVotes: async () => [],
      getMember: async () => null,
      partyLoyalty: async () => ({ votes: 0, withParty: 0, againstParty: 0 }),
      funding: async () => null,
    },
    bills: { getBill: async () => null, getAnalysis: async () => null },
    nominations: { getNomination: async () => null },
    status: { lastRuns: async () => [] },
    live: { chambers: async () => [], liveVotes: async () => [] },
    locate: async () => null,
  });

  it("drives every route concurrently and reports latency and status per route", async () => {
    const report = await runLoad({
      baseUrl: "http://localhost:8787",
      routes: voteNightRoutes(DEFAULT_IDS),
      durationMs: 150,
      connections: 4,
      fetch: (url) => Promise.resolve(app.request(url)),
    });
    expect(report.requests).toBeGreaterThan(20);
    expect(report.errors).toBe(0);
    const byName = Object.fromEntries(report.routes.map((r) => [r.name, r]));
    expect(byName["live"]!.statuses).toEqual({ 200: byName["live"]!.requests });
    expect(Object.keys(byName["vote"]!.statuses)).toEqual(["404"]); // empty repositories: no such vote
    expect(verdict(report, 10_000).ok).toBe(true);
    expect(formatReport(report)).toContain("overall p50");
  });

  it("counts 5xx, 429 and network failures as errors, and fails the verdict on them", async () => {
    let n = 0;
    const report = await runLoad({
      baseUrl: "http://localhost:8787",
      routes: [{ name: "live", path: "/v1/live", weight: 1 }],
      durationMs: 50,
      connections: 1,
      fetch: async () => {
        n++;
        if (n % 3 === 0) throw new Error("ECONNRESET");
        return new Response("", { status: n % 3 === 1 ? 500 : 429 });
      },
    });
    expect(report.errors).toBe(report.requests);
    expect(report.routes[0]!.statuses["network"]).toBeGreaterThan(0);
    expect(verdict(report, 10_000)).toMatchObject({ ok: false });
  });
});
