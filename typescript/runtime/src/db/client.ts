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

/** An open transaction handle — the same query API as `db`, taken from `db.transaction(tx => ...)`. */
export type Transaction = Parameters<Parameters<Database["transaction"]>[0]>[0];

/** Either the pool or an open transaction. Repositories accept this so a service can run them either
 *  standalone or composed inside a single `db.transaction`. */
export type Executor = Database | Transaction;

/** Close the pool; call on graceful shutdown and after integration tests. */
export const closeDb = (): Promise<void> => queryClient.end();
