/**
 * floor-api's static output holds nothing but `public/` (lesson 70).
 *
 * With no build step and no output directory, Vercel served `apps/api/` itself as static files,
 * ahead of the rewrite to the function: `/src/app.ts` answered 200. `outputDirectory: "public"`
 * stops that, and `public/` must only ever hold files meant for the world.
 */
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const apiDir = join(dirname(fileURLToPath(import.meta.url)), "..");

describe("floor-api deploy config", () => {
  it("serves static files only from public/", () => {
    const config = JSON.parse(readFileSync(join(apiDir, "vercel.json"), "utf8"));
    expect(config.outputDirectory).toBe("public");
  });

  it("puts nothing in public/ but robots.txt", () => {
    expect(readdirSync(join(apiDir, "public")).sort()).toEqual(["robots.txt"]);
  });

  it("still rewrites every other path to the function", () => {
    const config = JSON.parse(readFileSync(join(apiDir, "vercel.json"), "utf8"));
    expect(config.rewrites).toContainEqual({ source: "/(.*)", destination: "/api" });
  });
});
