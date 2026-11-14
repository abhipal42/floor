import {
  USER_AGENT,
  Throttle,
  isoDate,
  ownerOf,
  tidy,
  type Cache,
  type DisclosureSource,
  type ListedFiling,
  type ParseResult,
  type ParsedAsset,
  type ParsedTrade,
  type TxType,
} from "./disclosures.js";

// Senate financial disclosures from eFD (efdsearch.senate.gov).
//
// Searching needs a session that has accepted the site's agreement — a checkbox acknowledging the
// 5 U.S.C. §13107(c) prohibitions (docs/HANDOFF.md, "Financial disclosures") — then a Django CSRF
// token on every search request. The flow: GET /search/home/ (sets csrftoken, carries the form's
// csrfmiddlewaretoken), POST it back with prohibition_agreement=1 (302 to /search/), then POST
// /search/report/data/ with the cookie's token in X-CSRFToken. The search answers DataTables JSON:
// [first, last, office, <a href=/search/view/{annual|ptr|paper}/{uuid}/>title</a>, date received].
//
// Electronic reports are HTML pages of tables; paper reports are scanned page images
// (/search/view/paper/…) and are stored as paper, with their link, never OCR'd.

export const SENATE_BASE = "https://efdsearch.senate.gov";

/** eFD's report type ids for the search form. */
export const SENATE_REPORT_TYPES = { annual: 7, ptr: 11 } as const;
/** eFD's filer type id for a sitting or former senator (candidates and officers are other ids). */
const SENATOR = 1;

// ---------------------------------------------------------------------------------------------
// HTML

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", "#39": "'", "#35": "#" };

/** Text of an HTML fragment: tags dropped, entities decoded, whitespace collapsed. */
export function htmlText(html: string): string {
  return tidy(
    html
      .replace(/<br\s*\/?>/gi, " ")
      .replace(/<[^>]+>/g, " ")
      .replace(/&(#\d+|#x[0-9a-f]+|[a-z]+);/gi, (m, e: string) => {
        if (ENTITIES[e]) return ENTITIES[e]!;
        if (e.startsWith("#x")) return String.fromCodePoint(parseInt(e.slice(2), 16));
        if (e.startsWith("#")) return String.fromCodePoint(Number(e.slice(1)));
        return m;
      }),
  );
}

/** The rows of the first table after `marker`, each as its cells' inner HTML. Null when there is none before the next section. */
function tableAfter(html: string, marker: RegExp, until?: RegExp): { headers: string[]; rows: string[][] } | null {
  const at = html.search(marker);
  if (at < 0) return null;
  let rest = html.slice(at);
  const end = until ? rest.slice(1).search(until) : -1;
  if (end >= 0) rest = rest.slice(0, end + 1);
  const t = /<table[\s\S]*?<\/table>/i.exec(rest);
  if (!t) return null;
  const headers = [...t[0].matchAll(/<th[^>]*>([\s\S]*?)<\/th>/gi)].map((m) => htmlText(m[1]!));
  const body = /<tbody[^>]*>([\s\S]*?)<\/tbody>/i.exec(t[0])?.[1] ?? "";
  const rows = [...body.matchAll(/<tr[^>]*>([\s\S]*?)<\/tr>/gi)].map((r) => [...r[1]!.matchAll(/<td[^>]*>([\s\S]*?)<\/td>/gi)].map((c) => c[1]!));
  return { headers, rows };
}

function columns(headers: string[], wanted: string[]) {
  const idx = Object.fromEntries(wanted.map((w) => [w, headers.indexOf(w)]));
  const missing = wanted.filter((w) => idx[w]! < 0);
  if (missing.length) throw new Error(`table has no ${missing.join(", ")} column (has ${headers.join(" | ")})`);
  return idx as Record<string, number>;
}

const dash = (s: string) => (s === "--" || s === "" ? null : s);

const SENATE_TX: Record<string, TxType> = {
  Purchase: "buy",
  Sale: "sell",
  "Sale (Full)": "sell",
  "Sale (Partial)": "sell",
  Exchange: "exchange",
};

function owner(filed: string) {
  const o = ownerOf(filed);
  if (o === undefined) throw new Error(`unknown owner "${filed}"`);
  return o;
}

/** The trades of an electronically filed Senate PTR page. */
export function parseSenatePtr(html: string): ParsedTrade[] {
  const t = tableAfter(html, /<h3[^>]*>[\s\S]*?Transactions/i);
  if (!t) throw new Error("no Transactions table");
  const c = columns(t.headers, ["Transaction Date", "Owner", "Ticker", "Asset Name", "Asset Type", "Type", "Amount", "Comment"]);
  return t.rows.map((r) => {
    const cell = (k: string) => htmlText(r[c[k]!] ?? "");
    const name = cell("Asset Name");
    const txFiled = cell("Type");
    const txType = SENATE_TX[txFiled];
    if (!txType) throw new Error(`unknown transaction type "${txFiled}" for ${name}`);
    const transactedOn = isoDate(cell("Transaction Date"));
    if (!transactedOn) throw new Error(`no transaction date for ${name}`);
    const amount = cell("Amount");
    if (!amount) throw new Error(`no amount for ${name}`);
    return {
      owner: owner(cell("Owner")),
      assetName: name,
      ticker: dash(cell("Ticker")),
      assetType: dash(cell("Asset Type")),
      assetTypeCode: null,
      txType,
      txTypeFiled: txFiled,
      amountRange: amount,
      transactedOn,
      notifiedOn: null,
      capGainsOver200: null,
      comment: dash(cell("Comment")),
    };
  });
}

/**
 * Part 3 (assets) of an electronically filed Senate annual report. A row numbered "98.1" is held
 * inside row 98 (a trust's land, an account's funds), so it carries row 98's name as its account.
 */
export function parseSenateAnnual(html: string): ParsedAsset[] {
  const t = tableAfter(html, /<h3[^>]*>\s*Part 3\. Assets/i, /<h3[^>]*>\s*Part 4/i);
  if (!t) {
    // "Did you … own any asset …? No" leaves Part 3 with no table.
    if (/Part 3\. Assets/.test(html)) return [];
    throw new Error("no Part 3. Assets section");
  }
  const c = columns(t.headers, ["Asset", "Asset Type", "Owner", "Value", "Income Type", "Income"]);
  const byNumber = new Map<string, string>();
  return t.rows.map((r) => {
    const number = htmlText(r[0] ?? "");
    const assetCell = r[c["Asset"]!] ?? "";
    const strong = /<strong[^>]*>([\s\S]*?)<\/strong>/i.exec(assetCell);
    const name = htmlText(strong ? strong[1]! : assetCell);
    if (!name) throw new Error(`asset row ${number} has no name`);
    byNumber.set(number, name);
    const description = strong ? htmlText(assetCell.slice(strong.index + strong[0].length)) : "";
    // "Corporate Securities<div class=muted>Stock</div>": the type, then its subtype.
    const typeCell = r[c["Asset Type"]!] ?? "";
    const sub = /<div[^>]*>([\s\S]*?)<\/div>/i.exec(typeCell);
    const assetType = sub ? `${htmlText(typeCell.slice(0, sub.index))} / ${htmlText(sub[1]!)}` : htmlText(typeCell);
    const parent = number.includes(".") ? byNumber.get(number.slice(0, number.lastIndexOf("."))) : undefined;
    const cell = (k: string) => dash(htmlText(r[c[k]!] ?? ""));
    return {
      name,
      assetType: dash(assetType.replace(/ \/ $/, "")),
      assetTypeCode: null,
      account: parent ?? null,
      owner: owner(htmlText(r[c["Owner"]!] ?? "")),
      valueRange: cell("Value"),
      incomeType: cell("Income Type"),
      incomeRange: cell("Income"),
      description: description || null,
    };
  });
}

// ---------------------------------------------------------------------------------------------
// The search listing

/** One row of /search/report/data/ as a listed filing. Null for a report type we do not read. */
export function parseSenateRow(row: unknown[]): ListedFiling | null {
  const [first, last, , link, date] = row.map((v) => String(v ?? ""));
  const m = /href="(\/search\/view\/(annual|ptr|paper)\/([0-9a-f-]{36})\/)"[^>]*>([\s\S]*?)<\/a>/i.exec(link ?? "");
  if (!m) return null;
  const [, path, view, uuid, titleHtml] = m;
  const title = htmlText(titleHtml!);
  const kind = /Periodic Transaction/i.test(title) ? "ptr" : /Annual Report/i.test(title) ? "annual" : null;
  if (!kind) return null;
  const year = /\bCY (\d{4})\b|\bCalendar (\d{4})\b/.exec(title);
  return {
    id: `senate-${uuid}`,
    chamber: "senate",
    filerName: tidy(`${first} ${last}`),
    first: tidy(first ?? ""),
    last: tidy(last ?? ""),
    stateDistrict: null,
    kind,
    amendment: /Amendment/i.test(title),
    reportYear: kind === "annual" && year ? Number(year[1] ?? year[2]) : null,
    filedOn: isoDate(date ?? ""),
    sourceUrl: `${SENATE_BASE}${path}`,
    format: view === "paper" ? "paper" : null,
  };
}

// ---------------------------------------------------------------------------------------------
// The session and the source

/** A minimal cookie jar: name → value, from each response's Set-Cookie headers. */
class Jar {
  private cookies = new Map<string, string>();
  take(res: Response) {
    for (const c of res.headers.getSetCookie()) {
      const [pair] = c.split(";");
      const i = pair!.indexOf("=");
      if (i > 0) this.cookies.set(pair!.slice(0, i).trim(), pair!.slice(i + 1).trim());
    }
  }
  get(name: string) {
    return this.cookies.get(name);
  }
  header() {
    return [...this.cookies].map(([k, v]) => `${k}=${v}`).join("; ");
  }
}

export interface SenateSourceOptions {
  /** Annual reports received on or after this date are listed. */
  annualSince: string;
  /** PTRs received on or after this date are listed. */
  ptrSince: string;
  cache: Cache;
  throttle: Throttle;
  fetchImpl?: typeof fetch;
  /** Rows per search request; eFD's own page offers up to 100. */
  pageSize?: number;
}

const usDate = (iso: string) => `${iso.slice(5, 7)}/${iso.slice(8, 10)}/${iso.slice(0, 4)} 00:00:00`;

export function senateSource(opts: SenateSourceOptions): DisclosureSource {
  const fetchImpl = opts.fetchImpl ?? fetch;
  const jar = new Jar();
  let agreed = false;
  const request = async (path: string, init: RequestInit = {}) => {
    await opts.throttle.wait();
    const res = await fetchImpl(`${SENATE_BASE}${path}`, {
      ...init,
      redirect: "manual",
      headers: { "user-agent": USER_AGENT, cookie: jar.header(), referer: `${SENATE_BASE}/search/`, ...(init.headers ?? {}) },
    });
    jar.take(res);
    return res;
  };

  /** Accepts the agreement once per run. See the note at the top of this file. */
  const agree = async () => {
    if (agreed) return;
    const home = await request("/search/home/");
    const token = /name="csrfmiddlewaretoken" value="([^"]+)"/.exec(await home.text())?.[1];
    if (!token) throw new Error("eFD home page has no CSRF token (the agreement form changed?)");
    const res = await request("/search/home/", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", referer: `${SENATE_BASE}/search/home/` },
      body: new URLSearchParams({ prohibition_agreement: "1", csrfmiddlewaretoken: token }).toString(),
    });
    if (res.status !== 302 && !res.ok) throw new Error(`eFD agreement returned HTTP ${res.status}`);
    agreed = true;
  };

  const search = async (type: number, since: string): Promise<ListedFiling[]> => {
    const out: ListedFiling[] = [];
    const length = opts.pageSize ?? 100;
    for (let start = 0; ; start += length) {
      const csrf = jar.get("csrftoken") ?? "";
      const res = await request("/search/report/data/", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded", "x-csrftoken": csrf },
        body: new URLSearchParams({
          start: String(start),
          length: String(length),
          report_types: `[${type}]`,
          filer_types: `[${SENATOR}]`,
          submitted_start_date: usDate(since),
          submitted_end_date: "",
          candidate_state: "",
          senator_state: "",
          office_id: "",
          first_name: "",
          last_name: "",
          csrfmiddlewaretoken: csrf,
        }).toString(),
      });
      if (!res.ok) throw new Error(`eFD search returned HTTP ${res.status}`);
      const page = (await res.json()) as { recordsFiltered?: number; data?: unknown[][] };
      for (const row of page.data ?? []) {
        const f = parseSenateRow(row);
        if (f) out.push(f);
      }
      if (!page.data?.length || start + length >= (page.recordsFiltered ?? 0)) return out;
    }
  };

  return {
    chamber: "senate",
    throttle: opts.throttle,
    async list() {
      await agree();
      return [...(await search(SENATE_REPORT_TYPES.annual, opts.annualSince)), ...(await search(SENATE_REPORT_TYPES.ptr, opts.ptrSince))];
    },
    async parse(f): Promise<ParseResult> {
      if (/\/view\/paper\//.test(f.sourceUrl)) return { format: "paper" };
      const key = `senate/${f.id.replace(/^senate-/, "")}.html`;
      let bytes = opts.cache.get(key);
      if (!bytes) {
        await agree();
        const res = await request(new URL(f.sourceUrl).pathname);
        // Without an accepted agreement eFD redirects to the home page rather than refusing.
        if (!res.ok) throw new Error(`${f.sourceUrl} returned HTTP ${res.status}`);
        bytes = new Uint8Array(await res.arrayBuffer());
        opts.cache.put(key, bytes);
      }
      const html = new TextDecoder().decode(bytes);
      return f.kind === "ptr"
        ? { format: "electronic", assets: [], trades: parseSenatePtr(html) }
        : { format: "electronic", assets: parseSenateAnnual(html), trades: [] };
    },
  };
}
