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
cd typescript
pnpm install
pnpm -r run build
```

## Running locally

The runtime is one Postgres + one Node process; the admin web UI is baked
into the same image. Copy `.env.example` to `.env` first.

```sh
cp .env.example .env
# edit .env to set KATARI_API_KEY / KATARI_SECRET_KEY (or keep dev defaults)
```

Three dev modes, pick by what you're iterating on:

```sh
# A. Full stack in Docker — admin UI baked, "does the prod image work?"
docker compose up                       # http://localhost:8000/admin/

# B. Editing admin web — vite hot reload on host, Postgres in Docker
docker compose up db                                # Postgres only
pnpm --filter @katari-lang/api-server dev           # :8000, tsx watch
pnpm --filter @katari-lang/admin-web dev            # :5173/admin/, vite

# C. Editing api-server / runtime — same as B but ignore the vite step
docker compose up db
pnpm --filter @katari-lang/api-server dev
```

`katari apply` (the CLI) reads `[runtime].url` from each project's
`katari.toml`; the default `http://localhost:8000` works for all three
modes. Pass `--api-url` to override.

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

## Licence

[MIT](LICENSE)
