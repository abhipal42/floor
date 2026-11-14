/**
 * Pure helpers for bill lists and search: citations, plain short labels for long CRS titles, bill
 * numbers typed any way, and the CRS policy areas. No database here, so each is tested on real
 * titles in `bills.test.ts`.
 */

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

/** Topics whose name contains every word of the query: "health" → Health; "public lands" → Public Lands…. */
export function matchTopics(q: string): string[] {
  const words = q.toLowerCase().split(/[^a-z]+/).filter((w) => w.length >= 3);
  if (words.length === 0) return [];
  return POLICY_AREAS.filter((p) => {
    const area = p.toLowerCase();
    return words.every((w) => new RegExp(`\\b${w}`).test(area));
  });
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

/** Every bill a title cites in parentheses, "(H.R. 140)", in Floor's spelling. */
function citedBills(title: string): string[] {
  const cites: string[] = [];
  for (const m of title.matchAll(/\(((?:H|S)\.?\s?(?:R|Res|J\.?\s?Res|Con\.?\s?Res)?\.?\s?\d+)\)/gi)) {
    const parsed = parseBillNumber(m[1]!);
    if (parsed) {
      const c = billCitation(parsed.type, parsed.number);
      if (!cites.includes(c)) cites.push(c);
    }
  }
  return cites;
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
