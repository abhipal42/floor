/**
 * Pages someone when the API's `/v1/status` reports `ok: false` while a chamber is in session.
 *
 * Env:
 *   ALERT_WEBHOOK_URL  where to POST (Slack/Discord-compatible: the body has `text` and `content`).
 *                      Unset = no alerts are sent (the check still runs and logs).
 *   FLOOR_STATUS_URL   the status route to check; defaults to the deployed API.
 *
 * It asks the deployed API rather than recomputing freshness here, so an API that is down or
 * misconfigured pages too — that is the failure a user on vote night would actually see.
 */

export const DEFAULT_STATUS_URL = "https://floor-api.vercel.app/v1/status";

type Fetch = (
  url: string,
  init?: { method?: string; headers?: Record<string, string>; body?: string; signal?: AbortSignal },
) => Promise<{ status: number; json(): Promise<unknown> }>;

interface StatusBody {
  ok: boolean;
  sources?: { source: string; stale: boolean; lastSuccessAt: string | null; lastError: string | null }[];
}

export type AlertOutcome = "skipped" | "ok" | "failing" | "alerted" | "still-failing" | "recovered";

export interface AlerterOptions {
  webhookUrl?: string;
  statusUrl?: string;
  fetch?: Fetch;
  now?: () => number;
  log?: (msg: string) => void;
  /** Don't ask /v1/status more often than this. */
  checkEveryMs?: number;
  /** Never post more often than this (alerts, repeats and recoveries alike); also the repeat interval. */
  repeatEveryMs?: number;
  /** Consecutive failed checks before the first alert, and consecutive good ones before "recovered". */
  streak?: number;
}

export const ALERT_STREAK = 3;

/** What went wrong, in one line: the stale sources and their last errors. */
export function describeStatus(body: StatusBody): string {
  const stale = (body.sources ?? []).filter((s) => s.stale);
  if (stale.length === 0) return "ok: false with no stale source listed";
  return stale
    .map((s) => `${s.source} stale (last success ${s.lastSuccessAt ?? "never"}${s.lastError ? `; last error: ${s.lastError}` : ""})`)
    .join("; ");
}

/**
 * One bad answer is not an outage (a cold start, one slow query), and a status that flips every
 * minute must not post every minute: it takes `streak` failed checks in a row to alert and `streak`
 * good ones in a row to call it recovered, and nothing is posted less than `repeatEveryMs` after the
 * previous post. A recovery that comes too soon after the alert waits for that gap, unless it fails
 * again first.
 */
export class StatusAlerter {
  private lastCheck = -Infinity;
  private failingSince: number | null = null;
  private alerting = false;
  private failStreak = 0;
  private okStreak = 0;
  private lastPost = -Infinity;
  private readonly fetch: Fetch;
  private readonly now: () => number;

  constructor(private readonly opts: AlerterOptions = {}) {
    this.fetch = opts.fetch ?? (fetch as unknown as Fetch);
    this.now = opts.now ?? Date.now;
  }

  get enabled(): boolean {
    return Boolean(this.opts.webhookUrl);
  }

  /** Call every poll. Does nothing outside a session or more often than `checkEveryMs`. */
  async check(inSession: boolean): Promise<AlertOutcome> {
    const now = this.now();
    if (!inSession || now - this.lastCheck < (this.opts.checkEveryMs ?? 60_000)) return "skipped";
    this.lastCheck = now;

    let problem: string | null;
    try {
      const res = await this.fetch(this.opts.statusUrl ?? DEFAULT_STATUS_URL, { signal: AbortSignal.timeout(10_000) });
      if (res.status !== 200) problem = `/v1/status answered HTTP ${res.status}`;
      else {
        const body = (await res.json()) as StatusBody;
        problem = body.ok ? null : describeStatus(body);
      }
    } catch (err) {
      problem = `/v1/status could not be reached: ${err instanceof Error ? err.message : String(err)}`;
    }

    const streak = this.opts.streak ?? ALERT_STREAK;
    const gapOk = now - this.lastPost >= (this.opts.repeatEveryMs ?? 30 * 60_000);

    if (problem === null) {
      this.failStreak = 0;
      this.okStreak++;
      if (!this.alerting) {
        this.failingSince = null;
        return "ok";
      }
      if (this.okStreak < streak || !gapOk) return "still-failing";
      const minutes = Math.round((now - (this.failingSince ?? now)) / 60_000);
      this.alerting = false;
      this.failingSince = null;
      await this.post(`Floor recovered: /v1/status is ok again (it was failing for about ${minutes} min).`, now);
      return "recovered";
    }

    this.okStreak = 0;
    this.failStreak++;
    this.failingSince ??= now;
    if (this.failStreak < streak || !gapOk) return this.alerting ? "still-failing" : "failing";
    this.alerting = true;
    await this.post(`Floor is unhealthy during a session: ${problem}`, now);
    return "alerted";
  }

  /** Posts a one-off notice (the stuck-vote sweep). Not throttled here: the caller posts only news. */
  async notify(text: string): Promise<void> {
    await this.post(text, null);
  }

  private async post(text: string, at: number | null): Promise<void> {
    if (at !== null) this.lastPost = at;
    this.opts.log?.(`alert: ${text}`);
    const url = this.opts.webhookUrl;
    if (!url) return;
    try {
      const res = await this.fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ text, content: text }),
        signal: AbortSignal.timeout(10_000),
      });
      if (res.status >= 300) this.opts.log?.(`alert webhook answered HTTP ${res.status}`);
    } catch (err) {
      // A webhook URL is a secret (anyone holding it can post); report the failure, never the URL.
      this.opts.log?.(`alert webhook failed: ${err instanceof Error ? err.name : "error"}`);
    }
  }
}
