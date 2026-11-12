import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { censusUrl, geocodeDistrict, parseCensusDistrict } from "./district.js";

const fixture = (name: string) =>
  JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "../fixtures", name), "utf8"));

describe("parseCensusDistrict (real Census geocoder responses)", () => {
  it("resolves a numbered district with its county", () => {
    // Texas State Capitol, 119th Congress layer (ACS2025 vintage)
    expect(parseCensusDistrict(fixture("census-texas-capitol.json"), 119)).toEqual({
      congress: 119, state: "TX", stateFips: "48", district: 37, countyFips: "48453",
    });
  });

  it("treats a delegate seat as at-large (district 0)", () => {
    // U.S. Capitol, 120th Congress layer (Current vintage)
    expect(parseCensusDistrict(fixture("census-capitol.json"), 120)).toEqual({
      congress: 120, state: "DC", stateFips: "11", district: 0, countyFips: "11001",
    });
  });

  it("returns null when the response lacks the requested Congress's layer", () => {
    expect(parseCensusDistrict(fixture("census-capitol.json"), 119)).toBeNull();
  });

  it("returns null when the address doesn't match", () => {
    expect(parseCensusDistrict({ result: { addressMatches: [] } }, 119)).toBeNull();
  });
});

describe("censusUrl", () => {
  it("pins the vintage for the requested Congress", () => {
    expect(censusUrl("1 Main St", 119)).toContain("vintage=ACS2025_Current");
    expect(censusUrl("1 Main St", 120)).toContain("vintage=ACS2026_Current");
    expect(() => censusUrl("1 Main St", 121)).toThrow(/No Census vintage/);
  });

  it("geocodes through the injected fetcher", async () => {
    const urls: string[] = [];
    const match = await geocodeDistrict("1100 Congress Ave, Austin, TX", 119, async (url) => {
      urls.push(url);
      return fixture("census-texas-capitol.json");
    });
    expect(match?.district).toBe(37);
    expect(urls[0]).toContain("geocoding.geo.census.gov");
  });
});
