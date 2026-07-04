import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { drizzle } from "drizzle-orm/postgres-js";
import { migrate } from "drizzle-orm/postgres-js/migrator";
import postgres from "postgres";
import { config } from "../config/index.js";
import { createLogger } from "../lib/logger.js";

const logger = createLogger({
  level: config.logLevel,
  bindings: { module: "migrate" },
});

/**
 * Locate the shipped `drizzle/` folder relative to THIS module rather than the process cwd: the
 * folder is published with the package (`files`), so it sits beside the bundled `dist/` in the image
 * and beside `src/` in dev. Resolving from cwd breaks the moment the `katari-api-server` bin is run
 * from anywhere but the package root (a global/npx install launched from `$HOME`). Ascending from the
 * module covers both the bundled (`dist/bin.mjs` → `../drizzle`) and dev (`src/db/` → `../../drizzle`)
 * layouts without hardcoding a depth.
 */
function findMigrationsFolder(): string {
  let directory = dirname(fileURLToPath(import.meta.url));
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = resolve(directory, "drizzle");
    if (existsSync(candidate)) return candidate;
    const parent = dirname(directory);
    if (parent === directory) break;
    directory = parent;
  }
  throw new Error(
    "Could not locate the drizzle/ migrations folder relative to the runtime module.",
  );
}

/**
 * Apply pending migrations using only drizzle-orm (no drizzle-kit), so this
 * runs inside the distributed image. The server calls it on startup.
 *
 * Uses a throwaway single connection so it never touches the server's pool.
 */
export async function runMigrations(): Promise<void> {
  const migrationsFolder = findMigrationsFolder();
  const sql = postgres(config.databaseUrl, { max: 1 });
  try {
    logger.info("applying migrations", { migrationsFolder });
    await migrate(drizzle(sql), { migrationsFolder });
    logger.info("migrations applied");
  } finally {
    await sql.end();
  }
}
