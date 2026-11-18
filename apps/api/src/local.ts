import { z } from "@hono/zod-openapi";
import { JURISDICTIONS, type JurisdictionEntry } from "./jurisdictions.js";
import { HeadlineSchema, type Headline } from "./news.js";

/*
 * The Local tab: each state's and city's hub (apps/worker local.ts fills it), and the user's state
 * legislators from Open States.
 */

export const LOCAL_ENACTED_DAYS = 30;
export const LOCAL_COVERAGE_DAYS = 90;
export const LOCAL_NEWS_DAYS = 7;
export const LOCAL_MAX_ITEMS = 20;
/** The worker writes once a day. */
export const LOCAL_CACHE_CONTROL = "public, max-age=600, s-maxage=1800, stale-while-revalidate=3600";

export const JurisdictionSchema = z
  .object({
    id: z.string().openapi({ example: "ny" }),
    kind: z.enum(["state", "city"]).openapi("JurisdictionKind"),
    name: z.string().openapi({ example: "New York State" }),
    state: z.string().openapi({ example: "NY", description: "Postal code" }),
    placeGeoid: z.string().nullable().openapi({ example: "3651000", description: "Census place GEOID, for a city" }),
    coverage: z.enum(["records", "pending", "news_only"]).openapi("LocalCoverage", {
      description: "records: items from the last 90 days. news_only: no records source Floor can read. pending: a source, but nothing yet",
    }),
  })
  .openapi("Jurisdiction");

export const LocalItemSchema = z
  .object({
    id: z.string(),
    identifier: z.string().openapi({ example: "CB 121276" }),
    title: z.string(),
    summary: z.string().nullable(),
    body: z.string().openapi({ example: "City Council" }),
    date: z.string().openapi({ example: "2026-11-13" }),
    status: z.enum(["signed", "became_law", "passed", "awaiting_governor"]).openapi("LocalItemStatus"),
    yes: z.number().int().nullable(),
    no: z.number().int().nullable(),
    url: z.string().nullable(),
  })
  .openapi("LocalItem");

export const LocalHubSchema = z
  .object({
    jurisdiction: JurisdictionSchema,
    updatedAt: z.string().nullable().openapi({ description: "The worker's last successful check of this jurisdiction; null = never" }),
    enacted: z.array(LocalItemSchema).openapi({
      description: "State: signed into law or became law. City: passed by the council. Last 30 days, newest first, at most 20",
    }),
    waiting: z.array(LocalItemSchema).openapi({ description: "State only: passed both chambers, no executive action yet. [] for cities" }),
    news: z.array(HeadlineSchema).openapi({ description: "Last 7 days, newest first, at most 20; tone null (not AI-read)" }),
  })
  .openapi("LocalHub");

export const LocalListSchema = z.object({ jurisdictions: z.array(JurisdictionSchema) }).openapi("LocalList");

export const StateLegislatorSchema = z
  .object({
    id: z.string().openapi({ example: "ocd-person/adb58f21-f2fd-4830-85b6-f490b0867d14" }),
    name: z.string(),
    party: z.string().openapi({ example: "Democratic" }),
    chamber: z.enum(["upper", "lower"]).openapi("StateChamber"),
    district: z.string().openapi({ example: "27" }),
    photoUrl: z.string().nullable(),
    url: z.string().nullable().openapi({ description: "Their Open States page" }),
  })
  .openapi("StateLegislator");

export const StateLegislatorsSchema = z.object({ legislators: z.array(StateLegislatorSchema) }).openapi("StateLegislators");

export type Jurisdiction = z.infer<typeof JurisdictionSchema>;
export type LocalItem = z.infer<typeof LocalItemSchema>;
export type LocalHub = z.infer<typeof LocalHubSchema>;
export type StateLegislator = z.infer<typeof StateLegislatorSchema>;

export interface LocalRepository {
  /** Jurisdiction ids with at least one item dated on or after `since` (YYYY-MM-DD). */
  withRecords(since: string): Promise<Set<string>>;
  /** One jurisdiction's items dated on or after `since`, newest first. */
  items(jurisdictionId: string, since: string): Promise<LocalItem[]>;
  /** Its headlines from `from` on, newest first, at most `limit`. */
  news(jurisdictionId: string, from: Date, limit: number): Promise<Headline[]>;
  /** The worker's latest check of it (records or news), or null. */
  updatedAt(jurisdictionId: string): Promise<string | null>;
}

export const NO_LOCAL: LocalRepository = {
  withRecords: async () => new Set(),
  items: async () => [],
  news: async () => [],
  updatedAt: async () => null,
};

export function toJurisdiction(j: JurisdictionEntry, withRecords: Set<string>): Jurisdiction {
  return {
    id: j.id,
    kind: j.kind,
    name: j.name,
    state: j.state,
    placeGeoid: j.placeGeoid,
    coverage: !j.records ? "news_only" : withRecords.has(j.id) ? "records" : "pending",
  };
}

export const listJurisdictions = (withRecords: Set<string>) => JURISDICTIONS.map((j) => toJurisdiction(j, withRecords));

const day = (d: Date) => d.toISOString().slice(0, 10);

/** A hub from the repository: items split into enacted and waiting by the jurisdiction's kind. */
export async function localHub(repo: LocalRepository, j: JurisdictionEntry, now: Date): Promise<LocalHub> {
  const since = (n: number) => day(new Date(now.getTime() - n * 86_400_000));
  const [withRecords, items, news, updatedAt] = await Promise.all([
    repo.withRecords(since(LOCAL_COVERAGE_DAYS)),
    repo.items(j.id, since(LOCAL_COVERAGE_DAYS)),
    repo.news(j.id, new Date(now.getTime() - LOCAL_NEWS_DAYS * 86_400_000), LOCAL_MAX_ITEMS),
    repo.updatedAt(j.id),
  ]);
  const recent = since(LOCAL_ENACTED_DAYS);
  const enacted = items.filter((i) =>
    j.kind === "state" ? (i.status === "signed" || i.status === "became_law") && i.date >= recent : i.status === "passed" && i.date >= recent,
  );
  const waiting = j.kind === "state" ? items.filter((i) => i.status === "awaiting_governor") : [];
  return {
    jurisdiction: toJurisdiction(j, withRecords),
    updatedAt,
    enacted: enacted.slice(0, LOCAL_MAX_ITEMS),
    waiting: waiting.slice(0, LOCAL_MAX_ITEMS),
    news: news.slice(0, LOCAL_MAX_ITEMS).map((h) => ({ ...h, tone: null, storyId: null })),
  };
}

// ---------------------------------------------------------------------------------------------
// State legislators: Open States /people, cached a day

export const OPENSTATES_PEOPLE = "https://v3.openstates.org/people";
export const LEGISLATORS_TTL_MS = 24 * 60 * 60 * 1000;

export type LegislatorLookup = (state: string, chamber: "upper" | "lower", district: string) => Promise<StateLegislator[]>;

export const peopleUrl = (state: string, chamber: "upper" | "lower", district: string) =>
  `${OPENSTATES_PEOPLE}?jurisdiction=${encodeURIComponent(`ocd-jurisdiction/country:us/state:${state.toLowerCase()}/government`)}` +
  `&org_classification=${chamber}&district=${encodeURIComponent(district)}&per_page=10`;

interface OsPerson {
  id: string;
  name: string;
  party?: string;
  image?: string;
  openstates_url?: string;
  current_role?: { org_classification?: string; district?: string | number };
}

/** Open States' people as legislators; anyone whose current role is not that chamber is dropped. */
export function parsePeople(json: unknown, chamber: "upper" | "lower", district: string): StateLegislator[] {
  const results = ((json as { results?: OsPerson[] })?.results ?? []) as OsPerson[];
  return results
    .filter((p) => p.current_role?.org_classification === chamber)
    .map((p) => ({
      id: p.id,
      name: p.name,
      party: p.party ?? "",
      chamber,
      district: String(p.current_role?.district ?? district),
      photoUrl: p.image?.trim() || null,
      url: p.openstates_url?.trim() || null,
    }));
}

/**
 * Looks legislators up in Open States with the key in the X-API-KEY header (never a URL), caching
 * each answer for a day in this instance. An error answers [] and is not cached; it never names
 * the key. Without a key there is no lookup: callers use `NO_LEGISLATORS`.
 */
export function openStatesLegislators(
  key: string,
  opts: { fetch?: typeof fetch; now?: () => number; log?: (msg: string) => void } = {},
): LegislatorLookup {
  const cache = new Map<string, { at: number; value: StateLegislator[] }>();
  const doFetch = opts.fetch ?? fetch;
  const now = opts.now ?? Date.now;
  return async (state, chamber, district) => {
    const k = `${state}|${chamber}|${district}`;
    const hit = cache.get(k);
    if (hit && now() - hit.at < LEGISLATORS_TTL_MS) return hit.value;
    try {
      const res = await doFetch(peopleUrl(state, chamber, district), {
        headers: { "x-api-key": key, "user-agent": "floor-api/0.1" },
        signal: AbortSignal.timeout(8_000),
      });
      if (!res.ok) {
        opts.log?.(`Open States people returned HTTP ${res.status}`);
        return [];
      }
      const value = parsePeople(await res.json(), chamber, district);
      cache.set(k, { at: now(), value });
      return value;
    } catch {
      opts.log?.("Open States people lookup failed");
      return [];
    }
  };
}

export const NO_LEGISLATORS: LegislatorLookup = async () => [];
