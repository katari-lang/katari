# @katari-lang/e2e

The smoke e2e: `.ktr` source → the **stack-built katari CLI** (compile + sidecar bundle + deploy over
HTTP) → a **real runtime server** (compose postgres + s3mock) → runs, files, escalations, a rollback,
and a mid-run server restart. The unit suites cover each layer in isolation; this suite is the
wire-compatibility net between the Haskell compiler's output and the TypeScript runtime, driving
`examples/playground` end to end.

## Prerequisites

- docker (the suite runs `docker compose up -d postgres s3mock` itself; idempotent when already up)
- a built CLI: `stack build` (the suite resolves the binary via `stack path --local-install-root`)
- `pnpm install` (the suite builds `@katari-lang/bundle` itself)

## Run

```sh
pnpm run test:e2e   # from the repo root
```

The suite provisions and drops its own database (`katari_e2e`) and uses its own bucket
(`katari-e2e-blobs`), so it never touches dev data. It is **not** part of `pnpm run test` — the unit
suites stay runnable without docker or a Haskell toolchain.
