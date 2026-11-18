import { serve } from "@hono/node-server";
import pg from "pg";
import { createApp, NO_CONTACT, type AppDeps } from "./app.js";
import { locateDistrict } from "./district.js";
import { openStatesLegislators } from "./local.js";
import { pgRepositories, type Db } from "./pg.js";

const CONGRESS = Number(process.env.CONGRESS ?? 119);

function repositories(): Pick<
  AppDeps,
  | "votes"
  | "members"
  | "bills"
  | "nominations"
  | "status"
  | "live"
  | "devices"
  | "disclosures"
  | "schedule"
> {
  if (!process.env.DATABASE_URL) {
    console.warn("DATABASE_URL is not set: serving empty data");
    return {
      votes: {
        getVote: async () => null,
        recentVotes: async () => [],
        voteBreakdown: async () => ({
          partyTotals: [],
          candidateTotals: [],
          positions: [],
          measure: null,
        }),
      },
      members: {
        membersFor: async () => [],
        recentVotes: async () => [],
        getMember: async () => null,
        search: async () => [],
        partyLoyalty: async () => ({ votes: 0, withParty: 0, againstParty: 0 }),
        funding: async () => null,
        contact: async () => NO_CONTACT,
      },
      bills: { getBill: async () => null, getAnalysis: async () => null },
      nominations: { getNomination: async () => null },
      status: { lastRuns: async () => [] },
      live: { chambers: async () => [], liveVotes: async () => [] },
    };
  }
  const pool = new pg.Pool({
    connectionString: process.env.DATABASE_URL,
    max: 5,
  });
  return pgRepositories(pool as unknown as Db);
}

// Locally, the web page served by `npm run serve -w @floor/web` may read responses; set
// ALLOWED_ORIGINS (comma-separated) to allow others.
const allowedOrigins = (process.env.ALLOWED_ORIGINS ?? "http://localhost:8790")
  .split(",")
  .map((o) => o.trim())
  .filter(Boolean);

const port = Number(process.env.PORT ?? 8787);
const app = createApp({
  ...repositories(),
  locate: (place) => locateDistrict(place, CONGRESS),
  allowedOrigins,
  // Off unless set: financial disclosures wait on the §13107(c) question (HANDOFF.md).
  disclosuresEnabled: process.env.DISCLOSURES_ENABLED === "true",
  // State legislators (Open States); unset, the endpoint answers [].
  legislators: process.env.OPENSTATES_API_KEY ? openStatesLegislators(process.env.OPENSTATES_API_KEY, { log: console.warn }) : undefined,
  // Share pages served here link to, and look members up on, this server.
  share: { base: `http://localhost:${port}`, apiBase: `http://localhost:${port}` },
});

serve({ fetch: app.fetch, port }, (info) => {
  console.log(
    `Floor API on http://localhost:${info.port} (OpenAPI at /openapi.json)`,
  );
});
