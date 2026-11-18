/**
 * The Local tab's jurisdictions: every state and the nine cities Floor covers. One entry each, and
 * everything about a jurisdiction is derived from its entry: where its records come from, the
 * Google News query for its headlines, and its `coverage`.
 *
 * A copy lives in apps/worker/src/jurisdictions.ts (the worker cannot import the API);
 * apps/worker/src/local.test.ts checks the two are equal.
 *
 * Not covered, by name: DC and the territories (Open States has DC's council, but the Local tab's
 * state hub is a legislature with a governor), and every city past these nine.
 */

export type RecordsSource =
  /** Open States v3 `/bills`, with `jurisdiction` = this ocd-jurisdiction id. */
  | { source: "openstates"; jurisdiction: string }
  /**
   * Legistar's web API, `https://webapi.legistar.com/v1/<client>/…`. `token` names the environment
   * variable holding the client's token, for a client that requires one (NYC). `web` is the host
   * a matter's public page is on.
   */
  | { source: "legistar"; client: string; web: string; token?: string };

export interface JurisdictionEntry {
  id: string;
  kind: "state" | "city";
  name: string;
  /** Postal code. */
  state: string;
  /** Census Incorporated Places GEOID, for a city. */
  placeGeoid: string | null;
  /** Null: no records source Floor can read (coverage `news_only`). */
  records: RecordsSource | null;
  /** The legislative body a city's items come from; a state's are its chambers. */
  council: string | null;
}

const STATES: [string, string][] = [
  ["AL", "Alabama"], ["AK", "Alaska"], ["AZ", "Arizona"], ["AR", "Arkansas"], ["CA", "California"],
  ["CO", "Colorado"], ["CT", "Connecticut"], ["DE", "Delaware"], ["FL", "Florida"], ["GA", "Georgia"],
  ["HI", "Hawaii"], ["ID", "Idaho"], ["IL", "Illinois"], ["IN", "Indiana"], ["IA", "Iowa"],
  ["KS", "Kansas"], ["KY", "Kentucky"], ["LA", "Louisiana"], ["ME", "Maine"], ["MD", "Maryland"],
  ["MA", "Massachusetts"], ["MI", "Michigan"], ["MN", "Minnesota"], ["MS", "Mississippi"], ["MO", "Missouri"],
  ["MT", "Montana"], ["NE", "Nebraska"], ["NV", "Nevada"], ["NH", "New Hampshire"], ["NJ", "New Jersey"],
  ["NM", "New Mexico"], ["NY", "New York"], ["NC", "North Carolina"], ["ND", "North Dakota"], ["OH", "Ohio"],
  ["OK", "Oklahoma"], ["OR", "Oregon"], ["PA", "Pennsylvania"], ["RI", "Rhode Island"], ["SC", "South Carolina"],
  ["SD", "South Dakota"], ["TN", "Tennessee"], ["TX", "Texas"], ["UT", "Utah"], ["VT", "Vermont"],
  ["VA", "Virginia"], ["WA", "Washington"], ["WV", "West Virginia"], ["WI", "Wisconsin"], ["WY", "Wyoming"],
];

const city = (
  id: string,
  name: string,
  state: string,
  placeGeoid: string,
  records: RecordsSource | null,
  council = "City Council",
): JurisdictionEntry => ({ id, kind: "city", name, state, placeGeoid, records, council });

export const JURISDICTIONS: JurisdictionEntry[] = [
  ...STATES.map(([postal, name]): JurisdictionEntry => ({
    id: postal.toLowerCase(),
    kind: "state",
    // "New York State" so the hub's name is not the city's.
    name: postal === "NY" ? "New York State" : name,
    state: postal,
    placeGeoid: null,
    records: { source: "openstates", jurisdiction: `ocd-jurisdiction/country:us/state:${postal.toLowerCase()}/government` },
    council: null,
  })),
  city("nyc", "New York City", "NY", "3651000", { source: "legistar", client: "nyc", web: "legistar.council.nyc.gov", token: "NYC_LEGISTAR_TOKEN" }),
  city("seattle", "Seattle", "WA", "5363000", { source: "legistar", client: "seattle", web: "seattle.legistar.com" }),
  city("sf", "San Francisco", "CA", "0667000", { source: "legistar", client: "sfgov", web: "sfgov.legistar.com" }, "Board of Supervisors"),
  city("boston", "Boston", "MA", "2507000", { source: "legistar", client: "boston", web: "boston.legistar.com" }),
  city("denver", "Denver", "CO", "0820000", { source: "legistar", client: "denver", web: "denver.legistar.com" }),
  city("los-angeles", "Los Angeles", "CA", "0644000", null),
  city("chicago", "Chicago", "IL", "1714000", null),
  city("houston", "Houston", "TX", "4835000", null),
  city("philadelphia", "Philadelphia", "PA", "4260000", null),
];

export const jurisdictionById = (id: string) => JURISDICTIONS.find((j) => j.id === id);

/** The state's plain name, for news queries ("New York", not "New York State"). */
const stateName = (postal: string) => STATES.find(([p]) => p === postal)?.[1] ?? postal;

/** A city council's full name: "New York City Council", "San Francisco Board of Supervisors". */
export const councilName = (j: JurisdictionEntry) => `${j.name.replace(/ City$/, "")} ${j.council ?? "City Council"}`;

/**
 * The Google News query for a jurisdiction's headlines (7 days). A state: its legislature by name
 * (an unqualified "Assembly" would match every state's and the UN's). A city: its council by name.
 */
export function localNewsQuery(j: JurisdictionEntry): string {
  if (j.kind === "state") {
    const n = stateName(j.state);
    return `("${n} Legislature" OR "${n} State Senate" OR "${n} State Assembly" OR "${n} General Assembly") when:7d`;
  }
  return `"${councilName(j)}" when:7d`;
}
