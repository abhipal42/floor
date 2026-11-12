import type { Context, MiddlewareHandler } from "hono";

/** Where request counts are kept. In-memory by default; see the note on `rateLimit`. */
export interface LimitStore {
  /** Records a hit for `key` in the window ending at `resetAt`, and returns the new count. */
  hit(key: string, windowMs: number, now: number): { count: number; resetAt: number };
}

/**
 * A fixed-window counter held in this process.
 *
 * On a serverless host each instance keeps its own counts, so the effective limit is the configured
 * one multiplied by however many instances are warm. That is a real weakening, not a rounding
 * error: it slows a determined caller rather than stopping one. It is enough to keep a stray client
 * loop from hammering the Census geocoder, which is what this protects. A shared store (Vercel KV,
 * Upstash, Postgres) is what makes the number exact, and `LimitStore` exists so that swap is a
 * constructor argument rather than a rewrite.
 */
export class MemoryLimitStore implements LimitStore {
  private windows = new Map<string, { count: number; resetAt: number }>();

  hit(key: string, windowMs: number, now: number) {
    const existing = this.windows.get(key);
    if (existing && existing.resetAt > now) {
      existing.count += 1;
      return existing;
    }
    const fresh = { count: 1, resetAt: now + windowMs };
    this.windows.set(key, fresh);
    // Expired windows would otherwise accumulate for every address ever looked up.
    if (this.windows.size > 10_000) {
      for (const [k, v] of this.windows) if (v.resetAt <= now) this.windows.delete(k);
    }
    return fresh;
  }
}

/** The caller's address, as the host in front of us reports it. */
export function clientKey(c: Context): string {
  const forwarded = c.req.header("x-forwarded-for");
  // The left-most entry is the original client; the rest are proxies.
  const first = forwarded?.split(",")[0]?.trim();
  return first || c.req.header("x-real-ip") || "unknown";
}

export interface RateLimitOptions {
  /** Requests allowed per window, per caller. */
  limit: number;
  windowMs: number;
  store?: LimitStore;
  now?: () => number;
  /** Overridable so tests need not fake headers. */
  key?: (c: Context) => string;
}

/**
 * Caps how often one caller may hit a route.
 *
 * Used on `/v1/reps`, which is the only route that reaches a third party — every lookup is a
 * request to the U.S. Census geocoder, and being rate-limited there would take the route down for
 * everyone. The rest of the API reads our own database and is cheap.
 */
export function rateLimit(options: RateLimitOptions): MiddlewareHandler {
  const store = options.store ?? new MemoryLimitStore();
  const clock = options.now ?? Date.now;
  const keyOf = options.key ?? clientKey;

  return async (c, next) => {
    const now = clock();
    const { count, resetAt } = store.hit(keyOf(c), options.windowMs, now);
    const remaining = Math.max(0, options.limit - count);

    c.header("RateLimit-Limit", String(options.limit));
    c.header("RateLimit-Remaining", String(remaining));
    c.header("RateLimit-Reset", String(Math.ceil((resetAt - now) / 1000)));

    if (count > options.limit) {
      c.header("Retry-After", String(Math.ceil((resetAt - now) / 1000)));
      return c.json({ error: "Too many address lookups. Please wait a moment and try again." }, 429);
    }
    await next();
  };
}
