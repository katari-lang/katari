# Changelog — katari-compiler

All notable changes to `katari-compiler` are recorded here.

The format roughly follows [Keep a Changelog](https://keepachangelog.com/),
with project-specific extensions: every change to the `Diagnostic` table
updates the [Diagnostic code registry](#diagnostic-code-registry) section
below.

## Unreleased — OSS pre-publish refactor

This pass tightens the public surface area of the library so the API is
defensible under semver before the first OSS release.

### Added

- `Katari.Common` module hosting the shared `QualifiedName` and
  `LiteralValue` types (previously duplicated between `Katari.AST` /
  `Katari.IR` / `Katari.Id`).
- `Katari.Diagnostic.diagnosticInternalError` and the `K9999` reserved
  code for invariant-violation diagnostics.
- `Katari.Diagnostic.Render.renderDiagnosticAnsi` for severity-coloured
  terminal output (built on `prettyprinter` /
  `prettyprinter-ansi-terminal`).
- Golden-test suite (`test/golden/cases/`, runner in
  `Katari.GoldenSpec`) protecting the IR JSON, schema JSON, and
  diagnostic-rendering shapes.
- Property-test suite (`Katari.PropertySpec`, hedgehog-based) covering
  JSON round-trips and `compile` determinism.

### Changed

- `Katari.Internal.internalError` / `internalErrorNoSpan` no longer
  panic via `error`; they construct a `K9999` `Diagnostic` that callers
  thread through their existing error-collection mechanism. The
  `Lower` monad gains `ExceptT Diagnostic` so internal errors surface
  in `CompileResult.diagnostics` instead of crashing the host. Long-
  running embedders (LSP, playground) can now recover from a Katari
  compiler bug without taking the host process down.
- `Katari.Lexer` now has an explicit export list. Internal helpers
  (`LexerState`, `LexerContext`, `lexNumber`, etc.) are no longer
  public.
- `Katari.Typechecker.Identifier` no longer re-exports the ID newtypes
  (`VariableId` / `TypeId` / `ModuleId` / `RequestId` / `ConstructorId`)
  or `QualifiedName`. Downstream call sites now import them from
  `Katari.Id` (or from `Katari.Common` for `QualifiedName`).
- `Katari.Compile.CompileResult` drops the redundant `Maybe` wrappers
  on `identifierResult` / `solverResult` / `zonkResult` (these were
  always `Just`).
- `solve` and `zonk` now return `(Result, [Error])` tuples, matching
  the other phases. The `solverErrors` / `zonkErrors` record fields
  are gone.
- `ConstraintGenResult` replaces the bare `nextTypeVariableId` /
  `nextRequestVariableId` `Int` fields with a `VariableSupply`
  newtype.
- `ZonkResult` no longer republishes `IdentifierResult` fields. The
  affected downstream APIs (`lowerProgram`, `buildSchemas`,
  `checkExhaustive`, the `Katari.Query` family) now take both
  `IdentifierResult` and `ZonkResult` directly.
- IR identifier renames (JSON-breaking): `ReqId` → `RequestId`,
  `CtorId` → `ConstructorId`, `BlockCtor` → `BlockConstructor`. All
  `Block` variants are now positional and serialise their payload
  under the `body` key (previously `contents`); `sumOptions` for
  every IR sum type uses `contentsFieldName = "body"` consistently.
- `ImportDeclaration` drops its phase parameter — it carried no
  phase-dependent fields. The `retagImportDeclaration` helper is gone.
- `Katari.Diagnostic.Render` is rebuilt on `prettyprinter`. The plain
  text renderers (`renderDiagnostic` / `renderDiagnosticPlain`) keep
  their previous shape; the new ANSI renderer
  (`renderDiagnosticAnsi`) emits severity-coloured headers and
  underlines.
- `lowerProgram` returns `(Either Diagnostic IRModule, [LoweringError])`
  (was `(IRModule, [LoweringError])`) — `Left` carries the K9999
  diagnostic when an internal error fires.

### Removed

- `bytestring`, `scientific`, `vector` library dependencies — none of
  them were imported anywhere in the library or test suite.
- The hand-rolled Tarjan SCC implementation in
  `Katari.Typechecker.ImportGraph` (replaced by
  `Data.Graph.stronglyConnComp`).
- The hand-rolled list-index helper `(!?)` in `Diagnostic.Render`
  (replaced by `Safe.atMay`).
- The `nub`-based dedup in `Solver.Substitution` (replaced by an
  `Ord`-based set, O(n²) → O(n log n)).
- `Katari.Typechecker.Solver.solveRequestWorklist` no longer takes the
  unused leading `Int` parameter.

## Earlier — Phase 19 (pre-OSS internal refactor)

Highlights of the work that landed before the OSS pre-publish pass:

### Breaking changes

- IR JSON sum tags switched to camelCase with full type-name prefixes
  (`SCall` → `statementCall`, `MPAny` → `matchPatternAny`,
  `LVInteger` → `literalValueInteger`, etc.). The runtime must use
  these tag names.
- `IRModule` gained a `metadata` field carrying `schemaVersion`. The
  runtime should reject loads with an unexpected schema version.

### Added

- `CompileResult.identifierResult` exposes the name-resolution table
  for editor tooling.
- `Katari.Query` provides `lookupAtPosition`, `buildOccurrenceIndex`,
  `identifyAtPosition`, `findReferences`, `findDefinition`. Positions
  are code-point based; LSP layers convert UTF-16 offsets before
  calling.
- `Katari.Diagnostic.Render` separates source-text-dependent rendering
  from `Katari.Diagnostic` itself.
- `Katari.Diagnostic.{filterAtLeast, sortBySpan, groupByFilePath}`
  helpers for orchestrators.

### Internal

- All sum types switched to GADT syntax with constructor-name prefixes.
- `parse*` / `lex*` prefix conventions enforced project-wide.
- `passThroughX` boilerplate eliminated (phase transitions are now
  identity transformations on shape).

## Diagnostic code registry

| Range          | Phase                  |
| -------------- | ---------------------- |
| K0001 – K0099  | Lexer / Parser         |
| K0100 – K0199  | Identifier             |
| K0200 – K0299  | Constraint generator / Solver / Zonker / Exhaustive |
| K0300 – K0399  | Lowering               |
| K0400 – K0499  | Schema / emit (reserved) |
| K9999          | Internal compiler error (any phase) |

### Lexer / Parser

| Code  | Trigger |
| ----- | ------- |
| K0001 | unterminated template literal |
| K0002 | unterminated string literal |
| K0003 | invalid unicode escape sequence |
| K0004 | unrecognised character |
| K0020 | parse error (megaparsec failure) |
| K0021 | unexpected end-of-input |

### Identifier

| Code  | Trigger |
| ----- | ------- |
| K0100 | duplicate definition |
| K0101 | local binding shadows a non-variable (module / type) |
| K0102 | undefined name |
| K0103 | qualified-name lookup failed (`module.member`) |
| K0104 | name used in a type position is not a type |
| K0105 | name used as a module is not a module |
| K0106 | imported name not found in source module |
| K0107 | imported module not found |
| K0108 | request-handler target is not a `req` |
| K0109 | match-pattern constructor is not a `data` constructor |
| K0110 | import cycle |
| K0150 | external agent declaration without `@""` annotation |
| K0151 | external agent declaration with empty `@""` annotation |

### Constraint generator / Solver / Zonker / Exhaustive

| Code  | Trigger |
| ----- | ------- |
| K0200 | type synonym cycle |
| K0220 | structural type mismatch (function vs tuple, etc.) |
| K0221 | subtype mismatch |
| K0222 | annotation does not subtype-match expression |
| K0250 | solver substitution missing a type variable (defensive fallback) |
| K0251 | solver substitution missing a request variable (defensive fallback) |
| K0290 | non-exhaustive `match` |
| K0291 | refutable irrefutable-pattern context (`let`, parameter, etc.) |
| K0292 | unreachable `match` arm |

### Lowering

| Code  | Trigger |
| ----- | ------- |
| K0300 | unresolved variable reaching lowering |
| K0301 | parser / identifier sentinel reaching lowering |

### Internal

| Code  | Trigger |
| ----- | ------- |
| K9999 | internal compiler error (invariant violation; please report as a bug) |
