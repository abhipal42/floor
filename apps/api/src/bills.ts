/**
 * Pure helpers for bill lists and search: citations, plain short labels for long CRS titles, bill
 * numbers typed any way, and the CRS policy areas. No database here, so each is tested on real
 * titles in `bills.test.ts`.
 */

import { RULE_TITLE } from "./votekinds.js";

/**
 * How each chamber writes a bill number. Defined once because every route that names a bill uses
 * it: if they formatted it separately, the same bill could appear as "H.R. 1013" on one screen and
 * something else on another.
 */
export const BILL_LABEL: Record<string, string> = {
  hr: "H.R.",
  s: "S.",
  hres: "H.Res.",
  sres: "S.Res.",
  hjres: "H.J.Res.",
  sjres: "S.J.Res.",
  hconres: "H.Con.Res.",
  sconres: "S.Con.Res.",
};

export const BILL_TYPES = Object.keys(BILL_LABEL);

export const billCitation = (type: string, number: number): string =>
  `${BILL_LABEL[type] ?? type.toUpperCase()} ${number}`;

/**
 * A bill number in any spelling people type: "hr 1013", "H.R.1013", "HR-1013", "s 2", "hjres 12",
 * "s.j.res.197", "H. Con. Res. 14", or a Floor ID ("119-hr-1013", which also fixes the Congress).
 * Returns null for anything else, including words that merely start with a type ("s" alone, "hr").
 */
export function parseBillNumber(q: string): { type: string; number: number; congress: number | null } | null {
  const text = q.trim().toLowerCase();
  const id = /^(\d{2,3})-([a-z]+)-(\d+)$/.exec(text);
  if (id && BILL_TYPES.includes(id[2]!)) return { congress: Number(id[1]), type: id[2]!, number: Number(id[3]) };
  const compact = text.replace(/[\s.\-_]/g, "");
  const m = /^([a-z]+)(\d{1,5})$/.exec(compact);
  if (!m || !BILL_TYPES.includes(m[1]!)) return null;
  return { type: m[1]!, number: Number(m[2]), congress: null };
}

/**
 * The 32 policy areas the Congressional Research Service assigns, one per bill, as Congress.gov
 * spells them. A topic is one of these, so a topic page is a complete list rather than a keyword
 * guess. Congress.gov also has "Private Legislation" (bills for the relief of one person); it is
 * not one of the 32 and is not offered as a topic, but a bill carrying it is still stored and
 * searchable.
 */
export const POLICY_AREAS = [
  "Agriculture and Food",
  "Animals",
  "Armed Forces and National Security",
  "Arts, Culture, Religion",
  "Civil Rights and Liberties, Minority Issues",
  "Commerce",
  "Congress",
  "Crime and Law Enforcement",
  "Economics and Public Finance",
  "Education",
  "Emergency Management",
  "Energy",
  "Environmental Protection",
  "Families",
  "Finance and Financial Sector",
  "Foreign Trade and International Finance",
  "Government Operations and Politics",
  "Health",
  "Housing and Community Development",
  "Immigration",
  "International Affairs",
  "Labor and Employment",
  "Law",
  "Native Americans",
  "Public Lands and Natural Resources",
  "Science, Technology, Communications",
  "Social Sciences and History",
  "Social Welfare",
  "Sports and Recreation",
  "Taxation",
  "Transportation and Public Works",
  "Water Resources Development",
] as const;

/** The canonical spelling of a topic name, case and spacing ignored; null when it is not one. */
export function topicNamed(name: string): string | null {
  const key = name.trim().replace(/\s+/g, " ").toLowerCase();
  return POLICY_AREAS.find((p) => p.toLowerCase() === key) ?? null;
}

/** Words a search carries that name no topic, though "and" and "of" sit in many topic names. */
const TOPIC_STOPWORDS = new Set(["and", "the", "for", "with", "act", "bill", "bills", "from", "into", "that", "this", "are", "not"]);

/**
 * Topics for a search. Names holding every word come first and alone ("public lands" → Public
 * Lands…, not every topic with "public" in it); when none holds them all, any topic holding one of
 * the words ("rural health" → Health). A word is a prefix of a name's word ("immig" → Immigration),
 * at least three letters, and not a stopword: "and" alone matches nothing.
 */
export function matchTopics(q: string): string[] {
  const words = q
    .toLowerCase()
    .split(/[^a-z]+/)
    .filter((w) => w.length >= 3 && !TOPIC_STOPWORDS.has(w));
  if (words.length === 0) return [];
  const has = (area: string, w: string) => new RegExp(`\\b${w}`).test(area.toLowerCase());
  const every = POLICY_AREAS.filter((p) => words.every((w) => has(p, w)));
  return every.length > 0 ? every : POLICY_AREAS.filter((p) => words.some((w) => has(p, w)));
}

const LABEL_MAX = 160;

/** "Department of Veterans Affairs" → "Department of Veterans Affairs'"; "EPA" → "EPA's". */
const possessive = (who: string) => (/s$/i.test(who) ? `${who}'` : `${who}'s`);

/** Strips one pair of surrounding quotes, including the '' a few CRS titles close with. */
const unquote = (s: string) =>
  s
    .trim()
    .replace(/\.$/, "")
    .replace(/^["“](.*?)(?:["”]|'')$/s, "$1")
    .trim();

const capitalize = (s: string) => (s ? s[0]!.toUpperCase() + s.slice(1) : s);

/** Cuts at a word boundary with an ellipsis; the full title is always on the bill screen. */
function clamp(s: string): string {
  if (s.length <= LABEL_MAX) return s;
  const cut = s.slice(0, LABEL_MAX - 1);
  return `${cut.slice(0, cut.lastIndexOf(" ") > 80 ? cut.lastIndexOf(" ") : cut.length).replace(/[,;:]$/, "")}…`;
}

/** Every measure a title cites in parentheses, "(H.R. 140)", "(H. Res. 1182)", "(S. 1383)", in order. */
function citedNumbers(title: string): { type: string; number: number }[] {
  const cites: { type: string; number: number }[] = [];
  for (const m of title.matchAll(/\(((?:H|S)\.?\s?(?:R|Res|J\.?\s?Res|Con\.?\s?Res)?\.?\s?\d+)\)/gi)) {
    const parsed = parseBillNumber(m[1]!);
    if (parsed) cites.push({ type: parsed.type, number: parsed.number });
  }
  return cites;
}

/** Every bill a title cites in parentheses, "(H.R. 140)", in Floor's spelling. */
function citedBills(title: string): string[] {
  return [...new Set(citedNumbers(title).map((c) => billCitation(c.type, c.number)))];
}

/**
 * The bill a House special rule is for: "Providing for consideration of the bill (H.R. 2102) …" →
 * "119-hr-2102", so a feed can file the rule's votes under that bill's story. A rule often covers
 * several measures; the first one it names is taken. Null for a title that is not a rule
 * (`RULE_TITLE`) or that cites nothing.
 */
export function ruleForBill(title: string, congress: number): string | null {
  if (!RULE_TITLE.test(title.trim())) return null;
  const first = citedNumbers(title)[0];
  return first ? `${congress}-${first.type}-${first.number}` : null;
}

const LEAD_MAX = 320;
/** A first sentence shorter than this takes the next one too, while the lead stays within `LEAD_MAX`. */
const LEAD_SHORT = 120;

/** A paragraph CRS puts before the summary proper: the bill's title on a line of its own, or the draft-text note. */
const isPreamble = (p: string) => !/[.!?:;]["')”]*$/.test(p) || /^The following analysis is based on draft bill text/i.test(p);

/** A period that ends an abbreviation rather than a sentence: "H.R.", "U.S.", "i.e.", "No.", "Res.". */
const ABBREVIATION = /(?:^|[\s(])(?:(?:[A-Z]\.)+|i\.e\.|e\.g\.|(?:Mr|Mrs|Ms|Dr|St|No|Nos|Sec|Secs|Jr|Sr|Inc|Co|Corp|Ltd|vs|Gen|Res|Con|Pub|Stat|etc)\.)$/;

/** The sentences of a paragraph, each with its closing punctuation. */
function sentences(p: string): string[] {
  const out: string[] = [];
  let start = 0;
  for (const m of p.matchAll(/[.!?]["')\]”]*(?=\s+["(“]?[A-Z]|\s*$)/g)) {
    const end = m.index + m[0].length;
    if (m[0].startsWith(".") && ABBREVIATION.test(p.slice(start, m.index + 1)) && end < p.length) continue;
    out.push(p.slice(start, end).trim());
    start = end;
  }
  const rest = p.slice(start).trim();
  if (rest) out.push(rest);
  return out;
}

/**
 * The opening of a bill's CRS summary, for a feed card: its first sentence, cut at the sentence's
 * end (a short one takes the next sentence too), at most about 320 characters. The title line CRS
 * starts most summaries with, and the note on draft text it starts some with, are skipped. Null when
 * there is no summary. A first sentence longer than the limit is cut at a word with an ellipsis.
 */
export function summaryLead(summary: string | null): string | null {
  const paragraphs = (summary ?? "")
    .split(/\n\s*\n/)
    .flatMap((p) => {
      // A title on its own line directly above the text (no blank line between, as in some 118th
      // Congress summaries) is a paragraph of its own. A line before a bullet list is not.
      const lines = p.trim().split("\n");
      return lines.length > 1 && isPreamble(lines[0]!.trim()) && !lines[1]!.trim().startsWith("•")
        ? [lines[0]!, lines.slice(1).join("\n")]
        : [p];
    })
    // Bullets read on as one sentence: "the House • condemns …; • reaffirms …" → "the House condemns …; reaffirms …".
    .map((p) => p.replace(/\n\s*•\s*/g, " ").replace(/\s+/g, " ").trim())
    .filter(Boolean);
  const found = paragraphs.find((p) => !isPreamble(p));
  if (!found) return null;
  // Some 118th Congress summaries run the title into the text with only a space ("… Act of 2023 This bill requires").
  const body = found.replace(/^[^.!?]*?\s?(?=This (?:bill|joint resolution|concurrent resolution|resolution)\b)/, "");
  const [first, ...more] = sentences(body);
  let lead = first!;
  if (lead.length > LEAD_MAX) {
    const cut = lead.slice(0, LEAD_MAX - 1);
    return `${cut.slice(0, cut.lastIndexOf(" ")).replace(/[,;:]$/, "")}…`;
  }
  for (const next of more) {
    if (lead.length >= LEAD_SHORT || lead.length + 1 + next.length > LEAD_MAX) break;
    lead = `${lead} ${next}`;
  }
  return lead;
}

const listOf = (items: string[]) =>
  items.length <= 1 ? (items[0] ?? "") : `${items.slice(0, -1).join(", ")} and ${items.at(-1)}`;

/**
 * A plain short label for a bill, for lists. The short title when Congress gave it one; otherwise
 * deterministic rewrites of the official title's set phrasings (no AI):
 *
 * - Congressional Review Act resolutions: "A joint resolution providing for congressional
 *   disapproval under chapter 8 of title 5, United States Code, of the rule submitted by X relating
 *   to "Y"." → `Disapproving X's rule: Y`.
 * - Arms-sale disapprovals → `Disapproving the arms sale to Qatar`, with the title's own verb:
 *   `arms export` for a proposed export licence, `arms transfer` for a proposed transfer.
 * - House rules ("Providing for consideration of the bill (H.R. 140) …") → `Rule for H.R. 140`,
 *   naming every measure the rule covers.
 * - Otherwise the title without "A bill"/"A joint resolution" in front and ", and for other
 *   purposes" behind, capitalised.
 *
 * Anything still longer than 160 characters is cut at a word with an ellipsis.
 */
export function billLabel(title: string, shortTitle: string | null): string {
  if (shortTitle?.trim()) return shortTitle.trim();
  const t = title.trim().replace(/\s+/g, " ");

  const cra =
    /^(?:A joint resolution )?providing (?:for )?congressional disapproval under chapter 8 of title 5, United States Code, of the rule submitted by (.+?) relating to (.+)$/i.exec(
      t,
    );
  if (cra) return clamp(`Disapproving ${possessive(cra[1]!.trim())} rule: ${capitalize(unquote(cra[2]!))}`);

  if (/^(?:A joint resolution )?providing for congressional disapproval of the proposed .*defense (?:articles|services)/i.test(t)) {
    const to = /\bto (?:the Government of )?(?:the )?([A-Z][^,.;]*?)(?= of certain\b|\.|,|$)/.exec(
      t.replace(/^.*?disapproval of the proposed/i, ""),
    );
    // The title's own word for the deal: a "foreign military sale", a "proposed export" (a
    // direct commercial licence), a "proposed transfer". Calling an export a sale says more than it does.
    const kind = /\b(sale|export|transfer)\b/i.exec(t.replace(/^.*?disapproval of the proposed/i, ""))?.[1]?.toLowerCase() ?? "sale";
    if (to) return `Disapproving the arms ${kind} to ${to[1]!.trim()}`;
  }

  if (/^Providing (?:for )?consideration of /i.test(t)) {
    const cites = citedBills(t);
    if (cites.length > 0) return clamp(`Rule for ${listOf(cites)}`);
  }

  if (/^An executive resolution authorizing the en bloc consideration/i.test(t)) {
    return "Confirming nominations en bloc";
  }

  const plain = t
    .replace(/^An? (?:bill|joint resolution|concurrent resolution|resolution|executive resolution) /i, "")
    .replace(/,? and for other purposes\.?$/i, "")
    .replace(/\.$/, "");
  return clamp(capitalize(plain));
}
