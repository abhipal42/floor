// Builds the landing page into dist/: the TypeScript under src/ compiled to dist/js by the repo's
// own tsc, and public/ copied alongside it. Node built-ins only.
/* global process, console, URL */
import { execFileSync } from "node:child_process";
import { cpSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const dist = join(root, "dist");
const tsc = createRequire(import.meta.url).resolve("typescript/bin/tsc");

rmSync(dist, { recursive: true, force: true });
execFileSync(process.execPath, [tsc, "-p", join(root, "tsconfig.json")], { stdio: "inherit" });
cpSync(join(root, "public"), dist, { recursive: true });

// FLOOR_API_BASE points the page at another API (a local one, a preview); unset means production.
const apiBase = process.env.FLOOR_API_BASE;
if (apiBase) {
  const url = new URL(apiBase);
  if (url.protocol !== "https:" && url.hostname !== "localhost" && url.hostname !== "127.0.0.1") {
    throw new Error("FLOOR_API_BASE must be https (or localhost): " + apiBase);
  }
  const base = url.origin + url.pathname.replace(/\/+$/, "");
  writeFileSync(join(dist, "js", "config.js"), "export const API_BASE = " + JSON.stringify(base) + ";\n");
  console.log("API base " + base);
}
console.log("built " + dist);
