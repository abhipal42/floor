import { list, parseMeasureRef, type CongressGet, type Json } from "./bills.js";
import { startRun, type Db } from "./db.js";
import { withRetry } from "./rollcalls.js";

/**
 * A nomination's id, following the bill convention: `119-pn-1905`, or `119-pn-1093-3`
 * when the Senate split the nomination into parts and acted on one of them.
 */
export const nominationId = (congress: number, number: number, part: number | null) =>
  `${congress}-pn-${number}${part ? `-${part}` : ""}`;

/** Congress.gov addresses a part as its own nomination: `/nomination/119/1093-3`. */
export const nominationPath = (congress: number, number: number, part: number | null) =>
  `/nomination/${congress}/${number}${part ? `-${part}` : ""}`;

export interface NominationRow {
  id: string;
  congress: number;
  number: number;
  part: number;
  citation: string;
  nominee_name: string | null;
  position_title: string | null;
  organization: string | null;
  description: string | null;
  nominee_count: number | null;
  is_military: boolean;
  received_on: string | null;
  latest_action_on: string | null;
  latest_action_text: string | null;
  source_updated_at: string | null;
}

/**
 * Pulls the nominee out of Congress.gov's one-sentence description, which civilian nominations
 * write as "Matthew R. Byrne, of Ohio, to be United States District Judge …, vice Michael H.
 * Watson, retired."
 *
 * Military nominations have no description at all: they promote officers in bulk ("The following
 * named officer for appointment to the permanent grade indicated in the Regular Air Force …"),
 * so there is no single nominee to name and this returns null. Clients fall back to the position
 * and organization in that case.
 */
export function parseNomineeName(description: string | null): string | null {
  if (!description) return null;
  const d = description.trim();
  if (/^the following named/i.test(d)) return null;
  // "Name, of State, to be Position" first; a few descriptions omit the home state.
  const m = /^(.+?),\s+of\s+[^,]+,\s+to\s+be\s/i.exec(d) ?? /^(.+?),\s+to\s+be\s/i.exec(d);
  const name = m?.[1]?.trim();
  return name && name.length <= 120 ? name : null;
}

export function toNominationRow(nominationJson: Json): NominationRow {
  const n = nominationJson["nomination"] as Json;
  const congress = Number(n["congress"]);
  const number = Number(n["number"]);
  // partNumber is a zero-padded string: "00" when the nomination was never split, "03" for part 3.
  const part = Number(n["partNumber"] ?? 0) || 0;
  const nominees = list(n["nominees"]);
  const first = nominees[0];
  const latest = n["latestAction"] as Json | undefined;
  const type = n["nominationType"] as Json | undefined;
  const description = String(n["description"] ?? "").trim() || null;
  const count = nominees.reduce((sum, x) => sum + (Number(x["nomineeCount"]) || 0), 0);

  return {
    id: nominationId(congress, number, part),
    congress,
    number,
    part,
    citation: String(n["citation"] ?? "") || `PN${number}${part ? `-${part}` : ""}`,
    nominee_name: parseNomineeName(description),
    position_title: first ? String(first["positionTitle"] ?? "") || null : null,
    organization: first ? String(first["organization"] ?? "") || null : null,
    description,
    nominee_count: count || null,
    is_military: type?.["isMilitary"] === true,
    received_on: (n["receivedDate"] as string | undefined) ?? null,
    latest_action_on: (latest?.["actionDate"] as string | undefined) ?? null,
    latest_action_text: (latest?.["text"] as string | undefined) ?? null,
    source_updated_at: (n["updateDate"] as string | undefined) ?? null,
  };
}

export async function upsertNomination(db: Db, nom: NominationRow): Promise<void> {
  await db.query(
    `insert into nominations (id, congress, number, part, citation, nominee_name, position_title, organization,
                              description, nominee_count, is_military, received_on, latest_action_on,
                              latest_action_text, source_updated_at, updated_at)
     values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, now())
     on conflict (id) do update set
       citation = excluded.citation, nominee_name = excluded.nominee_name,
       position_title = excluded.position_title, organization = excluded.organization,
       description = excluded.description, nominee_count = excluded.nominee_count,
       is_military = excluded.is_military, received_on = excluded.received_on,
       latest_action_on = excluded.latest_action_on, latest_action_text = excluded.latest_action_text,
       source_updated_at = excluded.source_updated_at, updated_at = now()`,
    [
      nom.id, nom.congress, nom.number, nom.part, nom.citation, nom.nominee_name, nom.position_title,
      nom.organization, nom.description, nom.nominee_count, nom.is_military, nom.received_on,
      nom.latest_action_on, nom.latest_action_text, nom.source_updated_at,
    ],
  );
}

/**
 * Loads every nomination that a stored vote refers to but that isn't linked yet, then links those
 * votes to it. Roughly a quarter of Senate roll calls are on nominations ("PN1905", "PN1093-3"),
 * and without this they have no subject to show.
 *
 * With `refresh`, re-fetches nominations already stored instead, leaving the vote links alone.
 */
export async function ingestVotedNominations(
  db: Db,
  get: CongressGet,
  opts: { limit?: number; refresh?: boolean; log?: (msg: string) => void } = {},
): Promise<{ nominations: number; linkedVotes: number; failed: number }> {
  const finish = await startRun(db, "nominations");
  let nominations = 0;
  let linkedVotes = 0;
  let failed = 0;
  try {
    // Several votes (motion to proceed, cloture, confirmation) cite the same nomination.
    const byNomination = new Map<string, { congress: number; number: number; part: number; refs: string[] }>();
    if (opts.refresh) {
      const { rows } = await db.query<{ id: string; congress: number; number: number; part: number }>(
        "select id, congress, number, part from nominations order by congress, number, part",
      );
      for (const r of rows) byNomination.set(r.id, { congress: r.congress, number: r.number, part: r.part, refs: [] });
    } else {
      const { rows } = await db.query<{ congress: number; bill_ref: string }>(
        `select distinct congress, bill_ref from votes
          where nomination_id is null and bill_ref is not null order by congress, bill_ref`,
      );
      for (const r of rows) {
        const ref = parseMeasureRef(r.bill_ref);
        if (ref?.kind !== "nomination") continue;
        const id = nominationId(r.congress, ref.number, ref.part);
        const entry =
          byNomination.get(id) ?? { congress: r.congress, number: ref.number, part: ref.part ?? 0, refs: [] };
        entry.refs.push(r.bill_ref);
        byNomination.set(id, entry);
      }
    }

    for (const [id, n] of byNomination) {
      if (opts.limit !== undefined && nominations >= opts.limit) break;
      try {
        const nomination = await get(nominationPath(n.congress, n.number, n.part));
        await withRetry(() => upsertNomination(db, toNominationRow(nomination)));
        // A refresh has no refs to match: the votes are already linked, only the row is being rebuilt.
        if (n.refs.length > 0) {
          const { rows: linked } = await db.query<{ n: number }>(
            `with u as (update votes set nomination_id = $1 where congress = $2 and bill_ref = any($3::text[]) returning 1)
             select count(*)::int as n from u`,
            [id, n.congress, n.refs],
          );
          linkedVotes += linked[0]?.n ?? 0;
          opts.log?.(`${id}: linked ${linked[0]?.n ?? 0} votes`);
        } else {
          opts.log?.(`${id}: refreshed`);
        }
        nominations++;
      } catch (err) {
        // One missing or malformed nomination shouldn't stop the rest; it stays unlinked and is retried next run.
        failed++;
        opts.log?.(`${id}: ${err instanceof Error ? err.message : String(err)}`);
      }
    }
    // Per-nomination failures are counted, not reported as the run's error (lesson 38).
    await finish(nominations, undefined, failed);
  } catch (err) {
    await finish(nominations, err instanceof Error ? err.message : String(err), failed);
    throw err;
  }
  return { nominations, linkedVotes, failed };
}
