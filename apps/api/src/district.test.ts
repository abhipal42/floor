import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { censusCoordinatesUrl, censusUrl, geocodeDistrict, locateDistrict, parseCensusDistrict } from "./district.js";

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

describe("coordinates (real Census geocoder responses)", () => {
  it("resolves the Texas Capitol's coordinates to the same district as its address", () => {
    expect(parseCensusDistrict(fixture("census-coords-texas-capitol.json"), 119)).toEqual(
      parseCensusDistrict(fixture("census-texas-capitol.json"), 119),
    );
  });

  it("returns null for a point outside the United States", () => {
    expect(parseCensusDistrict(fixture("census-coords-london.json"), 119)).toBeNull();
  });

  it("rounds coordinates to about 11 m before they leave the API", () => {
    const url = new URL(censusCoordinatesUrl(30.274712345, -97.740398765, 119));
    expect(url.pathname).toBe("/geocoder/geographies/coordinates");
    expect(url.searchParams.get("y")).toBe("30.2747");
    expect(url.searchParams.get("x")).toBe("-97.7404");
    expect(url.searchParams.get("vintage")).toBe("ACS2025_Current");
  });

  it("routes an address and a pair of coordinates to the right Census endpoint", async () => {
    const urls: string[] = [];
    const fetchJson = async (url: string) => {
      urls.push(url);
      return fixture(url.includes("/coordinates") ? "census-coords-texas-capitol.json" : "census-texas-capitol.json");
    };
    expect((await locateDistrict({ lat: 30.2747, lng: -97.7404 }, 119, fetchJson))?.district).toBe(37);
    expect((await locateDistrict({ address: "1100 Congress Ave, Austin, TX" }, 119, fetchJson))?.district).toBe(37);
    expect(urls.map((u) => new URL(u).pathname)).toEqual([
      "/geocoder/geographies/coordinates",
      "/geocoder/geographies/onelineaddress",
    ]);
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
