/**
 * Where a bill stands on the road to law, stored in `bills.stage` so a list of bills never has to
 * fetch actions per row.
 *
 * The same reading as the iOS Bill screen's "Path to law" (`BillProgress` and `LawLevels` in
 * FloorKit): it keys on Congress.gov's own summary markers — `Introduced in House`, `Passed/agreed
 * to in Senate: …`, `Failed of passage/not agreed to in House …`, `Became Public Law No: …` — which
 * are far steadier than the clerks' free-text actions, plus the three presidential actions
 * (`Presented to President.`, `Vetoed by President.`, `Signed by President.`), which Congress.gov
 * records under the House as well as as markers. And as on that screen, a chamber's own passage
 * roll call settles that chamber when the marker has not landed yet: roll calls arrive within the
 * hour, while a bill's actions lag them by a day or more (H.R. 1013 passed the House 295–128 on
 * 2026-11-11 and its actions still said only "Introduced in House" two days later).
 *
 * "Stalled" is not a stage: it is "no action in 90 days", which changes with the calendar rather
 * than with the bill, so the API computes it at query time from `latest_action_on`.
 */

import type { Db } from "./db.js";
import { withRetry } from "./rollcalls.js";

export const STAGES = [
  "introduced",
  "passed_house",
  "passed_senate",
  "passed_both",
  "to_president",
  "law",
  "vetoed",
  "failed",
  "adopted",
] as const;

export type Stage = (typeof STAGES)[number];

export interface StageInput {
  /** hr, s, hjres, sjres, hres, sres, hconres, sconres. */
  type: string;
  originChamber: "house" | "senate" | null;
  actions: { text: string }[];
  /** Final roll calls on this bill. */
  votes: { chamber: "house" | "senate"; question: string; result: string | null }[];
}

const name = (chamber: "house" | "senate") => (chamber === "house" ? "House" : "Senate");

/** A simple resolution binds one chamber; a concurrent one binds both but is never presented. */
const canBecomeLaw = (type: string) => ["hr", "s", "hjres", "sjres"].includes(type);
const isSimpleResolution = (type: string) => ["hres", "sres"].includes(type);

/**
 * Whether a roll call's result says it carried. Rejection words first: "Not Agreed to" contains
 * "Agreed", as the Swift `recordedOutcome` notes.
 */
export function carried(result: string | null): boolean {
  if (!result) return false;
  const r = result.toLowerCase();
  if (/rejected|failed|defeated|not agreed|sustained/.test(r)) return false;
  return /passed|agreed to/.test(r);
}

/**
 * Whether a roll call carried the measure itself in its chamber, as opposed to a procedural vote
 * on the way. Broader than the Swift `isFinalPassage` on one point: the House's suspension
 * questions ("On Motion to Suspend the Rules and Pass, as Amended", "… and Agree") carry the
 * measure but never say "passage".
 */
export function isPassageVote(v: { question: string; result: string | null }): boolean {
  if (!carried(v.result)) return false;
  const q = v.question.toLowerCase();
  if (/veto|objections of the president/.test(q)) return false;
  // A carried motion to table, refer, commit, recommit or reconsider disposes of something else
  // ("On Motion to Table the Motion to Concur"): read it before the words it mentions.
  if (/\b(table|refer|commit|recommit|reconsider)\b/.test(q)) return false;
  return (
    q.includes("passage") ||
    q.includes("concur") ||
    /suspend the rules and (pass|agree)/.test(q) ||
    q.includes("agreeing to the resolution") ||
    /^on the (joint |concurrent )?resolution\b/.test(q)
  );
}

export function deriveStage(input: StageInput): Stage {
  const texts = input.actions.map((a) => a.text.trim());
  const starts = (prefix: string) => texts.some((t) => t.toLowerCase().startsWith(prefix.toLowerCase()));
  const origin = input.originChamber ?? (input.type.startsWith("s") ? "senate" : "house");
  const other = origin === "house" ? "senate" : "house";

  const passed = (chamber: "house" | "senate") =>
    starts(`Passed/agreed to in ${name(chamber)}`) ||
    input.votes.some((v) => v.chamber === chamber && isPassageVote(v));
  // A failed motion to suspend the rules is not a verdict on the measure: it needed two thirds, and
  // the House can still pass it under a rule (H.R. 9238 failed 198–218 under suspension; S. 2503
  // failed 264–133, short of two thirds, after passing the Senate). So it leaves the stage where it was.
  const failed = (chamber: "house" | "senate") =>
    texts.some(
      (t) => t.toLowerCase().startsWith(`failed of passage/not agreed to in ${name(chamber).toLowerCase()}`) && !/suspend the rules/i.test(t),
    );

  if (canBecomeLaw(input.type)) {
    if (starts("Became Public Law") || starts("Became Private Law") || starts("Signed by President")) return "law";
    // A veto that was overridden ends in "Became Public Law", caught above.
    if (starts("Vetoed by President") || starts("Pocket Vetoed")) return "vetoed";
    if (starts("Presented to President")) return "to_president";
  }

  if (isSimpleResolution(input.type)) {
    if (passed(origin)) return "adopted";
    return failed(origin) ? "failed" : "introduced";
  }

  const passedOrigin = passed(origin);
  const passedOther = passed(other);
  if (passedOrigin && passedOther) {
    if (canBecomeLaw(input.type)) return "passed_both";
    // A concurrent resolution is done once both chambers agree to one text. One chamber agreeing
    // "with an amendment" leaves it open until the other agrees to that amendment — and agreeing to
    // it "with an amendment" of its own sends it back again, so that is not the end either.
    const withAmendment = (t: string) => /with an amendment/i.test(t);
    const amended =
      texts.some((t) => /^Passed\/agreed to in/i.test(t) && withAmendment(t)) ||
      input.votes.some((v) => isPassageVote(v) && withAmendment(v.question));
    const resolved = texts.some((t) => /^Resolving differences/i.test(t) && /\bagree/i.test(t) && !withAmendment(t));
    return !amended || resolved ? "adopted" : "passed_both";
  }
  // Failed in a chamber it has not (also) passed: a suspension that failed and then passed under a
  // rule has a pass marker for the same chamber, so it is not failed.
  if ((failed(origin) && !passedOrigin) || (passedOrigin && failed(other) && !passedOther)) return "failed";
  if (passedOrigin || passedOther) return passedOrigin ? `passed_${origin}` : `passed_${other}`;
  return "introduced";
}

/** The settled stages: nothing more will happen to the measure. Used for "moving" and "stalled". */
export const SETTLED: readonly Stage[] = ["law", "vetoed", "failed", "adopted"];

/**
 * The stage of a bill known only from the list (its details not fetched yet), where the list's one
 * latest action settles it beyond doubt: "Became Public Law No: 119-98." Anything else — "Passed
 * Senate", "Referred to …" — says too little about the other chamber or what came before, so the
 * stage stays null (the API's "not staged yet") until the details are fetched.
 */
export function listStage(type: string, latestActionText: string | null): Stage | null {
  if (!canBecomeLaw(type) || !latestActionText) return null;
  return /^Became (Public|Private) Law No/i.test(latestActionText.trim()) ? "law" : null;
}

/** Which bills `stageUnstaged` can stage: fetched ones, and list-only ones `listStage` settles. */
export const STAGEABLE = `(b.details_fetched_at is not null
  or (b.bill_type in ('hr', 's', 'hjres', 'sjres') and b.latest_action_text ~* '^\\s*became (public|private) law no'))`;

// MARK: - Stage events (bill alerts)

/** What `bill_events.kind` records. `floor_scheduled` and `committee` come from billevents.ts. */
export type BillEventKind = "floor_scheduled" | "chamber_passed" | "chamber_failed" | "to_president" | "law" | "vetoed" | "committee";

/**
 * A step is news only while it is recent: a stage that changes because a fix to `deriveStage`
 * re-read a year-old bill, or a bill whose details were never fetched until now, is a correction,
 * not something to buzz a phone about. Recent means the bill's latest action, or a roll call on
 * it, is within this many days.
 */
export const EVENT_FRESH_DAYS = 14;

type Chamber = "house" | "senate";

/** The chambers a stage says the measure has passed (or agreed to). */
function passedChambers(stage: Stage | null, type: string, origin: Chamber): Set<Chamber> {
  switch (stage) {
    case "passed_house":
      return new Set(["house"]);
    case "passed_senate":
      return new Set(["senate"]);
    case "passed_both":
    case "to_president":
    case "law":
    case "vetoed":
      return new Set(["house", "senate"]);
    case "adopted":
      return isSimpleResolution(type) ? new Set([origin]) : new Set(["house", "senate"]);
    default:
      return new Set();
  }
}

/**
 * The steps a stage change is, for alerts. Only forward moves count, and only from a stage the
 * bill already had: a first staging (`was` null) is the backfill, not news. A jump straight to the
 * President, law or a veto is that one step, not the chamber passages it implies — one alert, not
 * three. A failure is in the origin chamber unless the bill had already passed it.
 */
export function stageEvents(input: {
  type: string;
  originChamber: Chamber | null;
  was: Stage | null;
  stage: Stage | null;
}): { kind: BillEventKind; chamber: Chamber | null }[] {
  const { was, stage, type } = input;
  if (was === null || stage === null || was === stage) return [];
  const origin = input.originChamber ?? (type.startsWith("s") ? "senate" : "house");
  if (stage === "law") return [{ kind: "law", chamber: null }];
  if (stage === "vetoed") return was === "law" ? [] : [{ kind: "vetoed", chamber: null }];
  if (stage === "to_president") return ["law", "vetoed"].includes(was) ? [] : [{ kind: "to_president", chamber: null }];
  if (SETTLED.includes(was) && was !== "failed") return [];
  if (stage === "failed") {
    const passed = passedChambers(was, type, origin);
    return [{ kind: "chamber_failed", chamber: passed.has(origin) ? (origin === "house" ? "senate" : "house") : origin }];
  }
  if (was === "to_president") return [];
  const before = passedChambers(was, type, origin);
  return [...passedChambers(stage, type, origin)]
    .filter((c) => !before.has(c))
    .sort()
    .map((chamber) => ({ kind: "chamber_passed" as const, chamber }));
}

interface StagedVote {
  id: string;
  chamber: Chamber;
  question: string;
  result: string | null;
  yea: number;
  nay: number;
  occurred_at: string | null;
}

/**
 * The roll call that settled a chamber step, for "with the score": the latest passage vote in that
 * chamber for a pass, the latest vote that did not carry for a failure. Null when the step came
 * from the actions alone (a voice vote, unanimous consent).
 */
export function scoreFor(kind: BillEventKind, chamber: Chamber | null, votes: StagedVote[]): StagedVote | null {
  if (!chamber || (kind !== "chamber_passed" && kind !== "chamber_failed")) return null;
  const mine = votes
    .filter((v) => v.chamber === chamber && (kind === "chamber_passed" ? isPassageVote(v) : !carried(v.result)))
    .sort((a, b) => String(b.occurred_at ?? "").localeCompare(String(a.occurred_at ?? "")));
  return mine[0] ?? null;
}

/**
 * Re-derives and stores the stage of these bills: from their stored actions (only the ones
 * `deriveStage` keys on) and final votes once their details are fetched, otherwise from the list's
 * latest action (`listStage`, usually null). Returns how many changed. Each recent forward move is
 * recorded in `bill_events` (`stageEvents`) for the bill alerts; the live worker sends them.
 */
export async function restage(db: Db, ids: string[], now: Date = new Date()): Promise<number> {
  if (ids.length === 0) return 0;
  const { rows } = await db.query<{
    id: string;
    bill_type: string;
    origin_chamber: "house" | "senate" | null;
    stage: Stage | null;
    fetched: boolean;
    latest_action_text: string | null;
    latest_action_on: string | null;
    actions: { text: string }[];
    votes: StagedVote[];
  }>(
    `select b.id, b.bill_type, b.origin_chamber, b.stage, b.details_fetched_at is not null as fetched, b.latest_action_text,
            to_char(b.latest_action_on, 'YYYY-MM-DD') as latest_action_on,
            coalesce((select jsonb_agg(jsonb_build_object('text', a.text)) from actions a
                       where a.bill_id = b.id
                         and a.text ~* '^(passed/agreed|failed of passage|became (public|private) law|signed by president|presented to president|vetoed by president|pocket veto|resolving differences)'),
                     '[]'::jsonb) as actions,
            coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'chamber', v.chamber, 'question', v.question, 'result', v.result,
                                                          'yea', v.yea, 'nay', v.nay, 'occurred_at', v.occurred_at))
                        from votes v where v.bill_id = b.id and v.state = 'final'),
                     '[]'::jsonb) as votes
       from bills b where b.id = any($1::text[])`,
    [ids],
  );
  const changed = rows
    .map((r) => ({
      row: r,
      id: r.id,
      stage: r.fetched
        ? deriveStage({ type: r.bill_type, originChamber: r.origin_chamber, actions: r.actions, votes: r.votes })
        : listStage(r.bill_type, r.latest_action_text),
      was: r.stage,
    }))
    .filter((r) => r.stage !== r.was);
  if (changed.length > 0) {
    await withRetry(() =>
      db.query(
        `update bills b set stage = x.stage from jsonb_to_recordset($1::jsonb) as x(id text, stage text) where b.id = x.id`,
        [JSON.stringify(changed.map(({ id, stage }) => ({ id, stage })))],
      ),
    );
    const since = now.getTime() - EVENT_FRESH_DAYS * 86_400_000;
    const events = changed.flatMap(({ row, id, stage, was }) => {
      const recent =
        (row.latest_action_on !== null && Date.parse(`${row.latest_action_on}T23:59:59Z`) >= since) ||
        row.votes.some((v) => v.occurred_at !== null && Date.parse(v.occurred_at) >= since);
      if (!recent) return [];
      return stageEvents({ type: row.bill_type, originChamber: row.origin_chamber, was, stage }).map((e) => {
        const score = scoreFor(e.kind, e.chamber, row.votes);
        return {
          bill_id: id,
          kind: e.kind,
          chamber: e.chamber,
          detail: score ? { voteId: score.id, yea: score.yea, nay: score.nay } : {},
          dedupe_key: `${id}:${e.kind}:${e.chamber ?? "-"}`,
        };
      });
    });
    if (events.length > 0) {
      await withRetry(() =>
        db.query(
          `insert into bill_events (bill_id, kind, chamber, detail, dedupe_key, created_at)
           select bill_id, kind, chamber::chamber, detail, dedupe_key, $2::timestamptz
             from jsonb_to_recordset($1::jsonb) as x(bill_id text, kind text, chamber text, detail jsonb, dedupe_key text)
           on conflict (dedupe_key) do nothing`,
          [JSON.stringify(events), now.toISOString()],
        ),
      );
    }
  }
  return changed.length;
}
