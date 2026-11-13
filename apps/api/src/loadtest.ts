/**
 * Vote-night load test: hammers the routes the app hits while a vote is on, in roughly the mix a
 * phone produces (the live view every few seconds, the vote screen, your members), and reports
 * latency per route.
 *
 *   npm run dev -w @floor/api                      # in one terminal
 *   npm run loadtest -w @floor/api -- --duration 30 --connections 50
 *
 * Options: --url (default http://localhost:8787), --duration seconds (30), --connections (50),
 * --vote, --members, --member, --bill (IDs to request; defaults are real staging rows),
 * --p95 budget in ms (500; the run exits 1 above it or above 1% errors).
 *
 * It refuses any host but this machine. The deployed API is never a target: a load test there
 * would spend the database's connections and Vercel's invocations on noise, and a "pass" against
 * the edge cache says nothing about the function behind it. `--allow-host <name>` exists for a
 * preview deployment of your own; it still refuses floor-api.vercel.app.
 */

export const PRODUCTION_HOSTS = new Set(["floor-api.vercel.app"]);
const LOOPBACK = new Set(["localhost", "127.0.0.1", "[::1]", "::1"]);

export function assertSafeTarget(url: string, allowHosts: string[] = []): URL {
  const target = new URL(url);
  if (PRODUCTION_HOSTS.has(target.hostname)) {
    throw new Error(`Refusing to load-test production (${target.hostname}). Run the API locally: npm run dev -w @floor/api`);
  }
  if (!LOOPBACK.has(target.hostname) && !allowHosts.includes(target.hostname)) {
    throw new Error(`Refusing to load-test ${target.hostname}: only this machine, unless named with --allow-host`);
  }
  return target;
}

export interface RouteSpec {
  name: string;
  path: string;
  weight: number;
}

export interface LoadIds {
  vote: string;
  members: string;
  member: string;
  bill: string;
}

/** Real staging IDs, so a run against a local API pointed at staging exercises real queries. */
export const DEFAULT_IDS: LoadIds = {
  vote: "house-119-1-100",
  members: "D000399,C001098,C001056",
  member: "D000399",
  bill: "119-hconres-14",
};

/** What one phone does on vote night, per minute, roughly: mostly polling the live view. */
export function voteNightRoutes(ids: LoadIds): RouteSpec[] {
  return [
    { name: "live", path: "/v1/live", weight: 12 },
    { name: "vote", path: `/v1/votes/${ids.vote}?members=${ids.members}`, weight: 4 },
    { name: "member votes", path: `/v1/members/${ids.member}/votes?limit=20`, weight: 2 },
    { name: "member", path: `/v1/members/${ids.member}`, weight: 1 },
    { name: "bill", path: `/v1/bills/${ids.bill}`, weight: 1 },
    { name: "status", path: "/v1/status", weight: 1 },
  ];
}

/** Picks a route in proportion to its weight; `r` is uniform in [0, 1). */
export function pickRoute(routes: RouteSpec[], r: number): RouteSpec {
  const total = routes.reduce((s, x) => s + x.weight, 0);
  let at = r * total;
  for (const route of routes) {
    if (at < route.weight) return route;
    at -= route.weight;
  }
  return routes[routes.length - 1]!;
}

/** Nearest-rank percentile of sorted values. */
export function percentile(sorted: number[], q: number): number | null {
  if (sorted.length === 0) return null;
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil(q * sorted.length) - 1))]!;
}

export interface RouteReport {
  name: string;
  requests: number;
  errors: number;
  statuses: Record<string, number>;
  p50: number | null;
  p95: number | null;
  p99: number | null;
  max: number | null;
}

export interface LoadReport {
  seconds: number;
  requests: number;
  errors: number;
  rps: number;
  routes: RouteReport[];
  overall: { p50: number | null; p95: number | null; p99: number | null };
}

type Fetch = (url: string) => Promise<{ status: number; arrayBuffer(): Promise<ArrayBuffer> }>;

export async function runLoad(opts: {
  baseUrl: string;
  routes: RouteSpec[];
  durationMs: number;
  connections: number;
  fetch?: Fetch;
  now?: () => number;
  random?: () => number;
}): Promise<LoadReport> {
  const get = opts.fetch ?? (fetch as unknown as Fetch);
  const now = opts.now ?? (() => performance.now());
  const random = opts.random ?? Math.random;
  const base = opts.baseUrl.replace(/\/+$/, "");
  const samples = new Map<string, { ms: number[]; errors: number; statuses: Record<string, number> }>();
  for (const r of opts.routes) samples.set(r.name, { ms: [], errors: 0, statuses: {} });

  const start = now();
  const deadline = start + opts.durationMs;
  const worker = async () => {
    while (now() < deadline) {
      const route = pickRoute(opts.routes, random());
      const s = samples.get(route.name)!;
      const t0 = now();
      try {
        const res = await get(`${base}${route.path}`);
        await res.arrayBuffer(); // a response isn't served until its body is read
        s.ms.push(now() - t0);
        s.statuses[res.status] = (s.statuses[res.status] ?? 0) + 1;
        if (res.status >= 500 || res.status === 429) s.errors++;
      } catch {
        s.ms.push(now() - t0);
        s.statuses["network"] = (s.statuses["network"] ?? 0) + 1;
        s.errors++;
      }
    }
  };
  await Promise.all(Array.from({ length: opts.connections }, worker));
  const seconds = Math.max((now() - start) / 1000, 1e-9);

  const all: number[] = [];
  const routes: RouteReport[] = opts.routes.map((r) => {
    const s = samples.get(r.name)!;
    const sorted = [...s.ms].sort((a, b) => a - b);
    all.push(...sorted);
    return {
      name: r.name,
      requests: sorted.length,
      errors: s.errors,
      statuses: s.statuses,
      p50: percentile(sorted, 0.5),
      p95: percentile(sorted, 0.95),
      p99: percentile(sorted, 0.99),
      max: sorted.at(-1) ?? null,
    };
  });
  all.sort((a, b) => a - b);
  const requests = all.length;
  const errors = routes.reduce((n, r) => n + r.errors, 0);
  return {
    seconds,
    requests,
    errors,
    rps: requests / seconds,
    routes,
    overall: { p50: percentile(all, 0.5), p95: percentile(all, 0.95), p99: percentile(all, 0.99) },
  };
}

export function formatReport(report: LoadReport): string {
  const ms = (v: number | null) => (v === null ? "-" : `${v.toFixed(1)}`);
  const lines = [
    `${report.requests} requests in ${report.seconds.toFixed(1)} s (${report.rps.toFixed(0)}/s), ${report.errors} errors`,
    `${"route".padEnd(14)}${"reqs".padStart(8)}${"errs".padStart(6)}${"p50".padStart(9)}${"p95".padStart(9)}${"p99".padStart(9)}${"max".padStart(9)}  statuses`,
  ];
  for (const r of report.routes) {
    lines.push(
      `${r.name.padEnd(14)}${String(r.requests).padStart(8)}${String(r.errors).padStart(6)}${ms(r.p50).padStart(9)}${ms(r.p95).padStart(9)}${ms(r.p99).padStart(9)}${ms(r.max).padStart(9)}  ${JSON.stringify(r.statuses)}`,
    );
  }
  lines.push(`overall p50 ${ms(report.overall.p50)} ms, p95 ${ms(report.overall.p95)} ms, p99 ${ms(report.overall.p99)} ms`);
  return lines.join("\n");
}

/** Pass/fail against a p95 budget and a 1% error ceiling. */
export function verdict(report: LoadReport, p95BudgetMs: number): { ok: boolean; reasons: string[] } {
  const reasons: string[] = [];
  if (report.requests === 0) reasons.push("no requests completed");
  if (report.errors > report.requests * 0.01) reasons.push(`${report.errors} errors is over 1% of ${report.requests}`);
  if (report.overall.p95 !== null && report.overall.p95 > p95BudgetMs) {
    reasons.push(`p95 ${report.overall.p95.toFixed(1)} ms is over the ${p95BudgetMs} ms budget`);
  }
  return { ok: reasons.length === 0, reasons };
}

export function parseArgs(argv: string[]): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    if (!a.startsWith("--")) continue;
    const next = argv[i + 1];
    const value = next !== undefined && !next.startsWith("--") ? (i++, next) : "true";
    (out[a.slice(2)] ??= []).push(value);
  }
  return out;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const one = (k: string, d: string) => args[k]?.at(-1) ?? d;
  const target = assertSafeTarget(one("url", "http://localhost:8787"), args["allow-host"] ?? []);
  const ids: LoadIds = {
    vote: one("vote", DEFAULT_IDS.vote),
    members: one("members", DEFAULT_IDS.members),
    member: one("member", DEFAULT_IDS.member),
    bill: one("bill", DEFAULT_IDS.bill),
  };
  const durationMs = Number(one("duration", "30")) * 1000;
  const connections = Number(one("connections", "50"));
  console.log(`Load-testing ${target.origin} for ${durationMs / 1000} s with ${connections} connections`);
  const report = await runLoad({ baseUrl: target.origin, routes: voteNightRoutes(ids), durationMs, connections });
  console.log(formatReport(report));
  const v = verdict(report, Number(one("p95", "500")));
  console.log(v.ok ? "PASS" : `FAIL: ${v.reasons.join("; ")}`);
  process.exit(v.ok ? 0 : 1);
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split("/").pop()!)) {
  main().catch((err) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  });
}
