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
  host: env.HOST,
  logLevel: env.LOG_LEVEL,
  databaseUrl: env.DATABASE_URL,
  // `*` for any origin, otherwise the parsed allowlist Hono's `cors` expects.
  corsOrigin:
    env.CORS_ORIGIN === "*" ? "*" : env.CORS_ORIGIN.split(",").map((origin) => origin.trim()),
  // The AES-256-GCM key for encrypting secret values at rest, decoded from its base64 form once at boot.
  secretKey: Buffer.from(env.KATARI_SECRET_KEY, "base64"),
  // The blob byte store: an S3 config when `BLOB_S3_BUCKET` is set, otherwise `null` (in-memory dev store).
  blobS3:
    env.BLOB_S3_BUCKET === undefined
      ? null
      : {
          bucket: env.BLOB_S3_BUCKET,
          region: env.BLOB_S3_REGION,
          endpoint: env.BLOB_S3_ENDPOINT,
          forcePathStyle: env.BLOB_S3_FORCE_PATH_STYLE,
          createBucket: env.BLOB_S3_CREATE_BUCKET,
        },
  // The built admin console's static dist, served at the server root when set (the runtime image bakes it in
  // and points here). Undefined in a source checkout — the console runs from its own vite dev server there.
  adminWebDist:
    env.KATARI_ADMIN_WEB_DIST === undefined || env.KATARI_ADMIN_WEB_DIST === ""
      ? undefined
      : env.KATARI_ADMIN_WEB_DIST,
} as const;

export type Config = typeof config;
