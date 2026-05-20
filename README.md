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

# TypeScript (pnpm v9 — pinned via packageManager)
cd typescript
pnpm install
pnpm -r run build
```

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
| `katari-runtime` (Docker) | `ghcr.io/katari-lang/katari-runtime` |
| `@katari-lang/runtime`, `@katari-lang/port`, `@katari-lang/bundle`, `@katari-lang/api-server` | npm |
| `katari-vscode` | VSIX on GitHub Releases (Marketplace TBD) |

See [`examples/self-host/`](examples/self-host) for a `docker compose`
quickstart for self-hosting.

## Licence

[MIT](LICENSE)
