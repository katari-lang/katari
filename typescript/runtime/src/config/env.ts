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
});

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
