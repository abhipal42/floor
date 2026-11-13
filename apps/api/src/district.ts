/** Where someone is: a typed address, or the browser's coordinates. Neither is ever kept. */
export type Place = { address: string } | { lat: number; lng: number };

/** A congressional district resolved from a place. The place itself is never kept. */
export interface DistrictMatch {
  congress: number;
  state: string;       // postal code, e.g. "TX"
  stateFips: string;   // e.g. "48"
  district: number;    // 0 for at-large seats and delegates
  countyFips: string | null;
}

/**
 * Census vintage whose congressional district layer matches each Congress.
 * The "Current" vintage moves to the next Congress's maps before members are seated,
 * so the vintage is pinned per Congress.
 */
export const CENSUS_VINTAGE: Record<number, string> = {
  119: "ACS2025_Current",
  120: "ACS2026_Current",
};

export function censusUrl(address: string, congress: number): string {
  const vintage = CENSUS_VINTAGE[congress];
  if (!vintage) throw new Error(`No Census vintage configured for the ${congress}th Congress`);
  const params = new URLSearchParams({
    address,
    benchmark: "Public_AR_Current",
    vintage,
    layers: "all",
    format: "json",
  });
  return `https://geocoding.geo.census.gov/geocoder/geographies/onelineaddress?${params}`;
}

/**
 * Coordinates are rounded to 4 decimal places (about 11 m) before they leave the API: enough to
 * place someone in the right district except within a few metres of a boundary, and no more
 * precise than that.
 */
export const COORDINATE_DECIMALS = 4;

export function censusCoordinatesUrl(lat: number, lng: number, congress: number): string {
  const vintage = CENSUS_VINTAGE[congress];
  if (!vintage) throw new Error(`No Census vintage configured for the ${congress}th Congress`);
  const params = new URLSearchParams({
    x: lng.toFixed(COORDINATE_DECIMALS),
    y: lat.toFixed(COORDINATE_DECIMALS),
    benchmark: "Public_AR_Current",
    vintage,
    layers: "all",
    format: "json",
  });
  return `https://geocoding.geo.census.gov/geocoder/geographies/coordinates?${params}`;
}

type Geo = Record<string, string>;

/**
 * Pulls state, district and county out of a Census geographies response. An address lookup nests
 * the layers under `addressMatches[0]`; a coordinates lookup puts them straight on `result`.
 */
export function parseCensusDistrict(json: unknown, congress: number): DistrictMatch | null {
  const result = (json as {
    result?: { addressMatches?: { geographies?: Record<string, Geo[]> }[]; geographies?: Record<string, Geo[]> };
  })?.result;
  const geographies = result?.addressMatches?.[0]?.geographies ?? result?.geographies;
  if (!geographies) return null;

  const cd = geographies[`${congress}th Congressional Districts`]?.[0];
  const state = geographies["States"]?.[0];
  if (!cd?.GEOID || !state?.STUSAB) return null;

  // GEOID is state FIPS + 2-digit district. "00" is at-large and "98" is a non-voting delegate seat.
  const code = cd.GEOID.slice(2);
  const district = code === "00" || code === "98" ? 0 : Number.parseInt(code, 10);
  return {
    congress,
    state: state.STUSAB,
    stateFips: cd.GEOID.slice(0, 2),
    district,
    countyFips: geographies["Counties"]?.[0]?.GEOID ?? null,
  };
}

export type FetchJson = (url: string) => Promise<unknown>;

export const defaultFetchJson: FetchJson = async (url) => {
  const res = await fetch(url, { headers: { "user-agent": "floor-api/0.1" } });
  if (!res.ok) throw new Error(`Census geocoder returned HTTP ${res.status}`);
  return res.json();
};

export async function geocodeDistrict(
  address: string,
  congress: number,
  fetchJson: FetchJson = defaultFetchJson,
): Promise<DistrictMatch | null> {
  return parseCensusDistrict(await fetchJson(censusUrl(address, congress)), congress);
}

/** Resolves a typed address or a pair of coordinates to a congressional district. */
export async function locateDistrict(
  place: Place,
  congress: number,
  fetchJson: FetchJson = defaultFetchJson,
): Promise<DistrictMatch | null> {
  const url =
    "address" in place ? censusUrl(place.address, congress) : censusCoordinatesUrl(place.lat, place.lng, congress);
  return parseCensusDistrict(await fetchJson(url), congress);
}
