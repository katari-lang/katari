import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import { config } from "../config/index.js";
import * as schema from "./schema.js";

/**
 * postgres.js connects lazily: constructing the pool does not require a
 * reachable database, so the server can boot and `/health` responds even when
 * Postgres is down. Queries surface a clear connection error until it is up.
 */
const queryClient = postgres(config.databaseUrl, { max: 10 });

export const db = drizzle(queryClient, { schema });
export type Database = typeof db;

/** Close the pool; call on graceful shutdown and after integration tests. */
export const closeDb = (): Promise<void> => queryClient.end();
