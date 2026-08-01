import { readFileSync } from "node:fs";
import { z } from "zod";

/**
 * Environment variable schema. All process configuration enters the app
 * through here so the rest of the code can rely on a validated, typed object.
 */
const envSchema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
  PORT: z.coerce.number().int().positive().max(65535).default(3000),
  /** The interface to bind. Defaults to all interfaces (required inside a container); set to
   *  `127.0.0.1` to additionally restrict the API to loopback as defense in depth — every route
   *  already requires the KATARI_API_KEY bearer token. */
  HOST: z.string().min(1).default("0.0.0.0"),
  LOG_LEVEL: z.enum(["debug", "info", "warn", "error"]).default("info"),
  /** Must be a postgres connection string — the only consumer is postgres.js. Validating the scheme
   *  here surfaces a mistyped URL at boot instead of as an opaque driver error on first query. */
  DATABASE_URL: z
    .url({ protocol: /^postgres(ql)?$/ })
    .default("postgres://katari:katari@localhost:5432/katari"),
  /** How the database connection is encrypted. Left unset, the runtime picks `disable` for a loopback host
   *  (a sibling container on a compose network, where TLS buys nothing) and `verify-full` for anything else,
   *  because a remote database — RDS, a managed provider — otherwise carries every secret's ciphertext, every
   *  run payload, and the database password itself in the clear. `require` is deliberately spelled out as
   *  "encrypted but UNAUTHENTICATED": postgres.js maps it to `rejectUnauthorized: false`, so it does not stop
   *  an active man in the middle. Prefer `verify-full`. */
  DATABASE_SSL: z.enum(["disable", "require", "verify-full"]).optional(),
  /** Allowed CORS origin(s): `*` (default), or a comma-separated allowlist. Every route requires
   *  the KATARI_API_KEY bearer token, so a wildcard alone exposes nothing — still, pin this to the
   *  admin origin in any shared/production deployment to shrink the cross-origin surface. */
  CORS_ORIGIN: z.string().min(1).default("*"),
  /** The AES-256-GCM key that encrypts secret (private) values at rest. Required (no default) — the runtime
   *  refuses to boot without it, since a missing key would silently persist secrets in plaintext. Must be a
   *  base64-encoded 32 bytes; generate one with `openssl rand -base64 32`.
   *
   *  KEEP THIS VALUE FOREVER. Every secret and every stored OAuth credential is sealed under it, and the
   *  ciphertext envelope records which key version sealed it (`lib/crypto.ts`) but not the key itself. Losing
   *  it destroys every stored secret irrecoverably; see KATARI_SECRET_KEY_PREVIOUS to rotate to a new one. */
  KATARI_SECRET_KEY: z
    .string()
    .refine(
      (value) => decodesToBytes(value, 32),
      "must be a base64-encoded 32-byte key (generate with `openssl rand -base64 32`)",
    ),
  /** Keys the runtime will still DECRYPT with, newest first, comma-separated — the other half of a rotation.
   *  Set the new key as KATARI_SECRET_KEY and move the old one here: everything written from then on is
   *  sealed under the new key, while values sealed under the old one keep opening. Once every stored value
   *  has been rewritten, drop the old key from this list. */
  KATARI_SECRET_KEY_PREVIOUS: z
    .string()
    .optional()
    .refine(
      (value) =>
        value === undefined ||
        value
          .split(",")
          .map((key) => key.trim())
          .every((key) => decodesToBytes(key, 32)),
      "must be a comma-separated list of base64-encoded 32-byte keys",
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
  /** Create the S3 bucket on boot if absent (idempotent). For a local S3 mock; leave false against real
   *  AWS, where the bucket is provisioned separately and the app should not need `CreateBucket`. */
  BLOB_S3_CREATE_BUCKET: z
    .enum(["true", "false"])
    .default("false")
    .transform((value) => value === "true"),
  /** The public base URL external services reach this runtime at — what `webhook.inbound` mints its
   *  URLs under (`<base>/inbound/<token>`). Behind a reverse proxy / tunnel, set it to the outside
   *  address; required under `NODE_ENV=production`, where the local default would mint URLs no external
   *  service can reach. */
  KATARI_PUBLIC_URL: z.url().optional(),
  /** The bearer token the API requires — every caller (the CLI, the web console) sends
   *  `Authorization: Bearer <this>`. Required (no default): the runtime refuses to boot without it, so an
   *  API is never accidentally left open. Distinct from KATARI_SECRET_KEY, which only encrypts secrets at
   *  rest. The 32-character floor is enforced rather than suggested: this single token is the whole of the
   *  API's authentication, and nothing rate-limits an attacker's guesses at network speed. */
  KATARI_API_KEY: z
    .string()
    .min(32, "must be at least 32 characters (generate one with `openssl rand -hex 32`)"),
  /** Disable the outbound address guard, letting a program reach loopback / private / link-local addresses.
   *  Development only: it is what makes `http.fetch("http://localhost:...")` work on a laptop, and it is
   *  exactly what must stay off in a deployment, where those addresses are the internal network and the
   *  cloud metadata service. Prefer KATARI_EGRESS_ALLOWED_HOSTS for a single genuine internal dependency. */
  KATARI_EGRESS_ALLOW_PRIVATE: z
    .enum(["true", "false"])
    .default("false")
    .transform((value) => value === "true"),
  /** Hostnames exempt from the outbound address guard, comma-separated — the narrow form of the escape
   *  hatch above, for a deployment whose programs must reach one named internal service. */
  KATARI_EGRESS_ALLOWED_HOSTS: z.string().default(""),
  /** How long one `http.fetch` may take end to end, and how long its connect may take. Without a ceiling a
   *  slow or hostile server holds a request slot (and its durable call row) indefinitely. */
  KATARI_HTTP_TIMEOUT_MS: z.coerce.number().int().positive().default(300_000),
  KATARI_HTTP_CONNECT_TIMEOUT_MS: z.coerce.number().int().positive().default(10_000),
  /** The ceiling on a single response body the runtime will buffer. Both `fetch` and `fetch_file` hold the
   *  whole body in memory, and the process is shared by every project, so one oversized download would
   *  otherwise be an availability problem for all of them. */
  KATARI_HTTP_MAX_RESPONSE_BYTES: z.coerce
    .number()
    .int()
    .positive()
    .default(64 * 1024 * 1024),
  /** The ceiling on an ordinary `/api` request body, and the one for a file upload. Unbounded reads
   *  are a trivial memory-exhaustion vector: a deploy buffers its body roughly three times over
   *  (raw text, the screening parse, the validator's), and an upload is buffered whole. The default is
   *  sized to a real deploy — a snapshot carries the IR plus every bundled FFI sidecar, which reaches
   *  tens of megabytes — and the surface is bearer-authenticated, so the cap is about a mistake, not
   *  an attacker. */
  KATARI_MAX_REQUEST_BYTES: z.coerce
    .number()
    .int()
    .positive()
    .default(64 * 1024 * 1024),
  KATARI_MAX_UPLOAD_BYTES: z.coerce
    .number()
    .int()
    .positive()
    .default(64 * 1024 * 1024),
  /** Requests per minute per client address on the surfaces that carry no bearer token (the inbound-webhook
   *  and MCP capability URLs, the OAuth callback), and on failed authentication. The tokens themselves are
   *  192-bit and unguessable, so this is about the cost of the attempt — each one costs a database round
   *  trip against a ten-connection pool — rather than about the search space. */
  KATARI_RATE_LIMIT_PER_MINUTE: z.coerce.number().int().positive().default(120),
  /** Whether the runtime takes the single-instance advisory lock at boot (see `db/instance-lock.ts`). The
   *  engine has no cross-process coordination, so two runtimes on one database both revive the same projects'
   *  actors and double-drive their in-flight runs. Turn it off only if you are certain nothing else runs
   *  against this database — it is not a performance knob. */
  KATARI_INSTANCE_LOCK: z
    .enum(["on", "off"])
    .default("on")
    .transform((value) => value === "on"),
  /** How long to wait for a previous runtime to release the lock before refusing to boot. The wait is what
   *  lets a rolling deploy work: the new process idles until the old one has drained. */
  KATARI_INSTANCE_LOCK_TIMEOUT_MS: z.coerce.number().int().positive().default(60_000),
});

/** Whether a base64 string decodes to exactly `length` bytes (Node accepts loose base64, so we re-encode and
 *  compare to reject malformed input rather than silently truncating it). */
function decodesToBytes(value: string, length: number): boolean {
  const decoded = Buffer.from(value, "base64");
  return decoded.length === length && decoded.toString("base64") === value;
}

/** The variables that may instead be supplied as `<NAME>_FILE`, naming a file whose contents are the value.
 *  Two reasons this exists. On ECS (and Kubernetes) it lets a secret arrive as a mounted file rather than as
 *  a task-definition environment variable, which anyone holding `ecs:DescribeTaskDefinition` can read. And it
 *  keeps the value out of the process environment altogether, which matters because an FFI sidecar runs as
 *  the same user as the runtime and can therefore read `/proc/<runtime pid>/environ` — restricting the
 *  sidecar's own environment does not hide what the parent was started with. */
const FILE_BACKED_VARIABLES = [
  "KATARI_API_KEY",
  "KATARI_SECRET_KEY",
  "KATARI_SECRET_KEY_PREVIOUS",
  "DATABASE_URL",
] as const;

/** Resolve every `<NAME>_FILE` into `<NAME>`. Setting both is a configuration error rather than a silent
 *  precedence rule, since which one wins is exactly the kind of guess that goes wrong with a secret. */
function resolveFileBackedVariables(source: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  const resolved: NodeJS.ProcessEnv = { ...source };
  for (const name of FILE_BACKED_VARIABLES) {
    const path = source[`${name}_FILE`];
    if (path === undefined || path === "") continue;
    if (source[name] !== undefined && source[name] !== "") {
      throw new Error(`Set either ${name} or ${name}_FILE, not both.`);
    }
    try {
      resolved[name] = readFileSync(path, "utf8").trim();
    } catch (error) {
      throw new Error(
        `Could not read ${name}_FILE at "${path}": ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }
  return resolved;
}

export type AppEnvVars = z.infer<typeof envSchema>;

export function loadEnv(source: NodeJS.ProcessEnv = process.env): AppEnvVars {
  const result = envSchema.safeParse(resolveFileBackedVariables(source));
  if (!result.success) {
    const issues = result.error.issues
      .map((issue) => `  - ${issue.path.join(".") || "(root)"}: ${issue.message}`)
      .join("\n");
    throw new Error(`Invalid environment variables:\n${issues}`);
  }
  // A production deployment that never set its outside address would mint webhook URLs pointing at its own
  // loopback, which no external service can deliver to. Failing at boot beats discovering it from a webhook
  // that silently never arrives.
  if (result.data.NODE_ENV === "production" && result.data.KATARI_PUBLIC_URL === undefined) {
    throw new Error(
      "Invalid environment variables:\n  - KATARI_PUBLIC_URL: required under NODE_ENV=production (the address external services reach this runtime at)",
    );
  }
  return result.data;
}
