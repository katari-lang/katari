# Generic `data` + `record` simplification + type-application syntax + variance

Status: **design** (2026-06-06). Implementation follows once the open questions
below are settled. Motivated by the AI-library abstraction (needs `model[S]`,
`session[S]`) and a confirmed soundness hole in `object <: record[V]`.

## 0. Summary of decisions

1. **`record` drops its parameter.** `record` (keyword, no `[V]`) is the
   homogeneous-map top — formerly `record[unknown]`. `record.get(r, key) ->
   unknown`. This is the *only* dynamic-map type; typed dictionaries, if ever
   needed, are expressed with generic `data`.
2. **The `object <: record[V]` soundness hole disappears for free.** It was
   unsound because objects are width-open (a value of type `{l:T}` may carry
   hidden fields of arbitrary type, so it is *not* a `record[T]` for `T <
   unknown`). With `record` unparameterised (= the map top), `object <: record`
   is always sound (record is the top) and there is no `record[V<unknown]` left
   to lie about. No bespoke variance fix needed for `record`.
3. **Type-level application syntax `Name[Arg, …]` is added.** It does not exist
   today (generic instantiation is expression-level only — `foo[int]` is a
   `TypeApplicationExpression`; there is no `SyntacticType` node for `foo[int]`
   *as a type*). This is the prerequisite primitive.
4. **`array` becomes a built-in covariant generic** applied through the new
   syntax (`array[T]`), unifying it with user generics. Internally it stays the
   `seqLayer`'s `Array` (already covariant); this is mostly a surface/representation
   unification so it is not special-cased at the syntax layer.
5. **`data` becomes generic, with variance.** `data foo[T, effect E]` (and
   explicit-variance `data foo[in T, out E]`). Variance is recorded per
   parameter and consumed by `NormalizedType` union / intersect / subtype.

## 1. Current architecture (grounding)

- **`SyntacticType`** (`AST.hs:809`) has *dedicated* nodes: `TypeArray`,
  `TypeRecord`, `TypeObject`, `TypeFunction`, `TypeName`, `TypeUnion`, … There is
  **no generic type-application node** and `TypeRecord` carries an element type.
- **`SemanticType`** (`SemanticType.hs:42`): `SemanticTypeData QualifiedName`
  (**no type args**), `SemanticTypeArray T`, `SemanticTypeRecord T`,
  `SemanticTypeObject (Map Text Parameter)`, `SemanticTypeGeneric GenericsId`
  (an in-scope generic param; already used by generic *agents*).
- **`NormalizedType`** (`NormalizedType.hs`) is a product of layers. Relevant:
  - `seqLayer :: BareSeq = NoSeq | Tuple [NT] | Array NT` — `array` lives here,
    already covariant (`Array a ∪ Array b → Array (a∪b)`).
  - `mapLayer :: MapSlot = { dataNames :: Set QualifiedName, bare :: BareObj }`.
    `BareObj = NoObj | ClosedObj (Map Text NormalizedParameter) | RecordObj NT`.
    **Data is stored as a bare name set**; fields are looked up on demand from an
    env during subtyping (`subtypeMap`, `NormalizedType.hs:897`) — this keeps
    union / intersect **env-free** and recursive data finite.
  - `genericsLayer :: Set GenericsId` — in-scope generic params; subtyping
    expands each to its declared upper bound.
- Generic **agents** already work: type+effect params, explicit type arguments
  at use sites, instantiation by substitution. The machinery (`GenericsId`,
  param binding, substitution) is reusable for `data`.

## 2. `record` de-parameterisation

- `SyntacticType`: `TypeRecord` loses its element type → `record` is a keyword /
  `TypeName "record"` (a built-in nullary type). Parser: `record` no longer
  takes `[V]`.
- `SemanticType`: `SemanticTypeRecord T` → `SemanticTypeRecord` (nullary).
- `NormalizedType`: `BareObj`'s `RecordObj NT` → `RecordObj` (nullary), the
  structural map top. Subtype: `ClosedObj _ <: RecordObj` (always), `RecordObj
  </: ClosedObj` (`NormalizedType.hs:905-916` simplifies — drop the
  per-field-`<: V` check). Union: `_ ∪ RecordObj = RecordObj`. Intersect:
  `RecordObj ∩ x = x`.
- `record.get : (record, string) -> unknown`; `record.set : (record, string,
  unknown) -> record`; `record.empty : () -> record`. Stdlib + prim-rule updates.
  A caller that wants a typed read narrows the `unknown` with a match, e.g.
  `match (record.get(r, k)) { integer(x) => …; x => throw(…) }`. (This relies on
  match type-narrowing of `unknown` to a primitive/tagged kind — runtime-kind
  discriminable, unlike non-tagged values; if that isn't already supported it is
  a small, **separate** match feature, noted as a dependency not part of this doc.)
- Migration: `record[T]` annotations in samples (e.g. 18) → `record`. Tool args
  `record[unknown]` → `record`.

## 3. Type-application syntax

Add one `SyntacticType` node:

```
TypeApplication :: TypeApplicationNode phase -> SyntacticType phase
  -- head :: NameRef phase TypeRef   (a data / type-synonym / built-in name)
  -- arguments :: [SyntacticType phase]   (types and/or effects, like agent [..])
```

- Parser: in type position, `Name [ T1 , … ]` parses to `TypeApplication`.
  Reuses the same bracket-list the expression-level `foo[..]` uses. `effect E`
  arguments allowed (mirrors generic agents).
- Identifier: resolve `head` against the type namespace; arity-check against the
  declaration's parameter list (K0218-style).
- `TypeApplication { head :: SyntacticType, arguments :: [SyntacticType] }` is the
  **one** application node, and `head` is itself a type. **`TypeArray` becomes a
  nullary node** — the bare `array` *constructor* (a 1-arg, covariant, built-in
  type that must be applied). So `array[int]` = `TypeApplication (TypeArray)
  [TypeInt]`, exactly parallel to a generic data `foo[int]` = `TypeApplication
  (TypeName foo) [TypeInt]`. `record` is a bare nullary `TypeRecord` (not applied).
  - Elaboration: `TypeApplication TypeArray [t]` → `SemanticTypeArray t`;
    `TypeApplication (TypeName foo) [args]` → `SemanticTypeData foo args`. Arity /
    head-kind checks live at the identifier/elaboration step (bare `array` with no
    application, or `array[a, b]`, is an arity error).
- **`request` generics are out of scope** for this work (deferred). Only `data`
  (and `type` synonyms) become generic now.

## 4. Generic `data` + variance

### 4.1 Declaration

```
data foo[T, effect E](field1: T, field2: agent(x: T) -> null with E)        -- variance inferred
data box[in T](consume: agent(x: T) -> null)                                 -- explicit: contravariant
data cell[out T](read: agent() -> T)                                         -- explicit: covariant
```

- Type params reuse the generic-agent param machinery (`GenericsId`, optional
  `extends` bound). Effect params allowed (`effect E`).
- Optional **explicit variance** `in` / `out` per param. When omitted, variance
  is **inferred** from field positions (§4.3). Explicit variance is **checked**
  (decided): the inferred (true-safe) variance must be usable where the declared
  one is expected — `inferred <: declared` in the variance lattice

  ```
        bivariant            (bottom — usable as anything)
        /        \
  covariant   contravariant  (incomparable)
        \        /
        invariant            (top — most restrictive)
  ```

  i.e. `bivariant <: covariant <: invariant`, `bivariant <: contravariant <:
  invariant`. So a covariant-safe param may be **declared** `invariant` (lose
  subtyping, still sound) but an invariant param may **not** be declared
  covariant; a bivariant param may be declared anything. Using a *more
  permissive* variance than the inferred-safe one is the unsound case and is
  rejected (a dedicated diagnostic). The annotation is then what union / intersect
  / subtype actually use (§4.4).

### 4.2 Representation

- `SemanticTypeData QualifiedName` → `SemanticTypeData QualifiedName [GenericArg]`
  where a `GenericArg` is a type or an effect (same shape as a generic-agent type
  argument list). Non-generic data = empty arg list.
- `MapSlot.dataNames :: Set QualifiedName` → `Map QualifiedName [GenericArg]`
  (name ↦ its applied args). Two instantiations of the same data merge per
  variance (§4.4). Distinct data names coexist (the discriminated-union part).
- **Variance must be available to union / intersect.** Decided: **option (a)** —
  extend the per-data env that subtyping already consults (`dataObjectView` /
  the `env :: Map QualifiedName <fields>` in `subtypeMap`,
  `NormalizedType.hs:897-903`) to *also* carry each param's variance:
  `Map QualifiedName DataInfo` where `DataInfo = { fields, variances }`. `unionNT`
  / `intersectNT` (which currently take no env) gain this env param. Variance is a
  fixed property of the decl, so the env is the right home (no per-instance
  duplication).
- The on-demand field lookup (`dataObjectView`) substitutes the data's type
  args into the looked-up field types before the `data <: object` comparison.

### 4.3 Variance inference (positions)

For each generic param `g` of a `data` decl, scan its field types and collect
the *sign* of every occurrence of `g`:

- **negative position**: an `agent(...)` **parameter** type.
- **positive position**: everywhere else (field type directly, agent return,
  agent effect, array element, tuple element, object field, nested data arg
  combined with that arg's own variance — **multiply** the signs through nesting).
- A nested `data` arg position multiplies by that arg's declared variance
  (covariant = +, contravariant = −, invariant = both, bivariant = neither).
- **Effect params get the *same* full variance treatment** (decided — not
  covariant-only). An effect can land in a negative position: in
  `agent(cb: agent(x: T) -> R with E) -> …`, the inner `with E` rides the inner
  agent, which is a **parameter** of the outer agent, so `E` multiplies to
  **negative** → contravariant. So `in` / `out` / invariant / bivariant all
  arise for effect generics exactly as for type generics; the position scan
  treats an agent type's `with E` as sharing that agent's position sign.

Then per `g`:

| occurrences        | variance     |
| ------------------ | ------------ |
| positive only      | covariant    |
| negative only      | contravariant|
| both               | invariant    |
| neither            | bivariant    |

**Recursive data** (a field mentions the data itself) requires a **fixpoint**
over the SCC: start every param at *bivariant* (the lattice bottom for "no
constraint"), iterate the position scan using the current estimates for
recursive references, until stable. Explicit `in`/`out` short-circuits the
fixpoint for that param (and is then checked / trusted, §7).

### 4.4 `NormalizedType` rules (per variance)

For two applications of the *same* data name, combine arg-wise by each param's
variance. (Different names never combine.)

**Union** `foo[a] ∪ foo[b]`:

| variance      | result                                                        |
| ------------- | ------------------------------------------------------------- |
| covariant     | `foo[a ∪ b]`                                                  |
| contravariant | `foo[a ∩ b]`                                                  |
| invariant     | `unknown` — *unless* `a <: b ∧ b <: a`, then `foo[a]`         |
| bivariant     | `foo[a ∪ b]` (any representative; `∪` chosen)                 |

**Intersect** `foo[a] ∩ foo[b]`:

| variance      | result                                                        |
| ------------- | ------------------------------------------------------------- |
| covariant     | `foo[a ∩ b]`                                                  |
| contravariant | `foo[a ∪ b]`                                                  |
| invariant     | `never` — *unless* `a == b`, then `foo[a]`                    |
| bivariant     | `foo[a ∩ b]` (same as covariant)                             |

**Subtype** `foo[a] <: foo[b]`:

| variance      | check                          |
| ------------- | ------------------------------ |
| covariant     | `a <: b`                       |
| contravariant | `b <: a`                       |
| invariant     | `a <: b ∧ b <: a`              |
| bivariant     | *no check* (always holds)      |

Soundness note (covariant union over a multi-position param): `pair[int] ∪
pair[string]` widening to `pair[int ∪ string]` is sound **because Katari has no
narrowing** — you cannot match a generic-data value and re-extract a component
at a type narrower than the field's declared (substituted) type, so a value like
`pair(first = "fizz", second = 42)` flowing through `pair[int ∪ string]` can
never be coerced back to a wrong-typed component. This is what makes the
covariant rule (and bivariant = `∪`) sound even when the param appears in
several fields.

The `invariant → unknown` (union) / `never` (intersect) collapse mirrors how the
seq/map layers already top-/bottom-out when shapes are incompatible.

## 5. `match`

- **Exhaustiveness (Maranget)** is unaffected: constructors are name-based and
  generic-arg-agnostic (`foo[int]` and `foo[string]` share constructor `foo`),
  so the constructor set / arity logic is unchanged.
- **Field-type binding in arms** must **substitute** the scrutinee's data type
  args into the constructor's declared field types before binding pattern vars
  (a `case foo(field = y)` over `foo[int]` binds `y : <field-type>[int := …]`).
  This is a localised change in the checker's constructor-pattern walk
  (and the `dataObjectView` substitution of §4.2 is the same operation).
- **To verify during implementation:** that the bidirectional checker synthesises
  the scrutinee (hence its concrete data args) before walking arms — it does
  (subject synthesised first), so substitution has the args it needs.

## 6. Implementation phases

1. **Type-application syntax** (parser + `SyntacticType` node + identifier
   resolution + arity check). Retire/keep `TypeArray` (open).
2. **`record` de-parameterisation** (syntactic + semantic + normalized + stdlib
   + sample migration). Closes the soundness hole; independently shippable.
3. **`SemanticType` / `NormalizedType` data args** (`SemanticTypeData` +
   `MapSlot` carry args; variance registry threaded into union/intersect/subtype).
4. **Variance inference + fixpoint** (+ optional explicit `in`/`out`).
5. **Generic `data` end-to-end** (declaration, construction `foo(...)` with
   inferred/explicit args, field access + match substitution, schema +
   runtime carry of applied args — mirrors generic agents, already done).
6. **AI-library abstraction** rebuilt on top (separate effort).

## 7. Open questions

Resolved (2026-06-06):

- **Explicit variance is checked**, via `inferred <: declared` in the variance
  lattice of §4.1 (`bivariant <: {covariant, contravariant} <: invariant`).
- **Union / intersect env: option (a)** — extend the existing per-data env with
  variance (`Map QualifiedName DataInfo`); thread it into `unionNT` /
  `intersectNT` / subtype (§4.2).
- **`array[T]` parses as a type-application** (§3). Whether it elaborates to
  `SemanticTypeArray` at the semantic phase or is interpreted as the `seqLayer`
  `Array` at normalisation is an **implementation choice (either is fine)** —
  the surface/parse behaviour is fixed.
- **`record.get -> unknown`** (decided); typed reads narrow via `match` (§2).
- **Effect generics get full variance** (not covariant-only): `in` / contravariant
  / invariant all arise via effects in nested agent-parameter positions (§4.3).

- **`TypeArray` is kept** (decided) — `array[T]` parses into it; array stays a
  distinct built-in node (not a `data`). §3.
- **`request` generics deferred** — only `data` / `type` become generic now.

Remaining:

- **Match-narrowing of `unknown`** to a primitive/tagged kind (needed to consume
  `record.get`) — confirm current support; if absent, scope it as a small
  separate match change (§2).

## 8. Existentials / heterogeneous sessions (out of scope)

A `session[S]` (or `model[S]`) that is both appended-to and read-from has `S` in
both a **negative** position (append's param) and a **positive** one (infer's
result / `new_session`) → **invariant**. So `session[A]` and `session[B]` are
incomparable; they cannot be unioned, and an array over *mixed* state types
(`array[∃S. session[S]]`) would need an **existential**, which Katari lacks.

This is **not a blocker for the AI library:**

- The core loop is **single-session, single-model**: a concrete `session[S]`
  threaded through, with `S` statically known. Invariance never bites — nothing
  unifies different `S`.
- The only case that wants heterogeneity — a pool of conversations over
  *different* providers/models in one array — is encodable with the
  **closures-are-existentials** trick: hide `S` *inside* a closure's captured
  scope and expose a uniform interface, e.g.
  `data conversation(send: agent(text: string) -> { reply: string, next: conversation })`.
  `S` is existentially hidden in `send`'s captured environment; `array[conversation]`
  is homogeneous at the interface even though each element's internal state type
  differs. (Same vtable-of-closures shape the model abstraction already uses.)
  The cost is the functional encoding (`send` returns the next `conversation`) or
  a handler-held mutable session.

So: **don't add existential types now.** Use the closure encoding if a
heterogeneous-session use case actually appears; revisit only if that proves too
painful.
