import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import { config } from "../config/index.js";
import * as schema from "./schema.js";

/**
 * postgres.js connects lazily: constructing the pool does not require a
 * reachable database, so the server can boot and `/api/v1/health` responds even
 * when Postgres is down. Queries surface a clear connection error until it is up.
 *
 * TLS is on by default for any non-loopback database (`config.databaseSsl`): postgres.js itself defaults to
 * no encryption, which is fine for a sibling container on a compose network and quietly wrong for a managed
 * database, which would otherwise carry every secret's ciphertext, every run payload, and the connection
 * password across the network in the clear.
 */
const queryClient = postgres(config.databaseUrl, {
  max: 10,
  ssl: config.databaseSslForPostgresJs,
});

export const db = drizzle(queryClient, { schema });
export type Database = typeof db;

/** An open transaction handle — the same query API as `db`, taken from `db.transaction(tx => ...)`. */
export type Transaction = Parameters<Parameters<Database["transaction"]>[0]>[0];

/** Either the pool or an open transaction. Repositories accept this so a service can run them either
 *  standalone or composed inside a single `db.transaction`. */
export type Executor = Database | Transaction;

/** Close the pool; call on graceful shutdown and after integration tests. */
export const closeDb = (): Promise<void> => queryClient.end();
