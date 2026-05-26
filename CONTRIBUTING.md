# Contributing to Katari

Thanks for your interest in Katari! This document captures the conventions
contributors should follow.

## Building

```sh
stack build      # compiler library
stack test       # unit + property + golden tests
```

For the runtime side:

```sh
cd typescript
pnpm install     # pnpm v11 (pinned via packageManager in root package.json)
pnpm -r run build
```

### Running tests

```sh
# Haskell
stack test

# TypeScript
cd typescript && pnpm -r run test

# End-to-end (requires a running runtime — see README.md)
cd e2e && pnpm test
```

## Workflow

1. Branch from `main`.
2. Keep commits focused: each commit should compile and pass `stack test`.
3. Run `stack haddock katari-compiler --no-haddock-deps` before opening a
   PR; the Haddock output should be warning-clean.
4. Open a PR with a description that explains the *why*, not the *what*.

## Coding conventions (Haskell)

The full guide is in [`CLAUDE.md`](CLAUDE.md). The condensed version:

- **No function-equation pattern matching.** Use `\case` or `case ... of`
  inside a single function definition.
- **Use the convenience extensions.** `LambdaCase`, `RecordWildCards`,
  `OverloadedStrings`, `OverloadedRecordDot`, `StrictData`, `GADTs`,
  `NoFieldSelectors` are all on by default.
- **Sum types use GADT syntax.** `data Foo where Bar :: ... -> Foo`.
- **Constructors carry the type-name prefix.** `BlockUser` rather than
  `User`; `KeywordFor` rather than `For`.
- **Full words for record fields and local bindings.** `parameters`, not
  `params`. `context`, not `ctx`. `zonkResult`, not `zr`. The exception
  is the `\state ->` lambda used in `modify` (the State updater idiom),
  which is allowed.
- **Type-variable names use full words too.** `phase`, not `p`;
  `nameRefKind`, not `s`. Single-letter type variables are reserved for
  truly generic abstractions (Functor / Monad style).
- **Parser-returning functions start with `parse`.** Lexer helpers start
  with `lex`.

## Adding a diagnostic code

1. Pick the next free code in the appropriate range (see the table in
   `CHANGELOG.md`).
2. Add a constructor to the relevant phase's error type, plus a
   `toDiagnostic` arm that emits the code.
3. Add a row to the `CHANGELOG.md` registry.
4. Add (or extend) a test that exercises the new diagnostic.

## Tests

- **Unit tests** live in `haskell/katari-compiler/test/Katari/*Spec.hs`.
- **Golden tests** live in `test/golden/cases/`. Snapshot files live in
  `test/golden/expected/`. Update with `KATARI_GOLDEN_ACCEPT=1 stack test`
  and review the diff before committing.
- **Property tests** (hedgehog) live in `test/Katari/PropertySpec.hs`.

## Commit message style

Follow the [Conventional Commits](https://www.conventionalcommits.org/)
prefix system: `feat(katari-compiler): ...`, `refactor(katari-compiler): ...`,
`test(katari-compiler): ...`, etc. The body explains the *why*; the *what*
should be discoverable from the diff.
