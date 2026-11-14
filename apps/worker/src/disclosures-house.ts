import { strFromU8, unzipSync } from "fflate";
import { getDocumentProxy } from "unpdf";
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

// House financial disclosures from the Clerk (disclosures-clerk.house.gov).
//
// The index is one zip a year, financial-pdfs/<YEAR>FD.zip, holding <YEAR>FD.txt (tab-separated)
// and the same rows as XML: Prefix, Last, First, Suffix, FilingType, StateDst, Year, FilingDate,
// DocID. Documents are PDFs: ptr-pdfs/<YEAR>/<DocID>.pdf for a PTR, financial-pdfs/<YEAR>/<DocID>.pdf
// for everything else. Electronically filed ones are generated from one template with extractable
// text; paper ones are scans with no text layer at all, and are stored as paper, never OCR'd.
//
// FilingType codes, from the 2025 index (2,977 rows): P periodic transaction report, O annual
// report (original), A amendment, C candidate report, X extension, T termination, W withdrawal,
// D, B, E, G, H other candidate/new-filer notices. Only P, O and A are member reports we read.

export const HOUSE_BASE = "https://disclosures-clerk.house.gov/public_disc";

/** FilingType codes we read, and what they are. */
const KINDS: Record<string, { kind: "annual" | "ptr"; amendment: boolean }> = {
  P: { kind: "ptr", amendment: false },
  O: { kind: "annual", amendment: false },
  A: { kind: "annual", amendment: true },
};

/**
 * Every asset type code the House uses, from fd.house.gov/reference/asset-type-codes.aspx (fetched
 * 2026-11-14). A filing writes the code in brackets after the asset ("GSK plc (GSK) [ST]").
 */
export const HOUSE_ASSET_TYPES: Record<string, string> = {
  "4K": "401K and Other Non-Federal Retirement Accounts",
  "5C": "529 College Savings Plan",
  "5F": "529 Portfolio",
  "5P": "529 Prepaid Tuition Plan",
  AB: "Asset-Backed Securities",
  BA: "Bank Accounts, Money Market Accounts and CDs",
  BK: "Brokerage Accounts",
  CO: "Collectibles",
  CS: "Corporate Securities (Bonds and Notes)",
  CT: "Cryptocurrency",
  DB: "Defined Benefit Pension",
  DO: "Debts Owed to the Filer",
  DS: "Delaware Statutory Trust",
  EF: "Exchange Traded Funds (ETF)",
  EQ: "Excepted/Qualified Blind Trust",
  ET: "Exchange Traded Notes",
  FA: "Farms",
  FE: "Foreign Exchange Position (Currency)",
  FN: "Fixed Annuity",
  FU: "Futures",
  GS: "Government Securities and Agency Debt",
  HE: "Hedge Funds & Private Equity Funds (EIF)",
  HN: "Hedge Funds & Private Equity Funds (non-EIF)",
  IC: "Investment Club",
  IH: "IRA (Held in Cash)",
  IP: "Intellectual Property & Royalties",
  IR: "IRA",
  MA: "Managed Accounts (e.g., SMA and UMA)",
  MF: "Mutual Funds",
  MO: "Mineral/Oil/Solar Energy Rights",
  OI: "Ownership Interest (Holding Investments)",
  OL: "Ownership Interest (Engaged in a Trade or Business)",
  OP: "Options",
  OT: "Other",
  PE: "Pensions",
  PM: "Precious Metals",
  PS: "Stock (Not Publicly Traded)",
  RE: "Real Estate Invest. Trust (REIT)",
  RF: "REIT (EIF)",
  RN: "REIT (non-EIF)",
  RP: "Real Property",
  RS: "Restricted Stock Units (RSUs)",
  SA: "Stock Appreciation Right",
  ST: "Stocks (including ADRs)",
  TR: "Trust",
  VA: "Variable Annuity",
  VI: "Variable Insurance",
  WU: "Whole/Universal Insurance",
};

export const houseIndexUrl = (year: number) => `${HOUSE_BASE}/financial-pdfs/${year}FD.zip`;
export const houseDocUrl = (kind: "annual" | "ptr", year: number, docId: string) =>
  `${HOUSE_BASE}/${kind === "ptr" ? "ptr-pdfs" : "financial-pdfs"}/${year}/${docId}.pdf`;

/** The member reports in one year's index (the TXT inside <YEAR>FD.zip). */
export function parseHouseIndex(txt: string): ListedFiling[] {
  const lines = txt.replace(/^\uFEFF/, "").split(/\r?\n/).filter((l) => l.trim());
  const header = lines.shift()?.split("\t") ?? [];
  const col = (name: string) => {
    const i = header.indexOf(name);
    if (i < 0) throw new Error(`House index has no ${name} column`);
    return i;
  };
  const [cLast, cFirst, cType, cSd, cYear, cDate, cDoc] = ["Last", "First", "FilingType", "StateDst", "Year", "FilingDate", "DocID"].map(col);
  // The index repeats some rows verbatim (2025FD lists Ansari's annual report, DocID 10078188,
  // twice), so rows are kept by DocID: the last listing wins.
  const out = new Map<string, ListedFiling>();
  for (const line of lines) {
    const f = line.split("\t").map((s) => s.trim());
    const kind = KINDS[f[cType!] ?? ""];
    const docId = f[cDoc!] ?? "";
    const year = Number(f[cYear!]);
    if (!kind || !/^\d+$/.test(docId) || !Number.isInteger(year)) continue;
    const last = f[cLast!] ?? "";
    const first = f[cFirst!] ?? "";
    out.set(docId, {
      id: `house-${docId}`,
      chamber: "house",
      filerName: tidy(`${first} ${last}`),
      first,
      last,
      stateDistrict: f[cSd!] || null,
      kind: kind.kind,
      amendment: kind.amendment,
      // The index Year of an annual report is the calendar year it covers (2025 reports are filed in
      // May 2026 and listed in 2025FD). For a PTR it is the year filed, and says nothing more.
      reportYear: kind.kind === "annual" ? year : null,
      filedOn: isoDate(f[cDate!] ?? ""),
      sourceUrl: houseDocUrl(kind.kind, year, docId),
      format: null,
    });
  }
  return [...out.values()];
}

// ---------------------------------------------------------------------------------------------
// Reading the PDFs

/** One run of text on a page, at its baseline position in PDF points (y grows upward). */
export interface TextItem {
  page: number;
  x: number;
  y: number;
  /** As extracted. The template's small-caps headings come out as capitals with NULs between. */
  raw: string;
  text: string;
}

export async function pdfItems(bytes: Uint8Array): Promise<TextItem[]> {
  // pdf.js takes ownership of (detaches) the buffer it is given; a copy keeps the caller's bytes usable.
  const pdf = await getDocumentProxy(new Uint8Array(bytes));
  const items: TextItem[] = [];
  for (let p = 1; p <= pdf.numPages; p++) {
    const page = await pdf.getPage(p);
    const content = await page.getTextContent();
    for (const it of content.items) {
      if (!("str" in it) || !it.str.trim()) continue;
      items.push({ page: p, x: it.transform[4], y: it.transform[5], raw: it.str, text: tidy(it.str.replaceAll("\u0000", "")) });
    }
  }
  await pdf.cleanup();
  return items;
}

/** A section heading of the House template: small caps (so NULs), set at the left margin. */
const isHeading = (it: TextItem) => it.raw.includes("\u0000") && it.x < 24;

/** Footer and boilerplate lines that sit inside a table's area but are not part of it. */
const isBoilerplate = (it: TextItem) =>
  /^Filing ID #\d+$/.test(it.text) ||
  // The footnote under a table ("* For the complete list of asset type abbreviations…", "* Investment
  // Vehicle details available at the bottom of this form…") and the link it wraps onto.
  it.text.startsWith("* ") ||
  it.text === "https://fd.house.gov/reference/asset-type-codes.aspx.";

/** The value of a "Label:" line in the filer block ("Name:", "State/District:"), or null. */
function field(items: TextItem[], label: string): string | null {
  const l = items.find((it) => it.text === label);
  if (!l) return null;
  const v = items.filter((it) => it.page === l.page && Math.abs(it.y - l.y) < 2 && it.x > l.x + 5).sort((a, b) => a.x - b.x);
  return v.length ? tidy(v.map((i) => i.text).join(" ")) : null;
}

interface Column {
  key: string;
  x: number;
}

/**
 * The items of the table under the heading `start` matches, up to the next heading, with each
 * page's repeated column-header band removed and every item tagged with its column. Columns come
 * from the header labels' x positions, so a template that moves a column still reads.
 */
function tableUnder(items: TextItem[], start: (heading: string) => boolean, labels: Record<string, string>) {
  const i0 = items.findIndex((it) => isHeading(it) && start(it.text));
  if (i0 < 0) return null;
  const body: TextItem[] = [];
  for (const it of items.slice(i0 + 1)) {
    if (isHeading(it)) break;
    if (!isBoilerplate(it)) body.push(it);
  }
  const columnsByPage = new Map<number, Column[]>();
  const out: (TextItem & { col: string })[] = [];
  for (const page of [...new Set(body.map((it) => it.page))]) {
    const onPage = body.filter((it) => it.page === page);
    const asset = onPage.find((it) => it.text === "Asset" && labels["Asset"]);
    let columns = columnsByPage.get(page - 1) ?? [];
    let headerFloor = Infinity;
    if (asset) {
      const band = onPage.filter((it) => Math.abs(it.y - asset.y) < 2 && labels[it.text]);
      columns = band.map((it) => ({ key: labels[it.text]!, x: it.x })).sort((a, b) => a.x - b.x);
      // Header labels wrap onto up to two more lines ("Gains >", "$200?"): everything from the top of
      // the page down to 26 points under the label row is header.
      headerFloor = asset.y - 26;
    }
    columnsByPage.set(page, columns);
    if (!columns.length) continue;
    for (const it of onPage) {
      if (it.y > headerFloor) continue;
      // An item belongs to the last column starting at or left of it (cells sit a point or two either side).
      const col = [...columns].reverse().find((c) => it.x >= c.x - 4) ?? columns[0]!;
      out.push({ ...it, col: col.key });
    }
  }
  // Reading order: page, then top to bottom, then left to right.
  return out.sort((a, b) => a.page - b.page || b.y - a.y || a.x - b.x);
}

/** A detail line under an asset: "D: description", "S O: account", "L: location", "C: comment", "F S: status". */
const DETAIL = /^(F S|S O|D|L|C):\s*/;

/** A complete range or value cell as the House prints them; anything else is waiting for its next line. */
const COMPLETE_VALUE = /^(None|Undetermined|(Spouse\/DC )?Over \$[\d,]+|\$[\d,]+ - \$[\d,]+)$/;

interface RawRow {
  cells: Record<string, string[]>;
  details: { tag: string; text: string }[];
}

/**
 * Cuts a table into rows. A row starts on the line where its anchor column (`anchor`) begins a new
 * cell; every other line belongs to the row above it, including lines carried onto the next page.
 * In the asset column, lines before the first detail tag are the asset's name and lines after a tag
 * continue that detail.
 */
function rowsOf(cells: (TextItem & { col: string })[], anchor: string, startsCell: (prevAnchorText: string | null, text: string) => boolean) {
  const anchors: { page: number; y: number }[] = [];
  let pending: string | null = null;
  for (const it of cells.filter((c) => c.col === anchor)) {
    if (startsCell(pending, it.text)) {
      anchors.push({ page: it.page, y: it.y });
      pending = it.text;
    } else pending = `${pending ?? ""} ${it.text}`;
  }
  const rows: RawRow[] = anchors.map(() => ({ cells: {}, details: [] }));
  for (const it of cells) {
    // The last anchor at or above this item, reading order.
    let r = -1;
    for (let i = 0; i < anchors.length; i++) {
      const a = anchors[i]!;
      if (a.page < it.page || (a.page === it.page && a.y >= it.y - 2)) r = i;
      else break;
    }
    if (r < 0) continue; // above the first row: nothing belongs there
    const row = rows[r]!;
    if (it.col === "asset") {
      const tag = DETAIL.exec(it.text);
      if (tag) row.details.push({ tag: tag[1]!, text: it.text.slice(tag[0].length) });
      else if (row.details.length) row.details.at(-1)!.text += ` ${it.text}`;
      else (row.cells.asset ??= []).push(it.text);
    } else (row.cells[it.col] ??= []).push(it.text);
  }
  return rows;
}

const cell = (row: RawRow, key: string) => {
  const v = row.cells[key];
  return v?.length ? tidy(v.join(" ")) : null;
};
const detail = (row: RawRow, tag: string) => {
  const v = row.details.filter((d) => d.tag === tag).map((d) => tidy(d.text));
  return v.length ? v.join("; ") : null;
};

/**
 * "GSK plc American Depositary Shares (GSK) [ST]" → name without the code, ticker GSK, code ST.
 * A holding inside an account is printed "Account ⇒ Holding [code]" (nested ones repeat the arrow):
 * the part before the last arrow is the account.
 */
export function splitAssetName(filed: string): { name: string; account: string | null; ticker: string | null; code: string | null } {
  const m = /\s*\[([0-9A-Z]{2})\]\s*$/.exec(filed);
  const code = m ? m[1]! : null;
  let full = m ? filed.slice(0, m.index).trim() : filed.trim();
  // Some filers type the code into the name as well: "FIMM Money Market (FNSXX) [BA] [BA]".
  while (code && full.endsWith(`[${code}]`)) full = full.slice(0, -code.length - 2).trim();
  // A second code inside the name means two rows ran together: refuse rather than store one wrong row.
  if (/\[[0-9A-Z]{2}\]/.test(full)) throw new Error(`two assets read as one: "${filed}"`);
  const parts = full.split("⇒").map((p) => p.trim());
  const name = parts.pop()!;
  const t = /\(([A-Z][A-Z0-9.-]{0,9})\)\s*$/.exec(name);
  return { name, account: parts.length ? parts.join(" ⇒ ") : null, ticker: t ? t[1]! : null, code };
}

function owner(row: RawRow) {
  const filed = cell(row, "owner") ?? "";
  const o = ownerOf(filed);
  if (o === undefined) throw new Error(`unknown owner "${filed}"`);
  return o;
}

const HOUSE_TX: Record<string, TxType> = { P: "buy", S: "sell", "S (partial)": "sell", E: "exchange" };

const PTR_LABELS: Record<string, string> = {
  ID: "id",
  Owner: "owner",
  Asset: "asset",
  Transaction: "type",
  Date: "date",
  Notification: "notified",
  Amount: "amount",
  "Cap.": "capGains",
};

const ANNUAL_LABELS: Record<string, string> = {
  Asset: "asset",
  Owner: "owner",
  "Value of Asset": "value",
  "Income Type(s)": "incomeType",
  Income: "income",
  "Tx. >": "tx",
};

/** The trades of an electronically filed House PTR. */
export function parseHousePtr(items: TextItem[]): ParsedTrade[] {
  const table = tableUnder(items, (h) => h === "T", PTR_LABELS);
  if (!table) throw new Error("no Transactions section");
  const rows = rowsOf(table, "date", (_, text) => isoDate(text) !== null);
  return rows.map((row) => {
    const filedName = cell(row, "asset");
    if (!filedName) throw new Error("a transaction with no asset");
    const { name, account: heldIn, ticker, code } = splitAssetName(filedName);
    const txFiled = cell(row, "type") ?? "";
    const txType = HOUSE_TX[txFiled];
    if (!txType) throw new Error(`unknown transaction type "${txFiled}" for ${name}`);
    const amount = cell(row, "amount");
    if (!amount) throw new Error(`no amount for ${name}`);
    const transactedOn = isoDate(cell(row, "date") ?? "");
    if (!transactedOn) throw new Error(`no transaction date for ${name}`);
    const account = heldIn ?? detail(row, "S O");
    const description = detail(row, "D");
    const comment = [account && `Held in: ${account}`, description, detail(row, "C")].filter(Boolean).join(" · ");
    return {
      owner: owner(row),
      assetName: name,
      ticker,
      assetType: code ? (HOUSE_ASSET_TYPES[code] ?? null) : null,
      assetTypeCode: code,
      txType,
      txTypeFiled: txFiled,
      amountRange: amount,
      transactedOn,
      notifiedOn: isoDate(cell(row, "notified") ?? ""),
      // Not read: in 125 sampled 2026 PTRs the "Cap. Gains > $200?" column never holds text (the box
      // is drawn, not written), so there is nothing to tell a tick from a blank. Null, not a guess.
      capGainsOver200: null,
      comment: comment || null,
    };
  });
}

/** Schedule A (assets and "unearned" income) of an electronically filed House annual report. */
export function parseHouseAnnual(items: TextItem[]): ParsedAsset[] {
  const table = tableUnder(items, (h) => h.startsWith("S A:"), ANNUAL_LABELS);
  if (!table) throw new Error("no Schedule A section");
  const rows = rowsOf(table, "value", (prev) => prev === null || COMPLETE_VALUE.test(prev));
  return rows.map((row) => {
    const filedName = cell(row, "asset");
    if (!filedName) throw new Error("an asset row with no asset");
    const { name, account, code } = splitAssetName(filedName);
    const location = detail(row, "L");
    const description = detail(row, "D");
    const comments = detail(row, "C");
    return {
      name,
      assetType: code ? (HOUSE_ASSET_TYPES[code] ?? null) : null,
      assetTypeCode: code,
      account: account ?? detail(row, "S O"),
      owner: owner(row),
      valueRange: cell(row, "value"),
      incomeType: cell(row, "incomeType"),
      incomeRange: cell(row, "income"),
      description: [location && `Location: ${location}`, description, comments].filter(Boolean).join(" · ") || null,
    };
  });
}

/** Reads one House filing's PDF. A document with no text layer is a scan: paper, not parsed. */
export async function parseHouseDocument(kind: "annual" | "ptr", bytes: Uint8Array): Promise<ParseResult> {
  const items = await pdfItems(bytes);
  if (items.length === 0) return { format: "paper" };
  return kind === "ptr"
    ? { format: "electronic", assets: [], trades: parseHousePtr(items) }
    : { format: "electronic", assets: parseHouseAnnual(items), trades: [] };
}

/** Name and State/District as printed on an electronic House filing, for checking a match. */
export const houseFiler = (items: TextItem[]) => ({ name: field(items, "Name:"), stateDistrict: field(items, "State/District:") });

// ---------------------------------------------------------------------------------------------
// The source

export interface HouseSourceOptions {
  years: number[];
  /** Only PTRs filed on or after this date are listed (the product shows a year of trades). */
  ptrSince: string;
  cache: Cache;
  throttle: Throttle;
  fetchImpl?: typeof fetch;
  /** How old a cached index zip may be before it is downloaded again. The Clerk rebuilds it daily. */
  indexMaxAgeMs?: number;
}

export function houseSource(opts: HouseSourceOptions): DisclosureSource {
  const fetchImpl = opts.fetchImpl ?? fetch;
  const get = async (key: string, url: string, maxAgeMs?: number) => {
    const hit = opts.cache.get(key, maxAgeMs);
    if (hit) return hit;
    await opts.throttle.wait();
    const res = await fetchImpl(url, { headers: { "user-agent": USER_AGENT } });
    if (!res.ok) throw new Error(`${url} returned HTTP ${res.status}`);
    const body = new Uint8Array(await res.arrayBuffer());
    opts.cache.put(key, body);
    return body;
  };
  return {
    chamber: "house",
    throttle: opts.throttle,
    async list() {
      const out: ListedFiling[] = [];
      for (const year of opts.years) {
        const zip = unzipSync(await get(`house/${year}FD.zip`, houseIndexUrl(year), opts.indexMaxAgeMs ?? 12 * 3600_000));
        const txt = Object.entries(zip).find(([name]) => name.toLowerCase().endsWith(".txt"));
        if (!txt) throw new Error(`${year}FD.zip has no TXT index`);
        out.push(
          ...parseHouseIndex(strFromU8(txt[1])).filter((f) => f.kind === "annual" || (f.filedOn !== null && f.filedOn >= opts.ptrSince)),
        );
      }
      return out;
    },
    async parse(f) {
      const docId = f.id.replace(/^house-/, "");
      const year = /\/(\d{4})\/\d+\.pdf$/.exec(f.sourceUrl)?.[1] ?? "x";
      return parseHouseDocument(f.kind, await get(`house/${year}/${docId}.pdf`, f.sourceUrl));
    },
  };
}
