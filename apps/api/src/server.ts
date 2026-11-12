import { serve } from "@hono/node-server";
import pg from "pg";
import { createApp, type AppDeps } from "./app.js";
import { geocodeDistrict } from "./district.js";
import { pgRepositories, type Db } from "./pg.js";

const CONGRESS = Number(process.env.CONGRESS ?? 119);

function repositories(): Pick<AppDeps, "votes" | "members" | "bills" | "nominations" | "status"> {
  if (!process.env.DATABASE_URL) {
    console.warn("DATABASE_URL is not set: serving empty data");
    return {
      votes: { getVote: async () => null },
      members: { membersFor: async () => [], recentVotes: async () => [] },
      bills: { getBill: async () => null },
      nominations: { getNomination: async () => null },
      status: { lastRuns: async () => [] },
    };
  }
  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 5 });
  return pgRepositories(pool as unknown as Db);
}

const app = createApp({
  ...repositories(),
  geocode: (address) => geocodeDistrict(address, CONGRESS),
});
const port = Number(process.env.PORT ?? 8787);

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`Floor API on http://localhost:${info.port} (OpenAPI at /openapi.json)`);
});
