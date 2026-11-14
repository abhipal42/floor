import { describe, expect, it } from "vitest";
import { fold, foldName, FOLDS, parseMemberQuery, STATES } from "./search.js";

describe("parseMemberQuery", () => {
  it("reads a House seat however it is typed", () => {
    for (const q of ["NY-8", "ny-8", "NY 8", "NY8", " ny - 8 ", "NY-08"]) {
      expect(parseMemberQuery(q), q).toEqual({ kind: "seat", state: "NY", district: 8 });
    }
    expect(parseMemberQuery("TX-37")).toEqual({ kind: "seat", state: "TX", district: 37 });
  });

  it("reads AL as the at-large seat, which is stored as district 0", () => {
    expect(parseMemberQuery("WY-AL")).toEqual({ kind: "seat", state: "WY", district: 0 });
    expect(parseMemberQuery("wy al")).toEqual({ kind: "seat", state: "WY", district: 0 });
    expect(parseMemberQuery("DC-AL")).toEqual({ kind: "seat", state: "DC", district: 0 });
  });

  it("reads a state by its full name, in any case and with the punctuation people type", () => {
    expect(parseMemberQuery("New York")).toMatchObject({ kind: "state", state: "NY" });
    expect(parseMemberQuery("  new   york ")).toMatchObject({ kind: "state", state: "NY" });
    expect(parseMemberQuery("District of Columbia")).toMatchObject({ kind: "state", state: "DC" });
    expect(parseMemberQuery("Washington, D.C.")).toMatchObject({ kind: "state", state: "DC" });
    expect(parseMemberQuery("D.C.")).toMatchObject({ kind: "state", state: "DC" });
    expect(parseMemberQuery("Virgin Islands")).toMatchObject({ kind: "state", state: "VI" });
    expect(parseMemberQuery("U.S. Virgin Islands")).toMatchObject({ kind: "state", state: "VI" });
    expect(parseMemberQuery("Puerto Rico")).toMatchObject({ kind: "state", state: "PR" });
  });

  it("knows every jurisdiction by name and code: 50 states, D.C. and five territories", () => {
    expect(Object.keys(STATES)).toHaveLength(56);
    for (const [code, name] of Object.entries(STATES)) {
      expect(parseMemberQuery(name)).toMatchObject({ kind: "state", state: code });
      expect(parseMemberQuery(code.toLowerCase())).toMatchObject({ kind: "state", state: code });
    }
  });

  it("reads Washington alone as the state, not D.C.", () => {
    expect(parseMemberQuery("Washington")).toMatchObject({ kind: "state", state: "WA" });
  });

  it("reads anything else as a name, folded the way the database side folds it", () => {
    expect(parseMemberQuery("Schumer")).toEqual({ kind: "name", text: "schumer" });
    expect(parseMemberQuery("Velázquez")).toEqual({ kind: "name", text: "velazquez" });
    expect(parseMemberQuery("Ocasio-Cortez")).toEqual({ kind: "name", text: "ocasio cortez" });
    expect(parseMemberQuery("O'Halleran")).toEqual({ kind: "name", text: "ohalleran" });
    expect(parseMemberQuery("alexandria  ocasio")).toEqual({ kind: "name", text: "alexandria ocasio" });
  });

  it("does not take two letters that are not a code, or a seat in no state, for a place", () => {
    expect(parseMemberQuery("Zz")).toEqual({ kind: "name", text: "zz" });
    expect(parseMemberQuery("Ro")).toEqual({ kind: "name", text: "ro" });
    expect(parseMemberQuery("XX-1")).toEqual({ kind: "name", text: "xx 1" });
    expect(parseMemberQuery("Carolina")).toEqual({ kind: "name", text: "carolina" });
  });

  it("also searches a state as a name: Washington is a state and a surname", () => {
    expect(parseMemberQuery("Washington")).toEqual({ kind: "state", state: "WA", name: "washington" });
    expect(parseMemberQuery("Al")).toEqual({ kind: "state", state: "AL", name: "al" });
  });

  it("reads a code written with periods", () => {
    expect(parseMemberQuery("N.Y.")).toEqual({ kind: "state", state: "NY", name: "ny" });
    expect(parseMemberQuery("n.y.-8")).toEqual({ kind: "seat", state: "NY", district: 8 });
    expect(parseMemberQuery("W.Y. AL")).toEqual({ kind: "seat", state: "WY", district: 0 });
  });

  it("leaves LIKE wildcards as text for the query to escape", () => {
    expect(parseMemberQuery("50%_off")).toEqual({ kind: "name", text: "50%_off" });
  });
});

describe("fold", () => {
  it("lower-cases, strips accents and collapses space", () => {
    expect(fold("  José   SERRANO ")).toBe("jose serrano");
    expect(foldName("Sánchez-Peña")).toBe("sanchez pena");
    // Letters with no decomposition, from the shared table the SQL side also uses.
    expect(fold("Søren Łukasz Đorđe Kılıç")).toBe("soren lukasz dorde kilic");
    for (const [from, to] of FOLDS) for (const c of from) expect(fold(c), c).toBe(to);
  });
});
