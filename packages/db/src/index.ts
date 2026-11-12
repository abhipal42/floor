import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const migrationsDir = join(dirname(fileURLToPath(import.meta.url)), "../../../supabase/migrations");

/** Migration files in apply order. */
export function loadMigrations(): { name: string; sql: string }[] {
  return readdirSync(migrationsDir)
    .filter((f) => f.endsWith(".sql"))
    .sort()
    .map((name) => ({ name, sql: readFileSync(join(migrationsDir, name), "utf8") }));
}
