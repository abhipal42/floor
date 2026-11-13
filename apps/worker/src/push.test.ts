import { generateKeyPairSync, verify } from "node:crypto";
import { describe, expect, it } from "vitest";
import { createServer } from "node:http2";
import type { AddressInfo } from "node:net";
import { ApnsSender, apnsConfigFromEnv, apnsJwt, http2Transport, type ApnsRequest } from "./apns.js";
import { StatusAlerter, describeStatus } from "./alert.js";
import { ALL_VOTES_TOPIC, supabaseBroadcaster, type VoteStateChange } from "./realtime.js";

const change: VoteStateChange = {
  id: "house-119-2-319",
  chamber: "house",
  congress: 119,
  session: 2,
  rollNumber: 319,
  state: "open",
  question: "On agreeing to the resolution",
  result: "Agreed to",
  openedAt: "2026-11-10T23:20:53.000Z",
  announcedAt: "2026-11-10T23:33:00.000Z",
  postedAt: null,
};

describe("supabaseBroadcaster", () => {
  it("is a no-op without both env vars", async () => {
    const b = supabaseBroadcaster({ SUPABASE_URL: "https://x.supabase.co" }, async () => {
      throw new Error("must not be called");
    });
    expect(b.enabled).toBe(false);
    await b.publish([change]);
  });

  it("posts each change to the all-votes topic and the vote's own topic", async () => {
    const calls: { url: string; headers: Record<string, string>; body: string }[] = [];
    const b = supabaseBroadcaster(
      { SUPABASE_URL: "https://abc.supabase.co/", SUPABASE_SERVICE_ROLE_KEY: "service-key" },
      async (url, init) => {
        calls.push({ url, headers: init.headers, body: init.body });
        return { status: 202 };
      },
    );
    await b.publish([change]);
    await b.publish([]); // nothing to say: no request
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe("https://abc.supabase.co/realtime/v1/api/broadcast");
    expect(calls[0]!.headers).toMatchObject({ apikey: "service-key", authorization: "Bearer service-key" });
    expect(JSON.parse(calls[0]!.body)).toEqual({
      messages: [
        { topic: ALL_VOTES_TOPIC, event: "vote_state", payload: change },
        { topic: "vote:house-119-2-319", event: "vote_state", payload: change },
      ],
    });
  });

  it("raises on a non-2xx without echoing the key", async () => {
    const b = supabaseBroadcaster(
      { SUPABASE_URL: "https://abc.supabase.co", SUPABASE_SERVICE_ROLE_KEY: "service-key" },
      async () => ({ status: 401 }),
    );
    await expect(b.publish([change])).rejects.toThrow(/^Realtime broadcast returned HTTP 401$/);
  });

  it("gives up on a broadcast that hangs instead of holding the poll", async () => {
    const b = supabaseBroadcaster(
      { SUPABASE_URL: "https://abc.supabase.co", SUPABASE_SERVICE_ROLE_KEY: "service-key" },
      // A server that never answers: only the abort signal can end this request.
      (_url, init) =>
        new Promise((_resolve, reject) => {
          if (!init.signal) return; // no timeout passed: hang, and the test times out
          init.signal.addEventListener("abort", () => reject(init.signal!.reason as Error));
        }),
      25,
    );
    await expect(b.publish([change])).rejects.toThrow(/timeout|aborted/i);
  });
});

describe("APNs", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const pem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
  const env = { APNS_KEY_ID: "ABC123DEFG", APNS_TEAM_ID: "TEAM123456", APNS_PRIVATE_KEY: pem, APNS_TOPIC: "app.floor.ios" };
  const token = "a".repeat(64);

  it("is unconfigured, and sends nothing, unless every variable is set", async () => {
    expect(apnsConfigFromEnv({ ...env, APNS_TEAM_ID: "" })).toBeNull();
    const sender = new ApnsSender(null, { send: async () => { throw new Error("must not be called"); } });
    expect(sender.enabled).toBe(false);
    expect(await sender.send({ deviceToken: token, pushType: "alert", payload: {} })).toEqual({ ok: false, skipped: true });
  });

  it("accepts a key pasted with \\n escapes, as env files and dashboards store it", () => {
    expect(apnsConfigFromEnv({ ...env, APNS_PRIVATE_KEY: pem.replace(/\n/g, "\\n") })).not.toBeNull();
  });

  it("signs an ES256 provider token Apple can verify with the key's public half", () => {
    const cfg = apnsConfigFromEnv(env)!;
    const jwt = apnsJwt(cfg, 1_800_000_000);
    const [h, c, s] = jwt.split(".");
    expect(JSON.parse(Buffer.from(h!, "base64url").toString())).toEqual({ alg: "ES256", kid: "ABC123DEFG" });
    expect(JSON.parse(Buffer.from(c!, "base64url").toString())).toEqual({ iss: "TEAM123456", iat: 1_800_000_000 });
    const sig = Buffer.from(s!, "base64url");
    expect(sig).toHaveLength(64); // raw r||s, as JOSE requires, not DER
    expect(
      verify("sha256", Buffer.from(`${h}.${c}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, sig),
    ).toBe(true);
  });

  it("addresses the device, topic and push type, and reuses the token for 50 minutes", async () => {
    const sent: ApnsRequest[] = [];
    let now = 1_800_000_000;
    const sender = new ApnsSender(
      apnsConfigFromEnv(env),
      { send: async (req) => (sent.push(req), { status: 200, body: "" }) },
      () => now,
    );
    expect(await sender.send({ deviceToken: token, pushType: "alert", payload: { aps: {} }, collapseId: "house-119-2-319" })).toEqual({
      ok: true,
      status: 200,
    });
    await sender.send({ deviceToken: token, pushType: "liveactivity", payload: { aps: {} } });
    now += 50 * 60;
    await sender.send({ deviceToken: token, pushType: "background", payload: { aps: { "content-available": 1 } } });

    expect(sent[0]).toMatchObject({
      origin: "https://api.sandbox.push.apple.com",
      headers: {
        ":method": "POST",
        ":path": `/3/device/${token}`,
        "apns-topic": "app.floor.ios",
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-collapse-id": "house-119-2-319",
      },
      body: '{"aps":{}}',
    });
    expect(sent[1]!.headers["apns-topic"]).toBe("app.floor.ios.push-type.liveactivity");
    expect(sent[2]!.headers["apns-priority"]).toBe("5");
    expect(sent[0]!.headers.authorization).toBe(sent[1]!.headers.authorization);
    expect(sent[2]!.headers.authorization).not.toBe(sent[0]!.headers.authorization);
  });

  it("uses production when told to, flags dead tokens, and refuses a malformed one", async () => {
    const sent: ApnsRequest[] = [];
    const sender = new ApnsSender(apnsConfigFromEnv({ ...env, APNS_ENV: "production" }), {
      send: async (req) => (sent.push(req), { status: 410, body: '{"reason":"Unregistered"}' }),
    });
    expect(await sender.send({ deviceToken: token, pushType: "alert", payload: {} })).toEqual({
      ok: false,
      status: 410,
      reason: "Unregistered",
      unregistered: true,
    });
    expect(sent[0]!.origin).toBe("https://api.push.apple.com");
    expect(await sender.send({ deviceToken: "not-a-token", pushType: "alert", payload: {} })).toEqual({
      ok: false,
      reason: "BadDeviceToken",
    });
  });
});

describe("http2Transport", () => {
  it("cancels a push whose stream never answers", async () => {
    const server = createServer();
    server.on("stream", () => {}); // accepts the request and never responds
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    const { port } = server.address() as AddressInfo;
    const transport = http2Transport(50);
    try {
      const started = Date.now();
      await expect(
        transport.send({ origin: `http://127.0.0.1:${port}`, headers: { ":method": "POST", ":path": "/3/device/x" }, body: "{}" }),
      ).rejects.toThrow(/timed out after 50 ms/);
      expect(Date.now() - started).toBeLessThan(5_000);
    } finally {
      transport.close?.();
      await new Promise((r) => server.close(r));
    }
  });
});

describe("StatusAlerter", () => {
  const healthy = { ok: true, sources: [] };
  const broken = {
    ok: false,
    sources: [
      { source: "members", stale: false, lastSuccessAt: "2026-11-13T02:08:59.684Z", lastError: null },
      // The real /v1/status answer on 2026-11-13.
      { source: "senate_rollcalls", stale: true, lastSuccessAt: "2026-11-12T04:28:40.578Z", lastError: "deadlock detected" },
    ],
  };

  function harness(statuses: (object | number | Error)[]) {
    let t = 0;
    const posts: string[] = [];
    let i = 0;
    const alerter = new StatusAlerter({
      webhookUrl: "https://hooks.example.test/T000/B000/secret",
      now: () => t,
      fetch: async (url, init) => {
        if (init?.method === "POST") {
          posts.push((JSON.parse(init.body!) as { text: string }).text);
          return { status: 200, json: async () => ({}) };
        }
        const s = statuses[Math.min(i++, statuses.length - 1)]!;
        if (s instanceof Error) throw s;
        if (typeof s === "number") return { status: s, json: async () => ({}) };
        return { status: 200, json: async () => s };
      },
    });
    return { alerter, posts, advance: (ms: number) => (t += ms) };
  }

  it("does nothing outside a session", async () => {
    const h = harness([broken]);
    expect(await h.alerter.check(false)).toBe("skipped");
    expect(h.posts).toEqual([]);
  });

  /** Checks once a minute, `n` times, and returns each outcome. */
  async function checks(h: ReturnType<typeof harness>, n: number): Promise<string[]> {
    const out: string[] = [];
    for (let k = 0; k < n; k++) {
      out.push(await h.alerter.check(true));
      h.advance(60_000);
    }
    return out;
  }

  it("pages only after three failed checks in a row, repeats every 30 minutes, and recovers after three good ones", async () => {
    const h = harness([broken, broken, broken, ...Array<object>(30).fill(broken), healthy]);
    expect(await checks(h, 3)).toEqual(["failing", "failing", "alerted"]);
    expect(h.posts).toEqual([
      "Floor is unhealthy during a session: senate_rollcalls stale (last success 2026-11-12T04:28:40.578Z; last error: deadlock detected)",
    ]);
    h.advance(-30_000);
    expect(await h.alerter.check(true)).toBe("skipped"); // checks at most once a minute
    h.advance(30_000);
    // 30 more failing minutes: one repeat, on the 30th minute after the first post.
    const more = await checks(h, 30);
    expect(more.filter((o) => o === "alerted")).toHaveLength(1);
    expect(more.at(-1)).toBe("alerted");
    expect(h.posts).toHaveLength(2);
    // Healthy again: not recovered until three good checks AND 30 minutes after the last post.
    const healing = await checks(h, 30);
    expect(healing.slice(0, 3)).toEqual(["still-failing", "still-failing", "still-failing"]);
    expect(healing.at(-1)).toBe("recovered");
    expect(healing.filter((o) => o === "recovered")).toHaveLength(1);
    expect(h.posts).toHaveLength(3);
    expect(h.posts[2]).toMatch(/^Floor recovered: \/v1\/status is ok again \(it was failing for about 62 min\)\.$/);
  });

  it("does not page for a status that flaps between good and bad", async () => {
    const h = harness([broken, broken, healthy, broken, broken, healthy, broken, healthy, broken, broken, healthy]);
    expect(await checks(h, 11)).not.toContain("alerted");
    expect(h.posts).toEqual([]);
  });

  it("does not call a single good check between failures a recovery", async () => {
    const h = harness([broken, broken, broken, healthy, broken, ...Array<object>(40).fill(healthy)]);
    expect(await checks(h, 3)).toEqual(["failing", "failing", "alerted"]);
    expect(await checks(h, 2)).toEqual(["still-failing", "still-failing"]);
    const rest = await checks(h, 40);
    expect(rest.filter((o) => o === "recovered")).toHaveLength(1);
    expect(h.posts).toHaveLength(2);
  });

  it("pages when the status route itself is down", async () => {
    const h = harness([500]);
    expect(await checks(h, 3)).toEqual(["failing", "failing", "alerted"]);
    expect(h.posts[0]).toBe("Floor is unhealthy during a session: /v1/status answered HTTP 500");
    const unreachable = harness([new Error("fetch failed")]);
    await checks(unreachable, 3);
    expect(unreachable.posts[0]).toContain("could not be reached: fetch failed");
  });

  it("checks but posts nothing without a webhook", async () => {
    const logs: string[] = [];
    let t = 0;
    const a = new StatusAlerter({
      fetch: async () => ({ status: 200, json: async () => broken }),
      log: (m) => logs.push(m),
      now: () => (t += 60_000),
    });
    expect(a.enabled).toBe(false);
    expect([await a.check(true), await a.check(true), await a.check(true)]).toEqual(["failing", "failing", "alerted"]);
    expect(logs).toHaveLength(1);
    expect(describeStatus({ ok: false })).toBe("ok: false with no stale source listed");
  });
});
