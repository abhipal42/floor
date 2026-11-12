// Builds the landing page into dist/: the TypeScript under src/ compiled to dist/js by the repo's
// own tsc, and public/ copied alongside it. Node built-ins only.
/* global process, console */
import { execFileSync } from "node:child_process";
import { cpSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const dist = join(root, "dist");
const tsc = createRequire(import.meta.url).resolve("typescript/bin/tsc");

rmSync(dist, { recursive: true, force: true });
execFileSync(process.execPath, [tsc, "-p", join(root, "tsconfig.json")], { stdio: "inherit" });
cpSync(join(root, "public"), dist, { recursive: true });
console.log("built " + dist);
