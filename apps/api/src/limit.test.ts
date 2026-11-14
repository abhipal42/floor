import { describe, expect, it } from "vitest";
import { createApp, MEMBER_SEARCH_RATE_LIMIT, REPS_RATE_LIMIT, VOTES_RATE_LIMIT, type AppDeps } from "./app.js";
import { MemoryLimitStore } from "./limit.js";

/** Repositories that answer nothing; these tests only exercise the middleware. */
const empty: Omit<AppDeps, "locate"> = {
  votes: {
    getVote: async () => null,
    recentVotes: async () => [],
    voteBreakdown: async () => ({ partyTotals: [], candidateTotals: [], positions: [], measure: null }),
  },
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

let geocodeCalls = 0;
function appWith(options: { origins?: string[]; now?: () => Date } = {}) {
  geocodeCalls = 0;
  return createApp({
    ...empty,
    allowedOrigins: options.origins,
    limitStore: new MemoryLimitStore(),
    now: options.now,
    locate: async () => {
      geocodeCalls++;
      return { congress: 119, state: "TX", stateFips: "48", district: 37, countyFips: "48453" };
    },
  });
}

const address = "address=1100%20Congress%20Ave,%20Austin,%20TX%2078701";
const from = (ip: string) => ({ headers: { "x-forwarded-for": ip } });

describe("rate limiting /v1/reps", () => {
  it("allows the quota and then refuses, without reaching the geocoder", async () => {
    const app = appWith();
    for (let i = 0; i < REPS_RATE_LIMIT.limit; i++) {
      const res = await app.request(`/v1/reps?${address}`, from("203.0.113.1"));
      expect(res.status).toBe(200);
    }
    expect(geocodeCalls).toBe(REPS_RATE_LIMIT.limit);

    const refused = await app.request(`/v1/reps?${address}`, from("203.0.113.1"));
    expect(refused.status).toBe(429);
    expect((await refused.json()).error).toMatch(/too many/i);
    // The whole point: a refused request must not cost us a call to the Census geocoder.
    expect(geocodeCalls).toBe(REPS_RATE_LIMIT.limit);
  });

  it("tells the caller where they stand", async () => {
    const app = appWith();
    const res = await app.request(`/v1/reps?${address}`, from("203.0.113.2"));
    expect(res.headers.get("RateLimit-Limit")).toBe(String(REPS_RATE_LIMIT.limit));
    expect(res.headers.get("RateLimit-Remaining")).toBe(String(REPS_RATE_LIMIT.limit - 1));
    expect(Number(res.headers.get("RateLimit-Reset"))).toBeGreaterThan(0);
  });

  it("gives a refused caller a Retry-After", async () => {
    const app = appWith();
    for (let i = 0; i <= REPS_RATE_LIMIT.limit; i++) {
      await app.request(`/v1/reps?${address}`, from("203.0.113.3"));
    }
    const refused = await app.request(`/v1/reps?${address}`, from("203.0.113.3"));
    expect(Number(refused.headers.get("Retry-After"))).toBeGreaterThan(0);
  });

  it("counts callers separately", async () => {
    const app = appWith();
    for (let i = 0; i <= REPS_RATE_LIMIT.limit; i++) {
      await app.request(`/v1/reps?${address}`, from("203.0.113.4"));
    }
    expect((await app.request(`/v1/reps?${address}`, from("203.0.113.4"))).status).toBe(429);
    // A different caller is unaffected by the first one's spending.
    expect((await app.request(`/v1/reps?${address}`, from("198.51.100.9"))).status).toBe(200);
  });

  it("takes the original client from the left of x-forwarded-for, not the proxy", async () => {
    const app = appWith();
    for (let i = 0; i <= REPS_RATE_LIMIT.limit; i++) {
      await app.request(`/v1/reps?${address}`, from("203.0.113.5, 10.0.0.1"));
    }
    // Same client, different proxy hop: still the same budget.
    const res = await app.request(`/v1/reps?${address}`, from("203.0.113.5, 10.0.0.2"));
    expect(res.status).toBe(429);
  });

  it("starts a fresh window once the old one has passed", async () => {
    let clock = new Date("2026-11-12T00:00:00Z");
    const app = appWith({ now: () => clock });
    for (let i = 0; i <= REPS_RATE_LIMIT.limit; i++) {
      await app.request(`/v1/reps?${address}`, from("203.0.113.6"));
    }
    expect((await app.request(`/v1/reps?${address}`, from("203.0.113.6"))).status).toBe(429);

    clock = new Date(clock.getTime() + REPS_RATE_LIMIT.windowMs + 1000);
    expect((await app.request(`/v1/reps?${address}`, from("203.0.113.6"))).status).toBe(200);
  });

  it("leaves the routes that only read our own database alone", async () => {
    const app = appWith();
    for (let i = 0; i < REPS_RATE_LIMIT.limit + 5; i++) {
      const res = await app.request("/v1/status", from("203.0.113.7"));
      expect(res.status).toBe(200);
    }
  });
});

describe("rate limiting /v1/members search", () => {
  it("allows a minute's quota, then refuses", async () => {
    const app = appWith();
    for (let i = 0; i < MEMBER_SEARCH_RATE_LIMIT.limit; i++) {
      expect((await app.request("/v1/members?q=ny", from("203.0.113.20"))).status).toBe(200);
    }
    const refused = await app.request("/v1/members?q=ny", from("203.0.113.20"));
    expect(refused.status).toBe(429);
    expect((await refused.json()).error).toBe("Too many requests. Please wait a moment and try again.");
  });

  it("counts searches apart from address lookups, though both share one store", async () => {
    const app = appWith();
    for (let i = 0; i < REPS_RATE_LIMIT.limit; i++) await app.request(`/v1/reps?${address}`, from("203.0.113.21"));
    expect((await app.request(`/v1/reps?${address}`, from("203.0.113.21"))).status).toBe(429);
    expect((await app.request("/v1/members?q=ny", from("203.0.113.21"))).status).toBe(200);
  });

  it("does not limit a member's own routes under the same prefix", async () => {
    const app = appWith();
    for (let i = 0; i < MEMBER_SEARCH_RATE_LIMIT.limit; i++) await app.request("/v1/members?q=ny", from("203.0.113.22"));
    expect((await app.request("/v1/members?q=ny", from("203.0.113.22"))).status).toBe(429);
    // 404 from the empty repository, not 429: /v1/members/{id} is not search.
    expect((await app.request("/v1/members/D000399", from("203.0.113.22"))).status).toBe(404);
  });
});

describe("rate limiting /v1/votes", () => {
  it("limits the list, not a vote by id", async () => {
    const app = appWith();
    for (let i = 0; i < VOTES_RATE_LIMIT.limit; i++) await app.request("/v1/votes", from("203.0.113.30"));
    expect((await app.request("/v1/votes", from("203.0.113.30"))).status).toBe(429);
    expect((await app.request("/v1/votes/house-119-1-100", from("203.0.113.30"))).status).toBe(404);
  });
});

describe("CORS", () => {
  it("lets a named browser origin read a response", async () => {
    const app = appWith({ origins: ["https://floor.app"] });
    const res = await app.request("/v1/status", { headers: { Origin: "https://floor.app" } });
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe("https://floor.app");
  });

  it("does not let an unnamed one", async () => {
    const app = appWith({ origins: ["https://floor.app"] });
    const res = await app.request("/v1/status", { headers: { Origin: "https://not-floor.example" } });
    expect(res.headers.get("Access-Control-Allow-Origin")).toBeNull();
    // The body is still served — CORS governs what a browser will hand to script, not what the
    // server will answer. A non-browser client was never restricted.
    expect(res.status).toBe(200);
  });

  it("allows none by default", async () => {
    const res = await appWith().request("/v1/status", { headers: { Origin: "https://floor.app" } });
    expect(res.headers.get("Access-Control-Allow-Origin")).toBeNull();
  });

  it("answers a preflight for a named origin", async () => {
    const app = appWith({ origins: ["https://floor.app"] });
    const res = await app.request("/v1/status", {
      method: "OPTIONS",
      headers: { Origin: "https://floor.app", "Access-Control-Request-Method": "GET" },
    });
    expect(res.status).toBeLessThan(300);
    expect(res.headers.get("Access-Control-Allow-Methods")).toContain("GET");
  });
});
