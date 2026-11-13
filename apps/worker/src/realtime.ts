/**
 * Publishes vote state changes to open apps through Supabase Realtime's broadcast REST endpoint.
 *
 * Env (all optional; with either unset this is a no-op and the live worker runs without it):
 *   SUPABASE_URL               https://<project-ref>.supabase.co (the API URL, not the Postgres one)
 *   SUPABASE_SERVICE_ROLE_KEY  service role key — server-side only, never shipped in the app
 *
 * Each change goes out twice: on `floor:votes` (every vote; the Home screen) and on `vote:<id>`
 * (one vote; the Vote screen), both as event `vote_state`. A client subscribes with
 * `supabase.channel("floor:votes").on("broadcast", { event: "vote_state" }, ...)`.
 * The payload is data only (no copy): push text and Live Activity layouts are UI, and wait for a
 * locked design.
 */

export interface VoteStateChange {
  id: string;
  chamber: "house" | "senate";
  congress: number;
  session: number;
  rollNumber: number | null;
  state: "open" | "final";
  question: string;
  result: string | null;
  /** The floor's own time for the vote (House only), ISO. */
  openedAt: string | null;
  /** When the worker first saw a floor source name it, ISO. */
  announcedAt: string | null;
  /** When the worker first saw its roll call XML while polling live, ISO. */
  postedAt: string | null;
}

export interface Broadcaster {
  readonly enabled: boolean;
  publish(changes: VoteStateChange[]): Promise<void>;
}

export const ALL_VOTES_TOPIC = "floor:votes";
export const voteTopic = (id: string) => `vote:${id}`;
export const VOTE_STATE_EVENT = "vote_state";

type Fetch = (
  url: string,
  init: { method: string; headers: Record<string, string>; body: string; signal?: AbortSignal },
) => Promise<{ status: number }>;

/** A broadcast that hangs must not hold up the poll (and every vote after it). */
export const BROADCAST_TIMEOUT_MS = 10_000;

export const noopBroadcaster: Broadcaster = { enabled: false, publish: async () => {} };

export function supabaseBroadcaster(
  env: Record<string, string | undefined>,
  fetchImpl: Fetch = fetch,
  timeoutMs = BROADCAST_TIMEOUT_MS,
): Broadcaster {
  const base = env.SUPABASE_URL?.trim().replace(/\/+$/, "");
  const key = env.SUPABASE_SERVICE_ROLE_KEY?.trim();
  if (!base || !key) return noopBroadcaster;
  const endpoint = `${base}/realtime/v1/api/broadcast`;
  return {
    enabled: true,
    async publish(changes) {
      if (changes.length === 0) return;
      const messages = changes.flatMap((payload) => [
        { topic: ALL_VOTES_TOPIC, event: VOTE_STATE_EVENT, payload },
        { topic: voteTopic(payload.id), event: VOTE_STATE_EVENT, payload },
      ]);
      const res = await fetchImpl(endpoint, {
        method: "POST",
        headers: { apikey: key, authorization: `Bearer ${key}`, "content-type": "application/json" },
        body: JSON.stringify({ messages }),
        signal: AbortSignal.timeout(timeoutMs),
      });
      // The status only: the request carries the service key, so nothing from it goes in a log line.
      if (res.status < 200 || res.status >= 300) throw new Error(`Realtime broadcast returned HTTP ${res.status}`);
    },
  };
}
