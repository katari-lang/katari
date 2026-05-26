# Katari

Katari is a small DSL for orchestrating agents — programs that delegate work
to other agents, raise effects via requests, and run in a structured-concurrency
runtime.

This repository hosts the Katari compiler (Haskell), the runtime (TypeScript),
the `katari` CLI binary, and the VSCode extension.

## Layout

```
haskell/
  katari-compiler/   Pure compiler library (input: source map → output: IR JSON + diagnostics)
  katari-project/    katari.toml / lockfile / snapshot / package resolution
  katari/            CLI binary (executable: katari)
  katari-lsp/        LSP server (in redesign)
typescript/
  packages/
    katari-runtime/      Runtime core + delegation engine + sidecar manager
    katari-api-server/   HTTP server that hosts a runtime instance
    katari-port/         FFI SDK for ext-agent sidecars
    katari-bundle/       esbuild-based bundler invoked by `katari apply`
    katari-vscode/       VSCode extension
e2e/                 End-to-end tests + samples
```

Companion repositories:

- [`katari-lang/katari-registry`](https://github.com/katari-lang/katari-registry)
  — curated package set snapshots (the spago-style registry).
- [`katari-lang/katari-web`](https://github.com/katari-lang/katari-web)
  — documentation site.

## Building

```sh
# Haskell (compiler / katari-project / katari binary / lsp)
stack build
stack test

# TypeScript (pnpm v11 — pinned via packageManager)
# Either from root (npm scripts delegate to pnpm):
npm run build:ts

# Or directly:
cd typescript
pnpm install
pnpm -r run build
```

## Running locally

The runtime is one Postgres + one Node process; the admin web UI is baked
into the same image at deploy time. Copy `.env.example` to `.env` first.

```sh
cp .env.example .env
# edit .env to set KATARI_API_KEY / KATARI_SECRET_KEY (or keep dev defaults)
```

### `pnpm dev` — runtime hot-reload (default while developing)

```sh
pnpm dev          # → http://localhost:5173/admin/ (vite HMR for admin web)
```

Brings up:

- Postgres in Docker (`docker compose up -d --wait db`)
- `katari-api-server` on the host with `tsx watch` (auto-restart on TS edits;
  `@katari-lang/runtime` is a workspace dep so edits there propagate too)
- `katari-admin-web` via `vite` (HMR — admin component edits are sub-second)

Vite proxies `/api/*` → `http://localhost:8000/*`, so the admin SPA talks
to the host-side api-server. Ctrl+C stops api-server + vite; Postgres
keeps running (state survives between sessions; nuke with
`docker compose down -v`).

### `docker compose up --build` — final-test the prod image

```sh
docker compose up --build       # → http://localhost:8000/admin/
```

This is the same image CI builds and pushes to GHCR (= what end users
self-host). admin-web is baked into `/app/admin-web/dist`, so no separate
process. Use before pushing — the dev path can mask integration bugs that
only surface in the built image.

### `katari apply` — push a snapshot to the running runtime

Works against either dev mode. From a project directory:

```sh
stack exec katari -- apply
```

Reads `[runtime].url` from `katari.toml` (default `http://localhost:8000`);
pass `--api-url` to override. Set `KATARI_API_KEY` in the same shell so the
CLI can authenticate (matches your `.env`).

## Compiler pipeline

`katari-compiler` is **pure** — no file I/O. The single entry point is

```haskell
compile :: CompileInput -> CompileResult
```

defined in [`Katari.Compile`](haskell/katari-compiler/src/Katari/Compile.hs).
It runs the entire pipeline (lex → parse → identify → constrain → solve →
zonk → exhaustiveness → lower) and returns:

- `irModule`         — JSON-serialisable IR for the runtime,
- `schemaBundle`     — JSON Schema for AI tool calling,
- `diagnostics`      — unified diagnostic stream (errors, warnings, hints),
- `identifierResult` / `solverResult` / `zonkResult` — partial-result
  artefacts useful for editor tooling (hover, find-references).

Diagnostics are stable: every `Diagnostic` carries a 4-digit `K####` code.
The full registry lives in [`haskell/katari-compiler/CHANGELOG.md`](haskell/katari-compiler/CHANGELOG.md).

## Distribution

| Artefact | Where |
|---|---|
| `katari` CLI binary | npm (`npm i -g @katari-lang/cli`) + GitHub Releases tarballs |
| Katari runtime (Docker) | `ghcr.io/katari-lang/katari` |
| `@katari-lang/runtime`, `@katari-lang/port`, `@katari-lang/bundle`, `@katari-lang/api-server` | npm |
| `katari-vscode` | VSIX on GitHub Releases (Marketplace TBD) |

See [`examples/self-host/`](examples/self-host) for a `docker compose`
quickstart for self-hosting.

## Directory notes

**`e2e/samples/`** — numbered sample projects (e.g. `01-hello`, `03-data-and-match`)
that double as end-to-end test fixtures. Each sample is a self-contained Katari
project exercising a specific language feature.

**`scripts/`** — release tooling (version bumping, binary staging, npm publish
bootstrap). See each script's header for usage.

## Licence

[MIT](LICENSE)
