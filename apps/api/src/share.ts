/**
 * The share link (round 11, section D "Share a bill"): `https://floor.app/bill/119/hr/5267`.
 *
 * The app's share sheet sends a neutral line and this link (`GET /v1/bills/{id}/share` gives both).
 * The link is a real page that works without the app — title, CRS summary, where the bill stands on
 * its road to law, the latest action, a lookup of how your own members voted, and "Get Floor for
 * iPhone" — and its preview card is a PNG rendered here (`/bill/…/card.png`: satori lays it out
 * as SVG, resvg's WebAssembly build rasterizes it; no native module, no headless browser). An unknown bill is a 404 page, not an empty one.
 *
 * It is served by the API because the API has the bill data; floor.app proxies `/bill/*` and
 * `/.well-known/apple-app-site-association` here (the root `vercel.json`, the `floor-web` project).
 * With the app installed and the associated-domains entitlement signed, iOS opens the same link in
 * the app instead (`FloorLink` reads it); until the Apple team exists, the association file answers
 * 404 rather than name an app id that is not real.
 *
 * Everything shown is public record. The member lookup runs in the reader's browser against the
 * existing `/v1/reps` and `/v1/votes/{id}` routes; the page saves nothing it is given.
 */
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import type { OpenAPIHono } from "@hono/zod-openapi";
import type { Bill, BillRepository, BillStage, ScheduleRepository } from "./app.js";
import { BILL_LABEL } from "./bills.js";

type Chamber = "house" | "senate";

/** Where share links point. floor.app is the locked design's domain; `FLOOR_SHARE_BASE` overrides it. */
export const DEFAULT_SHARE_BASE = "https://floor.app";
/** Where the page's browser-side lookups go. */
export const DEFAULT_API_BASE = "https://floor-api.vercel.app";
/** "Get Floor for iPhone": the beta sign-up on the landing page, until there is an App Store listing. */
export const DEFAULT_GET_APP_URL = "https://floor-web-seven.vercel.app/#get";
/** The app's bundle id (`FLOOR_BUNDLE_ID` in ios/project.yml). */
export const DEFAULT_BUNDLE_ID = "app.floor.ios";
/** A page or card changes when the bill does: the catalog refreshes hourly at most. */
export const SHARE_CACHE_CONTROL = "public, max-age=300, s-maxage=900, stale-while-revalidate=3600";

/** A bill on a chamber's floor schedule (`floor_schedule`), the week it is scheduled for. */
export interface FloorWeek {
  chamber: Chamber;
  /** The Monday, `2026-11-16`. */
  weekOf: string;
}

export interface ShareOptions {
  base?: string;
  apiBase?: string;
  getAppUrl?: string;
  /** The Apple Developer team id. Until it is set the association file is a 404. */
  appleTeamId?: string;
  bundleId?: string;
}

const LAW_TYPES = ["hr", "s", "hjres", "sjres"];
const TYPES = Object.keys(BILL_LABEL);

/** `119-hr-5267` from the link's parts, or null when they are not a bill's. */
export function billIdFromPath(congress: string, type: string, number: string): string | null {
  if (!/^\d{2,3}$/.test(congress) || !TYPES.includes(type) || !/^[1-9]\d{0,5}$/.test(number)) return null;
  return `${congress}-${type}-${number}`;
}

export const shareUrl = (bill: Pick<Bill, "congress" | "type" | "number">, base = DEFAULT_SHARE_BASE) =>
  `${base}/bill/${bill.congress}/${bill.type}/${bill.number}`;

const CHAMBER: Record<Chamber, string> = { house: "House", senate: "Senate" };

/** Eastern calendar day, `2026-11-14`. */
const easternDay = (at: Date) => new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York" }).format(at);

/** "Nov 16". */
const monthDay = (date: string) =>
  new Date(`${date}T12:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });

/** "Nov 13, 2026". */
const fullDate = (date: string) =>
  new Date(`${date.slice(0, 10)}T12:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });

/** True when `weekOf` (a Monday) is the week `now` falls in. */
const isThisWeek = (weekOf: string, now: Date) => {
  const today = easternDay(now);
  const end = new Date(Date.parse(`${weekOf}T00:00:00Z`) + 7 * 86_400_000).toISOString().slice(0, 10);
  return weekOf <= today && today < end;
};

const STAGE_KICKER: Record<BillStage, string> = {
  introduced: "INTRODUCED",
  passed_house: "PASSED THE HOUSE",
  passed_senate: "PASSED THE SENATE",
  passed_both: "PASSED BOTH CHAMBERS",
  to_president: "SENT TO THE PRESIDENT",
  law: "BECAME LAW",
  vetoed: "VETOED",
  failed: "FAILED",
  adopted: "AGREED TO",
};

/** "H.R. 5267 · ON THE FLOOR THIS WEEK", else the week it is scheduled for, else where it stands. */
export function shareKicker(bill: Bill, week: FloorWeek | null, now: Date): string {
  if (week) {
    return `${bill.citation} · ${isThisWeek(week.weekOf, now) ? "ON THE FLOOR THIS WEEK" : `ON THE FLOOR THE WEEK OF ${monthDay(week.weekOf).toUpperCase()}`}`;
  }
  return bill.stage ? `${bill.citation} · ${STAGE_KICKER[bill.stage]}` : bill.citation;
}

/** The bill's name, when it has a short one worth saying: "the American Franchise Act". */
/**
 * The name the text calls a bill by: its short title, or else its official title when that reads as a
 * name ("American Franchise Act") rather than a purpose clause ("To amend the National Trails System
 * Act…"), which most bills without a short title have and which reads badly mid-sentence.
 */
export function billName(bill: Pick<Bill, "shortTitle" | "title">): string | null {
  if (bill.shortTitle) return bill.shortTitle;
  const t = bill.title?.trim();
  if (!t || /^(to|a bill|a resolution|a joint resolution|a concurrent resolution|providing|expressing|recognizing|supporting|condemning|designating|authorizing|directing|requesting|relating)\b/i.test(t) || t.length > 90) return null;
  return t;
}

const named = (bill: Bill) => {
  const name = billName(bill);
  return name ? `, the ${name.replace(/^the\s+/i, "")},` : "";
};

const STAGE_CLAUSE: Record<BillStage, (b: Bill) => string> = {
  introduced: (b) => `was introduced in the ${b.originChamber ? CHAMBER[b.originChamber] : "Congress"}`,
  passed_house: () => "passed the House",
  passed_senate: () => "passed the Senate",
  passed_both: () => "passed the House and the Senate",
  to_president: () => "was sent to the President",
  law: () => "became law",
  vetoed: () => "was vetoed",
  failed: () => "failed",
  adopted: () => "was agreed to",
};

/**
 * The share sheet's line: a fact, neither for nor against. "H.R. 5267, the American Franchise Act,
 * is up for a House vote the week of Nov 16. What it does and how our members vote:"
 */
export function shareText(bill: Bill, week: FloorWeek | null): string {
  const what = week
    ? `is up for a ${CHAMBER[week.chamber]} vote the week of ${monthDay(week.weekOf)}`
    : bill.stage
      ? STAGE_CLAUSE[bill.stage](bill)
      : "is before Congress";
  const tail = week ? "What it does and how our members vote:" : bill.votes.length ? "What it does and how our members voted:" : "What it does and where it stands:";
  return `${bill.citation}${named(bill)} ${what}. ${tail}`;
}

export interface RoadStep {
  label: string;
  state: "done" | "current" | "todo" | "stopped";
}

/**
 * The five-step road for a bill that can become law (introduced, passed one chamber, passed both,
 * to the President, law); a resolution's shorter road. A veto or a failure stops the road at the
 * step it did not make.
 */
export function road(bill: Pick<Bill, "type" | "stage" | "actions">): RoadStep[] {
  const passedOne = bill.actions.some((a) => /^passed\/agreed to in/i.test(a.text));
  let labels: string[];
  let reached: number;
  let stoppedLabel: string | null = null;
  if (LAW_TYPES.includes(bill.type)) {
    labels = ["Introduced", "Passed one chamber", "Passed both", "To the President", "Law"];
    const at: Partial<Record<BillStage, number>> = { introduced: 0, passed_house: 1, passed_senate: 1, passed_both: 2, to_president: 3, law: 4, vetoed: 3 };
    reached = bill.stage === "failed" ? (passedOne ? 1 : 0) : (at[bill.stage ?? "introduced"] ?? 0);
    if (bill.stage === "vetoed") stoppedLabel = "Vetoed";
  } else if (bill.type === "hres" || bill.type === "sres") {
    labels = ["Introduced", "Agreed to"];
    reached = bill.stage === "adopted" ? 1 : 0;
  } else {
    labels = ["Introduced", "Passed one chamber", "Agreed to by both"];
    const at: Partial<Record<BillStage, number>> = { passed_house: 1, passed_senate: 1, passed_both: 1, adopted: 2 };
    reached = bill.stage === "failed" ? (passedOne ? 1 : 0) : (at[bill.stage ?? "introduced"] ?? 0);
  }
  if (bill.stage === "failed") stoppedLabel = "Failed";
  // Nothing more will happen: the step it reached is done, not in progress.
  const settled = bill.stage === "law" || bill.stage === "adopted" || stoppedLabel !== null;
  return labels.map((label, i) => {
    if (i < reached || (i === reached && settled)) return { label, state: "done" as const };
    if (i === reached) return { label, state: "current" as const };
    if (i === reached + 1 && stoppedLabel) return { label: stoppedLabel, state: "stopped" as const };
    return { label, state: "todo" as const };
  });
}

// MARK: - The page

const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

/** The CRS summary's first sentences, for the description meta tag. */
const describe = (bill: Bill) => {
  const text = (bill.summary ?? bill.title).replace(/\s+/g, " ").trim();
  return text.length > 200 ? `${text.slice(0, 197).replace(/\s+\S*$/, "")}…` : text;
};

const FONTS = "https://fonts.googleapis.com/css2?family=Barlow+Condensed:ital,wght@0,600;0,800;1,900&family=Inter:wght@400;600&display=swap";

const STYLE = `
:root{--ground:#07080a;--panel:#0b0c0f;--surface:#14161b;--surface-2:#1e2128;--line:#2a2e36;--muted:#9ba1ad;--body:#c4c9d2;--ink:#f2f4f7;--yea:#34d399;--nay:#fb923c;--accent:#facc15}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--ground);color:var(--body);font:400 17px/1.55 Inter,system-ui,sans-serif}
main{max-width:720px;margin:0 auto;padding:28px 16px 64px}
a{color:var(--ink)}
.brand{font:800 18px/1 "Barlow Condensed",sans-serif;letter-spacing:.08em;color:var(--ink);text-decoration:none}
.kicker{margin:32px 0 8px;font:800 16px/1.2 "Barlow Condensed",sans-serif;letter-spacing:.06em;color:var(--accent)}
h1{margin:0;font:italic 900 clamp(40px,9vw,72px)/.92 "Barlow Condensed",sans-serif;color:var(--ink);overflow-wrap:anywhere}
.official{margin:12px 0 0;color:var(--muted);font-size:15px}
section{margin-top:36px}
h2{margin:0 0 12px;font:800 16px/1.2 "Barlow Condensed",sans-serif;letter-spacing:.06em;color:var(--muted);text-transform:uppercase}
.card{background:var(--surface);border:1px solid var(--line);border-radius:18px;padding:18px}
.summary p{margin:0 0 12px}.summary p:last-child{margin:0}
.source{margin-top:10px;font-size:13px;color:var(--muted)}
ol.road{list-style:none;margin:0;padding:0;display:grid;grid-template-columns:repeat(var(--steps),minmax(0,1fr));gap:6px}
ol.road li{font:600 14px/1.15 "Barlow Condensed",sans-serif;color:var(--muted);padding-top:10px;border-top:4px solid var(--surface-2);overflow-wrap:anywhere}
ol.road li.done{color:var(--ink);border-color:var(--yea)}
ol.road li.current{color:var(--ink);border-color:var(--accent)}
ol.road li.stopped{color:var(--nay);border-color:var(--nay)}
@media (max-width:479px){ol.road{grid-template-columns:1fr;gap:4px}ol.road li{padding:4px 0 4px 12px;border-top:0;border-left:4px solid var(--surface-2);font-size:16px}}
.latest time{display:block;font-size:14px;color:var(--muted)}
ul.votes{list-style:none;margin:0;padding:0}
ul.votes li{padding:10px 0;border-top:1px solid var(--line)}ul.votes li:first-child{border-top:0;padding-top:0}
.score{font:800 18px/1 "Barlow Condensed",sans-serif;color:var(--ink)}
.yours label{display:block;margin-bottom:8px}
.row{display:flex;gap:8px;flex-wrap:wrap}
input{flex:1 1 220px;min-width:0;font:inherit;color:var(--ink);background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:11px 12px}
button,.get{font:800 17px/1 "Barlow Condensed",sans-serif;letter-spacing:.04em;border:0;border-radius:10px;padding:13px 18px;cursor:pointer}
button{background:var(--ink);color:var(--ground)}
.note{margin:8px 0 0;font-size:13px;color:var(--muted)}
#result{margin-top:14px}#result .member{margin-top:12px}#result strong{color:var(--ink)}
.pos-yea{color:var(--yea)}.pos-nay{color:var(--nay)}
.get{display:inline-block;margin-top:40px;background:var(--yea);color:var(--ground);text-decoration:none}
footer{margin-top:40px;font-size:13px;color:var(--muted)}
`;

/**
 * Runs in the reader's browser. Reads the API base and the bill's vote ids from `data-` attributes
 * (so the script never carries data and its hash in the CSP never changes), asks `/v1/reps` for the
 * typed address, then each vote for those members' positions. Nothing is stored.
 */
const SCRIPT = `(function(){
var root=document.getElementById("yours");if(!root)return;
var api=root.getAttribute("data-api"),votes=JSON.parse(root.getAttribute("data-votes")||"[]");
var form=root.querySelector("form"),input=root.querySelector("input"),out=document.getElementById("result");
var POS={yea:"Yea",nay:"Nay",present:"Present",not_voting:"Did not vote",candidate:"Voted"};
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!=null)e.textContent=x;return e}
function say(x){out.textContent="";out.appendChild(el("p","note",x))}
form.addEventListener("submit",function(ev){ev.preventDefault();
var q=input.value.trim();if(q.length<6||/^\\d{5}(-\\d{4})?$/.test(q)){say("Enter a street address with the city, state and ZIP. A ZIP alone can sit across two districts.");return}
say("Looking up your members…");
fetch(api+"/v1/reps?address="+encodeURIComponent(q)).then(function(r){return r.json().then(function(b){return{s:r.status,b:b}})}).then(function(x){
if(x.s!==200){say(x.b&&x.b.error?x.b.error:"Couldn't look that up. Try again in a minute.");return}
var ms=x.b.members||[];if(!ms.length){say("That seat is vacant right now.");return}
var ids=ms.map(function(m){return m.bioguideId}).join(",");
return Promise.all(votes.map(function(v){return fetch(api+"/v1/votes/"+v+"?members="+ids).then(function(r){return r.ok?r.json():null})})).then(function(vs){
out.textContent="";
ms.forEach(function(m){var d=el("div","member");d.appendChild(el("strong",null,m.firstName+" "+m.lastName+" ("+m.party+"-"+m.state+(m.chamber==="house"?"-"+m.district:"")+")"));
var any=false;vs.forEach(function(v){if(!v)return;var p=(v.positions||[]).filter(function(p){return p.member.bioguideId===m.bioguideId})[0];if(!p)return;any=true;
var line=el("div");line.appendChild(document.createTextNode((v.chamber==="house"?"House":"Senate")+" · "+v.question+": "));line.appendChild(el("span","pos-"+p.position,POS[p.position]||p.position));d.appendChild(line)});
if(!any)d.appendChild(el("div","note",votes.length?"Not on a recorded vote on this bill.":"No recorded votes on this bill yet."));
out.appendChild(d)})})}).catch(function(){say("Couldn't reach Floor's vote server.")})})})();`;

const SCRIPT_HASH = `'sha256-${createHash("sha256").update(SCRIPT).digest("base64")}'`;

/** The page's CSP: inline style, the one inline script by hash, Google Fonts, and the API for the lookup. */
export const pageCsp = (apiBase: string) =>
  [
    "default-src 'none'",
    `script-src ${SCRIPT_HASH}`,
    "style-src 'unsafe-inline' https://fonts.googleapis.com",
    "font-src https://fonts.gstatic.com",
    "img-src 'self'",
    `connect-src ${new URL(apiBase).origin}`,
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'none'",
  ].join("; ");

const shell = (head: string, body: string) =>
  `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">` +
  `<meta name="theme-color" content="#07080a"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>` +
  `<link rel="stylesheet" href="${FONTS}"><style>${STYLE}</style>${head}</head><body><main>` +
  `<a class="brand" href="/">FLOOR</a>${body}</main></body></html>`;

const positionWord = (v: Bill["votes"][number]) => `${v.totals.yea}–${v.totals.nay}`;

export function renderBillPage(bill: Bill, week: FloorWeek | null, now: Date, opts: ShareOptions = {}): string {
  const base = opts.base ?? DEFAULT_SHARE_BASE;
  const api = opts.apiBase ?? DEFAULT_API_BASE;
  const url = shareUrl(bill, base);
  const title = bill.shortTitle ?? bill.label;
  const kicker = shareKicker(bill, week, now);
  const description = describe(bill);
  const card = `${url}/card.png`;
  const finals = bill.votes.filter((v) => v.state === "final");
  const steps = road(bill);
  const head =
    `<title>${esc(`${bill.citation}: ${title}`)} · Floor</title>` +
    `<meta name="description" content="${esc(description)}"><link rel="canonical" href="${esc(url)}">` +
    `<meta property="og:type" content="website"><meta property="og:site_name" content="Floor">` +
    `<meta property="og:title" content="${esc(`${bill.citation}: ${title}`)}"><meta property="og:description" content="${esc(description)}">` +
    `<meta property="og:url" content="${esc(url)}"><meta property="og:image" content="${esc(card)}">` +
    `<meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">` +
    `<meta property="og:image:alt" content="${esc(`${kicker}. ${title}`)}">` +
    `<meta name="twitter:card" content="summary_large_image"><meta name="twitter:title" content="${esc(`${bill.citation}: ${title}`)}">` +
    `<meta name="twitter:description" content="${esc(description)}"><meta name="twitter:image" content="${esc(card)}">`;
  const summary = bill.summary
    ? `<div class="card summary">${bill.summary
        .split(/\n+/)
        .filter((p) => p.trim())
        .map((p) => `<p>${esc(p.trim())}</p>`)
        .join("")}<div class="source">Congressional Research Service summary${bill.summaryStage ? ` (${esc(bill.summaryStage)})` : ""}.</div></div>`
    : `<div class="card"><p class="note" style="margin:0">The Congressional Research Service has not summarized this bill yet.</p></div>`;
  const latest = bill.latestAction
    ? `<section class="latest"><h2>Latest action</h2><div class="card"><time datetime="${esc(bill.latestAction.on)}">${esc(fullDate(bill.latestAction.on))}</time>${esc(bill.latestAction.text)}</div></section>`
    : "";
  const votes = finals.length
    ? `<section><h2>Recorded votes</h2><div class="card"><ul class="votes">${finals
        .map(
          (v) =>
            `<li><span class="score">${esc(positionWord(v))}</span> · ${esc(v.chamber === "house" ? "House" : "Senate")}, ${esc(v.question)}` +
            `${v.result ? `: ${esc(v.result)}` : ""}${v.occurredAt ? ` <span class="note">${esc(fullDate(v.occurredAt))}</span>` : ""}</li>`,
        )
        .join("")}</ul></div></section>`
    : "";
  const body =
    `<p class="kicker">${esc(kicker)}</p><h1>${esc(title)}</h1>` +
    (bill.shortTitle && bill.shortTitle !== bill.title ? `<p class="official">${esc(bill.title)}</p>` : "") +
    `<section><h2>What it does</h2>${summary}</section>` +
    `<section><h2>Where it stands</h2><ol class="road" style="--steps:${steps.length}">${steps
      .map((s) => `<li class="${s.state}">${esc(s.label)}</li>`)
      .join("")}</ol></section>` +
    latest +
    votes +
    `<section class="yours" id="yours" data-api="${esc(api)}" data-votes="${esc(JSON.stringify(finals.slice(0, 10).map((v) => v.id)))}">` +
    `<h2>Your members</h2><div class="card"><form><label for="addr">Enter your address to see how your members voted.</label>` +
    `<div class="row"><input id="addr" name="address" autocomplete="street-address" placeholder="Street, city, state and ZIP" maxlength="200">` +
    `<button type="submit">Look up</button></div>` +
    `<p class="note">Floor sends it to the U.S. Census geocoder once to find your district. This page saves nothing.</p></form>` +
    `<div id="result" aria-live="polite"></div></div></section>` +
    `<a class="get" href="${esc(opts.getAppUrl ?? DEFAULT_GET_APP_URL)}">Get Floor for iPhone</a>` +
    `<footer>From Congress.gov, the House Clerk and the Senate. Floor is informational and takes no side.</footer>` +
    `<script>${SCRIPT}</script>`;
  return shell(head, body);
}

export function renderNotFound(): string {
  return shell(
    `<title>Bill not found · Floor</title><meta name="robots" content="noindex">`,
    `<p class="kicker">404</p><h1>No such bill</h1><p class="official">Floor has no bill at this address. Check the number, or find it in the app.</p>` +
      `<a class="get" href="${esc(DEFAULT_GET_APP_URL)}">Get Floor for iPhone</a>`,
  );
}

// MARK: - The card

type Node = { type: string; props: { style?: Record<string, unknown>; children?: unknown } };
const h = (style: Record<string, unknown>, children?: unknown): Node => ({ type: "div", props: { style: { display: "flex", ...style }, children } });

/**
 * Everything the card needs, loaded on the first card request and never at module load (lesson 64).
 *
 * `harfbuzzjs`, satori's text shaper, starts compiling `hb.wasm` the moment it is imported and
 * exports that work as a promise nothing awaits until the first render. v0.2.32 imported satori at
 * the top of this file, Vercel's file trace left `hb.wasm` out of the function, and the rejection,
 * with no handler yet, killed every instance at boot: every route answered 500. So the libraries
 * are dynamic imports here, `harfbuzzjs` is imported and awaited first so its failure is a rejection
 * someone is holding, and a failure costs this one route a 500 and nothing else. The wasm files are
 * in `includeFiles` (apps/api/vercel.json) because nothing the trace can follow names them.
 */
type CardLibs = {
  satori: typeof import("satori").default;
  Resvg: typeof import("@resvg/resvg-wasm").Resvg;
  fonts: { name: string; data: Buffer; weight: 800 | 900; style: "normal" | "italic" }[];
};
let libs: Promise<CardLibs> | null = null;

/**
 * Not `@vercel/og`: its Node bundle (1.0.3) throws "Dynamic require of fs is not supported" under
 * plain Node ESM, and it pulls in `sharp`.
 */
const loadCardLibs = () =>
  (libs ??= (async () => {
    // Required, not imported: under vitest an awaited `import()` of a module whose value is a
    // promise is itself assimilated as one, and fails. Node's ESM and CJS share this module, so it
    // is the same promise satori's own import of it gets.
    const require = createRequire(import.meta.url);
    await (require("harfbuzzjs") as Promise<unknown>);
    const [{ default: satori }, resvg, black, extra] = await Promise.all([
      import("satori"),
      import("@resvg/resvg-wasm"),
      readFile(new URL("../assets/BarlowCondensed-BlackItalic.ttf", import.meta.url)),
      readFile(new URL("../assets/BarlowCondensed-ExtraBold.ttf", import.meta.url)),
    ]);
    // Once per instance: a second initWasm throws "Already initialized".
    await resvg.initWasm(await readFile(require.resolve("@resvg/resvg-wasm/index_bg.wasm")));
    return {
      satori,
      Resvg: resvg.Resvg,
      fonts: [
        { name: "Barlow Condensed", data: black, weight: 900, style: "italic" },
        { name: "Barlow Condensed", data: extra, weight: 800, style: "normal" },
      ],
    };
  })());

/** The title's size on the card: as big as fits in three lines or so. */
export const cardTitleSize = (title: string) => (title.length <= 28 ? 120 : title.length <= 48 ? 100 : title.length <= 80 ? 80 : 64);

/** The 1200×630 preview card, PNG: dark Floor style, the kicker, the title big, italic and condensed. */
export async function renderCard(bill: Bill, week: FloorWeek | null, now: Date, base = DEFAULT_SHARE_BASE): Promise<Uint8Array> {
  const raw = bill.shortTitle ?? bill.label;
  const title = raw.length > 120 ? `${raw.slice(0, 117).replace(/\s+\S*$/, "")}…` : raw;
  const element = h(
    { width: "100%", height: "100%", flexDirection: "column", justifyContent: "space-between", background: "#07080a", padding: "64px 72px", fontFamily: "Barlow Condensed" },
    [
      h({ fontSize: 34, fontWeight: 800, letterSpacing: 2, color: "#facc15" }, shareKicker(bill, week, now)),
      h({ fontSize: cardTitleSize(title), fontWeight: 900, fontStyle: "italic", lineHeight: 0.92, color: "#f2f4f7" }, title),
      h({ justifyContent: "space-between", alignItems: "center", fontSize: 30, fontWeight: 800, color: "#9ba1ad", letterSpacing: 3 }, [
        h({ color: "#f2f4f7" }, "FLOOR"),
        h({}, new URL(base).host.toUpperCase()),
      ]),
    ],
  );
  const { satori, Resvg, fonts } = await loadCardLibs();
  const svg = await satori(element as never, { width: 1200, height: 630, fonts });
  return new Resvg(svg, { fitTo: { mode: "width", value: 1200 } }).render().asPng();
}

// MARK: - Universal links

/** The association file, or null while there is no Apple team to name the app by. */
export function appSiteAssociation(opts: ShareOptions): Record<string, unknown> | null {
  if (!opts.appleTeamId || !/^[A-Z0-9]{10}$/.test(opts.appleTeamId)) return null;
  return {
    applinks: {
      details: [
        {
          appIDs: [`${opts.appleTeamId}.${opts.bundleId ?? DEFAULT_BUNDLE_ID}`],
          components: [{ "/": "/bill/*", comment: "A shared bill opens its bill screen" }],
        },
      ],
    },
  };
}

// MARK: - Routes

export function mountShare(
  app: OpenAPIHono,
  deps: { bills: BillRepository; schedule: ScheduleRepository; now: () => Date; options: ShareOptions },
): void {
  const load = async (congress: string, type: string, number: string) => {
    const id = billIdFromPath(congress, type, number);
    const bill = id ? await deps.bills.getBill(id) : null;
    if (!bill) return null;
    const now = deps.now();
    return { bill, week: await deps.schedule.floorWeek(bill.id, now), now };
  };

  app.get("/bill/:congress/:type/:number", async (c) => {
    const { congress, type, number } = c.req.param();
    const found = await load(congress, type, number);
    c.header("Content-Security-Policy", pageCsp(deps.options.apiBase ?? DEFAULT_API_BASE));
    c.header("X-Content-Type-Options", "nosniff");
    c.header("Referrer-Policy", "no-referrer");
    if (!found) {
      c.header("Cache-Control", "public, max-age=60");
      return c.html(renderNotFound(), 404);
    }
    c.header("Cache-Control", SHARE_CACHE_CONTROL);
    return c.html(renderBillPage(found.bill, found.week, found.now, deps.options), 200);
  });

  app.get("/bill/:congress/:type/:number/card.png", async (c) => {
    const { congress, type, number } = c.req.param();
    const found = await load(congress, type, number);
    if (!found) return c.text("No such bill", 404);
    let png: Uint8Array;
    try {
      png = await renderCard(found.bill, found.week, found.now, deps.options.base);
    } catch (error) {
      // The card alone: the page, its og:image tag and every other route are unaffected.
      console.error("share card failed:", error);
      return c.text("The preview card could not be drawn", 500, { "Cache-Control": "no-store" });
    }
    return c.body(png.slice().buffer as ArrayBuffer, 200, { "Content-Type": "image/png", "Cache-Control": SHARE_CACHE_CONTROL });
  });

  const association = (c: { json: (body: unknown, status: 200 | 404) => Response; header: (k: string, v: string) => void }) => {
    const body = appSiteAssociation(deps.options);
    c.header("Cache-Control", "public, max-age=3600");
    return body ? c.json(body, 200) : c.json({ error: "No Apple team is configured yet (APPLE_TEAM_ID)." }, 404);
  };
  app.get("/.well-known/apple-app-site-association", (c) => association(c));
  app.get("/apple-app-site-association", (c) => association(c));
}
