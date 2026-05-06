# Katari

Katari is a small DSL for orchestrating agents — programs that delegate work
to other agents, raise effects via requests, and run in a structured-concurrency
runtime.

This repository hosts the Katari compiler (Haskell), the runtime and its
external services (TypeScript), and a set of language-server tools.

## Layout

```
haskell/
  katari-compiler/        Pure compiler library (input: source map → output: IR JSON + diagnostics)
  katari-cli/             Command-line front-end (in redesign)
  katari-lsp/             Language Server Protocol implementation (in redesign)
ts/
  packages/
    katari-protocol/        Inter-agent protocol library (types, store, server, router)
    katari-runtime/         Runtime (in redesign for the new IR JSON)
    katari-discord-server/  Discord external service
    katari-ai-server/       AI external service (Gemini)
    katari-cron-server/     Cron external service
    katari-websearch-server/ Web-search external service
    katari-sandbox-server/  Docker sandbox external service
```

## Building the compiler

```sh
stack build
stack test
```

Haddock:

```sh
stack haddock katari-compiler --no-haddock-deps
```

## Building the runtime

```sh
cd ts
pnpm install
pnpm -r run build
```

`pnpm` v9 is required (the project pins `pnpm@9.15.9`); v10 has a
workspace-detection bug we cannot work around yet.

## Compiler pipeline

`katari-compiler` is **pure** — no file I/O. The single entry point is

```haskell
compile :: CompileInput -> CompileResult
```

defined in [`Katari.Compile`](haskell/katari-compiler/src/Katari/Compile.hs).
It runs the entire pipeline (lex → parse → identify → constrain → solve →
zonk → exhaustiveness → lower) and returns:

- `irModule`         — JSON-serialisable IR for the runtime,
- `schemaEntries`    — JSON Schema for AI tool calling,
- `diagnostics`      — unified diagnostic stream (errors, warnings, hints),
- `identifierResult` / `solverResult` / `zonkResult` — partial-result
  artefacts useful for editor tooling (hover, find-references).

Diagnostics are stable: every `Diagnostic` carries a 4-digit `K####` code.
The full registry lives in [`haskell/katari-compiler/CHANGELOG.md`](haskell/katari-compiler/CHANGELOG.md).

## Status

The compiler is OSS-ready; the runtime and tooling are mid-redesign for the
new IR JSON shape.

## Licence

[MIT](LICENSE)
