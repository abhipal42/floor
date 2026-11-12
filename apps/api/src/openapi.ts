/**
 * Writes the OpenAPI document to `apps/api/openapi.json`.
 *
 * That committed snapshot is the contract the iOS app's model types are built against, so they can
 * be checked — or generated — without a database, a network or a running server. CI re-runs this and
 * fails if the snapshot has drifted from the routes in `app.ts`.
 *
 *   npm run openapi -w @floor/api
 */
import { writeFileSync } from "node:fs";
import { createApp } from "./app.js";

// The document describes the contract, so the repositories need no data behind them.
const app = createApp({
  votes: {
    getVote: async () => null,
    voteBreakdown: async () => ({ partyTotals: [], candidateTotals: [], positions: [] }),
  },
  members: {
    membersFor: async () => [],
    recentVotes: async () => [],
    getMember: async () => null,
    partyLoyalty: async () => ({ votes: 0, withParty: 0, againstParty: 0 }),
  },
  bills: { getBill: async () => null },
  nominations: { getNomination: async () => null },
  status: { lastRuns: async () => [] },
  geocode: async () => null,
});

const out = process.argv[2];
if (!out) {
  console.error("Usage: tsx src/openapi.ts <output path>");
  process.exit(1);
}

const doc = app.getOpenAPIDocument({ openapi: "3.0.0", info: { title: "Floor API", version: "0.1.0" } });
writeFileSync(out, `${JSON.stringify(doc, null, 2)}\n`);
console.log(`Wrote ${out}`);
