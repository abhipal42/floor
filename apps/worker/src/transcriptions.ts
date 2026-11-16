/**
 * Transcribed paper filings (lesson 73): a disclosure Floor can't read by machine, turned into rows
 * by reading the scan, kept in the repo as `apps/worker/transcriptions/<filing id>.json` so every
 * row is reviewable in a diff and reloadable, then loaded into the same tables a parsed filing uses.
 *
 * The filing is marked `transcribed_by`, which the API returns and the app labels as AI with the
 * link to the original. Loading replaces the filing's rows, so editing a file and reloading fixes
 * a misread. Only a filing the worker holds as paper can be filled this way: an electronic filing
 * is read from its own data, and a transcription must never stand in for that.
 */
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { Db } from "./db.js";

export const OWNERS = ["self", "spouse", "joint", "dependent"] as const;

export interface Transcription {
  filingId: string;
  member: string;
  sourceUrl: string;
  transcribedBy: "ai";
  transcribedOn: string;
  assets: { name: string; owner: (typeof OWNERS)[number] | null; value: string; type?: string; income?: string; incomeType?: string }[];
}

/** Throws on anything a file must not hold: a missing id, an unknown owner, an empty name or value. */
export function checkTranscription(raw: unknown, file: string): Transcription {
  const t = raw as Partial<Transcription>;
  const fail = (why: string) => {
    throw new Error(`${file}: ${why}`);
  };
  if (typeof t.filingId !== "string" || !/^(house|senate)-[\w-]+$/.test(t.filingId)) fail("filingId must be house-<DocID> or senate-<id>");
  if (`${t.filingId}.json` !== file) fail(`the file must be named ${t.filingId}.json`);
  if (typeof t.member !== "string" || !/^[A-Z]\d{6}$/.test(t.member)) fail("member must be a bioguide id");
  if (typeof t.sourceUrl !== "string" || !t.sourceUrl.startsWith("https://")) fail("sourceUrl must be the filing's https link");
  if (t.transcribedBy !== "ai") fail('transcribedBy must be "ai"');
  if (typeof t.transcribedOn !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(t.transcribedOn)) fail("transcribedOn must be YYYY-MM-DD");
  if (!Array.isArray(t.assets)) fail("assets must be a list");
  t.assets!.forEach((a, i) => {
    if (!a.name?.trim()) fail(`asset ${i + 1} has no name`);
    if (!a.value?.trim()) fail(`asset ${i + 1} has no value as filed`);
    if (a.owner !== null && !OWNERS.includes(a.owner)) fail(`asset ${i + 1} has an unknown owner "${a.owner}"`);
  });
  return t as Transcription;
}

export function readTranscriptions(dir: string): Transcription[] {
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .map((f) => checkTranscription(JSON.parse(readFileSync(join(dir, f), "utf8")), f));
}

export type LoadOutcome = "loaded" | "not-listed" | "not-paper";

/** Replaces one filing's rows with its transcription, in one statement. */
export async function loadTranscription(db: Db, t: Transcription): Promise<LoadOutcome> {
  const { rows } = await db.query<{ format: string | null; member_id: string | null; transcribed_by: string | null }>(
    "select format, member_id, transcribed_by from disclosure_filings where id = $1",
    [t.filingId],
  );
  const filing = rows[0];
  if (!filing) return "not-listed";
  if (filing.format !== "paper") return "not-paper";
  if (filing.member_id !== t.member) throw new Error(`${t.filingId} belongs to ${filing.member_id}, not ${t.member}`);
  await db.query(
    `with gone as (delete from disclosure_assets where filing_id = $1),
          added as (
            insert into disclosure_assets (filing_id, position, name, asset_type, owner, value_range, income_type, income_range)
            select $1, e.ord, e.a->>'name', e.a->>'type', e.a->>'owner', e.a->>'value', e.a->>'incomeType', e.a->>'income'
              from jsonb_array_elements($2::jsonb) with ordinality as e(a, ord))
     update disclosure_filings
        set parse_status = 'parsed', transcribed_by = $3, parse_error = null, parsed_at = now()
      where id = $1`,
    [t.filingId, JSON.stringify(t.assets), t.transcribedBy],
  );
  return "loaded";
}
