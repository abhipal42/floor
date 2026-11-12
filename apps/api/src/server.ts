import { serve } from "@hono/node-server";
import { createApp } from "./app.js";
import { geocodeDistrict } from "./district.js";

// Local dev server. Until the Postgres repositories land, votes and members are empty.
const CONGRESS = Number(process.env.CONGRESS ?? 119);
const app = createApp({
  votes: { getVote: async () => null },
  members: { membersFor: async () => [] },
  geocode: (address) => geocodeDistrict(address, CONGRESS),
});
const port = Number(process.env.PORT ?? 8787);

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`Floor API on http://localhost:${info.port} (OpenAPI at /openapi.json)`);
});
