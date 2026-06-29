import { z } from "zod";

/**
 * Environment variable schema. All process configuration enters the app
 * through here so the rest of the code can rely on a validated, typed object.
 */
const envSchema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
  PORT: z.coerce.number().int().positive().max(65535).default(3000),
  /** The interface to bind. Defaults to all interfaces (required inside a container); set to
   *  `127.0.0.1` to restrict the unauthenticated v0.1 API to loopback. */
  HOST: z.string().min(1).default("0.0.0.0"),
  LOG_LEVEL: z.enum(["debug", "info", "warn", "error"]).default("info"),
  /** Must be a postgres connection string — the only consumer is postgres.js. Validating the scheme
   *  here surfaces a mistyped URL at boot instead of as an opaque driver error on first query. */
  DATABASE_URL: z
    .url({ protocol: /^postgres(ql)?$/ })
    .default("postgres://katari:katari@localhost:5432/katari"),
  /** Allowed CORS origin(s): `*` (default), or a comma-separated allowlist. The API is currently
   *  unauthenticated, so a wildcard lets any site read responses cross-origin — lock this down in
   *  any shared/production deployment. */
  CORS_ORIGIN: z.string().min(1).default("*"),
  /** The AES-256-GCM key that encrypts secret (private) values at rest. Required (no default) — the runtime
   *  refuses to boot without it, since a missing key would silently persist secrets in plaintext. Must be a
   *  base64-encoded 32 bytes; generate one with `openssl rand -base64 32`. */
  KATARI_SECRET_KEY: z
    .string()
    .refine(
      (value) => decodesToBytes(value, 32),
      "must be a base64-encoded 32-byte key (generate with `openssl rand -base64 32`)",
    ),
  /** Blob byte store: set `BLOB_S3_BUCKET` to use an S3-compatible store (the bytes for file uploads /
   *  promoted blobs), otherwise the in-memory store (dev only — bytes are lost on restart). Credentials come
   *  from the standard AWS chain (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`); `BLOB_S3_ENDPOINT` +
   *  `BLOB_S3_FORCE_PATH_STYLE=true` target a non-AWS endpoint such as MinIO. */
  BLOB_S3_BUCKET: z.string().min(1).optional(),
  BLOB_S3_REGION: z.string().min(1).default("us-east-1"),
  BLOB_S3_ENDPOINT: z.url().optional(),
  BLOB_S3_FORCE_PATH_STYLE: z
    .enum(["true", "false"])
    .default("false")
    .transform((value) => value === "true"),
});

/** Whether a base64 string decodes to exactly `length` bytes (Node accepts loose base64, so we re-encode and
 *  compare to reject malformed input rather than silently truncating it). */
function decodesToBytes(value: string, length: number): boolean {
  const decoded = Buffer.from(value, "base64");
  return decoded.length === length && decoded.toString("base64") === value;
}

export type AppEnvVars = z.infer<typeof envSchema>;

export function loadEnv(source: NodeJS.ProcessEnv = process.env): AppEnvVars {
  const result = envSchema.safeParse(source);
  if (!result.success) {
    const issues = result.error.issues
      .map((issue) => `  - ${issue.path.join(".") || "(root)"}: ${issue.message}`)
      .join("\n");
    throw new Error(`Invalid environment variables:\n${issues}`);
  }
  return result.data;
}
