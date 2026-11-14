import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { beforeEach, describe, expect, it } from "vitest";
import type { ApnsMessage, ApnsResult } from "./apns.js";
import type { Json } from "./bills.js";
import {
  BillEventPusher,
  billAlertPayload,
  billEventAlert,
  committeeActions,
  recordCommitteeEvents,
  recordScheduledEvents,
  storedActionKeys,
  type BillEvent,
} from "./billevents.js";
import type { Db } from "./db.js";
import { restage, scoreFor, stageEvents } from "./stage.js";

const here = dirname(fileURLToPath(import.meta.url));
// Real: H.R. 1013's /actions (2026-11-13), which carry its Financial Services markup and report.
const hr1013Actions = JSON.parse(readFileSync(join(here, "../fixtures/congress/stage/119-hr-1013-actions.json"), "utf8")) as Json;

// H.R. 1013 passed the House 295–128 at 2:43 PM Eastern on Nov 11, 2026 (roll call 321).
const NOW = new Date("2026-11-11T20:30:00Z");
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
    insert into bills (id, congress, bill_type, number, title, short_title, origin_chamber, policy_area, stage,
                       latest_action_on, details_fetched_at)
      values ('119-hr-1013', 119, 'hr', 1013,
              'To amend the Internal Revenue Code of 1986 to allow 403(b) plans to invest in collective investment trusts.',
              'Retirement Fairness for Charities and Educational Institutions Act of 2025', 'house', 'Taxation', 'introduced',
              '2026-11-09', '2026-11-10T00:00:00Z');
    insert into votes (id, chamber, congress, session, roll_number, question, state, yea, nay, not_voting, result, bill_id, occurred_at)
      values ('house-119-2-321', 'house', 119, 2, 321, 'On Passage', 'final', 295, 128, 10, 'Passed', '119-hr-1013',
              '2026-11-11T19:43:00Z');
  `);
  return pg;
}

const events = async (pg: PGlite) =>
  (await pg.query<{ kind: string; chamber: string | null; detail: unknown; dedupe_key: string }>(
    "select kind, chamber, detail, dedupe_key from bill_events order by id",
  )).rows;

describe("stageEvents", () => {
  const ev = (was: string | null, stage: string, type = "hr") =>
    stageEvents({ type, originChamber: type.startsWith("s") ? "senate" : "house", was: was as never, stage: stage as never });

  it("a chamber passing, and the second chamber passing", () => {
    expect(ev("introduced", "passed_house")).toEqual([{ kind: "chamber_passed", chamber: "house" }]);
    expect(ev("passed_house", "passed_both")).toEqual([{ kind: "chamber_passed", chamber: "senate" }]);
    expect(ev("passed_senate", "passed_both", "s")).toEqual([{ kind: "chamber_passed", chamber: "house" }]);
  });

  it("the President, law and a veto are one step each, not the passages they imply", () => {
    expect(ev("passed_both", "to_president")).toEqual([{ kind: "to_president", chamber: null }]);
    expect(ev("passed_house", "law")).toEqual([{ kind: "law", chamber: null }]);
    expect(ev("to_president", "vetoed")).toEqual([{ kind: "vetoed", chamber: null }]);
    // Overridden: "Became Public Law" after the veto.
    expect(ev("vetoed", "law")).toEqual([{ kind: "law", chamber: null }]);
  });

  it("a failure is in the chamber that had not passed it", () => {
    expect(ev("introduced", "failed", "hconres")).toEqual([{ kind: "chamber_failed", chamber: "house" }]);
    expect(ev("passed_house", "failed")).toEqual([{ kind: "chamber_failed", chamber: "senate" }]);
  });

  it("nothing for a first staging, no change, or a move backwards", () => {
    expect(ev(null, "law")).toEqual([]);
    expect(ev("passed_house", "passed_house")).toEqual([]);
    expect(ev("passed_both", "passed_house")).toEqual([]);
    expect(ev("law", "to_president")).toEqual([]);
    expect(ev("adopted", "introduced", "hres")).toEqual([]);
  });

  it("a simple resolution agreed to passes its own chamber", () => {
    expect(ev("introduced", "adopted", "hres")).toEqual([{ kind: "chamber_passed", chamber: "house" }]);
  });

  it("scores a pass from the passage vote and a failure from the vote that did not carry", () => {
    const votes = [
      { id: "a", chamber: "house" as const, question: "On Motion to Recommit", result: "Failed", yea: 200, nay: 220, occurred_at: "2026-11-11T19:00:00Z" },
      { id: "b", chamber: "house" as const, question: "On Passage", result: "Passed", yea: 295, nay: 128, occurred_at: "2026-11-11T19:43:00Z" },
    ];
    expect(scoreFor("chamber_passed", "house", votes)?.id).toBe("b");
    expect(scoreFor("chamber_failed", "house", votes)?.id).toBe("a");
    expect(scoreFor("chamber_passed", "senate", votes)).toBeNull();
    expect(scoreFor("law", null, votes)).toBeNull();
  });
});

describe("recording", () => {
  let pg: PGlite;
  let db: Db;
  beforeEach(async () => {
    pg = await freshDb();
    db = pg as unknown as Db;
  });

  it("restage records a recent chamber pass once, with its score", async () => {
    expect(await restage(db, ["119-hr-1013"], NOW)).toBe(1);
    expect(await events(pg)).toEqual([
      {
        kind: "chamber_passed",
        chamber: "house",
        detail: { voteId: "house-119-2-321", yea: 295, nay: 128 },
        dedupe_key: "119-hr-1013:chamber_passed:house",
      },
    ]);
    // Staged back and forward again (a correction): the step is not news twice.
    await pg.exec("update bills set stage = 'introduced'");
    await restage(db, ["119-hr-1013"], NOW);
    expect(await events(pg)).toHaveLength(1);
  });

  it("records nothing for a first staging or an old bill", async () => {
    await pg.exec("update bills set stage = null");
    await restage(db, ["119-hr-1013"], NOW);
    expect(await events(pg)).toEqual([]);
    await pg.exec("update bills set stage = 'introduced'");
    await restage(db, ["119-hr-1013"], new Date("2027-02-01T00:00:00Z"));
    expect(await events(pg)).toEqual([]);
  });

  it("finds the committee actions, less the referrals", () => {
    const found = committeeActions(hr1013Actions);
    expect(found.length).toBeGreaterThan(0);
    expect(found.some((a) => /^Ordered to be Reported/.test(a.text))).toBe(true);
    expect(found.every((a) => !/^Referred to/i.test(a.text))).toBe(true);
  });

  it("records one committee event for new committee actions, none on a first fetch", async () => {
    const latest = committeeActions(hr1013Actions).sort((a, b) => a.actedOn.localeCompare(b.actedOn)).at(-1)!;
    const at = new Date(`${latest.actedOn}T20:00:00Z`);
    expect(await recordCommitteeEvents(db, "119-hr-1013", hr1013Actions, { fetched: false, keys: new Set() }, at)).toBe(0);
    const before = await storedActionKeys(db, "119-hr-1013");
    expect(before.fetched).toBe(true);
    expect(await recordCommitteeEvents(db, "119-hr-1013", hr1013Actions, before, at)).toBe(1);
    expect(await recordCommitteeEvents(db, "119-hr-1013", hr1013Actions, before, at)).toBe(0);
    const [row] = await events(pg);
    expect(row).toMatchObject({ kind: "committee", chamber: null, detail: { text: latest.text, actedOn: latest.actedOn } });
    // Already stored: nothing new.
    const known = { fetched: true, keys: new Set(committeeActions(hr1013Actions).map((a) => `${a.actedOn}|${a.text}`)) };
    await pg.exec("delete from bill_events");
    expect(await recordCommitteeEvents(db, "119-hr-1013", hr1013Actions, known, at)).toBe(0);
  });

  it("reads the floor schedule when the table exists, and does nothing when it does not", async () => {
    // A database without the floor schedule ingest's migration (20261117000000_floor_schedule.sql).
    await pg.exec("alter table floor_schedule rename to floor_schedule_hidden");
    expect(await recordScheduledEvents(db, NOW)).toBe(0);
    await pg.exec("alter table floor_schedule_hidden rename to floor_schedule");
    expect(await recordScheduledEvents(db, NOW)).toBe(0);
    await pg.exec(`
      insert into floor_schedule (chamber, week_of, item_id, category, category_text, legis_num, bill_id, title, added_at, removed_at) values
        ('house', '2026-11-16', 'a', 'suspension', 'Suspension', 'H.R. 1013', '119-hr-1013', 'Retirement Fairness', '2026-11-11T15:00:00Z', null),
        ('house', '2026-11-16', 'b', 'suspension', 'Suspension', 'H.R. 9', null, 'Unlinked', '2026-11-11T15:00:00Z', null),
        ('house', '2026-11-16', 'c', 'rule', 'Rule', 'H.R. 2', '119-hr-1013', 'Removed', '2026-11-11T15:00:00Z', '2026-11-11T16:00:00Z'),
        -- No add date (listed from the start of the week), for a week already over: not news.
        ('house', '2026-11-02', 'd', 'rule', 'Rule', 'H.R. 1013', '119-hr-1013', 'Old week', null, null);
    `);
    expect(await recordScheduledEvents(db, NOW)).toBe(1);
    expect(await recordScheduledEvents(db, NOW)).toBe(0);
    // Listed with no add date for a current week: alerts once, too.
    await pg.exec(
      `insert into floor_schedule (chamber, week_of, item_id, category, category_text, legis_num, bill_id, title)
       values ('senate', '2026-11-09', '2026-11-09:hr1013', 'other', 'Program', 'H.R. 1013', '119-hr-1013', 'Senate')`,
    );
    expect(await recordScheduledEvents(db, NOW)).toBe(1);
    await pg.exec("delete from bill_events where kind = 'floor_scheduled' and chamber = 'senate'");
    expect(await events(pg)).toEqual([
      {
        kind: "floor_scheduled",
        chamber: "house",
        detail: { weekOf: "2026-11-16", category: "suspension" },
        dedupe_key: "119-hr-1013:floor_scheduled:house:2026-11-16",
      },
    ]);
  });
});

describe("copy", () => {
  const base: BillEvent = {
    id: "1",
    billId: "119-hr-5267",
    kind: "floor_scheduled",
    chamber: "house",
    detail: { weekOf: "2026-11-16" },
    citation: "H.R. 5267",
    name: "American Franchise Act",
    policyArea: "Commerce",
  };

  it("says what happened, where, and by what score", () => {
    expect(billEventAlert(base)).toEqual({ title: "H.R. 5267 is up for a House vote the week of Nov 16.", body: "American Franchise Act." });
    expect(billEventAlert({ ...base, kind: "chamber_passed", detail: { yea: 295, nay: 128 } }).title).toBe("H.R. 5267 passed the House 295–128.");
    expect(billEventAlert({ ...base, kind: "chamber_passed", chamber: "senate", detail: {} }).title).toBe("H.R. 5267 passed the Senate.");
    expect(billEventAlert({ ...base, kind: "chamber_failed", detail: { yea: 198, nay: 218 } }).title).toBe("H.R. 5267 failed in the House 198–218.");
    expect(billEventAlert({ ...base, kind: "to_president", chamber: null }).title).toBe("H.R. 5267 was sent to the President.");
    expect(billEventAlert({ ...base, kind: "law", chamber: null }).title).toBe("H.R. 5267 became law.");
    expect(billEventAlert({ ...base, kind: "vetoed", chamber: null }).title).toBe("H.R. 5267 was vetoed.");
    expect(billEventAlert({ ...base, kind: "committee", chamber: null, detail: { text: "Ordered to be Reported by Voice Vote." } })).toEqual({
      title: "Committee action on H.R. 5267.",
      body: "Ordered to be Reported by Voice Vote. American Franchise Act.",
    });
  });

  it("says when it came through a topic, and links to the bill", () => {
    expect(billEventAlert(base, "Commerce").body).toBe("American Franchise Act. In Commerce, a topic you follow.");
    expect(billAlertPayload(billEventAlert(base), base.billId)).toMatchObject({ link: "floor://bill/119-hr-5267", aps: { "thread-id": "floor" } });
  });
});

class StubApns {
  enabled = true;
  sent: ApnsMessage[] = [];
  reply: (msg: ApnsMessage) => ApnsResult = () => ({ ok: true, status: 200 });
  async send(msg: ApnsMessage): Promise<ApnsResult> {
    this.sent.push(msg);
    return this.reply(msg);
  }
}

describe("BillEventPusher", () => {
  let pg: PGlite;
  let db: Db;
  let apns: StubApns;
  let ids: Record<string, string>;
  const pusher = (now = NOW) => new BillEventPusher({ db, apns, environment: "production", now: () => now });

  interface Phone {
    name: string;
    subs: [kind: "member" | "bill" | "topic", id: string, howVoted: boolean][];
    prefs?: Partial<Record<"bill_scheduled" | "bill_chamber_vote" | "bill_to_president" | "bill_law" | "bill_committee" | "bill_through_topics", boolean>>;
    apns?: string | null;
  }
  const register = async (phones: Phone[]) => {
    const out: Record<string, string> = {};
    for (const [i, p] of phones.entries()) {
      const prefs = { bill_scheduled: true, bill_chamber_vote: true, bill_to_president: true, bill_law: true, bill_committee: false, bill_through_topics: false, ...p.prefs };
      const { rows } = await pg.query<{ id: string }>(
        `insert into devices (key_hash, apns_token, bill_scheduled, bill_chamber_vote, bill_to_president, bill_law, bill_committee, bill_through_topics)
         values ($1, $2, $3, $4, $5, $6, $7, $8) returning id::text`,
        [hex(i.toString(16)), p.apns === undefined ? hex("abcdef0123456789"[i]!) : p.apns, prefs.bill_scheduled, prefs.bill_chamber_vote,
         prefs.bill_to_president, prefs.bill_law, prefs.bill_committee, prefs.bill_through_topics],
      );
      out[p.name] = rows[0]!.id;
      for (const [kind, id, howVoted] of p.subs) {
        await pg.query("insert into device_subscriptions values ($1, $2, $3, $4)", [rows[0]!.id, kind, id, howVoted]);
      }
    }
    return out;
  };
  const tokenOf = (name: string) => hex("abcdef0123456789"[Object.keys(ids).indexOf(name)]!);

  beforeEach(async () => {
    pg = await freshDb();
    db = pg as unknown as Db;
    apns = new StubApns();
    ids = await register([
      { name: "follower", subs: [["bill", "119-hr-1013", false]] },
      { name: "topicOptIn", subs: [["topic", "Taxation", false]], prefs: { bill_through_topics: true } },
      { name: "topicOnly", subs: [["topic", "Taxation", false]] },
      { name: "switchOff", subs: [["bill", "119-hr-1013", true]], prefs: { bill_chamber_vote: false } },
      { name: "toldByFinal", subs: [["bill", "119-hr-1013", true]] },
      { name: "memberOnly", subs: [["member", "D000399", true]] },
    ]);
    // The vote's own final alert already reached this phone.
    await pg.query("insert into push_log (device_id, vote_id, kind, bills, day) values ($1, 'house-119-2-321', 'final', '{119-hr-1013}', '2026-11-11')", [ids.toldByFinal]);
    await restage(db, ["119-hr-1013"], NOW);
  });

  it("sends a step to followers and opted-in topic followers whose switch is on, once", async () => {
    const stats = await pusher().run();
    expect(stats).toEqual({ sent: 2, failed: 0, unregistered: 0, events: 1 });
    const byToken = new Map(apns.sent.map((m) => [m.deviceToken, m]));
    expect([...byToken.keys()].sort()).toEqual([tokenOf("follower"), tokenOf("topicOptIn")].sort());
    expect(byToken.get(tokenOf("follower"))!.payload).toEqual({
      aps: {
        alert: { title: "H.R. 1013 passed the House 295–128.", body: "Retirement Fairness for Charities and Educational Institutions Act of 2025." },
        sound: "default",
        "thread-id": "floor",
      },
      link: "floor://bill/119-hr-1013",
    });
    expect((byToken.get(tokenOf("topicOptIn"))!.payload as { aps: { alert: { body: string } } }).aps.alert.body).toMatch(/In Taxation, a topic you follow\.$/);
    expect(byToken.get(tokenOf("follower"))!.collapseId).toMatch(/^bill-\d+$/);
    // A second run (or a retried one) sends nothing.
    await pusher().run();
    expect(apns.sent).toHaveLength(2);
  });

  it("sends nothing with APNs off, and drops an event too old to be news", async () => {
    apns.enabled = false;
    expect(await pusher().run()).toEqual({ sent: 0, failed: 0, unregistered: 0, events: 0 });
    apns.enabled = true;
    expect((await pusher(new Date(NOW.getTime() + 3 * 86_400_000)).run()).events).toBe(0);
    expect(apns.sent).toEqual([]);
  });

  it("clears a dead token", async () => {
    apns.reply = () => ({ ok: false, status: 410, reason: "Unregistered", unregistered: true });
    expect((await pusher().run()).unregistered).toBe(2);
    const { rows } = await pg.query<{ n: number }>("select count(*)::int as n from devices where apns_token is null");
    expect(rows[0]!.n).toBe(2);
  });

  it("past three bill alerts in a day, one notification replaces the next", async () => {
    await pg.exec(`
      insert into bill_events (bill_id, kind, dedupe_key, created_at) values
        ('119-hr-1013', 'to_president', 'a', '2026-11-11T20:00:00Z'),
        ('119-hr-1013', 'law', 'b', '2026-11-11T20:00:00Z'),
        ('119-hr-1013', 'vetoed', 'c', '2026-11-11T20:00:00Z');
    `);
    await pusher().run();
    const mine = apns.sent.filter((m) => m.deviceToken === tokenOf("follower"));
    expect(mine.map((m) => m.collapseId?.startsWith("bill-"))).toEqual([true, true, true, false]);
    expect(mine[3]!.collapseId).toBe("bills-2026-11-11");
    expect((mine[3]!.payload as { aps: { alert: { title: string } } }).aps.alert.title).toBe("4 updates on bills you follow today.");
  });
});
