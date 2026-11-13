import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import Anthropic from "@anthropic-ai/sdk";
import {
  analyzeBill,
  anthropicComplete,
  citationValid,
  analyzeOptions,
  paragraphs,
  PROMPT_VERSION,
  type AnalysisResult,
  type BillSource,
} from "./analysis.js";

/*
 * The Layer 1 eval: runs the real pipeline over ~50 real bills (fixtures/analysis/bills.json, CRS
 * summaries pulled from staging) and scores it. It spends money, so it only runs when asked:
 *
 *   npm run eval:analysis -w @floor/worker -- [--limit N] [--out results.json]
 *
 * Scores:
 *   - citation validity: of every citation the draft call wrote, the share that points at a real
 *     paragraph and quotes it verbatim. Invalid ones are cut by `checkCitations`; this measures how
 *     often the model needs that.
 *   - verifier drop rate: of the claims that passed the mechanical check, the share the verifier
 *     ruled unsupported. High means the drafter overreaches; zero on every bill would suggest the
 *     verifier isn't checking.
 *   - output validity: every citation in the stored result re-checked. Must be 100%.
 */

export interface FixtureBill {
  id: string;
  title: string;
  short_title: string | null;
  summary: string;
  summary_stage: string | null;
}

export interface BillOutcome {
  id: string;
  result?: AnalysisResult;
  error?: string;
}

export interface EvalScore {
  bills: number;
  failed: number;
  drafted: number;
  citations: number;
  validCitations: number;
  citationValidity: number | null;
  droppedByCheck: number;
  droppedByVerifier: number;
  verifierDropRate: number | null;
  kept: number;
  keepRate: number | null;
  emptyAnalyses: number;
  purposeKept: number;
  outputCitations: number;
  outputValidity: number | null;
  costUsd: number | null;
  costPerBillUsd: number | null;
  maxCostUsd: number | null;
  cacheReadTokens: number;
}

const ratio = (n: number, d: number) => (d === 0 ? null : n / d);

export function scoreEval(outcomes: BillOutcome[], sources: Map<string, string[]>): EvalScore {
  const ok = outcomes.flatMap((o) => (o.result ? [{ id: o.id, r: o.result }] : []));
  const sum = (f: (r: AnalysisResult) => number) => ok.reduce((n, { r }) => n + f(r), 0);
  const drafted = sum((r) => r.stats.drafted);
  const droppedByCheck = sum((r) => r.stats.droppedByCheck);
  const droppedByVerifier = sum((r) => r.stats.droppedByVerifier);
  const kept = sum((r) => r.stats.kept);

  let outputCitations = 0;
  let outputValid = 0;
  for (const { id, r } of ok) {
    const paras = sources.get(id) ?? r.analysis.sourceParagraphs;
    const a = r.analysis;
    for (const claim of [...(a.purpose ? [a.purpose] : []), ...a.provisions, ...a.affectedGroups, ...a.impact]) {
      for (const c of claim.citations) {
        outputCitations++;
        if (citationValid(paras, c)) outputValid++;
      }
    }
  }

  const costs = ok.map(({ r }) => r.stats.costUsd);
  const known = costs.every((c) => c !== null);
  const total = known ? (costs as number[]).reduce((a, b) => a + b, 0) : null;
  return {
    bills: outcomes.length,
    failed: outcomes.length - ok.length,
    drafted,
    citations: sum((r) => r.stats.citations),
    validCitations: sum((r) => r.stats.validCitations),
    citationValidity: ratio(sum((r) => r.stats.validCitations), sum((r) => r.stats.citations)),
    droppedByCheck,
    droppedByVerifier,
    verifierDropRate: ratio(droppedByVerifier, drafted - droppedByCheck),
    kept,
    keepRate: ratio(kept, drafted),
    emptyAnalyses: ok.filter(({ r }) => r.stats.kept === 0).length,
    purposeKept: ok.filter(({ r }) => r.analysis.purpose !== null).length,
    outputCitations,
    outputValidity: ratio(outputValid, outputCitations),
    costUsd: total,
    costPerBillUsd: total === null || ok.length === 0 ? null : total / ok.length,
    maxCostUsd: known && ok.length ? Math.max(...(costs as number[])) : null,
    cacheReadTokens: sum((r) =>
      [...r.stats.usage.draft, ...r.stats.usage.verify].reduce((n, p) => n + p.usage.cache_read_input_tokens, 0),
    ),
  };
}

const pct = (x: number | null) => (x === null ? "—" : `${(x * 100).toFixed(1)}%`);
const usd = (x: number | null) => (x === null ? "unknown" : `$${x.toFixed(4)}`);

export function formatScore(s: EvalScore): string {
  return [
    `bills                ${s.bills} (${s.failed} failed)`,
    `claims drafted       ${s.drafted}`,
    `citation validity    ${pct(s.citationValidity)} (${s.validCitations}/${s.citations})`,
    `cut by check         ${s.droppedByCheck}`,
    `verifier drop rate   ${pct(s.verifierDropRate)} (${s.droppedByVerifier})`,
    `kept                 ${s.kept} (${pct(s.keepRate)})`,
    `empty analyses       ${s.emptyAnalyses}`,
    `purpose kept         ${s.purposeKept}/${s.bills - s.failed}`,
    `output validity      ${pct(s.outputValidity)} (${s.outputCitations} citations)`,
    `cost                 ${usd(s.costUsd)} total, ${usd(s.costPerBillUsd)} per bill, ${usd(s.maxCostUsd)} max`,
    `cache read tokens    ${s.cacheReadTokens}`,
  ].join("\n");
}

export function loadFixtures(): FixtureBill[] {
  const here = dirname(fileURLToPath(import.meta.url));
  const file = JSON.parse(readFileSync(join(here, "../fixtures/analysis/bills.json"), "utf8")) as { bills: FixtureBill[] };
  return file.bills;
}

async function main() {
  const args = process.argv.slice(2);
  const flag = (name: string) => {
    const i = args.indexOf(name);
    return i >= 0 ? args[i + 1] : undefined;
  };
  const { effort, limit, model, verifierModel } = analyzeOptions(process.env, flag("--limit"));
  if (!process.env.ANTHROPIC_API_KEY && !process.env.ANTHROPIC_AUTH_TOKEN) {
    console.log("Not run: set ANTHROPIC_API_KEY to run the analysis eval (it calls the Claude API and costs money).");
    return;
  }
  const bills = loadFixtures().slice(0, limit);
  const client = new Anthropic();
  const draft = anthropicComplete(client, model, { effort });
  const verify = anthropicComplete(client, verifierModel, { effort });
  console.log(`Eval: ${bills.length} bills, ${model}, effort ${effort}, ${PROMPT_VERSION}`);

  const outcomes: BillOutcome[] = new Array(bills.length);
  let next = 0;
  // Four at a time: fast enough, and well inside rate limits.
  await Promise.all(
    Array.from({ length: 4 }, async () => {
      while (next < bills.length) {
        const i = next++;
        const b = bills[i]!;
        const source: BillSource = { billId: b.id, title: b.short_title ?? b.title, stage: b.summary_stage, summary: b.summary };
        try {
          const result = await analyzeBill(source, draft, verify);
          outcomes[i] = { id: b.id, result };
          console.log(`${b.id}: kept ${result.stats.kept}/${result.stats.drafted}`);
        } catch (err) {
          outcomes[i] = { id: b.id, error: err instanceof Error ? err.message : String(err) };
          console.log(`${b.id}: ${outcomes[i]!.error}`);
        }
      }
    }),
  );

  const score = scoreEval(outcomes, new Map(bills.map((b) => [b.id, paragraphs(b.summary)])));
  console.log("\n" + formatScore(score));
  const out = flag("--out");
  if (out) {
    writeFileSync(out, JSON.stringify({ model, effort, promptVersion: PROMPT_VERSION, score, outcomes }, null, 2) + "\n");
    console.log(`Wrote ${out}`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  });
}
