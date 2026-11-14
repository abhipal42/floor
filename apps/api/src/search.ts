/**
 * Reading a member search box: a name, a state ("New York", "NY") or a seat ("NY-8", "WY-AL", "DC").
 *
 * Parsed here rather than in SQL so every reading is tested on its own, and so the query the
 * database sees is one of three fixed shapes.
 */

/** Every jurisdiction with a member of Congress, by USPS code. The last six send a non-voting House member and no senators. */
export const STATES: Readonly<Record<string, string>> = {
  AL: "Alabama", AK: "Alaska", AZ: "Arizona", AR: "Arkansas", CA: "California", CO: "Colorado", CT: "Connecticut",
  DE: "Delaware", FL: "Florida", GA: "Georgia", HI: "Hawaii", ID: "Idaho", IL: "Illinois", IN: "Indiana", IA: "Iowa",
  KS: "Kansas", KY: "Kentucky", LA: "Louisiana", ME: "Maine", MD: "Maryland", MA: "Massachusetts", MI: "Michigan",
  MN: "Minnesota", MS: "Mississippi", MO: "Missouri", MT: "Montana", NE: "Nebraska", NV: "Nevada", NH: "New Hampshire",
  NJ: "New Jersey", NM: "New Mexico", NY: "New York", NC: "North Carolina", ND: "North Dakota", OH: "Ohio",
  OK: "Oklahoma", OR: "Oregon", PA: "Pennsylvania", RI: "Rhode Island", SC: "South Carolina", SD: "South Dakota",
  TN: "Tennessee", TX: "Texas", UT: "Utah", VT: "Vermont", VA: "Virginia", WA: "Washington", WV: "West Virginia",
  WI: "Wisconsin", WY: "Wyoming",
  DC: "District of Columbia", PR: "Puerto Rico", GU: "Guam", VI: "U.S. Virgin Islands", AS: "American Samoa",
  MP: "Northern Mariana Islands",
};

/** Places whose one House member is a delegate (or Puerto Rico's resident commissioner) for the whole place. */
export const DELEGATE_JURISDICTIONS: ReadonlySet<string> = new Set(["DC", "PR", "GU", "VI", "AS", "MP"]);

export type MemberQuery =
  /** One House seat. `district` 0 is at large; for a delegate jurisdiction any number means its one seat. */
  | { kind: "seat"; state: string; district: number }
  /** A state; `name` is the text as a name search too ("Washington" is a state and a surname). */
  | { kind: "state"; state: string; name: string }
  /** As `foldName` leaves it: lower case, accents folded, hyphens as spaces, no apostrophes. */
  | { kind: "name"; text: string };

/**
 * Lower-case letters folded to plain ASCII, one for one. The SQL side (`folded` in `pg.ts`) builds its
 * `translate()` from this same table, so a typed name and a stored one fold alike. NFD already strips
 * most of these in `fold`; ø, ł, ı and đ have no decomposition, which is why the table is needed.
 */
export const FOLDS: readonly (readonly [string, string])[] = [
  ["áàâäãåāăą", "a"], ["çćč", "c"], ["ďđ", "d"], ["éèêëēėęě", "e"], ["ğ", "g"], ["íìîïīįı", "i"],
  ["ł", "l"], ["ñńň", "n"], ["óòôöõøōő", "o"], ["ř", "r"], ["śšş", "s"], ["ťţ", "t"],
  ["úùûüūůűų", "u"], ["ýÿ", "y"], ["źżž", "z"],
];

const FOLD_MAP: ReadonlyMap<string, string> = new Map(FOLDS.flatMap(([from, to]) => [...from].map((c) => [c, to] as const)));

/** Lower case with accents removed and runs of space collapsed: "Velázquez " → "velazquez". */
export function fold(s: string): string {
  return s
    .normalize("NFD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replace(/\p{L}/gu, (c) => FOLD_MAP.get(c) ?? c)
    .replace(/\s+/g, " ")
    .trim();
}

/** Full names, folded and without punctuation, plus the spellings people type for the territories. */
const NAMES: ReadonlyMap<string, string> = new Map([
  ...Object.entries(STATES).map(([code, name]) => [bare(name), code] as const),
  ["washington dc", "DC"],
  ["washington d c", "DC"],
  ["dc", "DC"],
  ["virgin islands", "VI"],
  ["us virgin islands", "VI"],
  ["northern marianas", "MP"],
  ["mariana islands", "MP"],
]);

function bare(s: string): string {
  return fold(s).replace(/[.,']/g, "").replace(/\s+/g, " ").trim();
}

/**
 * What a search box means.
 *
 * - `NY-8`, `ny 8`, `NY8`, `WY-AL`, `DC-AL`: one seat (AL is district 0, which is how at-large and
 *   delegate seats are stored).
 * - `New York`, `new york`, `Washington, D.C.`: a state by name.
 * - `NY`, `dc`, `N.Y.`: a state by code.
 * - A state, by name or code, is also searched as a name and the two merged: "Washington" is a state
 *   and a surname, and two letters that are a code ("Al", "Ok") also start names.
 * - Anything else is a name.
 */
export function parseMemberQuery(raw: string): MemberQuery {
  const text = raw.trim().replace(/\s+/g, " ");
  // "N.Y.-8", "N.Y.": a code written with periods.
  const compact = text.replace(/\./g, "");
  const seat = /^([A-Za-z]{2})\s*-?\s*(\d{1,2}|al)$/i.exec(compact);
  if (seat) {
    const state = seat[1]!.toUpperCase();
    const number = seat[2]!.toLowerCase();
    if (Object.hasOwn(STATES, state)) return { kind: "seat", state, district: number === "al" ? 0 : Number(number) };
  }
  const named = NAMES.get(bare(text));
  if (named) return { kind: "state", state: named, name: foldName(text) };
  if (/^[A-Za-z]{2}$/.test(compact) && Object.hasOwn(STATES, compact.toUpperCase())) {
    return { kind: "state", state: compact.toUpperCase(), name: foldName(compact) };
  }
  return { kind: "name", text: foldName(text) };
}

/**
 * A typed name as the search compares it: `fold`, then hyphens read as spaces and apostrophes
 * dropped, so "Ocasio Cortez" finds Ocasio-Cortez and "OHalleran" finds O'Halleran. The SQL side
 * folds the stored names the same way (`folded` in `pg.ts`).
 */
export function foldName(s: string): string {
  return fold(s.replace(/-/g, " ").replace(/['’]/g, ""));
}
