import { serve } from "@hono/node-server";
import { createApp } from "./app.js";

// Local dev server. Until M1 wires Postgres, the repository is empty.
const app = createApp({ getVote: async () => null });
const port = Number(process.env.PORT ?? 8787);

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`Floor API on http://localhost:${info.port} (OpenAPI at /openapi.json)`);
});
