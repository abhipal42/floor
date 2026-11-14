import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { beforeEach, describe, expect, it } from "vitest";
import type { ApnsMessage, ApnsResult } from "./apns.js";
import type { Db } from "./db.js";
import {
  ACTIVITY_LINGER_S,
  DIGEST_AFTER,
  PushBroadcaster,
  activityAttributes,
  activityContent,
  composeBroadcasters,
  digestAlert,
  fitPayload,
  alertPayload,
  startPayload,
  truncate,
  pruneDevices,
  PAYLOAD_MAX,
  TITLE_MAX,
  finalBillAlert,
  finalMembersAlert,
  joinNames,
  loadVote,
  openedAlert,
  outcomeClause,
  type PushVote,
} from "./push.js";
import type { Broadcaster, VoteStateChange } from "./realtime.js";

const here = dirname(fileURLToPath(import.meta.url));
/** The cross-language contract: the Swift `VoteActivityAttributes` decodes these same files. */
const fixture = (name: string) =>
  JSON.parse(readFileSync(join(here, `../../../ios/FloorKit/Tests/ModelsTests/Fixtures/${name}`), "utf8")) as unknown;

// Real: House roll call 321 of the 119th Congress, 2nd session — H.R. 1013 passed 295–128 with 10
// not voting at 2:43 PM Eastern on Nov 11, 2026; Doggett (TX-37) and Jeffries voted nay, Hageman yea.
const NOW = new Date("2026-11-11T19:52:00Z");
const hex = (c: string) => c.repeat(64);

async function freshDb(): Promise<PGlite> {
  const pg = new PGlite();
  await pg.exec(`
    create schema auth;
    create table auth.users (id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
  `);
  for (const m of loadMigrations()) await pg.exec(m.sql);
  await pg.exec(`
    insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end) values
      ('D000399', 'Lloyd', 'Doggett', 'D', 'TX', 37, 'house', '2025-01-03', '2027-01-03'),
      ('J000294', 'Hakeem', 'Jeffries', 'D', 'NY', 8, 'house', '2025-01-03', '2027-01-03'),
      ('H001096', 'Harriet', 'Hageman', 'R', 'WY', 0, 'house', '2025-01-03', '2027-01-03'),
      ('C001056', 'John', 'Cornyn', 'R', 'TX', null, 'senate', '2021-01-03', '2027-01-03'),
      ('C001098', 'Ted', 'Cruz', 'R', 'TX', null, 'senate', '2025-01-03', '2031-01-03');
    insert into bills (id, congress, bill_type, number, title, short_title)
      values ('119-hr-1013', 119, 'hr', 1013,
              'To amend the Internal Revenue Code of 1986 to allow 403(b) plans to invest in collective investment trusts.',
              'Retirement Fairness for Charities and Educational Institutions Act of 2025');
    -- As the live worker stores it from the House floor summary: open, not linked to its bill yet.
    insert into votes (id, chamber, congress, session, roll_number, question, state, bill_ref, opened_at, occurred_at, announced_at)
      values ('house-119-2-321', 'house', 119, 2, 321, 'On Passage', 'open', 'H R 1013',
              '2026-11-11T19:43:00Z', '2026-11-11T19:43:00Z', '2026-11-11T19:43:30Z');
  `);
  return pg;
}

/** The roll call XML lands: final, with positions. */
async function finalize(pg: PGlite) {
  await pg.exec(`
    update votes set state = 'final', yea = 295, nay = 128, not_voting = 10, result = 'Passed' where id = 'house-119-2-321';
    insert into vote_positions (vote_id, member_id, position) values
      ('house-119-2-321', 'D000399', 'nay'), ('house-119-2-321', 'J000294', 'nay'), ('house-119-2-321', 'H001096', 'yea');
  `);
}

interface Phone {
  name: string;
  apns?: string | null;
  start?: string | null;
  env?: "sandbox" | "production";
  voteOpened?: boolean;
  liveActivities?: boolean;
  subs: [kind: "member" | "bill", id: string, howVoted: boolean][];
}

/** Registers phones as `PUT /v1/devices` would; returns name → device id. */
async function register(pg: PGlite, phones: Phone[]): Promise<Record<string, string>> {
  const ids: Record<string, string> = {};
  for (const [i, p] of phones.entries()) {
    const { rows } = await pg.query<{ id: string }>(
      `insert into devices (key_hash, apns_token, push_to_start_token, apns_env, vote_opened, live_activities)
       values ($1, $2, $3, $4, $5, $6) returning id`,
      [hex(i.toString(16)), p.apns === undefined ? hex("abcdef0123456789"[i]!) : p.apns, p.start ?? null, p.env ?? "production", p.voteOpened ?? false, p.liveActivities ?? true],
    );
    ids[p.name] = rows[0]!.id;
    for (const [kind, id, howVoted] of p.subs) {
      await pg.query("insert into device_subscriptions values ($1, $2, $3, $4)", [rows[0]!.id, kind, id, howVoted]);
    }
  }
  return ids;
}

class StubApns {
  enabled = true;
  sent: ApnsMessage[] = [];
  reply: (msg: ApnsMessage) => ApnsResult = () => ({ ok: true, status: 200 });
  async send(msg: ApnsMessage): Promise<ApnsResult> {
    this.sent.push(msg);
    return this.reply(msg);
  }
}

const change = (state: "open" | "final", id = "house-119-2-321"): VoteStateChange => ({
  id,
  chamber: id.startsWith("senate") ? "senate" : "house",
  congress: 119,
  session: 2,
  rollNumber: Number(id.split("-").at(-1)),
  state,
  question: "On Passage",
  result: null,
  openedAt: null,
  announcedAt: null,
  postedAt: null,
});

type Aps = { aps: Record<string, unknown>; link?: string };
const aps = (m: ApnsMessage) => m.payload as Aps;
const alertOf = (m: ApnsMessage) => aps(m).aps.alert as { title: string; body?: string };

let pg: PGlite;
let db: Db;
let apns: StubApns;
let push: PushBroadcaster;
const logs: string[] = [];
let clock = NOW;
/** Publishes and waits for the queue: `publish` itself returns before anything is sent. */
const send = async (changes: VoteStateChange[]) => {
  await push.publish(changes);
  await push.idle();
};

beforeEach(async () => {
  pg = await freshDb();
  db = pg as unknown as Db;
  apns = new StubApns();
  logs.length = 0;
  clock = NOW;
  push = new PushBroadcaster({ db, apns, environment: "production", now: () => clock, log: (m) => logs.push(m) });
});

describe("a vote opens", () => {
  it("alerts phones with \"A vote opened\" on whose members sit in that chamber or who follow the bill, in the mock's words", async () => {
    const ids = await register(pg, [
      { name: "doggett", voteOpened: true, subs: [["member", "D000399", true]] },
      { name: "off", voteOpened: false, subs: [["member", "D000399", true]] },
      { name: "bill", voteOpened: true, subs: [["bill", "119-hr-1013", false]] },
      { name: "senators", voteOpened: true, subs: [["member", "C001056", true]] },
      { name: "sandbox", voteOpened: true, env: "sandbox", subs: [["member", "D000399", true]] },
      { name: "silent", voteOpened: true, apns: null, subs: [["member", "D000399", true]] },
    ]);
    await send([change("open")]);
    expect(apns.sent.map((m) => m.deviceToken).sort()).toEqual([hex("a"), hex("c")]);
    const m = apns.sent[0]!;
    expect(m.pushType).toBe("alert");
    expect(alertOf(m)).toEqual({
      title: "A House vote opened: H.R. 1013, On Passage.",
      body: "Retirement Fairness for Charities and Educational Institutions Act of 2025.",
    });
    expect(aps(m)).toMatchObject({ aps: { sound: "default", "thread-id": "floor" }, link: "floor://vote/house-119-2-321" });
    expect(m.collapseId).toBe("opened-house-119-2-321");
    expect(m.expiration).toBe(Math.floor(NOW.getTime() / 1000) + 3600);
    expect(Object.keys(ids)).toHaveLength(6);
  });

  it("starts a Live Activity by push instead where the phone gave a push-to-start token: one buzz, not two", async () => {
    await register(pg, [{ name: "la", voteOpened: true, start: hex("e"), subs: [["member", "D000399", true], ["member", "J000294", false]] }]);
    await send([change("open")]);
    expect(apns.sent).toHaveLength(1);
    const m = apns.sent[0]!;
    expect(m).toMatchObject({ deviceToken: hex("e"), pushType: "liveactivity", priority: 10 });
    const nowS = Math.floor(NOW.getTime() / 1000);
    expect(aps(m).aps).toEqual({
      timestamp: nowS,
      event: "start",
      "attributes-type": "VoteActivityAttributes",
      attributes: fixture("live-activity-attributes-hr1013.json"),
      "content-state": {
        ...(fixture("live-activity-open-hr1013.json") as object),
        members: [
          { id: "D000399", name: "Doggett", position: null, choice: null },
          { id: "J000294", name: "Jeffries", position: null, choice: null },
        ],
      },
      "stale-date": nowS + 7200,
      alert: {
        title: "A House vote opened: H.R. 1013, On Passage.",
        body: "Retirement Fairness for Charities and Educational Institutions Act of 2025.",
        sound: "default",
      },
      "input-push-token": 1,
    });
  });

  it("starts a Live Activity silently for a phone with \"A vote opened\" off (activities are on by default)", async () => {
    await register(pg, [
      { name: "silent", start: hex("e"), subs: [["member", "D000399", false]] },
      { name: "noActivities", liveActivities: false, start: hex("d"), subs: [["member", "D000399", true]] },
    ]);
    await send([change("open")]);
    expect(apns.sent).toHaveLength(1);
    expect(apns.sent[0]).toMatchObject({ deviceToken: hex("e"), pushType: "liveactivity", priority: 5 });
    expect((aps(apns.sent[0]!).aps.alert as { sound?: string }).sound).toBeUndefined();
  });

  it("sends the opened alert, not an activity, where Live Activities are off", async () => {
    await register(pg, [{ name: "a", voteOpened: true, liveActivities: false, start: hex("e"), subs: [["member", "D000399", true]] }]);
    await send([change("open")]);
    expect(apns.sent.map((m) => [m.deviceToken, m.pushType])).toEqual([[hex("a"), "alert"]]);
  });

  it("sends a plain alert, not a second activity, to a phone already running one for the vote", async () => {
    const ids = await register(pg, [{ name: "la", voteOpened: true, start: hex("e"), subs: [["member", "D000399", true]] }]);
    await pg.query("insert into live_activity_tokens (device_id, vote_id, token) values ($1, 'house-119-2-321', $2)", [ids.la, hex("f")]);
    await send([change("open")]);
    expect(apns.sent.map((m) => [m.deviceToken, m.pushType])).toEqual([[hex("a"), "alert"]]);
  });

  it("sends each phone one opened alert however often the vote is published, and stops stacking after three a day", async () => {
    await register(pg, [{ name: "a", voteOpened: true, subs: [["member", "D000399", true]] }]);
    await send([change("open")]);
    await send([change("open")]);
    expect(apns.sent).toHaveLength(1);
    for (const roll of [322, 323, 324]) {
      await pg.query(
        `insert into votes (id, chamber, congress, session, roll_number, question, state, announced_at) values ($1, 'house', 119, 2, $2, 'On Motion to Adjourn', 'open', now())`,
        [`house-119-2-${roll}`, roll],
      );
      await send([change("open", `house-119-2-${roll}`)]);
    }
    expect(apns.sent.map((m) => m.collapseId)).toEqual([
      "opened-house-119-2-321",
      "opened-house-119-2-322",
      "opened-house-119-2-323",
      "opened-2026-11-11",
    ]);
    expect(alertOf(apns.sent[1]!)).toEqual({ title: "A House vote opened: On Motion to Adjourn." });
  });
});

describe("a vote is final", () => {
  it("tells each phone how its alerting members voted, in the mock's words, and nothing for a switch that is off", async () => {
    await register(pg, [
      { name: "doggett", subs: [["member", "D000399", true]] },
      { name: "off", subs: [["member", "D000399", false]] },
      { name: "two", subs: [["member", "D000399", true], ["member", "J000294", true]] },
      { name: "split", subs: [["member", "D000399", true], ["member", "H001096", true]] },
      { name: "bill", subs: [["bill", "119-hr-1013", true]] },
      { name: "billOff", subs: [["bill", "119-hr-1013", false]] },
      { name: "senate", subs: [["member", "C001056", true]] },
    ]);
    await finalize(pg);
    await send([change("final")]);
    const byToken = Object.fromEntries(apns.sent.map((m) => [m.deviceToken, alertOf(m)]));
    expect(byToken).toEqual({
      [hex("a")]: { title: "Doggett voted nay on H.R. 1013.", body: "It passed the House 295–128." },
      [hex("c")]: { title: "Doggett and Jeffries voted nay on H.R. 1013.", body: "It passed the House 295–128." },
      [hex("d")]: { title: "Your members split on H.R. 1013.", body: "Doggett nay, Hageman yea. It passed the House 295–128." },
      [hex("e")]: { title: "A vote on H.R. 1013, which you follow.", body: "On Passage: it passed the House 295–128." },
    });
    expect(apns.sent.every((m) => m.collapseId === "final-house-119-2-321" && m.pushType === "alert")).toBe(true);
  });

  it("is retried safely: a vote published twice (a failed Realtime broadcast) alerts once", async () => {
    await register(pg, [{ name: "a", subs: [["member", "D000399", true]] }]);
    await finalize(pg);
    await send([change("final")]);
    await send([change("final")]);
    expect(apns.sent).toHaveLength(1);
  });

  it("shows the final on every Live Activity registered for the vote, which ends itself 15 minutes later", async () => {
    const ids = await register(pg, [{ name: "a", apns: null, subs: [["member", "D000399", false]] }]);
    await pg.query("insert into live_activity_tokens (device_id, vote_id, token) values ($1, 'house-119-2-321', $2)", [ids.a, hex("f")]);
    await finalize(pg);
    await send([change("final")]);
    expect(apns.sent).toHaveLength(1);
    const nowS = Math.floor(NOW.getTime() / 1000);
    expect(apns.sent[0]).toMatchObject({ deviceToken: hex("f"), pushType: "liveactivity" });
    expect(aps(apns.sent[0]!).aps).toEqual({
      timestamp: nowS,
      event: "end",
      "content-state": fixture("live-activity-final-hr1013.json"),
      "dismissal-date": nowS + ACTIVITY_LINGER_S,
    });
  });

  it("clears a token Apple says is gone (410) and deletes a dead activity token", async () => {
    const ids = await register(pg, [{ name: "a", subs: [["member", "D000399", true]] }]);
    await pg.query("insert into live_activity_tokens (device_id, vote_id, token) values ($1, 'house-119-2-321', $2)", [ids.a, hex("f")]);
    apns.reply = () => ({ ok: false, status: 410, reason: "Unregistered", unregistered: true });
    await finalize(pg);
    await send([change("final")]);
    const { rows } = await pg.query<{ apns_token: string | null; activities: number }>(
      "select apns_token, (select count(*)::int from live_activity_tokens) as activities from devices",
    );
    expect(rows).toEqual([{ apns_token: null, activities: 0 }]);
    expect(logs).toEqual(["push house-119-2-321 final: 0 sent, 0 failed, 2 tokens gone"]);
  });

  it("clears a token APNs calls bad, for another app, or for the other gateway (400s), as for a 410", async () => {
    for (const reason of ["BadDeviceToken", "DeviceTokenNotForTopic", "BadEnvironmentKeyInToken"]) {
      await pg.exec("delete from push_log; delete from device_subscriptions; delete from devices");
      await register(pg, [{ name: "a", subs: [["member", "D000399", true]] }]);
      apns.reply = () => ({ ok: false, status: 400, reason });
      await finalize(pg).catch(() => undefined);
      await send([change("final")]);
      const { rows } = await pg.query<{ apns_token: string | null }>("select apns_token from devices");
      expect(rows, reason).toEqual([{ apns_token: null }]);
    }
  });

  it("deletes an activity's token once its end is delivered", async () => {
    const ids = await register(pg, [{ name: "a", apns: null, subs: [["member", "D000399", false]] }]);
    await pg.query("insert into live_activity_tokens (device_id, vote_id, token) values ($1, 'house-119-2-321', $2)", [ids.a, hex("f")]);
    await finalize(pg);
    await send([change("final")]);
    expect((await pg.query("select 1 from live_activity_tokens")).rows).toEqual([]);
  });

  it("puts a final published over an hour late into the digest only", async () => {
    await register(pg, [{ name: "a", subs: [["member", "D000399", true]] }]);
    await finalize(pg);
    clock = new Date(Date.parse("2026-11-11T19:43:00Z") + 2 * 3_600_000);
    await send([change("final")]);
    expect(apns.sent[0]!.collapseId).toBe("digest-2026-11-11");
    expect(alertOf(apns.sent[0]!)).toEqual({ title: "Your members cast 1 vote today.", body: "Doggett 1. Tap to catch up." });
  });

  it("logs, and does not throw, when APNs refuses for another reason", async () => {
    await register(pg, [{ name: "a", subs: [["member", "D000399", true]] }]);
    apns.reply = () => ({ ok: false, status: 429, reason: "TooManyRequests" });
    await finalize(pg);
    await expect(push.publish([change("final")])).resolves.toBeUndefined();
    await push.idle();
    expect(logs[0]).toBe("push house-119-2-321: APNs refused (429 TooManyRequests)");
  });

  it("collapses a busy night into one digest: from the fourth final of the day, in the mock's words", async () => {
    await register(pg, [{ name: "a", subs: [["member", "D000399", true], ["member", "C001056", true], ["member", "C001098", true]] }]);
    await finalize(pg);
    await send([change("final")]);
    // Synthetic: a second House vote and two Senate votes later the same evening.
    await pg.exec(`
      insert into votes (id, chamber, congress, session, roll_number, question, state, yea, nay, result, occurred_at) values
        ('house-119-2-322', 'house', 119, 2, 322, 'On Motion to Adjourn', 'final', 220, 200, 'Agreed to', '2026-11-11T20:10:00Z'),
        ('senate-119-2-300', 'senate', 119, 2, 300, 'On the Motion to Proceed', 'final', 62, 21, 'Motion to Proceed Agreed to', '2026-11-11T21:00:00Z'),
        ('senate-119-2-301', 'senate', 119, 2, 301, 'On the Cloture Motion', 'final', 52, 47, 'Cloture Motion Rejected', '2026-11-11T22:00:00Z');
      insert into vote_positions (vote_id, member_id, position) values
        ('house-119-2-322', 'D000399', 'yea'),
        ('senate-119-2-300', 'C001056', 'not_voting'), ('senate-119-2-300', 'C001098', 'yea'),
        ('senate-119-2-301', 'C001056', 'yea'), ('senate-119-2-301', 'C001098', 'yea');
    `);
    for (const [i, id] of ["house-119-2-322", "senate-119-2-300", "senate-119-2-301"].entries()) {
      clock = new Date(NOW.getTime() + (i + 1) * 3_600_000);
      await send([change("final", id)]);
    }
    expect(apns.sent).toHaveLength(DIGEST_AFTER + 1);
    expect(alertOf(apns.sent[1]!)).toEqual({
      title: "Doggett voted yea on a procedural vote.",
      body: "On Motion to Adjourn: it was agreed to in the House 220–200.",
    });
    expect(alertOf(apns.sent[2]!)).toEqual({
      title: "Your members split on a procedural vote.",
      body: "Cornyn did not vote, Cruz yea. On the Motion to Proceed: it was agreed to in the Senate 62–21.",
    });
    const digest = apns.sent[3]!;
    expect(digest.collapseId).toBe("digest-2026-11-11");
    expect(aps(digest).link).toBe("floor://open");
    // Cornyn did not vote on one, so he cast one: "cast" counts yea, nay and present.
    expect(alertOf(digest)).toEqual({
      title: "Your members cast 5 votes today.",
      body: "Doggett 2 · Cruz 2 · Cornyn 1 · Cornyn missed 1. Tap to catch up.",
    });
  });

  it("counts absences toward the digest, and not as votes on a followed bill", async () => {
    await register(pg, [{ name: "a", subs: [["member", "D000399", true]] }]);
    await finalize(pg);
    await send([change("final")]);
    for (const [i, roll] of [322, 323, 324].entries()) {
      await pg.query(
        `insert into votes (id, chamber, congress, session, roll_number, question, state, yea, nay, result)
         values ($1, 'house', 119, 2, $2, 'On Motion to Adjourn', 'final', 220, 200, 'Agreed to')`,
        [`house-119-2-${roll}`, roll],
      );
      await pg.query("insert into vote_positions values ($1, 'D000399', 'not_voting')", [`house-119-2-${roll}`]);
      clock = new Date(NOW.getTime() + (i + 1) * 3_600_000);
      await send([change("final", `house-119-2-${roll}`)]);
    }
    // Absences alert (they are facts) and count toward the digest, never as "votes on bills you follow".
    expect(alertOf(apns.sent[1]!).title).toBe("Doggett did not vote on a procedural vote.");
    expect(alertOf(apns.sent[3]!)).toEqual({ title: "Your members cast 1 vote today.", body: "Doggett 1 · Doggett missed 3. Tap to catch up." });
  });
});

describe("without APNs configured", () => {
  it("reads nothing and sends nothing", async () => {
    const off = new PushBroadcaster({
      db: { query: async () => Promise.reject(new Error("must not query")) },
      apns: { enabled: false, send: async () => Promise.reject(new Error("must not send")) },
      environment: "production",
    });
    expect(off.enabled).toBe(false);
    await off.publish([change("final")]);
  });

  it("composes with Realtime: Realtime first, pushes in a finally, a disabled one skipped", async () => {
    const order: string[] = [];
    const b = (name: string, enabled: boolean, fails = false): Broadcaster => ({
      enabled,
      publish: async () => {
        order.push(name);
        if (fails) throw new Error("Realtime broadcast returned HTTP 500");
      },
    });
    const both = composeBroadcasters(b("realtime", true), b("push", true));
    expect(both.enabled).toBe(true);
    await both.publish([change("open")]);
    expect(order).toEqual(["realtime", "push"]);
    order.length = 0;
    await expect(composeBroadcasters(b("realtime", true, true), b("push", true)).publish([change("open")])).rejects.toThrow(/500/);
    expect(order).toEqual(["realtime", "push"]);
    expect(composeBroadcasters(b("a", false), b("b", false)).enabled).toBe(false);
  });

  it("returns from publish before APNs answers: a slow gateway never holds up the live loop", async () => {
    await register(pg, [{ name: "a", subs: [["member", "D000399", true]] }]);
    await finalize(pg);
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    apns.reply = () => ({ ok: true, status: 200 });
    const slow = { enabled: true, send: async (m: ApnsMessage) => (await gate, apns.send(m)) };
    const queued = new PushBroadcaster({ db, apns: slow, environment: "production", now: () => NOW });
    await queued.publish([change("final")]);
    expect(apns.sent).toHaveLength(0);
    release();
    await queued.idle();
    expect(apns.sent).toHaveLength(1);
  });
});

describe("the copy", () => {
  const vote = (over: Partial<PushVote>): PushVote => ({
    id: "senate-119-2-300",
    chamber: "senate",
    kind: "question",
    rollNumber: 300,
    question: "On the Cloture Motion",
    result: null,
    threshold: "three_fifths_sworn",
    state: "final",
    totals: { yea: 52, nay: 47, present: 0, notVoting: 1 },
    candidates: [],
    openedAt: null,
    announcedAt: null,
    occurredAt: null,
    billId: "119-hr-2347",
    citation: "H.R. 2347",
    title: null,
    ...over,
  });

  it("reads the chamber's own result first, then the threshold", () => {
    expect(outcomeClause(vote({ result: "Cloture Motion Rejected" }))).toBe("was rejected in the Senate 52–47");
    expect(outcomeClause(vote({ result: "Cloture on the Motion to Proceed Not Agreed to" }))).toBe("was rejected in the Senate 52–47");
    expect(outcomeClause(vote({ result: "Cloture Motion Agreed to", totals: { yea: 62, nay: 21, present: 0, notVoting: 17 } }))).toBe(
      "was agreed to in the Senate 62–21",
    );
    expect(outcomeClause(vote({ result: "Nomination Confirmed" }))).toBe("confirmed the nomination 52–47");
    expect(outcomeClause(vote({ result: "Failed" }))).toBe("failed in the Senate 52–47");
    expect(outcomeClause(vote({ result: "Veto Overridden" }))).toBe("overrode the veto 52–47");
    expect(outcomeClause(vote({ result: "Cloture Invoked" }))).toBe("carried in the Senate 52–47");
    // No recorded result: 52 is short of 60 sworn.
    expect(outcomeClause(vote({ result: null }))).toBe("failed in the Senate 52–47");
  });

  it("never calls a Speaker ballot's leader a winner (lesson 16)", () => {
    const ballot = (candidates: { name: string; total: number }[]) =>
      vote({ kind: "election", chamber: "house", candidates, result: candidates[0]!.name, citation: null });
    expect(outcomeClause(ballot([{ name: "McCarthy", total: 201 }, { name: "Jeffries", total: 212 }, { name: "Biggs", total: 19 }]))).toBe(
      "elected no one; Jeffries led with 212",
    );
    expect(outcomeClause(ballot([{ name: "Johnson", total: 220 }, { name: "Jeffries", total: 215 }]))).toBe("elected Johnson Speaker with 220");
    expect(
      finalMembersAlert(ballot([{ name: "Johnson", total: 220 }, { name: "Jeffries", total: 215 }]), [
        { id: "D000399", name: "Doggett", position: "candidate", choice: "Jeffries" },
      ]).title,
    ).toBe("Doggett voted for Jeffries on a procedural vote.");
  });

  it("names members as a sentence, and counts them past three", () => {
    expect(joinNames(["Doggett"])).toBe("Doggett");
    expect(joinNames(["Cornyn", "Cruz"])).toBe("Cornyn and Cruz");
    expect(joinNames(["Cornyn", "Cruz", "Doggett"])).toBe("Cornyn, Cruz and Doggett");
    const four = ["A", "B", "C", "D"].map((n) => ({ id: n, name: n, position: "yea" as const, choice: null }));
    expect(finalMembersAlert(vote({ result: "Passed" }), four).title).toBe("4 of your members voted yea on H.R. 2347.");
  });

  it("opens and digests in the mock's words", () => {
    expect(openedAlert(vote({ question: "Motion to Proceed", state: "open", title: "Example Act." }))).toEqual({
      title: "A Senate vote opened: H.R. 2347, Motion to Proceed.",
      body: "Example Act.",
    });
    expect(digestAlert({ members: [{ name: "Doggett", votes: 2 }, { name: "Cornyn", votes: 2 }, { name: "Cruz", votes: 2 }], billVotes: 0 })).toEqual({
      title: "Your members cast 6 votes today.",
      body: "Doggett 2 · Cornyn 2 · Cruz 2. Tap to catch up.",
    });
    expect(digestAlert({ members: [], billVotes: 4 })).toEqual({ title: "4 votes on bills you follow today.", body: "Tap to catch up." });
    expect(digestAlert({ members: [{ name: "Doggett", votes: 1 }], billVotes: 1 }).body).toBe(
      "Doggett 1, and 1 vote on bills you follow. Tap to catch up.",
    );
    expect(finalBillAlert(vote({ result: "Motion to Proceed Agreed to", question: "On the Motion to Proceed" }))).toEqual({
      title: "A vote on H.R. 2347, which you follow.",
      body: "On the Motion to Proceed: it was agreed to in the Senate 52–47.",
    });
  });

  it("cuts a very long title, and shrinks a payload that would pass APNs' 4 KB", () => {
    const long = "To amend title 10, United States Code, ".repeat(40);
    expect(truncate(long).length).toBeLessThanOrEqual(TITLE_MAX);
    expect(truncate(long).endsWith("…")).toBe(true);
    expect(truncate("Short Act")).toBe("Short Act");
    const v = vote({ state: "open", title: truncate(long) });
    expect(openedAlert(v).body.length).toBeLessThanOrEqual(TITLE_MAX + 1);
    const members = Array.from({ length: 3 }, (_, i) => ({ id: `X${i}`, name: "N".repeat(1500), position: null, choice: null }));
    const huge = startPayload(v, members, { title: "t", body: "b".repeat(3000) }, 0);
    expect(Buffer.byteLength(JSON.stringify(huge))).toBeGreaterThan(PAYLOAD_MAX);
    expect(fitPayload(huge)).toBeNull();
    const big = startPayload(v, [], { title: "t", body: "b".repeat(4000) }, 0);
    const fitted = fitPayload(big)!;
    expect(Buffer.byteLength(JSON.stringify(fitted))).toBeLessThanOrEqual(PAYLOAD_MAX);
    expect((fitted.aps as { alert: { body?: string } }).alert.body).toBeUndefined();
    expect(fitPayload(alertPayload({ title: "t", body: "b" }, null))).toEqual(alertPayload({ title: "t", body: "b" }, null));
  });

  it("builds the Live Activity's halves to the Swift contract, listing three members and counting the rest", async () => {
    const v = (await loadVote(await freshDb().then((p) => p as unknown as Db), "house-119-2-321"))!;
    expect(activityAttributes(v)).toEqual(fixture("live-activity-attributes-hr1013.json"));
    expect(activityContent(v, [{ id: "D000399", name: "Doggett", position: "nay", choice: null }])).toEqual(
      fixture("live-activity-open-hr1013.json"),
    );
    const five = ["E", "D", "C", "B", "A"].map((n) => ({ id: n, name: n, position: null, choice: null }));
    const content = activityContent(v, five);
    expect(content.members.map((m) => m.name)).toEqual(["A", "B", "C"]);
    expect(content.moreMembers).toBe(2);
  });
});

describe("housekeeping", () => {
  it("drops old push_log rows, dead activity tokens, token-less and silent devices, and old signup counts", async () => {
    const now = new Date("2026-11-20T12:00:00Z");
    const ids = await register(pg, [
      { name: "fresh", subs: [] },
      { name: "tokenless", apns: null, subs: [] },
      { name: "stale", subs: [] },
    ]);
    await pg.query("update devices set updated_at = $1 where id = $2", ["2026-11-18T00:00:00Z", ids.tokenless]);
    await pg.query("update devices set updated_at = $1 where id = $2", ["2026-09-01T00:00:00Z", ids.stale]);
    await pg.query("update devices set updated_at = $1 where id = $2", ["2026-11-20T11:00:00Z", ids.fresh]);
    await pg.query(
      `insert into push_log (device_id, vote_id, kind, day, sent_at) values ($1, 'house-119-2-321', 'final', '2026-11-11', '2026-11-11T20:00:00Z')`,
      [ids.fresh],
    );
    await pg.query("insert into live_activity_tokens (device_id, vote_id, token, updated_at) values ($1, 'house-119-2-321', $2, '2026-11-11T20:00:00Z')", [ids.fresh, hex("f")]);
    await pg.query("insert into device_signups values ($1, '2026-11-01', 3), ($2, '2026-11-20', 1)", ["a".repeat(64), "b".repeat(64)]);
    expect(await pruneDevices(pg as unknown as Db, now)).toEqual({ pushLog: 1, activityTokens: 1, tokenless: 1, stale: 1, signups: 1 });
    const { rows } = await pg.query<{ id: string }>("select id::text from devices");
    expect(rows.map((r) => r.id)).toEqual([ids.fresh]);
  });
});
