/**
 * Polls that name a member (the News page). One file per poll, `apps/worker/polls/<id>.json`,
 * added by hand from the pollster's own release and reviewed in a PR like the transcriptions: the
 * file is the record, the database a copy. Loading is idempotent, and the directory is the whole
 * set: a poll whose file is gone is deleted.
 *
 * A file holds the member ids it names, the pollster, the fielding dates, the population and sample
 * size as published, the positive and negative shares (and the rest, when the release gives it)
 * labelled as the pollster worded them, and the release's https url. The loader refuses a file
 * without a url, with an unknown field, or with shares adding up past 100.
 */
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { Db } from "./db.js";
import { withRetry } from "./rollcalls.js";

export interface PollShare {
  label: string;
  pct: number;
}

export interface PollFile {
  id: string;
  members: string[];
  pollster: string;
  fieldedFrom: string;
  fieldedTo: string;
  population: string;
  sampleSize: number | null;
  positive: PollShare;
  negative: PollShare;
  other: PollShare | null;
  url: string;
}

const KEYS = new Set(["members", "pollster", "fieldedFrom", "fieldedTo", "population", "sampleSize", "positive", "negative", "other", "url", "note"]);
const DAY = /^\d{4}-\d{2}-\d{2}$/;

/** Throws on anything a poll file must not hold. `file` is the file name; the id is its stem. */
export function checkPoll(raw: unknown, file: string): PollFile {
  const fail = (why: string): never => {
    throw new Error(`${file}: ${why}`);
  };
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) fail("must be a JSON object");
  const p = raw as Record<string, unknown>;
  for (const k of Object.keys(p)) if (!KEYS.has(k)) fail(`unknown field "${k}"`);
  const id = file.replace(/\.json$/, "");
  if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(id)) fail("the file name must be lower-case words joined by hyphens");
  if (typeof p.url !== "string" || !p.url.startsWith("https://")) fail("url must be the release's https link");
  if (!Array.isArray(p.members) || !p.members.length || !p.members.every((m) => typeof m === "string" && /^[A-Z]\d{6}$/.test(m))) {
    fail("members must be a non-empty list of Bioguide ids");
  }
  const text = (k: string) => (typeof p[k] === "string" && (p[k] as string).trim() ? (p[k] as string).trim() : fail(`${k} is required`));
  const pollster = text("pollster");
  const population = text("population");
  const fieldedFrom = text("fieldedFrom");
  const fieldedTo = text("fieldedTo");
  if (!DAY.test(fieldedFrom) || !DAY.test(fieldedTo) || fieldedFrom > fieldedTo) fail("fieldedFrom and fieldedTo must be YYYY-MM-DD, in order");
  if (p.sampleSize !== null && (!Number.isInteger(p.sampleSize) || (p.sampleSize as number) <= 0)) fail("sampleSize must be a whole number or null");
  const share = (k: string, optional: boolean): PollShare | null => {
    const s = p[k];
    if ((s === null || s === undefined) && optional) return null;
    const v = s as Partial<PollShare>;
    if (!v || typeof v.label !== "string" || !v.label.trim() || typeof v.pct !== "number" || !(v.pct >= 0 && v.pct <= 100)) {
      return fail(`${k} must be {label, pct} with pct 0-100`);
    }
    return { label: v.label.trim(), pct: v.pct };
  };
  const positive = share("positive", false)!;
  const negative = share("negative", false)!;
  const other = share("other", true);
  if (positive.pct + negative.pct + (other?.pct ?? 0) > 100) fail("shares add up to more than 100");
  return {
    id,
    members: [...new Set(p.members as string[])],
    pollster,
    fieldedFrom,
    fieldedTo,
    population,
    sampleSize: (p.sampleSize as number | null) ?? null,
    positive,
    negative,
    other,
    url: p.url as string,
  };
}

export function readPolls(dir: string): PollFile[] {
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .map((f) => checkPoll(JSON.parse(readFileSync(join(dir, f), "utf8")), f));
}

/**
 * Replaces the polls table with these files: upserts each, replaces its members, deletes polls not
 * among them. A member id Floor does not hold is skipped and returned (a typo, or someone not yet
 * loaded), so one bad id never blocks the rest.
 */
export async function loadPolls(db: Db, polls: PollFile[]): Promise<{ polls: number; unknownMembers: string[] }> {
  const { rows: known } = await db.query<{ bioguide_id: string }>("select bioguide_id from members where bioguide_id = any($1::text[])", [
    [...new Set(polls.flatMap((p) => p.members))],
  ]);
  const have = new Set(known.map((r) => r.bioguide_id));
  const unknownMembers = [...new Set(polls.flatMap((p) => p.members).filter((m) => !have.has(m)))];
  const rows = polls.map((p) => ({
    id: p.id,
    pollster: p.pollster,
    fielded_from: p.fieldedFrom,
    fielded_to: p.fieldedTo,
    population: p.population,
    sample_size: p.sampleSize,
    positive_label: p.positive.label,
    positive_pct: p.positive.pct,
    negative_label: p.negative.label,
    negative_pct: p.negative.pct,
    other_label: p.other?.label ?? null,
    other_pct: p.other?.pct ?? null,
    url: p.url,
  }));
  const links = polls.flatMap((p) => p.members.filter((m) => have.has(m)).map((m) => ({ poll_id: p.id, member_id: m })));
  await withRetry(() =>
    db.query(
      `with gone as (delete from polls where not (id = any($2::text[]))),
            up as (
              insert into polls (id, pollster, fielded_from, fielded_to, population, sample_size, positive_label, positive_pct,
                                 negative_label, negative_pct, other_label, other_pct, url)
              select * from jsonb_to_recordset($1::jsonb) as x(id text, pollster text, fielded_from date, fielded_to date,
                population text, sample_size int, positive_label text, positive_pct numeric, negative_label text,
                negative_pct numeric, other_label text, other_pct numeric, url text)
              on conflict (id) do update set pollster = excluded.pollster, fielded_from = excluded.fielded_from,
                fielded_to = excluded.fielded_to, population = excluded.population, sample_size = excluded.sample_size,
                positive_label = excluded.positive_label, positive_pct = excluded.positive_pct,
                negative_label = excluded.negative_label, negative_pct = excluded.negative_pct,
                other_label = excluded.other_label, other_pct = excluded.other_pct, url = excluded.url
              returning id)
       select count(*)::int as n from up`,
      [JSON.stringify(rows), polls.map((p) => p.id)],
    ),
  );
  // Two statements: a delete and an insert of the same key in one statement see the same snapshot.
  await withRetry(() => db.query("delete from poll_members where poll_id = any($1::text[])", [polls.map((p) => p.id)]));
  await withRetry(() =>
    db.query(
      `insert into poll_members (poll_id, member_id)
       select poll_id, member_id from jsonb_to_recordset($1::jsonb) as x(poll_id text, member_id text)
       on conflict do nothing`,
      [JSON.stringify(links)],
    ),
  );
  return { polls: polls.length, unknownMembers };
}
