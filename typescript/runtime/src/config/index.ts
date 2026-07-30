import { loadEnv } from "./env.js";

const env = loadEnv();

/** The hosts that mean "the database is on this machine / this compose network", where TLS adds nothing and
 *  requiring it would break the documented local flow. Anything else is treated as remote. */
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "::1", "[::1]"]);

/** Whether a postgres URL points at a loopback host. A URL that will not parse falls back to "remote", so an
 *  odd connection string errs toward requiring TLS rather than toward silently dropping it. */
function isLoopbackDatabase(url: string): boolean {
  try {
    return LOOPBACK_HOSTS.has(new URL(url).hostname);
  } catch {
    return false;
  }
}

/** How the database connection is encrypted: the explicit setting when given, otherwise off for a loopback
 *  database and fully verified for a remote one. See `DATABASE_SSL` in `env.ts` for why `require` is not the
 *  default a reader might expect. */
const databaseSsl =
  env.DATABASE_SSL ?? (isLoopbackDatabase(env.DATABASE_URL) ? "disable" : "verify-full");

/** `DATABASE_SSL` in the form postgres.js takes. Shared by the query pool and the single-instance lock's own
 *  connection so the two can never disagree about how the database is reached. The `require` value is passed
 *  through as a string deliberately: postgres.js reads it as "encrypted but do not verify the certificate",
 *  which is a weaker thing than its name suggests — see `DATABASE_SSL` in `env.ts`. */
function sslForPostgresJs(
  setting: "disable" | "require" | "verify-full",
): false | "require" | "verify-full" {
  return setting === "disable" ? false : setting;
}

/** Every key the runtime may DECRYPT with, newest first. The first entry is also the one it encrypts under,
 *  so putting a fresh key at the head and the retired one behind it is a complete rotation. */
const secretKeys = [
  Buffer.from(env.KATARI_SECRET_KEY, "base64"),
  ...(env.KATARI_SECRET_KEY_PREVIOUS ?? "")
    .split(",")
    .map((key) => key.trim())
    .filter((key) => key.length > 0)
    .map((key) => Buffer.from(key, "base64")),
];

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
  databaseSsl,
  databaseSslForPostgresJs: sslForPostgresJs(databaseSsl),
  instanceLock: {
    enabled: env.KATARI_INSTANCE_LOCK,
    timeoutMs: env.KATARI_INSTANCE_LOCK_TIMEOUT_MS,
  },
  // `*` for any origin, otherwise the parsed allowlist Hono's `cors` expects.
  corsOrigin:
    env.CORS_ORIGIN === "*" ? "*" : env.CORS_ORIGIN.split(",").map((origin) => origin.trim()),
  // The AES-256-GCM keys for secret values at rest: `[0]` seals new writes, the rest only open old ones.
  secretKeys,
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
  // The bearer token every API caller must present (required — see `env.ts`). Auth is always enforced.
  apiKey: env.KATARI_API_KEY,
  // The public base URL webhook endpoints are minted under (trailing slash trimmed so path joins are
  // uniform). Required in production; a source checkout falls back to the local port.
  publicUrl: (env.KATARI_PUBLIC_URL ?? `http://localhost:${env.PORT}`).replace(/\/$/, ""),
  // What a program's own outbound requests may reach — see `runtime/external/egress-guard.ts`.
  egress: {
    allowPrivateAddresses: env.KATARI_EGRESS_ALLOW_PRIVATE,
    allowedHosts: new Set(
      env.KATARI_EGRESS_ALLOWED_HOSTS.split(",")
        .map((host) => host.trim())
        .filter((host) => host.length > 0),
    ),
  },
  http: {
    timeoutMs: env.KATARI_HTTP_TIMEOUT_MS,
    connectTimeoutMs: env.KATARI_HTTP_CONNECT_TIMEOUT_MS,
    maxResponseBytes: env.KATARI_HTTP_MAX_RESPONSE_BYTES,
  },
  limits: {
    maxRequestBytes: env.KATARI_MAX_REQUEST_BYTES,
    maxUploadBytes: env.KATARI_MAX_UPLOAD_BYTES,
    rateLimitPerMinute: env.KATARI_RATE_LIMIT_PER_MINUTE,
  },
} as const;

export type Config = typeof config;
