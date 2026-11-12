export * from "./rollcall.js";

export type Chamber = "house" | "senate";

export type VotePosition = "yea" | "nay" | "present" | "not_voting";

/** Votes needed to pass, given the vote's threshold rule and the members voting. */
export type Threshold = "majority" | "three_fifths_sworn" | "two_thirds";

export function votesNeeded(threshold: Threshold, voting: number, sworn = 100): number {
  switch (threshold) {
    case "majority":
      return Math.floor(voting / 2) + 1;
    case "two_thirds":
      return Math.ceil((voting * 2) / 3);
    case "three_fifths_sworn":
      return Math.ceil((sworn * 3) / 5);
  }
}
