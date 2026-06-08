import { resolve } from "node:path";
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
 * Apply pending migrations using only drizzle-orm (no drizzle-kit), so this
 * runs inside the distributed image. The server calls it on startup; the
 * `drizzle/` folder is resolved from the cwd, which is the package root in dev
 * and `/app` (WORKDIR) in the image — both contain `drizzle/`.
 *
 * Uses a throwaway single connection so it never touches the server's pool.
 */
export async function runMigrations(): Promise<void> {
  const migrationsFolder = resolve(process.cwd(), "drizzle");
  const sql = postgres(config.databaseUrl, { max: 1 });
  try {
    logger.info("applying migrations", { migrationsFolder });
    await migrate(drizzle(sql), { migrationsFolder });
    logger.info("migrations applied");
  } finally {
    await sql.end();
  }
}
