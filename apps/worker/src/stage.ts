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

/**
 * Re-derives and stores the stage of these bills: from their stored actions (only the ones
 * `deriveStage` keys on) and final votes once their details are fetched, otherwise from the list's
 * latest action (`listStage`, usually null). Returns how many changed.
 */
export async function restage(db: Db, ids: string[]): Promise<number> {
  if (ids.length === 0) return 0;
  const { rows } = await db.query<{
    id: string;
    bill_type: string;
    origin_chamber: "house" | "senate" | null;
    stage: Stage | null;
    fetched: boolean;
    latest_action_text: string | null;
    actions: { text: string }[];
    votes: { chamber: "house" | "senate"; question: string; result: string | null }[];
  }>(
    `select b.id, b.bill_type, b.origin_chamber, b.stage, b.details_fetched_at is not null as fetched, b.latest_action_text,
            coalesce((select jsonb_agg(jsonb_build_object('text', a.text)) from actions a
                       where a.bill_id = b.id
                         and a.text ~* '^(passed/agreed|failed of passage|became (public|private) law|signed by president|presented to president|vetoed by president|pocket veto|resolving differences)'),
                     '[]'::jsonb) as actions,
            coalesce((select jsonb_agg(jsonb_build_object('chamber', v.chamber, 'question', v.question, 'result', v.result))
                        from votes v where v.bill_id = b.id and v.state = 'final'),
                     '[]'::jsonb) as votes
       from bills b where b.id = any($1::text[])`,
    [ids],
  );
  const changed = rows
    .map((r) => ({
      id: r.id,
      stage: r.fetched
        ? deriveStage({ type: r.bill_type, originChamber: r.origin_chamber, actions: r.actions, votes: r.votes })
        : listStage(r.bill_type, r.latest_action_text),
      was: r.stage,
    }))
    .filter((r) => r.stage !== r.was)
    .map(({ id, stage }) => ({ id, stage }));
  if (changed.length > 0) {
    await withRetry(() =>
      db.query(
        `update bills b set stage = x.stage from jsonb_to_recordset($1::jsonb) as x(id text, stage text) where b.id = x.id`,
        [JSON.stringify(changed)],
      ),
    );
  }
  return changed.length;
}
