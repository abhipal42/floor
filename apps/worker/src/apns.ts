/**
 * Sends Apple push notifications with token-based (JWT) authentication.
 *
 * Env (all required to send; with any unset `apnsFromEnv` returns a sender that sends nothing):
 *   APNS_KEY_ID       the 10-character Key ID of the .p8 key (Apple Developer → Keys)
 *   APNS_TEAM_ID      the 10-character Team ID
 *   APNS_PRIVATE_KEY  the .p8 file's contents (PEM, "-----BEGIN PRIVATE KEY-----..."); \n escapes are accepted
 *   APNS_TOPIC        the app's bundle ID (app.floor.ios)
 *   APNS_ENV          "production" for TestFlight/App Store builds; anything else uses the sandbox
 *
 * Plumbing only. Nothing calls this yet: what a push says, and the Live Activity it starts, are UI and
 * wait for a locked design (CLAUDE.md, "Large UI changes"). The `devices` table already holds
 * `apns_token` and `live_activity_push_to_start_token` per user.
 */
import { createPrivateKey, sign, type KeyObject } from "node:crypto";
import { connect, constants, type ClientHttp2Session } from "node:http2";

export interface ApnsConfig {
  keyId: string;
  teamId: string;
  privateKey: KeyObject;
  /** The bundle ID. A Live Activity push goes to `<topic>.push-type.liveactivity`. */
  topic: string;
  production: boolean;
}

export type PushType = "alert" | "background" | "liveactivity";

export interface ApnsMessage {
  deviceToken: string;
  pushType: PushType;
  /** The JSON body Apple delivers (`aps` plus any custom keys). */
  payload: Record<string, unknown>;
  /** 10 = deliver now; 5 = power-considerate (required for background pushes). */
  priority?: 5 | 10;
  /** Unix seconds after which Apple may drop it; 0 = deliver once or not at all. */
  expiration?: number;
  /** Coalesces pushes with the same ID on the device (e.g. one per vote). */
  collapseId?: string;
}

export interface ApnsResult {
  ok: boolean;
  /** Not sent at all because APNs isn't configured. */
  skipped?: boolean;
  status?: number;
  /** Apple's reason string on failure, e.g. "BadDeviceToken". */
  reason?: string;
  /** 410: the token is no longer valid and should be deleted from `devices`. */
  unregistered?: boolean;
}

export interface ApnsRequest {
  origin: string;
  headers: Record<string, string>;
  body: string;
}

/** The network half, swapped for a stub in tests. */
export interface ApnsTransport {
  send(req: ApnsRequest): Promise<{ status: number; body: string }>;
  close?(): void;
}

export const APNS_PRODUCTION = "https://api.push.apple.com";
export const APNS_SANDBOX = "https://api.sandbox.push.apple.com";

/** Apple rejects a token older than an hour and throttles refreshing more often than every 20 minutes. */
const TOKEN_LIFETIME_S = 50 * 60;

const b64url = (data: Buffer | string) => Buffer.from(data).toString("base64url");

/** An ES256 provider token: header {alg, kid}, claims {iss, iat}. */
export function apnsJwt(cfg: Pick<ApnsConfig, "keyId" | "teamId" | "privateKey">, issuedAt: number): string {
  const header = b64url(JSON.stringify({ alg: "ES256", kid: cfg.keyId }));
  const claims = b64url(JSON.stringify({ iss: cfg.teamId, iat: issuedAt }));
  const input = `${header}.${claims}`;
  // JOSE wants the raw r||s signature, not DER.
  const signature = sign("sha256", Buffer.from(input), { key: cfg.privateKey, dsaEncoding: "ieee-p1363" });
  return `${input}.${b64url(signature)}`;
}

export function apnsConfigFromEnv(env: Record<string, string | undefined>): ApnsConfig | null {
  const keyId = env.APNS_KEY_ID?.trim();
  const teamId = env.APNS_TEAM_ID?.trim();
  const pem = env.APNS_PRIVATE_KEY?.replace(/\\n/g, "\n").trim();
  const topic = env.APNS_TOPIC?.trim();
  if (!keyId || !teamId || !pem || !topic) return null;
  return {
    keyId,
    teamId,
    privateKey: createPrivateKey(pem),
    topic,
    production: env.APNS_ENV?.trim() === "production",
  };
}

export class ApnsSender {
  private token: { value: string; issuedAt: number } | null = null;

  constructor(
    private readonly cfg: ApnsConfig | null,
    private readonly transport: ApnsTransport = http2Transport(),
    private readonly nowSeconds: () => number = () => Math.floor(Date.now() / 1000),
  ) {}

  get enabled(): boolean {
    return this.cfg !== null;
  }

  private bearer(cfg: ApnsConfig): string {
    const now = this.nowSeconds();
    if (!this.token || now - this.token.issuedAt >= TOKEN_LIFETIME_S) {
      this.token = { value: apnsJwt(cfg, now), issuedAt: now };
    }
    return this.token.value;
  }

  async send(msg: ApnsMessage): Promise<ApnsResult> {
    const cfg = this.cfg;
    if (!cfg) return { ok: false, skipped: true };
    if (!/^[0-9a-f]{64,200}$/i.test(msg.deviceToken)) return { ok: false, reason: "BadDeviceToken" };
    const headers: Record<string, string> = {
      ":method": "POST",
      ":path": `/3/device/${msg.deviceToken}`,
      authorization: `bearer ${this.bearer(cfg)}`,
      "apns-topic": msg.pushType === "liveactivity" ? `${cfg.topic}.push-type.liveactivity` : cfg.topic,
      "apns-push-type": msg.pushType,
      "apns-priority": String(msg.priority ?? (msg.pushType === "background" ? 5 : 10)),
      "content-type": "application/json",
    };
    if (msg.expiration !== undefined) headers["apns-expiration"] = String(msg.expiration);
    if (msg.collapseId) headers["apns-collapse-id"] = msg.collapseId;
    const { status, body } = await this.transport.send({
      origin: cfg.production ? APNS_PRODUCTION : APNS_SANDBOX,
      headers,
      body: JSON.stringify(msg.payload),
    });
    if (status === 200) return { ok: true, status };
    let reason: string | undefined;
    try {
      reason = (JSON.parse(body) as { reason?: string }).reason;
    } catch {
      reason = undefined;
    }
    // An expired provider token is ours to fix: mint a fresh one on the next send.
    if (reason === "ExpiredProviderToken") this.token = null;
    return { ok: false, status, reason, unregistered: status === 410 };
  }

  close(): void {
    this.transport.close?.();
  }
}

/** How long one push may take before its stream is cancelled; a stalled stream must not hang the worker. */
export const APNS_STREAM_TIMEOUT_MS = 10_000;

/** APNs speaks HTTP/2 only, which `fetch` does not; one long-lived session per origin, as Apple asks. */
export function http2Transport(timeoutMs = APNS_STREAM_TIMEOUT_MS): ApnsTransport {
  const sessions = new Map<string, ClientHttp2Session>();
  const session = (origin: string) => {
    const open = sessions.get(origin);
    if (open && !open.closed && !open.destroyed) return open;
    const s = connect(origin);
    s.on("error", () => sessions.delete(origin));
    s.on("close", () => sessions.delete(origin));
    sessions.set(origin, s);
    return s;
  };
  return {
    send(req) {
      return new Promise((resolve, reject) => {
        const stream = session(req.origin).request(req.headers);
        let status = 0;
        let body = "";
        stream.setEncoding("utf8");
        stream.on("response", (h) => (status = Number(h[":status"] ?? 0)));
        stream.on("data", (chunk: string) => (body += chunk));
        stream.on("end", () => resolve({ status, body }));
        stream.on("error", reject);
        // setTimeout fires on inactivity; closing the stream with CANCEL rejects through "error"/"close".
        stream.setTimeout(timeoutMs, () => {
          reject(new Error(`APNs stream timed out after ${timeoutMs} ms`));
          stream.close(constants.NGHTTP2_CANCEL);
        });
        stream.end(req.body);
      });
    },
    close() {
      for (const s of sessions.values()) s.close();
      sessions.clear();
    },
  };
}

export const apnsFromEnv = (env: Record<string, string | undefined> = process.env) =>
  new ApnsSender(apnsConfigFromEnv(env));
