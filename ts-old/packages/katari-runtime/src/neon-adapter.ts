/**
 * Neon serverless SQL adapter for Cloudflare Workers.
 *
 * Uses @neondatabase/serverless's neon() function which makes
 * HTTP-based SQL queries — compatible with edge runtimes.
 */
import type { SqlAdapter } from "./db.js";

/**
 * Create a SqlAdapter backed by @neondatabase/serverless.
 *
 * The neon driver is imported dynamically so that Node.js entry points
 * don't need it as a dependency.
 */
export function createNeonAdapter(databaseUrl: string): SqlAdapter {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { neon } = require("@neondatabase/serverless") as { neon: (url: string, opts?: any) => any };
  const sql = neon(databaseUrl, { fullResults: true });
  let lastCount = 0;

  return {
    async query(text: string, params?: unknown[]): Promise<Record<string, unknown>[]> {
      const result = await sql(text, params ?? []);
      lastCount = result.rowCount ?? 0;
      return result.rows as Record<string, unknown>[];
    },
    get lastCount() { return lastCount; },
    set lastCount(v) { lastCount = v; },
  };
}
