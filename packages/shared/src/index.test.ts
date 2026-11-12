import { describe, expect, it } from "vitest";
import { votesNeeded } from "./index.js";

describe("votesNeeded", () => {
  it("needs a simple majority of those voting", () => {
    expect(votesNeeded("majority", 435)).toBe(218);
    expect(votesNeeded("majority", 408)).toBe(205);
  });
  it("needs two thirds of those voting for suspensions", () => {
    expect(votesNeeded("two_thirds", 420)).toBe(280);
    expect(votesNeeded("two_thirds", 421)).toBe(281);
  });
  it("needs three fifths of sworn senators for cloture", () => {
    expect(votesNeeded("three_fifths_sworn", 97)).toBe(60);
    expect(votesNeeded("three_fifths_sworn", 99, 99)).toBe(60);
  });
});
