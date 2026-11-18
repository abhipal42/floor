import { z } from "@hono/zod-openapi";

/*
 * Members' news (the News page): Google News headlines from the last 7 days, the AI's tone and
 * stories over them, and published polls that name the member (apps/worker news.ts, polls.ts).
 */

export const NEWS_WINDOW_DAYS = 7;
export const POLL_WINDOW_DAYS = 90;
/** Headlines change hourly at most (the worker's schedule). */
export const NEWS_CACHE_CONTROL = "public, max-age=300, s-maxage=600, stale-while-revalidate=600";

export const HeadlineToneSchema = z
  .enum(["favorable", "neutral", "critical", "office"])
  .openapi("HeadlineTone", {
    description:
      "AI-read: how the headline frames the member (not whether the news is good). office = from the member's own office or " +
      "another .gov publisher, set by Floor, never by the AI, and never counted in a tone bar",
  });

export const ToneCountsSchema = z
  .object({
    favorable: z.number().int(),
    neutral: z.number().int(),
    critical: z.number().int(),
    office: z.number().int().openapi({ description: "Shown apart, never in the bar" }),
  })
  .openapi("ToneCounts");

export const StorySchema = z
  .object({
    id: z.string(),
    title: z.string().openapi({ example: "Van Hollen challenges Schumer for leader", description: "Written by the AI, in neutral wording" }),
    tone: ToneCountsSchema,
    headlineIds: z.array(z.string()).openapi({ description: "At least 2, newest first" }),
  })
  .openapi("Story", { description: "An AI group of headlines about the same event" });

export const HeadlineSchema = z
  .object({
    id: z.string(),
    title: z.string().openapi({ example: "Schumer declares he has votes to beat Van Hollen and become majority leader" }),
    source: z.string().openapi({ example: "The Hill" }),
    url: z.string().openapi({ description: "The Google News link to the article" }),
    publishedAt: z.string().openapi({ example: "2026-11-17T20:23:00.000Z" }),
    tone: HeadlineToneSchema.nullable().openapi({ description: "null = not AI-read (or, for a jurisdiction's headlines, never)" }),
    storyId: z.string().nullable(),
  })
  .openapi("Headline", { description: "Headline, publisher, date and link only: Floor stores no article text" });

export const PollShareSchema = z
  .object({
    label: z.string().openapi({ example: "favorable", description: "As the pollster worded it" }),
    pct: z.number(),
  })
  .openapi("PollShare");

export const PollSchema = z
  .object({
    id: z.string(),
    pollster: z.string().openapi({ example: "Economist/YouGov" }),
    fieldedFrom: z.string().openapi({ example: "2026-11-13" }),
    fieldedTo: z.string().openapi({ example: "2026-11-16" }),
    population: z.string().openapi({ example: "U.S. adults" }),
    sampleSize: z.number().int().nullable().openapi({ example: 1628 }),
    positive: PollShareSchema,
    negative: PollShareSchema,
    other: PollShareSchema.nullable().openapi({ description: "null when the release does not break the rest out" }),
    url: z.string().openapi({ description: "The release (or the report of it the poll file names)" }),
  })
  .openapi("Poll");

export const MemberNewsSchema = z
  .object({
    memberId: z.string().openapi({ example: "S000148" }),
    checkedAt: z.string().nullable().openapi({ description: "When Floor last asked Google News; null = never" }),
    window: z.object({ from: z.string(), to: z.string() }).openapi({ description: "The 7 days served" }),
    // `stories` before `tone`: Story.tone is the first use of ToneCounts the generator meets, so it
    // stays non-nullable (a nullable first use hoists `nullable` onto the shared component).
    stories: z.array(StorySchema).openapi({ description: "Groups of >= 2 headlines, biggest first; [] when not AI-read" }),
    tone: ToneCountsSchema.nullable().openapi({ description: "Over `headlines`; null when none were AI-read" }),
    headlines: z.array(HeadlineSchema).openapi({ description: "Every headline in the window, newest first (stories' members included)" }),
    polls: z.array(PollSchema).openapi({ description: "Polls naming the member, fielded within the last 90 days, newest first" }),
  })
  .openapi("MemberNews");

export type Headline = z.infer<typeof HeadlineSchema>;
export type Poll = z.infer<typeof PollSchema>;
export type MemberNews = z.infer<typeof MemberNewsSchema>;
type Tone = z.infer<typeof HeadlineToneSchema>;
type ToneCounts = z.infer<typeof ToneCountsSchema>;

/** What the repository reads: rows, before stories and counts are derived. */
export interface MemberNewsRows {
  checkedAt: string | null;
  headlines: Headline[];
  storyTitles: Map<string, string>;
  polls: Poll[];
}

export interface NewsRepository {
  /** The member's headlines from `from` on (newest first), their stories' titles, polls fielded since `pollsFrom`, and the last check. */
  memberNews(bioguideId: string, from: Date, pollsFrom: string): Promise<MemberNewsRows>;
}

export const NO_NEWS: NewsRepository = {
  memberNews: async () => ({ checkedAt: null, headlines: [], storyTitles: new Map(), polls: [] }),
};

const counts = (tones: (Tone | null)[]): ToneCounts => {
  const c = { favorable: 0, neutral: 0, critical: 0, office: 0 };
  for (const t of tones) if (t) c[t]++;
  return c;
};

/**
 * The response from the rows. A story is served only with at least two of its headlines in the
 * window; a headline whose story is not served has `storyId` null. With no headline AI-read, `tone`
 * is null and `stories` empty.
 */
export function memberNews(memberId: string, rows: MemberNewsRows, now: Date): MemberNews {
  const from = new Date(now.getTime() - NEWS_WINDOW_DAYS * 86_400_000);
  const aiRead = rows.headlines.some((h) => h.tone !== null && h.tone !== "office");
  const groups = new Map<string, Headline[]>();
  for (const h of rows.headlines) {
    if (h.storyId && rows.storyTitles.has(h.storyId)) groups.set(h.storyId, [...(groups.get(h.storyId) ?? []), h]);
  }
  const served = aiRead ? [...groups.entries()].filter(([, hs]) => hs.length >= 2) : [];
  const keep = new Set(served.map(([id]) => id));
  const stories = served
    .map(([id, hs]) => ({ id, title: rows.storyTitles.get(id)!, tone: counts(hs.map((h) => h.tone)), headlineIds: hs.map((h) => h.id) }))
    .sort((a, b) => b.headlineIds.length - a.headlineIds.length || a.id.localeCompare(b.id));
  return {
    memberId,
    checkedAt: rows.checkedAt,
    window: { from: from.toISOString(), to: now.toISOString() },
    tone: aiRead ? counts(rows.headlines.map((h) => h.tone)) : null,
    stories,
    headlines: rows.headlines.map((h) => ({ ...h, storyId: h.storyId && keep.has(h.storyId) ? h.storyId : null })),
    polls: rows.polls,
  };
}
