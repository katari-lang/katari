import { loadEnv } from "./env.js";

const env = loadEnv();

/**
 * Resolved, immutable application configuration derived from the environment.
 * Import this anywhere instead of touching `process.env` directly.
 */
export const config = {
  nodeEnv: env.NODE_ENV,
  isProduction: env.NODE_ENV === "production",
  isDevelopment: env.NODE_ENV === "development",
  port: env.PORT,
  logLevel: env.LOG_LEVEL,
  databaseUrl: env.DATABASE_URL,
} as const;

export type Config = typeof config;
