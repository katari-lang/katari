# Deploying a Katari runtime

This is the operations counterpart to the README's local flow. It covers what changes when the runtime moves
off a laptop and onto a real deployment — most of it AWS/ECS-flavoured, because that is the common case, but
the reasoning holds for any container platform.

Read [`SECURITY.md`](../SECURITY.md) alongside this: it states the trust model that these settings assume.

---

## The two credentials, and why one of them is forever

| Variable | What it is | If you lose it |
|---|---|---|
| `KATARI_API_KEY` | The bearer token every API caller presents. | Rotate it freely; callers just re-authenticate. |
| `KATARI_SECRET_KEY` | The AES-256-GCM key that encrypts secrets at rest. | **Every stored secret and every OAuth credential is unrecoverable.** |

Generate them once:

```bash
openssl rand -hex 32     # KATARI_API_KEY  (32-character minimum is enforced at boot)
openssl rand -base64 32  # KATARI_SECRET_KEY
```

`KATARI_SECRET_KEY` must be carried across every deployment, forever. Re-running `openssl rand` when you
rebuild a task definition destroys the data — the failure does not appear at boot but later, as scattered
"could not decrypt a stored secret" errors when a program reads an env secret.

**To rotate it** (supported since 0.1.2): put the new key in `KATARI_SECRET_KEY` and move the old one to
`KATARI_SECRET_KEY_PREVIOUS`. New writes use the new key; old values keep opening. Once everything has been
rewritten, drop the old key from the list.

### Getting them in without putting them in the task definition

Values in `containerDefinitions[].environment` are readable by anyone with `ecs:DescribeTaskDefinition`, are
rendered in the console, and end up in CloudTrail and Terraform state. Two better options, in order:

1. **ECS `secrets` + `valueFrom`** — Secrets Manager or SSM Parameter Store. ECS injects them as environment
   variables at container start without them appearing in the task definition.
2. **The `*_FILE` variables** — `KATARI_API_KEY_FILE`, `KATARI_SECRET_KEY_FILE`,
   `KATARI_SECRET_KEY_PREVIOUS_FILE`, `DATABASE_URL_FILE`. Each names a file whose contents are the value.
   This additionally keeps the value out of the process environment, which matters because an FFI sidecar
   runs as the same OS user and can read `/proc/<runtime pid>/environ`.

Setting both `X` and `X_FILE` is a boot error rather than a silent precedence rule.

---

## Database

`DATABASE_SSL` is `disable` for a loopback host and `verify-full` for anything else, chosen automatically.
You normally do not need to set it.

If you do set it, know that **`require` is not what it sounds like**: postgres.js maps it to
`rejectUnauthorized: false`, so the connection is encrypted but the server is not authenticated and an active
man in the middle still succeeds. Use `verify-full` unless you have a specific reason not to.

The runtime applies migrations at boot and therefore needs DDL rights on its database.

---

## Exactly one runtime process per database

The engine keeps warm, in-memory per-project state and revives an actor for every project with a live run on
every boot. Two processes against one database both drive the same runs: the at-most-once guarantee that
`http` and `ffi` recovery depend on is gone and external side effects happen twice.

The runtime enforces this with a Postgres advisory lock. A second process waits
(`KATARI_INSTANCE_LOCK_TIMEOUT_MS`, default 60s) and then refuses to boot.

**This changes how you deploy.** ECS rolling deploys default to `minimumHealthyPercent: 100`, which
deliberately overlaps the old and new tasks — so the new task will sit waiting for the old one to drain. Set:

```json
"deploymentConfiguration": { "minimumHealthyPercent": 0, "maximumPercent": 100 }
```

and keep `desiredCount` at 1. Horizontal scaling is not supported.

---

## What a program is allowed to reach

`http.fetch`'s `url` and an MCP server descriptor's `url` are ordinary runtime strings, so their value can
come from an LLM's output, a webhook payload, or a tool result. The runtime therefore refuses to connect to
loopback, private, link-local, and other non-public addresses — which is what keeps a prompt-injected agent
from reading the cloud metadata service (`169.254.169.254`, or `169.254.170.2` on ECS) or sweeping your VPC.

The check happens at connect time, so DNS rebinding and redirect chains are covered too.

- `KATARI_EGRESS_ALLOWED_HOSTS=internal.example` — exempt a named host you genuinely need to reach.
- `KATARI_EGRESS_ALLOW_PRIVATE=true` — disable the check entirely. **Development only**; it is what makes
  `http.fetch("http://localhost:…")` work on a laptop.

Defence in depth worth having anyway: give the task role only the permissions the runtime needs (S3 on its
blob bucket), and set `HttpPutResponseHopLimit: 1` with IMDSv2 required on EC2-backed capacity.

---

## Other settings you may want

| Variable | Default | Notes |
|---|---|---|
| `KATARI_PUBLIC_URL` | — | **Required** under `NODE_ENV=production`. The outside address `webhook.inbound` mints its URLs under. |
| `CORS_ORIGIN` | `*` | Pin it to the console's origin. Harmless as a wildcard (auth is a header, not a cookie) but there is no reason to leave it open. |
| `KATARI_RATE_LIMIT_PER_MINUTE` | `120` | Per client address, on the unauthenticated capability paths and on failed authentication. |
| `KATARI_MAX_REQUEST_BYTES` | 64 MiB | Ordinary `/api` bodies — a deploy's snapshot (IR plus bundled sidecars) arrives as one. Bounds both the bytes on the wire and what a compressed body expands to. |
| `KATARI_MAX_UPLOAD_BYTES` | 64 MiB | File uploads. |
| `KATARI_HTTP_TIMEOUT_MS` | 300000 | Ceiling on one `http.fetch`. |
| `KATARI_HTTP_MAX_RESPONSE_BYTES` | 64 MiB | Ceiling on one response body. |

---

## Container notes

- The image runs as a non-root user and needs no writable root filesystem **except `/tmp`**, where FFI
  sidecar bundles are written before they are executed. With `readonlyRootFilesystem: true`, mount a `tmpfs`
  volume at `/tmp`.
- ECS ignores the image's `HEALTHCHECK`; restate it as `healthCheck` in the task definition.
  `/api/v1/health` is deliberately auth-exempt and deliberately does **not** touch the database, so it is a
  liveness probe. Wiring it as an ALB health check will route traffic to a task whose database is
  unreachable.
- The runtime serves plain HTTP and expects TLS to be terminated in front of it.
- `/api` accepts a `Content-Encoding: gzip` request body, and the CLI sends one for a deploy past a
  megabyte — a snapshot is largely repeated schema text, so it arrives at roughly a tenth of its size. A
  proxy in front of the runtime has to pass the header and the body through unchanged.
- Delete the `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` lines from the compose file if you port it: on
  AWS they override the task role and break S3 with a confusing 403. The runtime uses the default AWS
  credential chain, so the task role works with no configuration.
- Capability URLs (`/inbound/<token>`, `/mcp/<token>`) carry their token in the path. The runtime redacts
  them from its own logs, but a load balancer's access logs record full paths — treat that log bucket as
  secret-bearing, or leave access logging off.
