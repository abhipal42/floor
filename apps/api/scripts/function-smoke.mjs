#!/usr/bin/env node
/* global process, console, setTimeout, fetch, Buffer */
/**
 * Run the API exactly as Vercel will: from the traced function and nothing else (lesson 64).
 *
 *   npm run function-smoke -w @floor/api      # builds with the Vercel CLI, then serves the function
 *
 * No Vercel login is needed: `vercel build` runs offline against a placeholder `.vercel/project.json`
 * (written only when the directory is not linked to the real project), with the settings of the
 * `floor-api` project — framework detection off, Node 22.
 *
 * `vercel build` traces the entry with @vercel/nft and writes `.vercel/output/functions/api/index.func`:
 * the compiled entry, the node_modules it reaches, and a `filePathMap` of the `includeFiles` it
 * uploads at deploy. This copies that function, and only that, to an empty directory — so a file the
 * trace missed is missing here too, as `hb.wasm` was in v0.2.32 — and serves its handler under plain
 * Node. It fails on any unhandled rejection or uncaught exception, on /v1/status not answering, on
 * the share page not answering, and on the card not rendering from the traced files.
 */
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const api = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repo = resolve(api, "../..");
const func = join(api, ".vercel/output/functions/api/index.func");

const fail = (why) => {
  console.error(`function smoke FAILED: ${why}`);
  process.exit(1);
};
process.on("unhandledRejection", (e) => fail(`unhandled rejection: ${e?.stack ?? e}`));
process.on("uncaughtException", (e) => fail(`uncaught exception: ${e?.stack ?? e}`));

if (!existsSync(join(api, ".vercel/project.json"))) {
  mkdirSync(join(api, ".vercel"), { recursive: true });
  const settings = { framework: null, nodeVersion: "22.x", installCommand: null, buildCommand: null, outputDirectory: null };
  writeFileSync(join(api, ".vercel/project.json"), JSON.stringify({ projectId: "prj_smoke", orgId: "team_smoke", settings }));
}
rmSync(join(api, ".vercel/output"), { recursive: true, force: true });
// The CLI's version is pinned so the trace cannot change under us between runs.
execFileSync("npx", ["-y", "vercel@65.16.0", "build", "--yes"], { cwd: api, stdio: ["ignore", "ignore", "inherit"] });

const config = JSON.parse(readFileSync(join(func, ".vc-config.json"), "utf8"));
const dir = mkdtempSync(join(tmpdir(), "floor-func-"));
cpSync(func, dir, { recursive: true, dereference: true });
for (const [to, from] of Object.entries(config.filePathMap ?? {})) cpSync(join(repo, from), join(dir, to));

delete process.env.DATABASE_URL;
const entry = pathToFileURL(join(dir, config.handler)).href;
const { default: handler } = await import(entry);
// Let anything the import set off (a wasm compile, say) settle or reject before the first request.
await new Promise((r) => setTimeout(r, 1000));

const server = createServer(handler);
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;

const expectStatus = async (path, want) => {
  const res = await fetch(base + path);
  if (res.status !== want) fail(`${path} answered ${res.status}, expected ${want}: ${(await res.text()).slice(0, 300)}`);
  console.log(`ok ${res.status} ${path}`);
};
await expectStatus("/v1/status", 200);
// No database here, so no bill: the share page's own 404, which still means the route answered.
await expectStatus("/bill/119/hr/5267", 404);

// The card, from the traced copy's own share.js, so its fonts and wasm come from the function.
const share = await import(pathToFileURL(join(dir, dirname(config.handler), "../src/share.js")).href);
const png = await share
  .renderCard(
    { congress: 119, type: "hr", number: 5267, citation: "H.R. 5267", shortTitle: "American Franchise Act", label: "American Franchise Act", stage: "introduced" },
    null,
    new Date(),
  )
  .catch((e) => fail(`the card did not render from the traced files: ${String(e).slice(0, 300)}`));
if (Buffer.from(png).subarray(1, 4).toString() !== "PNG") fail("the card is not a PNG");
console.log(`ok card.png renders from the traced files (${png.length} bytes)`);

server.close();
rmSync(dir, { recursive: true, force: true });
console.log("function smoke passed");
