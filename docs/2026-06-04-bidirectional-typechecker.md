# Bidirectional typechecker (replace the global solver)

Status: design agreed 2026-06-04. Implementation pending.

## Motivation

Every callable *parameter* is now fully annotated:

- **Parameters** carry a mandatory `: type` (enforced in the parser, K0020).
- **Return types** are mandatory on `req` / `ext` / `prim`, and on a **recursive**
  `agent`; a **non-recursive** agent's return type is *inferred* by forward
  synthesis of its body (see "Return types" below).

With every parameter type and every recursive boundary known up-front, a value's
type never has to be *inferred from its uses*, so the global type-variable machinery
(constraint generation → unification solver → zonking) is unnecessary. A
single top-down **bidirectional** walk type-checks each body directly.

This dissolves the long-standing pain points: type variables, the bound-pair
Solver, `Branch`/narrowing, the projection-direction problem, and the
Constrained/Unresolved + Zonk phase split.

## What already exists (do NOT rebuild)

`Katari.Typechecker.NormalizedType` already provides the entire relational
core as pure, solver-independent functions:

- `normaliseSemantic :: SemanticType Resolved -> NormalizedType`
- `subtypeNormalizedType :: DataFieldEnv -> NormalizedType -> NormalizedType -> Bool`
  (includes the `data <: object <: record` and `tuple <: array` edges)
- `denormalise :: NormalizedType -> SemanticType Resolved`
- `unionNT` / `intersectNT` (lattice join / meet — for `if` / `match` arm joins)
- `buildDataFieldEnv :: Map QualifiedName (SemanticType Resolved) -> DataFieldEnv`

The checker is essentially: *walk the tree, call `subtypeNormalizedType` at
each flow point, `unionNT` at each branch join.* No new relational logic.

## Core: two mutually-recursive judgments

Work entirely in `SemanticType Resolved`. Produce `Module Zonked` directly
(the existing `Zonked` phase = Resolved types), so Lowering / Schema / Query
downstream are untouched.

```
check  :: Expression Identified -> SemanticType Resolved -> Check (Expression Zonked)
synth  :: Expression Identified -> Check (Expression Zonked, SemanticType Resolved)
```

- **check** is used when an expected type flows down (return position, `let x: T`,
  call argument against the param type, annotated branch). It synthesises, then
  asserts `synthesised <: expected` via `subtypeNormalizedType` (emit a diagnostic
  on failure; recover by stamping the *expected* type so the walk continues).
- **synth** is used where no expectation exists (trailing block value, `let x = e`,
  operands). It builds the node bottom-up.

Most forms are synth-directed; `check` is a thin wrapper (`synth` + subtype
assert) except where a form genuinely needs the expectation pushed inward
(currently none do — Katari has no bare lambdas; closures/agents are always
annotated). So a single `synth` + a `subtypeAssert` helper covers everything;
`check e t = do (e', s) <- synth e; subtypeAssert s t span; pure e'`.

### Per-form synth rules

- **literal** → its singleton/base `SemanticType` (`literalValueToSemantic`).
- **variable** → look it up in the local env (params + `let` bindings + state
  vars + pattern bindings) or the top-level/imported signature map.
- **tuple `[e…]`** → `SemanticTypeTuple [synth eᵢ]`.
- **record `{l = e…}`** → `SemanticTypeObject (l ↦ synth e)` (precise object).
- **call `f(l = a…)`** → synth `f` to a `SemanticTypeFunction params ret eff`;
  for each arg, `check aᵢ (paramType l)`; missing args must have defaults; the
  call's type is `ret`. Records the callee's `eff` for the effect pass.
- **field access `e.x`** → synth `e` to `S`; require `S <: {x: α}` is *not* how
  we do it now — instead read the field type directly from `S`'s map layer
  (object/data/record) via the normalized form; error if absent (K-mismatch).
- **binary/unary op** → desugars to a prim call (already the case); synth the prim.
- **if** → check condition `<: boolean`; synth both branches; result =
  `unionNT thenT elseT` (no else ⇒ `unionNT thenT null`).
- **match** → synth the subject `S`; for each arm, bind pattern variables by
  *projecting* `S` through the pattern (the subject type is known, so this is a
  direct structural read, never a constraint); synth each arm body; result =
  `unionNT` of arm types. Exhaustiveness check unchanged (`Exhaustive.hs`).
- **for** → element type from the iterable's seq layer; body checked; result
  type `finType ∪ breakType` per the existing rule.
- **handle** → check the body with the state vars / handlers in scope; result
  type = body ∪ handler-result types ∪ break types (existing semantics).
- **block** → thread `let` / statements, return the trailing expression's synth
  (or `null` if none).

### Pattern projection (replaces the projection-direction problem)

Because the subject type is *known* (synthesised), binding pattern-variable
types is a direct read, not a constraint:

- tuple pattern `[p₀ … pₙ]` over subject seq type: `pᵢ`'s subject = element type
  at position `i` (array → its element; tuple → positional, padding beyond named
  positions is fine under minimum-elements).
- constructor pattern `C(f = p…)` over a data/union subject: narrow to `C`'s
  declared field types (from `DataFieldEnv` / the data decl).
- record pattern `{l = p}` over a map subject: `p`'s subject = the field type `l`.
- literal / wildcard / type-guard: as today, narrowing the subject locally.

This is exactly the arity-mismatched / array-subject case that the
variable-based projection could not serve in either direction; with a concrete
subject type both work trivially.

## Return types (infer for non-recursive, annotate recursion)

Making `agent` return types mandatory was tried and rejected: 395 of 701
compiler tests omit `-> T` (most agents are non-recursive and their return is
obvious), so it is far too heavy. Instead:

- A **non-recursive** agent's return type is **inferred** by forward-synthesising
  its body. No annotation needed. (An annotation, if present, is still checked:
  `bodySynth <: declared`.)
- A **recursive** agent **must** annotate its return type. The type lattice has
  infinite ascending chains, so forward synthesis through a cycle has no
  terminating fixpoint; the annotation breaks the cycle (callers use it).

Recursion is detected from the call graph we already build (`AgentGraph` /
`agentSCCs`):

```
recursive(A) = (A's SCC has > 1 member) ∨ (A ∈ callees(A))   -- self-call
```

Enforcement lives in the **checker**, not the parser (the parser cannot see
recursion). A recursive agent missing `-> T` is a dedicated diagnostic:
"recursive agent 'foo' needs an explicit return type — it can't be inferred
through the recursion." This keeps `-> T` optional in the grammar.

Contrast with effects (next): the effect lattice is *finite*, so a recursive
agent's effect can be inferred by fixpoint with no annotation — the asymmetry is
infinite-vs-finite lattice, not types-vs-effects per se.

## Effects: per-SCC finite-lattice fixpoint

Effects are **inferred** (annotation optional), so recursion is not broken by
annotations — but the effect lattice is the powerset of the program's (finite)
request names, so a least fixpoint terminates.

During the same body walk, accumulate each agent's effect contribution:

```
eff(A) = directReqs(A) ∪ ⋃_{call to G} eff(G)        -- handle scopes subtract:
       … inside a handle/where covering H: (subEff ∖ H) ∪ ⋃ handlerBodyEff
```

`throw` contributes ∅ (implicit, every agent may raise it).

Per SCC: pin annotated agents to their declared `with E`; start unannotated
agents at ∅; iterate to fixpoint (monotone, finite ⇒ terminates). Callees
outside the SCC use their finalised `eff` from the module interface.

Then **check**: for each annotated agent, `eff_body ⊆ E_declared` (else
"raises a request outside its `with` clause"). `pure` is just `with ()`
(`eff_body = ∅`). Published effect = `E` (annotated) or inferred (bare). The
existing `where`-handler coverage check is unchanged.

Implementation note: store, per agent, a small "effect term" built during the
walk (direct reqs / callee refs / handle-scoped sub-terms + their handled set)
and re-evaluate it each fixpoint iteration. Bodies are small; a naive re-walk
per iteration (bounded by the request-name count) is also acceptable.

## Generics (no inference — explicit application)

Out of scope for the first cut, but the design is compatible: a generic
callable `agent foo<T: Bound>(x: T) -> T` is applied explicitly `foo<integer>(…)`;
substitute `T := integer` in the signature before checking. Inside a generic
body, replace each type parameter by its bound (upper bound in covariant
positions, lower in contravariant) for exhaustiveness / match typing. No
inference variable is ever introduced.

## Orchestration change

`Katari.Typechecker.typecheckModule` keeps the per-SCC fold. `runOneSCC`
changes from `generateConstraintsForSCC → solve → zonk` to:

1. **Seed signatures**: elaborate every SCC decl's parameter types into the env.
   - Recursive SCC (cycle): the return type is annotated (required) → seed the
     full `param → return` signature *before* checking bodies, so recursive
     calls resolve. A missing annotation here is the recursive-return diagnostic.
   - Non-recursive singleton `{A}`: A is not referenced recursively, so no
     pre-seed of its return is needed — synthesise it from the body in step 2.
2. **Check bodies**: for each agent, walk the body once. Recursive agents:
   `check body <: declaredReturn`. Non-recursive agents: `synth body` ⇒ the
   inferred return type (then check against an annotation if one was written).
   Produces `Zonked` decls + per-agent effect terms.
3. **Effect fixpoint** over the SCC; effect checks.
4. Accumulate resolved types forward (unchanged accumulator shape).

`DataFieldEnv` is built from the accumulated resolved types, exactly as today.

## Delete / keep

- **Keep**: per-SCC ordering, `Identifier`, `NormalizedType` (+ its subtype /
  normalise / union / intersect), `Exhaustive`, `AgentGraph` (SCC computation),
  `ModuleInterface`, the effect SCC fixpoint concept.
- **Delete**: `ConstraintGenerator`, `Solver` (+ `Branch` / `Bounds` / `Request` /
  `Internal` / `Substitution` / `Decompose`), `Zonker`, the type-variable id
  space, the `Constrained` AST phase (go `Identified → Zonked` directly).

`Solver/Decompose.hs` decomposes *variable-bearing* constraints — its logic is
subsumed by `subtypeNormalizedType` on concrete types, so it goes too.

## Implementation phasing

1. New module `Katari.Typechecker.Check` (standalone-compiling): the `Check`
   monad + env, `elaborateType` (Resolved), `subtypeAssert`, `synth`/`check`
   for every form, pattern projection, block/statement threading. Drive it from
   a fresh `CheckSpec` against the existing 700-test corpus's expectations.
2. Effect fixpoint (in `Check` or a sibling module).
3. New `runOneSCC` using the checker; wire `typecheckModule` behind it.
4. Once the suite is green on the new path, delete CG / Solver / Zonker and the
   `Constrained` phase; drop the type-variable id space from `Identifiers`.

Phases 1–2 add a parallel path without touching the live pipeline (the new
module is just unused until phase 3), so the build stays green throughout.
