import { PGlite } from "@electric-sql/pglite";
import Anthropic from "@anthropic-ai/sdk";
import { loadMigrations } from "@floor/db";
import { beforeAll, describe, expect, it } from "vitest";
import {
  AnalysisError,
  analyzeBill,
  analyzeOptions,
  anthropicComplete,
  checkCitations,
  citationValid,
  costUsd,
  MAX_ATTEMPTS,
  MAX_SOURCE_CHARS,
  paragraphs,
  partsCost,
  pendingAnalyses,
  PROMPT_VERSION,
  runAnalyses,
  sectionAt,
  sourceHash,
  usageParts,
  type BillSource,
  type Complete,
  type ModelCall,
} from "./analysis.js";
import { formatScore, loadFixtures, scoreEval } from "./analysis-eval.js";
import type { Db } from "./db.js";

const usage = { input_tokens: 1000, output_tokens: 200, cache_creation_input_tokens: 0, cache_read_input_tokens: 800 };
const parts = [{ model: "claude-sonnet-5-5", usage }];

const SUMMARY = [
  "Further Continuing Appropriations and Other Extensions Act, 2024",
  "This act provides continuing FY2024 appropriations for federal agencies. The act also extends several expiring programs and authorities, including programs authorized by the 2018 farm bill.",
  "(Sec. 101) This section provides continuing FY2024 appropriations for federal agencies and extends several expiring programs and authorities.",
  "The CR provides funding through January 19, 2024, for agencies and programs that were funded in four FY2023 appropriations acts.",
].join("\n\n");

const source: BillSource = { billId: "118-hr-6363", title: "Further Continuing Appropriations Act", stage: "Public Law", summary: SUMMARY };

const claim = (text: string, ...citations: [number, string][]) => ({
  text,
  citations: citations.map(([paragraph, quote]) => ({ paragraph, quote })),
});

type Verdict = { id: string; supported: boolean; problem: string };

/** A draft with one claim of each kind of trouble, and the calls each stub received. */
function stubs(verdicts?: (ids: string[]) => Verdict[]) {
  const calls: ModelCall[] = [];
  const draft: Complete = async (call) => {
    calls.push(call);
    return {
      model: "claude-sonnet-5-5",
      parts,
      data: {
        purpose: claim("The act continues FY2024 funding for federal agencies.", [2, "provides continuing FY2024 appropriations for federal agencies"]),
        provisions: [
          // Valid, with the section read off the paragraph.
          claim("Section 101 extends expiring programs.", [3, "extends several expiring programs and authorities"]),
          // Quote not in the paragraph: cut by the check.
          claim("It funds the Pentagon through 2030.", [4, "funds the Pentagon through 2030"]),
          // Paragraph out of range: cut by the check.
          claim("It raises the debt limit.", [9, "raises the debt limit by"]),
          // One bad citation and one good: kept, with only the good one.
          claim("Some agencies are funded through January 19, 2024.", [4, "not in there at all ok"], [4, "provides funding through January 19, 2024"]),
        ],
        affected_groups: [claim("Federal agencies.", [2, "appropriations for federal agencies"])],
        // Valid citation, but the verifier will reject it.
        impact: [claim("It prevents a shutdown forever.", [3, "provides continuing FY2024 appropriations"])],
      },
    };
  };
  const verify: Complete = async (call) => {
    calls.push(call);
    const ids = (JSON.parse(call.user.slice(call.user.indexOf("Claims:") + 7)) as { id: string }[]).map((c) => c.id);
    return {
      model: "claude-sonnet-5-5",
      parts,
      data: {
        verdicts: verdicts
          ? verdicts(ids)
          : ids.map((id) => ({ id, supported: id !== "impact-1", problem: id === "impact-1" ? "not stated" : "" })),
      },
    };
  };
  return { calls, draft, verify };
}

describe("source handling", () => {
  it("splits paragraphs", () => {
    expect(paragraphs(SUMMARY)).toHaveLength(4);
    expect(paragraphs("\n\nA\n\n\n\nB\n• bullet\n\n")).toEqual(["A", "B\n• bullet"]);
  });

  it("reads the section label in force where the quote starts, not the paragraph's first", () => {
    const p = "(Sec. 101) This section extends the program. (Sec. 102) This section repeals the old fee.";
    expect(sectionAt(p, 0)).toBe("Sec. 101");
    expect(sectionAt(p, p.indexOf("extends"))).toBe("Sec. 101");
    expect(sectionAt(p, p.indexOf("repeals"))).toBe("Sec. 102");
    expect(sectionAt("(Secs.  3-5) These sections", 5)).toBe("Secs. 3-5");
    expect(sectionAt("This bill designates a post office.", 10)).toBeNull();
    // A label after the quote doesn't apply to it.
    expect(sectionAt("The bill starts here. (Sec. 4) Later text.", 4)).toBeNull();

    const paras = [p];
    expect(checkCitations(paras, claim("Repeals the fee.", [1, "This section repeals the old fee"]))?.citations[0]?.section).toBe(
      "Sec. 102",
    );
    // Typography folded before matching still maps back to the right place in the original text.
    expect(
      checkCitations(["(Sec. 7) Intro.   (Sec. 8)  The Secretary’s report is due."], claim("x", [1, "the secretary's report is due"]))
        ?.citations[0]?.section,
    ).toBe("Sec. 8");
  });

  it("matches quotes despite case, spacing and typographic quotes, and refuses fragments and stock phrases", () => {
    const paras = ["The bill requires the Secretary’s  report — within 90 days.", "Short one."];
    expect(citationValid(paras, { paragraph: 1, quote: "the secretary's report - within 90 days" })).toBe(true);
    expect(citationValid(paras, { paragraph: 1, quote: "...requires the Secretary’s report..." })).toBe(true);
    expect(citationValid(paras, { paragraph: 1, quote: "requires" })).toBe(false);
    // Under 20 characters, even when it is the whole paragraph.
    expect(citationValid(paras, { paragraph: 2, quote: "Short one." })).toBe(false);
    // Long enough, but nothing in it that couldn't be in any paragraph.
    expect(citationValid(paras, { paragraph: 1, quote: "The bill requires the" })).toBe(false);
    expect(citationValid(["Among other things, the bill requires the agency to act."], { paragraph: 1, quote: "Among other things, the bill requires the" })).toBe(false);
    expect(citationValid(paras, { paragraph: 0, quote: "requires the Secretary’s report" })).toBe(false);
    expect(citationValid(paras, { paragraph: 1.5, quote: "requires the Secretary’s report" })).toBe(false);
  });

  it("drops a claim whose citations all fail, and dedupes the rest", () => {
    const paras = paragraphs(SUMMARY);
    expect(checkCitations(paras, claim("X", [7, "anything at all here, really"]))).toBeNull();
    expect(checkCitations(paras, claim("  ", [3, "extends several expiring programs"]))).toBeNull();
    const kept = checkCitations(
      paras,
      claim("X", [3, "extends several expiring programs"], [3, "Extends  several expiring programs"]),
    );
    expect(kept?.citations).toEqual([{ paragraph: 3, quote: "extends several expiring programs", section: "Sec. 101" }]);
  });

  it("prices each model that ran, and refuses to guess an unknown one", () => {
    expect(costUsd("claude-sonnet-5-5", usage)).toBeCloseTo((1000 * 2 + 800 * 0.1 + 200 * 10) / 1e6);
    expect(costUsd("some-other-model", usage)).toBeNull();
    expect(partsCost([{ model: "claude-sonnet-5-5", usage }, { model: "claude-opus-5-5", usage }])).toBeCloseTo(
      costUsd("claude-sonnet-5-5", usage)! + costUsd("claude-opus-5-5", usage)!,
    );
    expect(partsCost([{ model: "claude-sonnet-5-5", usage }, { model: "some-other-model", usage }])).toBeNull();
  });

  it("splits a fallback response's usage by model, billing the declined attempt too", () => {
    const declined = { type: "message", model: null, input_tokens: 900, output_tokens: 40, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 };
    const served = { type: "fallback_message", model: "claude-sonnet-5", input_tokens: 900, output_tokens: 300, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 };
    const top = { input_tokens: 900, output_tokens: 300, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 };
    expect(usageParts({ ...top, iterations: [declined, served] }, "claude-sonnet-5-5", "claude-sonnet-5")).toEqual([
      { model: "claude-sonnet-5-5", usage: { input_tokens: 900, output_tokens: 40, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 } },
      { model: "claude-sonnet-5", usage: { input_tokens: 900, output_tokens: 300, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 } },
    ]);
    expect(usageParts({ ...top, iterations: null }, "claude-sonnet-5-5", "claude-sonnet-5-5")).toEqual([
      { model: "claude-sonnet-5-5", usage: top },
    ]);
  });

  it("validates the effort and the limit before a run", () => {
    expect(analyzeOptions({}, undefined)).toEqual({ effort: "medium", limit: undefined, model: "claude-sonnet-5-5", verifierModel: "claude-sonnet-5-5" });
    expect(analyzeOptions({ FLOOR_AI_EFFORT: "high", FLOOR_AI_MODEL: "m", FLOOR_AI_VERIFIER_MODEL: "v" }, "10")).toEqual({
      effort: "high", limit: 10, model: "m", verifierModel: "v",
    });
    expect(() => analyzeOptions({ FLOOR_AI_EFFORT: "hgih" }, undefined)).toThrow(/FLOOR_AI_EFFORT/);
    for (const bad of ["0", "-3", "2.5", "ten", ""]) expect(() => analyzeOptions({}, bad)).toThrow(/positive integer/);
  });
});

describe("analyzeBill", () => {
  it("keeps only claims that pass the check and the verifier", async () => {
    const { calls, draft, verify } = stubs();
    const r = await analyzeBill(source, draft, verify);
    expect(r.analysis.purpose?.text).toMatch(/continues FY2024/);
    expect(r.analysis.provisions.map((c) => c.text)).toEqual([
      "Section 101 extends expiring programs.",
      "Some agencies are funded through January 19, 2024.",
    ]);
    expect(r.analysis.provisions[0]!.citations[0]!.section).toBe("Sec. 101");
    expect(r.analysis.provisions[1]!.citations).toHaveLength(1);
    expect(r.analysis.affectedGroups).toHaveLength(1);
    expect(r.analysis.impact).toEqual([]);
    expect(r.analysis.sourceParagraphs).toEqual(paragraphs(SUMMARY));
    expect(r.stats).toMatchObject({
      paragraphs: 4,
      drafted: 7,
      citations: 8,
      validCitations: 5,
      droppedByCheck: 2,
      droppedByVerifier: 1,
      kept: 4,
      verifierProblems: [{ text: "It prevents a shutdown forever.", problem: "not stated" }],
      usage: { draft: parts, verify: parts },
    });
    expect(r.stats.costUsd).toBeCloseTo(2 * costUsd("claude-sonnet-5-5", usage)!);

    // The verifier sees numbered paragraphs and only the claims that survived the check.
    const verifyCall = calls[1]!;
    expect(verifyCall.user).toContain("[3] (Sec. 101)");
    expect(verifyCall.user).not.toContain("Pentagon");
    expect(verifyCall.user).not.toContain("debt limit");
    // System prompts are fixed text, so the shared prefix caches across bills.
    const again = stubs();
    await analyzeBill({ ...source, billId: "x", title: "Another bill entirely", summary: `${SUMMARY}\n\nMore.` }, again.draft, again.verify);
    expect(again.calls[0]!.user).not.toBe(calls[0]!.user);
    expect(again.calls[0]!.system).toBe(calls[0]!.system);
    expect(again.calls[1]!.system).toBe(calls[1]!.system);
  });

  it("drops claims the verifier doesn't rule on (fails closed)", async () => {
    const { draft, verify } = stubs((ids) => ids.filter((id) => id !== "purpose-1").map((id) => ({ id, supported: true, problem: "" })));
    const r = await analyzeBill(source, draft, verify);
    expect(r.analysis.purpose).toBeNull();
    expect(r.stats.verifierProblems).toContainEqual({ text: "The act continues FY2024 funding for federal agencies.", problem: "no verdict returned" });
  });

  it("keeps a claim with repeated verdicts only if every one supports it", async () => {
    const { draft, verify } = stubs((ids) => [
      ...ids.map((id) => ({ id, supported: true, problem: "" })),
      { id: "purpose-1", supported: false, problem: "overstates" },
      { id: "affectedGroups-1", supported: true, problem: "" },
    ]);
    const r = await analyzeBill(source, draft, verify);
    expect(r.analysis.purpose).toBeNull();
    expect(r.analysis.affectedGroups).toHaveLength(1);
    expect(r.stats.verifierProblems).toEqual([{ text: "The act continues FY2024 funding for federal agencies.", problem: "overstates" }]);
  });

  it("reports cost as unknown when a model with no known price ran", async () => {
    const { draft } = stubs();
    const unpriced: Complete = async (call) => ({ ...(await stubs().verify(call)), parts: [{ model: "mystery", usage }] });
    expect((await analyzeBill(source, draft, unpriced)).stats.costUsd).toBeNull();
  });

  it("throws on output that doesn't match the schema", async () => {
    const bad: Complete = async () => ({ model: "m", parts, data: { purpose: "nope" } });
    await expect(analyzeBill(source, bad)).rejects.toBeInstanceOf(AnalysisError);
    await expect(analyzeBill({ ...source, summary: "  \n\n " }, bad)).rejects.toThrow("summary is empty");
  });
});

describe("anthropicComplete", () => {
  function fakeClient(response: Record<string, unknown>) {
    const requests: Record<string, unknown>[] = [];
    const client = {
      beta: {
        messages: {
          create: async (params: Record<string, unknown>) => {
            requests.push(params);
            return { model: "claude-sonnet-5-5", stop_reason: "end_turn", stop_details: null, usage, ...response };
          },
        },
      },
    } as unknown as Anthropic;
    return { client, requests };
  }
  const call: ModelCall = { system: "SYS", user: "USER", schema: { type: "object" }, maxTokens: 123 };

  it("asks for structured output with the system prompt cached and the refusal fallback on", async () => {
    const { client, requests } = fakeClient({ content: [{ type: "text", text: '{"a":1}' }] });
    const r = await anthropicComplete(client, "claude-sonnet-5-5")(call);
    expect(r).toEqual({ data: { a: 1 }, model: "claude-sonnet-5-5", parts });
    expect(requests[0]).toMatchObject({
      model: "claude-sonnet-5-5",
      max_tokens: 123,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      system: [{ type: "text", text: "SYS", cache_control: { type: "ephemeral" } }],
      messages: [{ role: "user", content: "USER" }],
      output_config: { effort: "medium", format: { type: "json_schema", schema: { type: "object" } } },
    });
  });

  it("turns refusals, truncation and non-JSON into AnalysisError", async () => {
    for (const response of [
      { stop_reason: "refusal", stop_details: { category: "cyber" }, content: [] },
      { stop_reason: "max_tokens", content: [{ type: "text", text: '{"a":' }] },
      { content: [{ type: "text", text: "not json" }] },
    ]) {
      await expect(anthropicComplete(fakeClient(response).client, "m")(call)).rejects.toBeInstanceOf(AnalysisError);
    }
  });
});

describe("the job", () => {
  let pg: PGlite;
  let db: Db;
  const resetBills = async () => {
    await pg.exec("delete from bill_analyses; delete from bill_analysis_runs; delete from bills;");
    await pg.query(
      `insert into bills (id, congress, bill_type, number, title, summary, summary_stage, latest_action_on) values
         ('118-hr-6363', 118, 'hr', 6363, 'Further Continuing Appropriations Act', $1, 'Public Law', '2023-11-16'),
         ('118-hr-1', 118, 'hr', 1, 'No summary yet', null, null, '2023-11-01')`,
      [SUMMARY],
    );
  };
  beforeAll(async () => {
    pg = new PGlite();
    await pg.exec(`
      create schema auth;
      create table auth.users (id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
    `);
    for (const m of loadMigrations()) await pg.exec(m.sql);
    db = pg as unknown as Db;
    await resetBills();
  });

  it("hashes the source the same way in SQL and in code", async () => {
    const { rows } = await pg.query<{ h: string }>(
      `select encode(sha256(convert_to(coalesce(summary_stage, '') || E'\\n' || summary, 'UTF8')), 'hex') as h
         from bills where id = '118-hr-6363'`,
    );
    expect(rows[0]!.h).toBe(sourceHash("Public Law", SUMMARY));
  });

  it("analyses each source once, and again only when the summary or the prompt changes", async () => {
    const { draft, verify } = stubs();
    expect((await pendingAnalyses(db, 10)).map((r) => r.id)).toEqual(["118-hr-6363"]);

    const first = await runAnalyses(db, draft, { verifyWith: verify });
    expect(first).toMatchObject({ ran: true, analysed: 1, failed: 0 });
    const { rows } = await pg.query<Record<string, unknown>>("select * from bill_analyses");
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      bill_id: "118-hr-6363",
      bill_version_id: null,
      source_kind: "crs_summary",
      source_stage: "Public Law",
      source_hash: sourceHash("Public Law", SUMMARY),
      prompt_version: PROMPT_VERSION,
      model: "claude-sonnet-5-5",
      verifier_model: "claude-sonnet-5-5",
    });
    expect((rows[0]!.analysis as { provisions: unknown[] }).provisions).toHaveLength(2);
    // Rejected claims and cost never reach the public table.
    expect(rows[0]).not.toHaveProperty("stats");
    expect(JSON.stringify(rows[0])).not.toContain("shutdown forever");
    const { rows: runs } = await pg.query<{ attempts: number; stats: { kept: number; verifierProblems: unknown[] } }>(
      "select attempts, stats from bill_analysis_runs",
    );
    expect(runs).toHaveLength(1);
    expect(runs[0]).toMatchObject({ attempts: 0, stats: { kept: 4, verifierProblems: [{ text: "It prevents a shutdown forever." }] } });

    // Unchanged: nothing to do.
    expect(await runAnalyses(db, draft, { verifyWith: verify })).toMatchObject({ analysed: 0 });

    // The summary is revised within its stage: the same row is regenerated.
    await pg.query("update bills set summary = summary || $1 where id = '118-hr-6363'", ["\n\nA new closing paragraph."]);
    expect(await runAnalyses(db, draft, { verifyWith: verify })).toMatchObject({ analysed: 1 });
    expect((await pg.query("select 1 from bill_analyses")).rows).toHaveLength(1);

    // A new stage is a new version: a second row, and the first is kept.
    await pg.query("update bills set summary_stage = 'Passed Senate' where id = '118-hr-6363'");
    expect(await runAnalyses(db, draft, { verifyWith: verify })).toMatchObject({ analysed: 1 });
    const { rows: stages } = await pg.query<{ source_stage: string }>("select source_stage from bill_analyses order by source_stage");
    expect(stages.map((r) => r.source_stage)).toEqual(["Passed Senate", "Public Law"]);
  });

  it(`records failures, and stops trying a source after ${MAX_ATTEMPTS} attempts until it changes`, async () => {
    await resetBills();
    let calls = 0;
    const failing: Complete = async () => {
      calls++;
      throw new AnalysisError("model declined (cyber)");
    };
    const log: string[] = [];
    expect(await runAnalyses(db, failing, { log: (m) => log.push(m) })).toMatchObject({ analysed: 0, failed: 1 });
    expect(log).toEqual(["118-hr-6363: model declined (cyber)"]);
    // Per-bill failures are counted in `failed`; `error` is only for a run that failed as a whole.
    const { rows } = await pg.query<{ items: number; error: string | null; failed: number }>(
      "select items, error, failed from ingest_runs where source = 'bill_analyses' order by id desc limit 1",
    );
    expect(rows[0]).toEqual({ items: 0, error: null, failed: 1 });

    for (let i = 1; i < MAX_ATTEMPTS; i++) await runAnalyses(db, failing);
    expect(calls).toBe(MAX_ATTEMPTS);
    const { rows: runs } = await pg.query<{ attempts: number; last_error: string }>("select attempts, last_error from bill_analysis_runs");
    expect(runs).toEqual([{ attempts: MAX_ATTEMPTS, last_error: "model declined (cyber)" }]);

    // Out of attempts: not tried again, and the run says so.
    expect(await pendingAnalyses(db, 10)).toEqual([]);
    const later: string[] = [];
    expect(await runAnalyses(db, failing, { log: (m) => later.push(m) })).toMatchObject({ analysed: 0, failed: 0, exhausted: 1 });
    expect(calls).toBe(MAX_ATTEMPTS);
    expect(later).toEqual([`not trying 0 summaries over ${MAX_SOURCE_CHARS} characters, 1 out of attempts`]);

    // A revised summary is a new source with fresh attempts.
    await pg.query("update bills set summary = 'A revised summary of what the bill does now.' where id = '118-hr-6363'");
    expect((await pendingAnalyses(db, 10)).map((r) => r.id)).toEqual(["118-hr-6363"]);
  });

  it("never sends a summary over the size limit", async () => {
    await resetBills();
    await pg.query("update bills set summary = repeat('x', $1) where id = '118-hr-6363'", [MAX_SOURCE_CHARS + 1]);
    expect(await pendingAnalyses(db, 10)).toEqual([]);
    expect(await runAnalyses(db, stubs().draft)).toMatchObject({ analysed: 0, tooLarge: 1 });
  });

  it("ends the run on credential, permission and exhausted rate-limit errors, without charging the bill an attempt", async () => {
    for (const fatal of [
      new Anthropic.AuthenticationError(401, {}, "invalid x-api-key", new Headers()),
      new Anthropic.PermissionDeniedError(403, {}, "no access", new Headers()),
      new Anthropic.RateLimitError(429, {}, "rate limited", new Headers()),
    ]) {
      await resetBills();
      await pg.query(
        `insert into bills (id, congress, bill_type, number, title, summary, summary_stage, latest_action_on)
         values ('118-hr-2', 118, 'hr', 2, 'Second', 'Another summary that is long enough to analyse.', 'Introduced in House', '2023-01-01')`,
      );
      let calls = 0;
      const draft: Complete = async () => {
        calls++;
        throw fatal;
      };
      await expect(runAnalyses(db, draft)).rejects.toBe(fatal);
      expect(calls).toBe(1);
      expect((await pg.query("select 1 from bill_analysis_runs")).rows).toEqual([]);
      const { rows } = await pg.query<{ error: string }>(
        "select error from ingest_runs where source = 'bill_analyses' order by id desc limit 1",
      );
      expect(rows[0]!.error).toBe(fatal.message);
    }
    // The lock was released on the way out.
    expect((await pg.query("select 1 from pg_locks where locktype = 'advisory'")).rows).toEqual([]);
  });

  it("exits without spending anything when another run holds the lock", async () => {
    await resetBills();
    const busy: Db = {
      query: async <T,>(text: string, params?: unknown[]) =>
        text.includes("pg_try_advisory_lock")
          ? ({ rows: [{ locked: false }] as T[] })
          : ((await pg.query(text, params)) as { rows: T[] }),
    };
    let calls = 0;
    const draft: Complete = async () => {
      calls++;
      throw new Error("should not be called");
    };
    const log: string[] = [];
    expect(await runAnalyses(busy, draft, { log: (m) => log.push(m) })).toMatchObject({ ran: false, analysed: 0 });
    expect(calls).toBe(0);
    expect(log).toEqual(["another analysis run is in progress; exiting"]);

    // And a normal run takes the lock and gives it back.
    await runAnalyses(db, stubs().draft, { verifyWith: stubs().verify });
    expect((await pg.query("select 1 from pg_locks where locktype = 'advisory'")).rows).toEqual([]);
  });
});

describe("the eval", () => {
  it("has ~50 real bills with CRS summaries", () => {
    const bills = loadFixtures();
    expect(bills.length).toBeGreaterThanOrEqual(50);
    for (const b of bills) {
      expect(b.id).toMatch(/^\d{3}-[a-z]+-\d+$/);
      expect(paragraphs(b.summary).length).toBeGreaterThan(0);
    }
    expect(new Set(bills.map((b) => b.summary_stage)).size).toBeGreaterThanOrEqual(5);
  });

  it("scores citation validity, verifier drops and output validity", async () => {
    const { draft, verify } = stubs();
    const result = await analyzeBill(source, draft, verify);
    const score = scoreEval(
      [{ id: source.billId, result }, { id: "118-hr-2", error: "model declined" }],
      new Map([[source.billId, paragraphs(SUMMARY)]]),
    );
    expect(score).toMatchObject({
      bills: 2,
      failed: 1,
      drafted: 7,
      citationValidity: 5 / 8,
      droppedByCheck: 2,
      droppedByVerifier: 1,
      verifierDropRate: 1 / 5,
      kept: 4,
      emptyAnalyses: 0,
      purposeKept: 1,
      outputCitations: 4,
      outputValidity: 1,
      cacheReadTokens: 1600,
    });
    expect(formatScore(score)).toContain("verifier drop rate   20.0% (1)");
  });
});
