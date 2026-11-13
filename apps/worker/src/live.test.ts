import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { parseHouseFloor, parseHouseRollCall, parseSenateFloorActivity, parseSenateSchedule } from "@floor/shared";
import { beforeEach, describe, expect, it } from "vitest";
import { lastRollNumber, upsertMembers, upsertRollCall, type Db } from "./db.js";
import {
  HostBackoff,
  LiveWorker,
  POLL_IDLE_MS,
  POLL_IN_SESSION_MS,
  REVALIDATION_CACHE_MAX,
  SENATE_FLOOR_URL,
  SENATE_SCHEDULE_URL,
  STUCK_OPEN_MS,
  houseFloorUrl,
  houseSession,
  parseLatencyDays,
  postingLatency,
  pruneIngestRuns,
  publishFinals,
  recordHouseFloor,
  recordSenateMenu,
  revalidatingFetch,
  runLive,
  senateSession,
  senateVoteMenuUrl,
  stampPosted,
  stuckOpenVotes,
  summarize,
  type RevalidatingFetch,
  type TickResult,
} from "./live.js";
import { houseRollUrl, type FetchText } from "./rollcalls.js";
import { toMemberRows, type LegislatorEntry } from "./members.js";
import type { Broadcaster, VoteStateChange } from "./realtime.js";
import { parseSenateVoteMenu } from "@floor/shared";

const here = dirname(fileURLToPath(import.meta.url));
const read = (p: string) => readFileSync(join(here, p), "utf8");
const shared = (name: string) => read(`../../../packages/shared/fixtures/${name}`);

// Real responses saved 2026-11-13 (see packages/shared/fixtures and apps/worker/fixtures).
const houseNov10 = shared("house-floor-20261110.xml");
const houseNov13 = shared("house-floor-20261113.xml");
const senateSchedule = shared("senate-floor-schedule-20261112.json");
const senateFloor = shared("senate-floor-activity-20261112.htm");
const senateMenu = shared("senate-vote-menu-119-2.xml");
const roll319 = read("../fixtures/house-2026-roll319.xml");
const legislators = JSON.parse(read("../fixtures/legislators-sample.json")) as LegislatorEntry[];

/** Eastern wall-clock instants used below (EST in November: UTC-5). */
const et = (local: string) => new Date(`${local}-05:00`);

async function freshDb(): Promise<Db> {
  const pg = new PGlite();
  await pg.exec(`
    create schema auth;
    create table auth.users (id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
  `);
  for (const m of loadMigrations()) await pg.exec(m.sql);
  const db = pg as unknown as Db;
  await upsertMembers(db, toMemberRows(legislators));
  return db;
}

describe("houseSession (real floor summaries)", () => {
  const finishedDay = parseHouseFloor(houseNov13); // finished; next meets 2026-11-17 12:00

  it("is out between a finished day and the next convening", () => {
    expect(houseSession(finishedDay, et("2026-11-15T12:00:00"))).toMatchObject({ inSession: false, legislativeDay: "2026-11-13" });
    expect(houseSession(finishedDay, et("2026-11-15T12:00:00")).convenesAt?.toISOString()).toBe("2026-11-17T17:00:00.000Z");
  });

  it("polls fast from 15 minutes before the next convening until the new day's file shows up (2 h at most)", () => {
    expect(houseSession(finishedDay, et("2026-11-17T11:44:00")).inSession).toBe(false);
    expect(houseSession(finishedDay, et("2026-11-17T11:46:00")).inSession).toBe(true);
    expect(houseSession(finishedDay, et("2026-11-17T14:01:00")).inSession).toBe(false);
  });

  it("is in for an unfinished day, recesses included, but not for one the Clerk left open for days", () => {
    const open = { ...parseHouseFloor(houseNov10), finished: false, nextConvenesEastern: null };
    expect(houseSession(open, et("2026-11-10T13:00:00")).inSession).toBe(true);
    expect(houseSession(open, et("2026-11-13T13:00:00")).inSession).toBe(false);
    expect(houseSession(null, et("2026-11-10T13:00:00")).inSession).toBe(false);
  });
});

describe("senateSession (real senate.gov schedule and floor page)", () => {
  const schedule = parseSenateSchedule(senateSchedule); // convenes 2026-11-16 15:00, 15 min offset
  const meetings = parseSenateFloorActivity(senateFloor); // 2026-11-12 adjourned 4:52 p.m.

  it("is in from 15 minutes before the convening and out before that", () => {
    expect(senateSession(schedule, meetings, et("2026-11-14T12:00:00")).inSession).toBe(false);
    expect(senateSession(schedule, meetings, et("2026-11-16T14:40:00")).inSession).toBe(false);
    expect(senateSession(schedule, meetings, et("2026-11-16T14:50:00")).inSession).toBe(true);
    expect(senateSession(schedule, meetings, et("2026-11-16T20:00:00")).inSession).toBe(true);
  });

  it("is out once the floor page says that meeting adjourned, or 16 hours on from a stale schedule", () => {
    const adjourned = [...meetings, { date: "2026-11-16", text: "", convenedAt: "15:00", adjournedAt: "18:30", convenesAt: null }];
    expect(senateSession(schedule, adjourned, et("2026-11-16T18:45:00")).inSession).toBe(false);
    expect(senateSession(schedule, meetings, et("2026-11-17T07:01:00")).inSession).toBe(false);
  });
});


/** Stores rolls 1..`upto` of 119-2 as final and already broadcast, as the migration leaves existing votes. */
async function seedFinal(db: Db, chamber: "house" | "senate", upto: number, except: number[] = []): Promise<void> {
  await db.query(
    `insert into votes (id, chamber, congress, session, roll_number, question, state, broadcast_at)
     select $1 || '-119-2-' || n, $1::chamber, 119, 2, n, 'q', 'final', '2026-11-01T00:00:00Z'
       from generate_series(1, $2::int) n where n <> all($3::int[])`,
    [chamber, upto, except],
  );
}

const recorder = () => {
  const published: VoteStateChange[][] = [];
  const broadcaster: Broadcaster = { enabled: true, publish: async (c) => void published.push(c) };
  return { published, broadcaster };
};

describe("vote state from floor events", () => {
  let db: Db;
  beforeEach(async () => {
    db = await freshDb();
  });

  it("opens each roll call the House floor summary names, with the floor's time, and stores every action", async () => {
    const seen = et("2026-11-10T18:33:00");
    const { events, opened } = await recordHouseFloor(db, parseHouseFloor(houseNov10), seen);
    expect(events).toBe(32);
    expect(opened.map((v) => v.id)).toEqual(["house-119-2-317", "house-119-2-318", "house-119-2-319"]);
    expect(opened[2]).toMatchObject({
      state: "open",
      question: "On agreeing to the resolution",
      result: "Agreed to",
      openedAt: "2026-11-10T23:20:53.000Z",
      announcedAt: "2026-11-10T23:33:00.000Z",
      postedAt: null,
    });
    const { rows } = await db.query<{ yea: number; nay: number; bill_ref: string }>(
      "select yea, nay, bill_ref from votes where id = 'house-119-2-319'",
    );
    expect(rows[0]).toEqual({ yea: 215, nay: 209, bill_ref: "H. Res. 1650" });
    const { rows: ev } = await db.query<{ kind: string; vote_id: string | null }>(
      "select kind, vote_id from floor_events where roll_number = 319",
    );
    expect(ev).toEqual([{ kind: "vote", vote_id: "house-119-2-319" }]);

    // The same file again: nothing new, and the first sighting is kept.
    const again = await recordHouseFloor(db, parseHouseFloor(houseNov10), et("2026-11-10T18:40:00"));
    expect(again).toEqual({ events: 0, opened: [] });
    const { rows: kept } = await db.query<{ announced_at: Date }>("select announced_at from votes where id = 'house-119-2-319'");
    expect(new Date(kept[0]!.announced_at).toISOString()).toBe("2026-11-10T23:33:00.000Z");
  });

  it("stores votes that are not news without announcing them or stamping a sighting time", async () => {
    const { opened } = await recordHouseFloor(db, parseHouseFloor(houseNov10), et("2026-11-13T10:00:00"), () => false);
    expect(opened).toEqual([]);
    const { rows } = await db.query<{ id: string; state: string; announced_at: Date | null }>(
      "select id, state, announced_at from votes order by id",
    );
    expect(rows).toEqual([
      { id: "house-119-2-317", state: "open", announced_at: null },
      { id: "house-119-2-318", state: "open", announced_at: null },
      { id: "house-119-2-319", state: "open", announced_at: null },
    ]);
  });

  it("does not count an open vote as ingested, so the roll call ingest still fetches it", async () => {
    await recordHouseFloor(db, parseHouseFloor(houseNov10), et("2026-11-10T18:33:00"));
    expect(await lastRollNumber(db, "house", 119, 2)).toBe(0);
  });

  it("stamps posted_at and publishes a vote once when its roll call XML lands", async () => {
    await recordHouseFloor(db, parseHouseFloor(houseNov10), et("2026-11-10T18:33:00"));
    await upsertRollCall(db, parseHouseRollCall(roll319));
    const posted = et("2026-11-10T18:33:10");
    expect((await stampPosted(db, "house", posted)).map((v) => v.id)).toEqual(["house-119-2-319"]);
    const { published, broadcaster } = recorder();
    const finals = await publishFinals(db, broadcaster, posted);
    expect(finals).toEqual([
      expect.objectContaining({
        id: "house-119-2-319",
        state: "final",
        result: "Passed",
        openedAt: "2026-11-10T23:20:53.000Z",
        announcedAt: "2026-11-10T23:33:00.000Z",
        postedAt: "2026-11-10T23:33:10.000Z",
      }),
    ]);
    expect(published).toEqual([finals]);
    // Published once: a later poll finds nothing to publish and nothing to stamp.
    const later = et("2026-11-10T19:00:00");
    expect(await publishFinals(db, broadcaster, later)).toEqual([]);
    expect(await stampPosted(db, "house", later)).toEqual([]);
    expect(published).toHaveLength(1);
    const [row] = await postingLatency(db, 100_000);
    expect(row).toMatchObject({ id: "house-119-2-319", fromOpenSeconds: 737, fromAnnouncedSeconds: 10 });
  });

  it("publishes a vote found without a live poll, but records no posting delay for it", async () => {
    await upsertRollCall(db, parseHouseRollCall(roll319));
    const { broadcaster } = recorder();
    const finals = await publishFinals(db, broadcaster, et("2026-11-11T09:00:00"));
    expect(finals).toEqual([expect.objectContaining({ id: "house-119-2-319", postedAt: null })]);
    expect(await postingLatency(db, 100_000)).toEqual([]);
  });

  it("marks a final vote older than a day as broadcast without publishing it", async () => {
    await upsertRollCall(db, parseHouseRollCall(roll319));
    const { published, broadcaster } = recorder();
    expect(await publishFinals(db, broadcaster, et("2026-11-20T12:00:00"))).toEqual([]);
    expect(published).toEqual([]);
    const { rows } = await db.query<{ broadcast_at: Date | null }>("select broadcast_at from votes where id = 'house-119-2-319'");
    expect(new Date(rows[0]!.broadcast_at!).toISOString()).toBe("2026-11-20T17:00:00.000Z");
  });

  it("leaves a vote unmarked when the broadcast fails, and publishes it on the next try", async () => {
    await upsertRollCall(db, parseHouseRollCall(roll319));
    const down: Broadcaster = { enabled: true, publish: async () => Promise.reject(new Error("Realtime down")) };
    await expect(publishFinals(db, down, et("2026-11-10T18:34:00"))).rejects.toThrow("Realtime down");
    const { rows } = await db.query<{ broadcast_at: Date | null }>("select broadcast_at from votes where id = 'house-119-2-319'");
    expect(rows[0]!.broadcast_at).toBeNull();
    const { published, broadcaster } = recorder();
    await publishFinals(db, broadcaster, et("2026-11-10T18:34:10"));
    expect(published.flat().map((c) => c.id)).toEqual(["house-119-2-319"]);
  });

  it("opens Senate votes the vote menu lists past the newest one stored, and nothing further back", async () => {
    const menu = parseSenateVoteMenu(senateMenu);
    // Roll 100 is missing, as after an ingest failure: that is a gap to repair, not a vote happening now.
    await seedFinal(db, "senate", 260, [100]);
    const { opened, events } = await recordSenateMenu(db, menu, et("2026-11-12T16:00:00"));
    expect(opened.map((v) => v.id)).toEqual(["senate-119-2-261", "senate-119-2-262"]);
    expect(events).toBe(2);
    expect(opened[1]).toMatchObject({ question: "On the Cloture Motion", result: "Agreed to", openedAt: null });
    const { rows } = await db.query<{ bill_ref: string; yea: number }>("select bill_ref, yea from votes where id = 'senate-119-2-262'");
    expect(rows[0]).toEqual({ bill_ref: "PN1181-7", yea: 49 });
  });

  it("asks whether each menu vote is news by its date, and keeps a menu entry's first sighting time", async () => {
    const menu = parseSenateVoteMenu(senateMenu);
    await seedFinal(db, "senate", 257);
    const asked: string[] = [];
    const first = et("2026-11-12T16:00:00");
    const { opened } = await recordSenateMenu(db, menu, first, (d) => (asked.push(d), d === "2026-11-12"));
    // 258 was voted on 2026-11-10 (per the menu), 259-262 on 2026-11-12.
    expect(asked).toEqual(["2026-11-10", "2026-11-12", "2026-11-12", "2026-11-12", "2026-11-12"]);
    expect(opened.map((v) => v.id)).toEqual(["senate-119-2-259", "senate-119-2-260", "senate-119-2-261", "senate-119-2-262"]);

    await recordSenateMenu(db, menu, et("2026-11-12T18:00:00"));
    const { rows } = await db.query<{ occurred_at: Date }>(
      "select occurred_at from floor_events where source_ref = 'vote_menu:119-2-262'",
    );
    expect(new Date(rows[0]!.occurred_at).toISOString()).toBe(first.toISOString());
  });

  it("finds votes stuck open for hours, by when a floor source first named them", async () => {
    const seen = et("2026-11-10T18:33:00");
    await recordHouseFloor(db, parseHouseFloor(houseNov10), seen);
    expect(await stuckOpenVotes(db, et("2026-11-10T23:33:00"), STUCK_OPEN_MS)).toEqual([]);
    await upsertRollCall(db, parseHouseRollCall(roll319));
    const stuck = await stuckOpenVotes(db, et("2026-11-11T01:00:00"), STUCK_OPEN_MS);
    expect(stuck).toEqual([
      { id: "house-119-2-317", since: seen.toISOString() },
      { id: "house-119-2-318", since: seen.toISOString() },
    ]);
  });
});

/**
 * Serves the saved responses by URL, like the live sites did on 2026-11-13, with the revalidation
 * contract: a body is `unchanged` only once it has been committed. `routes` can be changed between
 * polls; `calls` records every URL asked for.
 */
function floorServer(routes: Record<string, { status: number; text: string }> = {}, calls: string[] = []): RevalidatingFetch {
  const pages: Record<string, string> = {
    [houseFloorUrl("2026-11-10")]: houseNov10,
    [SENATE_SCHEDULE_URL]: senateSchedule,
    [SENATE_FLOOR_URL]: senateFloor,
    [senateVoteMenuUrl(119, 2)]: senateMenu,
  };
  const committed = new Map<string, string>();
  return async (url) => {
    calls.push(url);
    const o = routes[url];
    const status = o?.status ?? (pages[url] !== undefined ? 200 : 404);
    const text = o?.text ?? pages[url] ?? "";
    return {
      status,
      text,
      unchanged: status === 200 && committed.get(url) === text,
      commit: () => void (status === 200 && committed.set(url, text)),
    };
  };
}

/** The 2026-11-10 file as it read while the House sat: the same actions, the day not yet finished. */
const houseNov10Sitting = houseNov10.replace(">Yes</legislative_day_finished>", ">No</legislative_day_finished>");
const sitting = { [houseFloorUrl("2026-11-10")]: { status: 200, text: houseNov10Sitting } };
const noRolls: FetchText = async () => ({ status: 404, text: "" });
const idle: Broadcaster = { enabled: false, publish: async () => {} };

describe("LiveWorker.tick", () => {
  it("opens, then finalizes, a House vote across two polls, publishing both, and polls the idle Senate less often", async () => {
    const db = await freshDb();
    await seedFinal(db, "house", 318);
    await seedFinal(db, "senate", 262);
    let rollPosted = false;
    const fetchRoll: FetchText = async (url) =>
      rollPosted && url === houseRollUrl(119, 2, 319) ? { status: 200, text: roll319 } : { status: 404, text: "" };
    const { published, broadcaster } = recorder();
    const logs: string[] = [];
    let now = et("2026-11-10T18:33:00");
    const worker = new LiveWorker({ db, fetchFloor: floorServer({ ...sitting }), fetchRoll, broadcaster, now: () => now, log: (m) => logs.push(m) });

    const first = await worker.tick();
    expect(first.errors).toEqual([]);
    expect(first.polled).toEqual(["house", "senate"]);
    expect(first.changes.map((c) => `${c.id}:${c.state}`)).toEqual(["house-119-2-319:open"]);
    expect(first.sessions.map((s) => `${s.chamber}:${s.inSession}`)).toEqual(["house:true", "senate:false"]);

    rollPosted = true;
    now = new Date(now.getTime() + POLL_IN_SESSION_MS);
    const second = await worker.tick();
    expect(second.errors).toEqual([]);
    expect(second.polled).toEqual(["house"]); // the Senate is out: next asked 5 minutes after the first poll
    expect(second.changes).toEqual([
      expect.objectContaining({ id: "house-119-2-319", state: "final", postedAt: "2026-11-10T23:33:10.000Z" }),
    ]);
    expect(published.map((p) => p.map((c) => `${c.id}:${c.state}`))).toEqual([["house-119-2-319:open"], ["house-119-2-319:final"]]);
    expect(logs).toContain("latency house-119-2-319: XML seen 737 s after the floor's vote time, 10 s after a floor source named it");

    now = new Date(now.getTime() + POLL_IDLE_MS);
    expect((await worker.tick()).polled).toEqual(["house", "senate"]);

    const { rows } = await db.query<{ chamber: string; in_session: boolean }>(
      "select chamber, in_session from chamber_status order by chamber",
    );
    expect(rows).toEqual([
      { chamber: "house", in_session: true },
      { chamber: "senate", in_session: false },
    ]);
  });

  it("still publishes what it stored when the roll call ingest throws partway", async () => {
    const db = await freshDb();
    await seedFinal(db, "house", 318);
    await seedFinal(db, "senate", 262);
    let posted = false;
    const fetchRoll: FetchText = async (url) => {
      if (!posted) return { status: 404, text: "" };
      if (url === houseRollUrl(119, 2, 319)) return { status: 200, text: roll319 };
      if (url === houseRollUrl(119, 2, 320)) throw new Error("socket hang up");
      return { status: 404, text: "" };
    };
    const { published, broadcaster } = recorder();
    let now = et("2026-11-10T18:33:00");
    const worker = new LiveWorker({ db, fetchFloor: floorServer({ ...sitting }), fetchRoll, broadcaster, now: () => now });
    await worker.tick();
    posted = true;
    now = new Date(now.getTime() + POLL_IN_SESSION_MS);
    const second = await worker.tick();
    expect(second.errors).toEqual(["house roll calls: socket hang up"]);
    expect(second.changes.map((c) => `${c.id}:${c.state}`)).toEqual(["house-119-2-319:final"]);
    expect(second.changes[0]!.postedAt).toBe("2026-11-10T23:33:10.000Z");
    expect(published.at(-1)!.map((c) => `${c.id}:${c.state}`)).toEqual(["house-119-2-319:final"]);
  });

  it("publishes finals someone else stored (the hourly workflow, a run before a restart), except old ones", async () => {
    const db = await freshDb();
    await seedFinal(db, "house", 318);
    await seedFinal(db, "senate", 262);
    const before = new LiveWorker({ db, fetchFloor: floorServer({ ...sitting }), fetchRoll: noRolls, broadcaster: idle, now: () => et("2026-11-10T18:33:00") });
    await before.tick();
    // While the worker is down: the workflow stores 319, and a backfill stores a vote from 2025.
    await upsertRollCall(db, parseHouseRollCall(roll319));
    await db.query(
      `insert into votes (id, chamber, congress, session, roll_number, question, state, occurred_at)
       values ('house-119-1-10', 'house', 119, 1, 10, 'On Passage', 'final', '2025-02-01T15:00:00Z')`,
    );
    const { published, broadcaster } = recorder();
    const after = new LiveWorker({ db, fetchFloor: floorServer({ ...sitting }), fetchRoll: noRolls, broadcaster, now: () => et("2026-11-10T18:45:00") });
    const result = await after.tick();
    expect(result.changes.map((c) => `${c.id}:${c.state}:${c.postedAt}`)).toEqual(["house-119-2-319:final:null"]);
    expect(published.flat().map((c) => c.id)).toEqual(["house-119-2-319"]);
    const { rows } = await db.query<{ n: number }>("select count(*)::int as n from votes where state = 'final' and broadcast_at is null");
    expect(rows[0]!.n).toBe(0); // the 2025 vote is marked, silently
  });

  it("keeps going when an upstream fails, reports which, and leaves that chamber's stored status alone", async () => {
    const db = await freshDb();
    await seedFinal(db, "senate", 262); // so any vote opened below is the House's
    const worker = new LiveWorker({
      db,
      fetchFloor: floorServer({ [SENATE_SCHEDULE_URL]: { status: 503, text: "" } }),
      fetchRoll: noRolls,
      broadcaster: idle,
      now: () => et("2026-11-10T18:33:00"),
    });
    const result = await worker.tick();
    expect(result.errors).toEqual(["senate schedule: HTTP 503"]);
    expect(result.sessions[1]).toMatchObject({ chamber: "senate", inSession: false });
    expect(result.changes.map((c) => `${c.id}:${c.state}`)).toEqual([
      "house-119-2-317:open",
      "house-119-2-318:open",
      "house-119-2-319:open",
    ]);
    const { rows } = await db.query<{ chamber: string }>("select chamber from chamber_status order by chamber");
    expect(rows.map((r) => r.chamber)).toEqual(["house"]);
  });

  it("rides out a failed Senate schedule on its last good copy for 30 minutes, then calls the Senate out", async () => {
    const db = await freshDb();
    const routes: Record<string, { status: number; text: string }> = {};
    let now = et("2026-11-16T15:30:00"); // the Senate convened at 15:00
    const worker = new LiveWorker({ db, fetchFloor: floorServer(routes), fetchRoll: noRolls, broadcaster: idle, now: () => now });
    expect((await worker.tick()).sessions[1]!.inSession).toBe(true);
    const checked = async () =>
      new Date((await db.query<{ checked_at: Date }>("select checked_at from chamber_status where chamber = 'senate'")).rows[0]!.checked_at).toISOString();
    const firstCheck = await checked();

    routes[SENATE_SCHEDULE_URL] = { status: 503, text: "" };
    now = new Date(now.getTime() + POLL_IN_SESSION_MS);
    const failing = await worker.tick();
    expect(failing.polled).toContain("senate");
    expect(failing.errors).toContain("senate schedule: HTTP 503");
    expect(failing.sessions[1]!.inSession).toBe(true);
    expect(await checked()).toBe(firstCheck); // a failed poll writes no status

    now = new Date(now.getTime() + 30 * 60_000);
    expect((await worker.tick()).sessions[1]!.inSession).toBe(false);
  });

  it("treats senate.gov's 200 error page for the floor page as unknown, keeping the adjournment it already knew", async () => {
    const db = await freshDb();
    // A schedule naming 2026-11-12 at noon: the floor page says that meeting adjourned at 4:52 p.m.
    const routes: Record<string, { status: number; text: string }> = {
      [SENATE_SCHEDULE_URL]: {
        status: 200,
        text: senateSchedule.replace('"conveneDay": "16"', '"conveneDay": "12"').replace('"conveneHour": "15"', '"conveneHour": "12"'),
      },
    };
    expect(routes[SENATE_SCHEDULE_URL]!.text).not.toBe(senateSchedule);
    let now = et("2026-11-12T17:00:00");
    const worker = new LiveWorker({ db, fetchFloor: floorServer(routes), fetchRoll: noRolls, broadcaster: idle, now: () => now });
    expect((await worker.tick()).sessions[1]!.inSession).toBe(false);

    routes[SENATE_FLOOR_URL] = { status: 200, text: '<html><head><meta name="description" content="404 Error Page"></head><body></body></html>' };
    now = new Date(now.getTime() + POLL_IDLE_MS);
    const result = await worker.tick();
    expect(result.errors).toContain("senate floor page: Senate floor activity page has no meeting blocks");
    expect(result.sessions[1]!.inSession).toBe(false); // with no meetings it would read as still sitting
  });

  it("backs off senate.gov after a 403: 30 s, then 60 s, and resets once it answers", async () => {
    const db = await freshDb();
    await seedFinal(db, "senate", 262);
    const routes: Record<string, { status: number; text: string }> = {};
    const calls: string[] = [];
    const rollCalls: string[] = [];
    const fetchRoll: FetchText = async (url) => (rollCalls.push(url), { status: 404, text: "" });
    let now = et("2026-11-16T15:30:00");
    const worker = new LiveWorker({ db, fetchFloor: floorServer(routes, calls), fetchRoll, broadcaster: idle, now: () => now });
    const senateCalls = async (atSeconds: number) => {
      now = new Date(et("2026-11-16T15:30:00").getTime() + atSeconds * 1000);
      calls.length = 0;
      rollCalls.length = 0;
      const r = await worker.tick();
      const all = [...calls, ...rollCalls].filter((u) => u.includes("senate.gov"));
      return { all, r };
    };
    expect((await senateCalls(0)).all.length).toBeGreaterThan(2); // schedule, floor page, menu, roll call 263

    routes[SENATE_SCHEDULE_URL] = { status: 403, text: "" };
    // The schedule and floor page go out together; nothing after the 403 does.
    expect((await senateCalls(10)).all).toEqual([SENATE_SCHEDULE_URL, SENATE_FLOOR_URL]);
    const blocked = await senateCalls(20);
    expect(blocked.all).toEqual([]);
    expect(blocked.r.errors.join("; ")).toMatch(/www\.senate\.gov refused us \(403\/429\); backing off/);
    expect((await senateCalls(30)).all).toEqual([]);
    expect((await senateCalls(41)).all).toEqual([SENATE_SCHEDULE_URL, SENATE_FLOOR_URL]); // 31 s on: tried, 403 again
    expect((await senateCalls(91)).all).toEqual([]); // now 60 s
    delete routes[SENATE_SCHEDULE_URL];
    expect((await senateCalls(102)).all).toContain(senateVoteMenuUrl(119, 2)); // answered: back to normal
    expect((await senateCalls(112)).all).toContain(senateVoteMenuUrl(119, 2));
  });

  it("re-fetches votes saved without positions once an hour, not every poll", async () => {
    const db = await freshDb();
    await seedFinal(db, "house", 318); // seeded without positions
    await seedFinal(db, "senate", 262);
    const fetched: string[] = [];
    const fetchRoll: FetchText = async (url) => (fetched.push(url), { status: 404, text: "" });
    let now = et("2026-11-10T18:33:00");
    const worker = new LiveWorker({ db, fetchFloor: floorServer({ ...sitting }), fetchRoll, broadcaster: idle, now: () => now });
    const roll5 = houseRollUrl(119, 2, 5);
    const at = async (ms: number) => {
      now = new Date(et("2026-11-10T18:33:00").getTime() + ms);
      fetched.length = 0;
      const r = await worker.tick();
      expect(r.polled).toContain("house");
      return fetched.filter((u) => u === roll5).length;
    };
    expect(await at(0)).toBe(1);
    expect(await at(POLL_IN_SESSION_MS)).toBe(0);
    expect(await at(30 * 60_000)).toBe(0);
    expect(await at(61 * 60_000)).toBe(1);
  });

  it("stores the floor file again next poll when storing it failed, instead of treating it as seen", async () => {
    const pglite = await freshDb();
    await seedFinal(pglite, "house", 318);
    await seedFinal(pglite, "senate", 262);
    let failOnce = true;
    const db: Db = {
      query: async (text, params) => {
        if (failOnce && text.includes("insert into votes") && text.includes("jsonb_to_recordset")) {
          failOnce = false;
          throw new Error("connection reset");
        }
        return pglite.query(text, params);
      },
    };
    let now = et("2026-11-10T18:33:00");
    const worker = new LiveWorker({ db, fetchFloor: floorServer({ ...sitting }), fetchRoll: noRolls, broadcaster: idle, now: () => now });
    const first = await worker.tick();
    expect(first.errors).toEqual(["house floor store: connection reset"]);
    expect(first.changes).toEqual([]);
    now = new Date(now.getTime() + POLL_IN_SESSION_MS);
    const second = await worker.tick();
    expect(second.errors).toEqual([]);
    expect(second.changes.map((c) => `${c.id}:${c.state}`)).toEqual(["house-119-2-319:open"]);
  });

  it("does not announce votes found after downtime or on a first run, only stores them", async () => {
    const db = await freshDb(); // a fresh table: nothing stored for either chamber
    const { published, broadcaster } = recorder();
    // 2026-11-13: the House last sat on the 10th, the Senate's newest votes are from the 12th.
    const worker = new LiveWorker({ db, fetchFloor: floorServer(), fetchRoll: noRolls, broadcaster, now: () => et("2026-11-13T10:00:00") });
    const result = await worker.tick();
    expect(result.errors).toEqual([]);
    expect(result.changes).toEqual([]);
    expect(published).toEqual([]);
    const { rows } = await db.query<{ chamber: string; n: number; announced: number }>(
      `select chamber, count(*)::int as n, count(announced_at)::int as announced from votes where state = 'open'
        group by chamber order by chamber`,
    );
    expect(rows).toEqual([
      { chamber: "house", n: 3, announced: 0 },
      { chamber: "senate", n: 262, announced: 0 },
    ]);
  });

  it("announces a menu vote dated today even on the first poll", async () => {
    const db = await freshDb();
    await seedFinal(db, "senate", 257);
    const worker = new LiveWorker({ db, fetchFloor: floorServer(), fetchRoll: noRolls, broadcaster: idle, now: () => et("2026-11-12T17:00:00") });
    const result = await worker.tick();
    // 258 is from 2026-11-10: stored quietly. 259-262 are today's.
    expect(result.changes.filter((c) => c.chamber === "senate").map((c) => c.id)).toEqual([
      "senate-119-2-259",
      "senate-119-2-260",
      "senate-119-2-261",
      "senate-119-2-262",
    ]);
  });

  it("asks the alerter every poll with whether a chamber sits", async () => {
    const db = await freshDb();
    const calls: boolean[] = [];
    const worker = new LiveWorker({
      db,
      fetchFloor: floorServer(),
      fetchRoll: noRolls,
      broadcaster: idle,
      alerter: { check: async (s: boolean) => (calls.push(s), "ok" as const) },
      now: () => et("2026-11-16T15:30:00"), // Senate convened at 15:00
    });
    await worker.tick();
    expect(calls).toEqual([true]);
  });

  it("reports votes stuck open for six hours once each, not every hourly sweep", async () => {
    const db = await freshDb();
    await seedFinal(db, "senate", 262);
    await recordHouseFloor(db, parseHouseFloor(houseNov10), et("2026-11-10T11:00:00"));
    const notices: string[] = [];
    const logs: string[] = [];
    let now = et("2026-11-10T18:33:00");
    const worker = new LiveWorker({
      db,
      fetchFloor: floorServer({ ...sitting }),
      fetchRoll: noRolls,
      broadcaster: idle,
      alerter: { check: async () => "skipped" as const, notify: async (t: string) => void notices.push(t) },
      now: () => now,
      log: (m) => logs.push(m),
    });
    await worker.tick();
    expect(notices).toEqual([
      "Floor: 3 vote(s) open for over 6 h with no roll call stored: house-119-2-317, house-119-2-318, house-119-2-319",
    ]);
    expect(logs.some((l) => l.startsWith("stuck open: 3 vote(s) open for over 6 h"))).toBe(true);
    now = new Date(now.getTime() + 61 * 60_000);
    await worker.tick();
    expect(notices).toHaveLength(1);
    expect(logs.filter((l) => l.startsWith("stuck open:"))).toHaveLength(2);
  });
});

describe("runLive", () => {
  const tick = (inSession: boolean): TickResult => ({ sessions: [], inSession, polled: [], changes: [], errors: [] });

  it("waits 10 s in session and 5 min out, and stops on abort after the poll in flight", async () => {
    const stop = new AbortController();
    const waits: number[] = [];
    const results = [tick(true), tick(false), tick(true)];
    let i = 0;
    const ticks = await runLive(
      {
        tick: async () => {
          const r = results[i++]!;
          if (i === results.length) stop.abort();
          return r;
        },
      },
      stop.signal,
      { wait: async (ms) => void waits.push(ms) },
    );
    expect(ticks).toBe(3);
    expect(waits).toEqual([POLL_IN_SESSION_MS, POLL_IDLE_MS]);
  });
});

describe("revalidatingFetch", () => {
  const server = (sent: (string | null)[]) =>
    (async (_url: string, init?: { headers?: Record<string, string> }) => {
      const tag = init?.headers?.["if-none-match"] ?? null;
      sent.push(tag);
      return tag === '"v1"'
        ? new Response(null, { status: 304 })
        : new Response("<menu/>", { status: 200, headers: { etag: '"v1"' } });
    }) as typeof fetch;

  it("sends the ETag back and serves the cached body on a 304, once the body is committed", async () => {
    const sent: (string | null)[] = [];
    const get = revalidatingFetch(server(sent));
    const first = await get("https://example.test/a");
    expect(first).toMatchObject({ status: 200, text: "<menu/>", unchanged: false });
    first.commit();
    expect(await get("https://example.test/a")).toMatchObject({ status: 200, text: "<menu/>", unchanged: true });
    expect(sent).toEqual([null, '"v1"']);
  });

  it("asks again in full, and reports the body as changed, until it is committed", async () => {
    const sent: (string | null)[] = [];
    const get = revalidatingFetch(server(sent));
    await get("https://example.test/a"); // the store failed: no commit
    const again = await get("https://example.test/a");
    expect(again).toMatchObject({ status: 200, text: "<menu/>", unchanged: false });
    expect(sent).toEqual([null, null]);
  });

  it("remembers at most REVALIDATION_CACHE_MAX URLs, dropping the least recently stored", async () => {
    const sent: (string | null)[] = [];
    const get = revalidatingFetch(server(sent));
    for (let i = 0; i <= REVALIDATION_CACHE_MAX; i++) (await get(`https://example.test/${i}`)).commit();
    sent.length = 0;
    await get("https://example.test/0"); // evicted
    await get(`https://example.test/${REVALIDATION_CACHE_MAX}`); // kept
    expect(sent).toEqual([null, '"v1"']);
  });
});

describe("HostBackoff", () => {
  it("refuses a host for 30 s after a 403 or 429, doubles to 5 minutes, and resets on any other answer", async () => {
    let t = 0;
    const b = new HostBackoff(() => t);
    let calls = 0;
    const answer = (status: number) => async () => (calls++, { status });
    const url = "https://www.senate.gov/x";
    await b.run(url, answer(429));
    await expect(b.run(url, answer(200))).rejects.toThrow(/backing off for 30 s more/);
    await expect(b.run("https://clerk.house.gov/x", answer(200))).resolves.toEqual({ status: 200 }); // other hosts unaffected
    const delays: number[] = [];
    for (let k = 0; k < 5; k++) {
      // Wait out the current backoff, get refused again, and read the new delay off the error.
      t += 10 * 60_000;
      await b.run(url, answer(403));
      const msg = await b.run(url, answer(200)).then(
        () => "",
        (e: Error) => e.message,
      );
      delays.push(Number(/for (\d+) s more/.exec(msg)?.[1]));
    }
    expect(delays).toEqual([60, 120, 240, 300, 300]);
    t += 10 * 60_000;
    await b.run(url, answer(200)); // answered: reset
    await b.run(url, answer(403));
    await expect(b.run(url, answer(200))).rejects.toThrow(/for 30 s more/);
    expect(calls).toBe(1 + 1 + 5 + 1 + 1);
  });
});

describe("pruneIngestRuns", () => {
  it("drops old empty runs but keeps errors, runs that stored something, and the newest per source", async () => {
    const db = await freshDb();
    await db.query(
      `insert into ingest_runs (source, started_at, finished_at, items, error, failed) values
         ('house_rollcalls', now() - interval '5 days', now() - interval '5 days', 0, null, 0),
         ('house_rollcalls', now() - interval '4 days', now() - interval '4 days', 3, null, 0),
         ('house_rollcalls', now() - interval '4 days', now() - interval '4 days', 0, 'boom', 0),
         ('house_rollcalls', now() - interval '4 days', null, 0, null, 0),
         ('house_rollcalls', now() - interval '4 days', now() - interval '4 days', 0, null, 2),
         ('house_rollcalls', now() - interval '3 days', now() - interval '3 days', 0, null, 0),
         ('senate_rollcalls', now() - interval '9 days', now() - interval '9 days', 0, null, 0)`,
    );
    // Only the 5-day-old empty House run goes: the 4-day ones stored, failed, failed items, or never
    // finished (an "abandoned run" on /v1/status); the 3-day one and the Senate one are the newest.
    expect(await pruneIngestRuns(db)).toBe(1);
    const { rows } = await db.query<{ n: number }>("select count(*)::int as n from ingest_runs");
    expect(rows[0]!.n).toBe(6);
  });
});

describe("summarize and parseLatencyDays", () => {
  it("takes the median and 90th percentile of what was measured", () => {
    expect(summarize([30, null, 10, 20, 40, 50, 60, 70, 80, 90, 100])).toEqual({ n: 10, median: 50, p90: 90 });
    expect(summarize([null])).toEqual({ n: 0, median: null, p90: null });
  });

  it("takes a whole number of days and refuses anything else", () => {
    expect(parseLatencyDays(undefined)).toBe(30);
    expect(parseLatencyDays("7")).toBe(7);
    for (const bad of ["0", "-3", "1.5", "abc", "", "99999"]) expect(() => parseLatencyDays(bad)).toThrow(/whole number of days/);
  });
});

describe("the M3 migration", () => {
  it("marks every vote already final as broadcast, so the worker's first poll announces none of them", async () => {
    const pg = new PGlite();
    await pg.exec(`
      create schema auth;
      create table auth.users (id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
    `);
    const migrations = loadMigrations();
    const live = migrations.findIndex((m) => m.name.endsWith("_live_layer.sql"));
    expect(live).toBeGreaterThan(0);
    for (const m of migrations.slice(0, live)) await pg.exec(m.sql);
    await pg.exec(`
      insert into votes (id, chamber, congress, session, roll_number, question, state, occurred_at) values
        ('house-119-2-1', 'house', 119, 2, 1, 'q', 'final', '2026-01-06T15:00:00Z'),
        ('house-119-2-2', 'house', 119, 2, 2, 'q', 'final', null),
        ('house-119-2-3', 'house', 119, 2, 3, 'q', 'open', null);
    `);
    for (const m of migrations.slice(live)) await pg.exec(m.sql);
    const db = pg as unknown as Db;
    const { rows } = await db.query<{ id: string; broadcast_at: Date | null }>("select id, broadcast_at from votes order by id");
    expect(new Date(rows[0]!.broadcast_at!).toISOString()).toBe("2026-01-06T15:00:00.000Z");
    expect(rows[1]!.broadcast_at).not.toBeNull();
    expect(rows[2]!.broadcast_at).toBeNull();
    const { published, broadcaster } = recorder();
    expect(await publishFinals(db, broadcaster, new Date())).toEqual([]);
    expect(published).toEqual([]);
    await pg.close();
  });
});
