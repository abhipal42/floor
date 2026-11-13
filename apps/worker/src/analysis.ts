import { createHash } from "node:crypto";
import Anthropic from "@anthropic-ai/sdk";
import { z } from "zod";
import { startRun, type Db } from "./db.js";

/*
 * M4 Layer 1: an AI analysis of a bill, written from its CRS summary.
 *
 * Product rule (CLAUDE.md): every AI-written line is labelled, points at the source paragraph it came
 * from, and says it may contain errors; a claim that can't be tied to a source is cut, not softened.
 * So nothing the model writes is stored on its say-so. A claim survives three gates:
 *
 *   1. The draft call must cite a paragraph number and quote it verbatim (structured output).
 *   2. `checkCitations` drops any citation whose paragraph doesn't exist or whose quote isn't in it,
 *      then any claim left with no citation. Mechanical, no model.
 *   3. A second call, the verifier, reads each surviving claim against the paragraphs it cites and
 *      says whether they support it. Unsupported claims, and claims it fails to rule on, are dropped.
 *
 * The bill's section ("Sec. 101") is never the model's word: `sectionAt` reads it off the cited
 * paragraph, where CRS writes "(Sec. 101)" — the last such label before the quote.
 *
 * What readers may see goes in `bill_analyses` (public read). Run bookkeeping — attempts, errors,
 * tokens, cost and the claims the verifier rejected — goes in `bill_analysis_runs`, which has no
 * public policy.
 */

/** Bump whenever the prompts or schemas change: the job regenerates every analysis on another version. */
export const PROMPT_VERSION = "bill-analysis/1";

/** Overridable with FLOOR_AI_MODEL / FLOOR_AI_VERIFIER_MODEL. */
export const DEFAULT_MODEL = "claude-sonnet-5-5";

/**
 * A summary larger than this is skipped and logged rather than cut down: analysing part of a summary
 * would present it as the whole bill. The largest stored today is ~292k characters (~75k tokens), well
 * inside the model's context; this limit exists to stop a pathological row, not a real one.
 */
export const MAX_SOURCE_CHARS = 600_000;

/** Failed attempts at one source (bill, summary hash, prompt version) before the job stops trying it. */
export const MAX_ATTEMPTS = 3;

/** Session advisory lock held for a whole run, so two overlapping runs never pay for the same bill. */
export const RUN_LOCK_KEY = 4_200_001;

export type Effort = "low" | "medium" | "high";

/** Validates the CLI's knobs before anything is spent. Throws with a usable message. */
export function analyzeOptions(env: Record<string, string | undefined>, limitArg: string | undefined) {
  const effort = z
    .enum(["low", "medium", "high"], { message: "FLOOR_AI_EFFORT must be low, medium or high" })
    .parse(env.FLOOR_AI_EFFORT ?? "medium");
  let limit: number | undefined;
  if (limitArg !== undefined) {
    if (!/^\d+$/.test(limitArg) || Number(limitArg) < 1) throw new Error(`limit must be a positive integer, got "${limitArg}"`);
    limit = Number(limitArg);
  }
  const model = env.FLOOR_AI_MODEL || DEFAULT_MODEL;
  return { effort, limit, model, verifierModel: env.FLOOR_AI_VERIFIER_MODEL || model };
}

/** Splits a stored summary (see `htmlToText` in bills.ts) into the paragraphs citations point at. */
export function paragraphs(summary: string): string[] {
  return summary
    .split(/\n{2,}/)
    .map((p) => p.trim())
    .filter(Boolean);
}

/**
 * Identifies the exact source an analysis was made from. Must stay byte-for-byte equal to the SQL in
 * `pendingAnalyses` (tested), which uses it to find summaries whose analysis is missing or out of date.
 */
export function sourceHash(stage: string | null, summary: string): string {
  return createHash("sha256").update(`${stage ?? ""}\n${summary}`, "utf8").digest("hex");
}

const SOURCE_HASH_SQL = `encode(sha256(convert_to(coalesce(b.summary_stage, '') || E'\\n' || b.summary, 'UTF8')), 'hex')`;

/**
 * The bill section a passage of a CRS paragraph is about, as CRS labels it ("(Sec. 101)",
 * "(Secs. 3-5)"): the last label that starts at or before `position` (an index into the paragraph).
 * A paragraph can cover several sections in turn, so its first label is not necessarily the one the
 * quote sits under.
 */
export function sectionAt(paragraph: string, position: number): string | null {
  let found: string | null = null;
  for (const m of paragraph.matchAll(/\((Secs?\.\s*[^)]{1,40})\)/g)) {
    if (m.index! > position) break;
    found = m[1]!.replace(/\s+/g, " ");
  }
  return found;
}

export interface Citation {
  /** 1-based index into the source's paragraphs. */
  paragraph: number;
  /** Verbatim excerpt of that paragraph. */
  quote: string;
  section: string | null;
}

export interface Claim {
  text: string;
  citations: Citation[];
}

export interface Analysis {
  purpose: Claim | null;
  provisions: Claim[];
  affectedGroups: Claim[];
  impact: Claim[];
  /** The paragraphs as they were analysed, so citations still resolve after the summary moves on. */
  sourceParagraphs: string[];
}

const LISTS = ["provisions", "affectedGroups", "impact"] as const;

// ---------------------------------------------------------------------------------------------------
// Model interface. The job only ever sees `Complete`, so tests stub it and never reach the network.

export interface Usage {
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
}

export interface ModelCall {
  system: string;
  user: string;
  schema: Record<string, unknown>;
  maxTokens: number;
}

/** Tokens one model spent on a call. A call has several when a refusal fell back to another model. */
export interface ModelUsage {
  model: string;
  usage: Usage;
}

export interface ModelResult {
  data: unknown;
  /** The model that actually answered, which differs from the one asked for after a refusal fallback. */
  model: string;
  /** Every model that ran for this call, each with its own tokens, so each is priced at its own rate. */
  parts: ModelUsage[];
}

/** Cost of every part; null when any part's model has no known price. */
export function partsCost(parts: ModelUsage[]): number | null {
  let total = 0;
  for (const p of parts) {
    const c = costUsd(p.model, p.usage);
    if (c === null) return null;
    total += c;
  }
  return total;
}

/** Errors that no other bill would avoid: bad credentials, no permission, or a rate limit the SDK's retries didn't outlast. */
export function isFatal(err: unknown): boolean {
  return (
    err instanceof Anthropic.AuthenticationError ||
    err instanceof Anthropic.PermissionDeniedError ||
    err instanceof Anthropic.RateLimitError
  );
}

export type Complete = (call: ModelCall) => Promise<ModelResult>;

export class AnalysisError extends Error {}

/**
 * `Complete` on the Claude API: structured JSON output, the shared system prompt cached, and the
 * server-side refusal fallback on (a decline is re-run on the fallback model in the same call).
 */
export function anthropicComplete(
  client: Anthropic,
  model: string,
  opts: { effort?: Effort } = {},
): Complete {
  return async (call) => {
    const res = await client.beta.messages.create({
      model,
      max_tokens: call.maxTokens,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      system: [{ type: "text", text: call.system, cache_control: { type: "ephemeral" } }],
      messages: [{ role: "user", content: call.user }],
      output_config: { effort: opts.effort ?? "medium", format: { type: "json_schema", schema: call.schema } },
    });
    if (res.stop_reason === "refusal") {
      throw new AnalysisError(`model declined (${res.stop_details?.category ?? "no category"})`);
    }
    if (res.stop_reason === "max_tokens") throw new AnalysisError("output hit max_tokens");
    const text = res.content.flatMap((b) => (b.type === "text" ? [b.text] : [])).join("");
    let data: unknown;
    try {
      data = JSON.parse(text);
    } catch {
      throw new AnalysisError("model output was not JSON");
    }
    return { data, model: res.model, parts: usageParts(res.usage, model, res.model) };
  };
}

interface UsageLike {
  input_tokens: number | null;
  output_tokens: number | null;
  cache_creation_input_tokens?: number | null;
  cache_read_input_tokens?: number | null;
  iterations?: ({ type: string; model?: string | null } & Partial<Record<keyof Usage, number | null>>)[] | null;
}

const toUsage = (u: Partial<Record<keyof Usage, number | null>>): Usage => ({
  input_tokens: u.input_tokens ?? 0,
  output_tokens: u.output_tokens ?? 0,
  cache_creation_input_tokens: u.cache_creation_input_tokens ?? 0,
  cache_read_input_tokens: u.cache_read_input_tokens ?? 0,
});

/**
 * Splits a response's usage by model. With a refusal fallback, `usage.iterations` lists the declined
 * attempt (`message`) and the serving one (`fallback_message`) separately, each with its model; the
 * declined attempt is billed too, at its own model's rate. Without iterations, the top-level usage is
 * the whole call, on the model that answered.
 */
export function usageParts(usage: UsageLike, requested: string, answeredBy: string): ModelUsage[] {
  const iterations = (usage.iterations ?? []).filter((i) => i.type === "message" || i.type === "fallback_message");
  if (iterations.length === 0) return [{ model: answeredBy, usage: toUsage(usage) }];
  // These calls use no tools, so a `message` entry is a hop that ran before the serving one: the
  // requested model unless the entry names another.
  return iterations.map((i) => ({
    model: i.model ?? (i.type === "fallback_message" ? answeredBy : requested),
    usage: toUsage(i),
  }));
}

/** $ per million tokens. Unknown models get no cost estimate rather than a wrong one. */
const PRICES: Record<string, { input: number; output: number; cacheRead: number }> = {
  "claude-sonnet-5-5": { input: 2, output: 10, cacheRead: 0.1 },
  "claude-sonnet-5": { input: 2, output: 10, cacheRead: 0.2 },
  "claude-opus-5-5": { input: 4, output: 20, cacheRead: 0.2 },
  "claude-haiku-5-5": { input: 0.1, output: 0.5, cacheRead: 0.01 },
};

/** Cache writes bill at 1.25x input on the 5-minute TTL. */
export function costUsd(model: string, u: Usage): number | null {
  const p = PRICES[model];
  if (!p) return null;
  return (
    (u.input_tokens * p.input +
      u.cache_creation_input_tokens * p.input * 1.25 +
      u.cache_read_input_tokens * p.cacheRead +
      u.output_tokens * p.output) /
    1_000_000
  );
}

// ---------------------------------------------------------------------------------------------------
// Prompts and schemas. Both system prompts are fixed text (no dates, no IDs) so they cache.

const DRAFT_SYSTEM = `You write the plain-language explainer for a bill in Floor, a nonpartisan app that tracks votes in the U.S. Congress. Your only source is the Congressional Research Service (CRS) summary of one version of the bill, given to you as numbered paragraphs [1], [2], ... Readers see your lines labelled as AI-written, each linked to the paragraph it came from.

Write four things:
- purpose: one sentence on what the bill does, as the summary describes it.
- provisions: the main things the bill does, one claim each, in the summary's order. Up to 8; fewer for a short summary. A one-paragraph summary may have one provision or none beyond the purpose.
- affected_groups: who the summary says the bill applies to, regulates, funds, or benefits (agencies, states, employers, veterans, and so on). Only groups the summary names or plainly describes. Empty if it names none.
- impact: the concrete changes the summary says the bill makes: money provided or cut, deadlines, requirements created or ended, programs extended, penalties. Empty if the summary states none.

Rules. These matter more than coverage:
1. Every claim must be supported by the paragraphs it cites. Cite 1 to 3 paragraphs per claim by number, and for each give a quote: a short excerpt (at least four words) copied exactly, character for character, from that paragraph. Do not paraphrase, abbreviate, fix, or join text inside a quote.
2. Say only what the summary says. No outside knowledge, no background, no predictions about whether it will pass or what will happen after, no estimates the summary does not give. If you are not sure the summary supports a claim, leave the claim out.
3. Neutral wording. Do not characterise the bill as good, bad, controversial, partisan, sweeping or modest, and do not attribute motives. Use the summary's own terms for people and programs.
4. Plain English, short sentences, present tense ("The bill requires..."). Each claim stands alone and is at most 30 words. Do not start claims with "This bill" more than once.
5. Numbers, dates and dollar amounts must appear in a quote you cite.
6. Procedural resolutions (a rule providing for consideration of other bills) have a purpose and provisions describing that procedure; do not describe the underlying bills beyond what the summary says.

Paragraph numbers are 1-based and refer only to the numbered paragraphs in the message.`;

const VERIFY_SYSTEM = `You check AI-written claims about a bill against the Congressional Research Service (CRS) summary they cite, for Floor, a nonpartisan app that tracks votes in the U.S. Congress. Claims that fail are removed before anyone reads them, so be strict: a claim nobody can trace to the source is worse than a missing one.

You get the summary as numbered paragraphs, then a list of claims. Each claim has an id, its text, and the paragraph numbers it cites. For every claim, decide whether the cited paragraphs, read on their own, support everything the claim says.

A claim is supported only if all of these hold:
- Every fact in it (what the bill does, who it applies to, every number, date, amount and name) is stated in, or follows directly from, the cited paragraphs. Support in some other paragraph does not count.
- It does not overstate: no "all" where the source says "some", no "requires" where it says "authorizes" or "allows", no "bans" where it says "limits", no certainty where the source is conditional.
- It adds no outside knowledge, prediction, motive, or opinion, and its wording is neutral.
- It is not misleading by omission of a qualifier that changes its meaning (an exception, a time limit, a condition).

Minor rewording and plain-language simplification are fine when the meaning is unchanged.

Examples, for a paragraph reading "(Sec. 3) The bill authorizes the Department of Veterans Affairs to award grants to states for veterans cemeteries through FY2027.":
- "The bill lets the VA give states grants for veterans cemeteries through FY2027." Supported: a faithful plain-language restatement.
- "The bill requires the VA to fund veterans cemeteries in every state." Not supported: "authorizes" became "requires", and "every state" is not stated.
- "The bill provides $50 million for veterans cemeteries." Not supported: the amount is not in the paragraph.
- "The bill expands support for veterans, a long-standing bipartisan priority." Not supported: "bipartisan priority" is outside knowledge and characterisation.
- "The bill funds veterans cemeteries through FY2027, which will improve access for families." Not supported: the effect on families is a prediction the summary does not make.

Return one verdict per claim id, in the order given. Set supported to false when in doubt. In problem, say in one short sentence what is unsupported or wrong; leave it empty when supported.`;

const citationSchema = {
  type: "object",
  properties: { paragraph: { type: "integer" }, quote: { type: "string" } },
  required: ["paragraph", "quote"],
  additionalProperties: false,
};
const claimSchema = {
  type: "object",
  properties: { text: { type: "string" }, citations: { type: "array", items: citationSchema } },
  required: ["text", "citations"],
  additionalProperties: false,
};
export const DRAFT_SCHEMA = {
  type: "object",
  properties: {
    purpose: claimSchema,
    provisions: { type: "array", items: claimSchema },
    affected_groups: { type: "array", items: claimSchema },
    impact: { type: "array", items: claimSchema },
  },
  required: ["purpose", "provisions", "affected_groups", "impact"],
  additionalProperties: false,
};
export const VERIFY_SCHEMA = {
  type: "object",
  properties: {
    verdicts: {
      type: "array",
      items: {
        type: "object",
        properties: { id: { type: "string" }, supported: { type: "boolean" }, problem: { type: "string" } },
        required: ["id", "supported", "problem"],
        additionalProperties: false,
      },
    },
  },
  required: ["verdicts"],
  additionalProperties: false,
};

// Validated again on our side: the schema constrains the model, these guard the code that reads it.
const DraftClaim = z.object({
  text: z.string(),
  citations: z.array(z.object({ paragraph: z.number().int(), quote: z.string() })),
});
const Draft = z.object({
  purpose: DraftClaim,
  provisions: z.array(DraftClaim),
  affected_groups: z.array(DraftClaim),
  impact: z.array(DraftClaim),
});
const Verdicts = z.object({
  verdicts: z.array(z.object({ id: z.string(), supported: z.boolean(), problem: z.string() })),
});

export interface BillSource {
  billId: string;
  title: string;
  stage: string | null;
  summary: string;
}

const numbered = (paras: string[]) => paras.map((p, i) => `[${i + 1}] ${p}`).join("\n\n");

export function draftPrompt(source: BillSource, paras: string[]): string {
  return [
    `Bill: ${source.title}`,
    `Summary version: ${source.stage ?? "unknown"}`,
    "",
    "CRS summary, numbered paragraphs:",
    "",
    numbered(paras),
  ].join("\n");
}

export function verifyPrompt(paras: string[], claims: { id: string; claim: Claim }[]): string {
  const list = claims.map(({ id, claim }) => ({
    id,
    text: claim.text,
    cites: claim.citations.map((c) => c.paragraph),
  }));
  return ["CRS summary, numbered paragraphs:", "", numbered(paras), "", "Claims:", JSON.stringify(list, null, 2)].join(
    "\n",
  );
}


// ---------------------------------------------------------------------------------------------------
// The mechanical check.

/** Lowercases and folds whitespace, dashes and curly quotes, so a quote matches despite typography. */
export function normalize(s: string): string {
  return normalizeMapped(s).text;
}

/**
 * `normalize`, plus for every output character the index of the input character it came from, so a
 * match found in normalized text can be located in the original (for `sectionAt`).
 */
function normalizeMapped(s: string): { text: string; map: number[] } {
  let text = "";
  const map: number[] = [];
  let space = false;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i]!;
    if (/\s/.test(ch)) {
      space = text.length > 0;
      continue;
    }
    if (space) {
      text += " ";
      map.push(i);
      space = false;
    }
    const folded = ch
      .toLowerCase()
      .replace(/[‘’′]/, "'")
      .replace(/[“”″]/, '"')
      .replace(/[–—]/, "-");
    for (const f of folded) {
      text += f;
      map.push(i);
    }
  }
  return { text, map };
}

/** A quote shorter than this (normalized) proves too little about where a claim came from. */
export const MIN_QUOTE_CHARS = 20;

/**
 * Words that appear in nearly every CRS summary. A quote made only of these ("this bill requires
 * the", "among other things, the") could be found in any paragraph, so it points at nothing.
 */
const STOPWORDS = new Set(
  (
    "a an and or nor but the of to in on at by for from with without into onto upon as is are was were be been being " +
    "it its this that these those such which who whom whose than then there their them they he she his her " +
    "any all each every other others some no not only also more most less least many much " +
    "shall must may might can could will would should do does did has have had " +
    "bill bills act acts resolution resolutions section sections sec secs title titles subtitle division part " +
    "provides provide provided requires require required establishes establish among things including include includes " +
    "certain specified respect regard regarding related relating under through within between after before during " +
    "federal government united states u.s"
  ).split(" "),
);

/** Where a citation's quote sits in its paragraph (index into the original text), or null if it is not a valid citation. */
export function locateCitation(paras: string[], c: { paragraph: number; quote: string }): number | null {
  if (!Number.isInteger(c.paragraph)) return null;
  const para = paras[c.paragraph - 1];
  if (!para) return null;
  const quote = normalize(c.quote.replace(/^[.…\s]+|[.…\s]+$/g, ""));
  if (quote.length < MIN_QUOTE_CHARS) return null;
  const words = quote.split(/[^a-z0-9.$%'-]+/).filter(Boolean);
  if (!words.some((w) => !STOPWORDS.has(w.replace(/^[^a-z0-9$]+|[^a-z0-9%]+$/g, "")))) return null;
  const { text, map } = normalizeMapped(para);
  const at = text.indexOf(quote);
  return at < 0 ? null : map[at]!;
}

/** Whether a citation points at a real paragraph and quotes a meaningful part of it verbatim. */
export function citationValid(paras: string[], c: { paragraph: number; quote: string }): boolean {
  return locateCitation(paras, c) !== null;
}

/** Keeps a claim's valid citations (deduplicated, section added); null when none survive. */
export function checkCitations(
  paras: string[],
  claim: { text: string; citations: { paragraph: number; quote: string }[] },
): Claim | null {
  const text = claim.text.trim();
  if (!text) return null;
  const seen = new Set<string>();
  const citations: Citation[] = [];
  for (const c of claim.citations) {
    const at = locateCitation(paras, c);
    if (at === null) continue;
    const key = `${c.paragraph}|${normalize(c.quote)}`;
    if (seen.has(key)) continue;
    seen.add(key);
    citations.push({ paragraph: c.paragraph, quote: c.quote.trim(), section: sectionAt(paras[c.paragraph - 1]!, at) });
  }
  return citations.length > 0 ? { text, citations } : null;
}

// ---------------------------------------------------------------------------------------------------
// One bill.

/**
 * Run bookkeeping, stored in the private `bill_analysis_runs` table and never served: it holds the
 * claims the verifier rejected, which by the product rule must not reach readers.
 */
export interface AnalysisStats {
  paragraphs: number;
  /** Claims the draft call wrote. */
  drafted: number;
  /** Citations the draft call wrote, and how many of them passed the mechanical check. */
  citations: number;
  validCitations: number;
  /** Claims cut because no citation survived the mechanical check. */
  droppedByCheck: number;
  /** Claims the verifier ruled unsupported, or didn't rule on. */
  droppedByVerifier: number;
  kept: number;
  /** The verifier's reasons, for the eval and for tuning the prompt. */
  verifierProblems: { text: string; problem: string }[];
  /** Tokens per model per call; more than one entry when a refusal fell back. */
  usage: { draft: ModelUsage[]; verify: ModelUsage[] };
  /** null when any model that ran has no known price. */
  costUsd: number | null;
}

export interface AnalysisResult {
  analysis: Analysis;
  model: string;
  verifierModel: string | null;
  stats: AnalysisStats;
}

/** Writes, checks and verifies one bill's analysis. Throws `AnalysisError` when a call fails. */
export async function analyzeBill(
  source: BillSource,
  draftWith: Complete,
  verifyWith: Complete = draftWith,
): Promise<AnalysisResult> {
  const paras = paragraphs(source.summary);
  if (paras.length === 0) throw new AnalysisError("summary is empty");

  const drafted = await draftWith({ system: DRAFT_SYSTEM, user: draftPrompt(source, paras), schema: DRAFT_SCHEMA, maxTokens: 16000 });
  const parsed = Draft.safeParse(drafted.data);
  if (!parsed.success) throw new AnalysisError("draft did not match the schema");
  const d = parsed.data;

  const sections = {
    purpose: [d.purpose],
    provisions: d.provisions,
    affectedGroups: d.affected_groups,
    impact: d.impact,
  };
  const all = Object.values(sections).flat();
  const citations = all.reduce((n, c) => n + c.citations.length, 0);
  const validCitations = all.reduce((n, c) => n + c.citations.filter((x) => citationValid(paras, x)).length, 0);

  // Mechanical gate; ids let the verifier's verdicts be matched back.
  const candidates: { id: string; key: keyof typeof sections; claim: Claim }[] = [];
  let droppedByCheck = 0;
  for (const [key, claims] of Object.entries(sections) as [keyof typeof sections, typeof all][]) {
    claims.forEach((raw, i) => {
      const claim = checkCitations(paras, raw);
      if (claim) candidates.push({ id: `${key}-${i + 1}`, key, claim });
      else droppedByCheck++;
    });
  }

  let verify: ModelResult | null = null;
  const supported = new Set<string>();
  const verifierProblems: { text: string; problem: string }[] = [];
  if (candidates.length > 0) {
    verify = await verifyWith({
      system: VERIFY_SYSTEM,
      user: verifyPrompt(paras, candidates),
      schema: VERIFY_SCHEMA,
      maxTokens: 8000,
    });
    const v = Verdicts.safeParse(verify.data);
    if (!v.success) throw new AnalysisError("verifier output did not match the schema");
    // A claim with several verdicts (the model repeated an id) is kept only if every one supports it.
    const byId = new Map<string, { supported: boolean; problem: string }[]>();
    for (const x of v.data.verdicts) byId.set(x.id, [...(byId.get(x.id) ?? []), x]);
    for (const c of candidates) {
      const verdicts = byId.get(c.id) ?? [];
      if (verdicts.length > 0 && verdicts.every((x) => x.supported)) supported.add(c.id);
      else {
        const problem = verdicts.find((x) => !x.supported)?.problem || (verdicts.length ? "ruled unsupported" : "no verdict returned");
        verifierProblems.push({ text: c.claim.text, problem });
      }
    }
  }

  const kept = candidates.filter((c) => supported.has(c.id));
  const analysis: Analysis = {
    purpose: kept.find((c) => c.key === "purpose")?.claim ?? null,
    provisions: [],
    affectedGroups: [],
    impact: [],
    sourceParagraphs: paras,
  };
  for (const key of LISTS) analysis[key] = kept.filter((c) => c.key === key).map((c) => c.claim);

  const parts = [...drafted.parts, ...(verify?.parts ?? [])];
  return {
    analysis,
    model: drafted.model,
    verifierModel: verify?.model ?? null,
    stats: {
      paragraphs: paras.length,
      drafted: all.length,
      citations,
      validCitations,
      droppedByCheck,
      droppedByVerifier: candidates.length - kept.length,
      kept: kept.length,
      verifierProblems,
      usage: { draft: drafted.parts, verify: verify?.parts ?? [] },
      costUsd: partsCost(parts),
    },
  };
}

// ---------------------------------------------------------------------------------------------------
// The job.

interface PendingRow {
  id: string;
  title: string;
  short_title: string | null;
  summary: string;
  summary_stage: string | null;
}

/**
 * Bills whose current summary has no analysis at this prompt version: never analysed, a new stage, a
 * summary that changed within its stage, or an older prompt. Leaves out sources over
 * MAX_SOURCE_CHARS and sources that have already failed MAX_ATTEMPTS times, so neither is billed
 * again nor holds up the queue. Newest activity first.
 */
export async function pendingAnalyses(db: Db, limit: number): Promise<PendingRow[]> {
  const { rows } = await db.query<PendingRow>(
    `select b.id, b.title, b.short_title, b.summary, b.summary_stage
       from bills b
      where b.summary is not null and length(b.summary) between 1 and $3
        and not exists (
          select 1 from bill_analyses a
           where a.bill_id = b.id and a.source_kind = 'crs_summary'
             and a.source_stage = coalesce(b.summary_stage, '')
             and a.source_hash = ${SOURCE_HASH_SQL}
             and a.prompt_version = $1)
        and not exists (
          select 1 from bill_analysis_runs r
           where r.bill_id = b.id and r.source_hash = ${SOURCE_HASH_SQL}
             and r.prompt_version = $1 and r.attempts >= $4)
      order by b.latest_action_on desc nulls last, b.id
      limit $2`,
    [PROMPT_VERSION, limit, MAX_SOURCE_CHARS, MAX_ATTEMPTS],
  );
  return rows;
}

/** Sources the queue leaves out, for the run's log line. */
async function excludedCount(db: Db): Promise<{ tooLarge: number; exhausted: number }> {
  const { rows } = await db.query<{ too_large: number; exhausted: number }>(
    `select (select count(*)::int from bills where length(summary) > $3) as too_large,
            (select count(*)::int from bill_analysis_runs r join bills b on b.id = r.bill_id
              where r.prompt_version = $1 and r.attempts >= $2 and r.succeeded_at is null
                and r.source_hash = ${SOURCE_HASH_SQL}) as exhausted`,
    [PROMPT_VERSION, MAX_ATTEMPTS, MAX_SOURCE_CHARS],
  );
  return { tooLarge: rows[0]?.too_large ?? 0, exhausted: rows[0]?.exhausted ?? 0 };
}

/** The public row: only what readers may see. */
export async function storeAnalysis(db: Db, source: BillSource, result: AnalysisResult): Promise<void> {
  const hash = sourceHash(source.stage, source.summary);
  await db.query(
    `insert into bill_analyses (bill_id, source_kind, source_stage, source_hash, prompt_version, analysis,
                                model, verifier_model, generated_at)
     values ($1, 'crs_summary', $2, $3, $4, $5::jsonb, $6, $7, now())
     on conflict (bill_id, source_kind, source_stage) where bill_id is not null do update set
       source_hash = excluded.source_hash, prompt_version = excluded.prompt_version, analysis = excluded.analysis,
       model = excluded.model, verifier_model = excluded.verifier_model,
       generated_at = excluded.generated_at, reviewed_by = null`,
    [source.billId, source.stage ?? "", hash, PROMPT_VERSION, JSON.stringify(result.analysis), result.model, result.verifierModel],
  );
  await recordRun(db, source, { stats: result.stats });
}

/** The private row: a success with its stats, or one more failed attempt with its error. */
async function recordRun(db: Db, source: BillSource, outcome: { stats: AnalysisStats } | { error: string }) {
  const ok = "stats" in outcome;
  await db.query(
    `insert into bill_analysis_runs (bill_id, source_hash, prompt_version, source_stage, attempts, last_error, last_at,
                                     succeeded_at, stats)
     values ($1, $2, $3, $4, $5, $6, now(), case when $7 then now() end, $8::jsonb)
     on conflict (bill_id, source_hash, prompt_version) do update set
       attempts = bill_analysis_runs.attempts + excluded.attempts,
       last_error = excluded.last_error, last_at = now(),
       succeeded_at = coalesce(excluded.succeeded_at, bill_analysis_runs.succeeded_at),
       stats = coalesce(excluded.stats, bill_analysis_runs.stats)`,
    [
      source.billId,
      sourceHash(source.stage, source.summary),
      PROMPT_VERSION,
      source.stage ?? "",
      ok ? 0 : 1,
      ok ? null : outcome.error,
      ok,
      ok ? JSON.stringify(outcome.stats) : null,
    ],
  );
}

export interface RunResult {
  /** false when another run held the lock, and this one did nothing. */
  ran: boolean;
  analysed: number;
  failed: number;
  /** Summaries over MAX_SOURCE_CHARS, and sources out of attempts; neither is tried. */
  tooLarge: number;
  exhausted: number;
  /** null when any model that ran has no known price. */
  costUsd: number | null;
}

/**
 * Analyses up to `limit` bills that need it. A bill that fails is recorded and retried on later runs,
 * up to MAX_ATTEMPTS; it never stops the others. What would fail every bill the same way — bad
 * credentials, no permission, a rate limit the SDK's own retries didn't outlast — ends the run and
 * is rethrown, without counting against the bill.
 *
 * `db` must be a single connection (a `pg.PoolClient`, not a `pg.Pool`): the run holds a session
 * advisory lock on it, so an overlapping run exits at once instead of paying for the same bills.
 */
export async function runAnalyses(
  db: Db,
  draftWith: Complete,
  opts: { limit?: number; verifyWith?: Complete; log?: (msg: string) => void } = {},
): Promise<RunResult> {
  const { rows: lock } = await db.query<{ locked: boolean }>("select pg_try_advisory_lock($1) as locked", [RUN_LOCK_KEY]);
  if (!lock[0]?.locked) {
    opts.log?.("another analysis run is in progress; exiting");
    return { ran: false, analysed: 0, failed: 0, tooLarge: 0, exhausted: 0, costUsd: 0 };
  }
  try {
    const finish = await startRun(db, "bill_analyses");
    let analysed = 0;
    let failed = 0;
    let cost: number | null = 0;
    try {
      const { tooLarge, exhausted } = await excludedCount(db);
      if (tooLarge || exhausted) {
        opts.log?.(`not trying ${tooLarge} summaries over ${MAX_SOURCE_CHARS} characters, ${exhausted} out of attempts`);
      }
      for (const row of await pendingAnalyses(db, opts.limit ?? 25)) {
        const source: BillSource = {
          billId: row.id,
          title: row.short_title ?? row.title,
          stage: row.summary_stage,
          summary: row.summary,
        };
        try {
          const result = await analyzeBill(source, draftWith, opts.verifyWith ?? draftWith);
          await storeAnalysis(db, source, result);
          analysed++;
          const s = result.stats;
          cost = cost === null || s.costUsd === null ? null : cost + s.costUsd;
          opts.log?.(
            `${row.id}: kept ${s.kept} of ${s.drafted} (${s.droppedByCheck} bad citations, ${s.droppedByVerifier} unsupported), ` +
              (s.costUsd === null ? "cost unknown" : `$${s.costUsd.toFixed(4)}`),
          );
        } catch (err) {
          if (isFatal(err)) throw err;
          failed++;
          const message = err instanceof Error ? err.message : String(err);
          await recordRun(db, source, { error: message });
          opts.log?.(`${row.id}: ${message}`);
        }
      }
      await finish(analysed, undefined, failed);
      return { ran: true, analysed, failed, tooLarge, exhausted, costUsd: cost };
    } catch (err) {
      await finish(analysed, err instanceof Error ? err.message : String(err), failed);
      throw err;
    }
  } finally {
    await db.query("select pg_advisory_unlock($1)", [RUN_LOCK_KEY]);
  }
}
