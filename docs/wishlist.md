# Wishlist / known gaps

Language, SDK, and tooling gaps surfaced mostly while dogfooding (writing the
`e2e/samples` and `examples/discord_bot`). This is the running backlog — items
move out as they're built or proven moot. Resolved findings are kept in the
git history / design docs, not here.

Priority tags: **[blocking]** wanted before v0.1.0 · **[v0.1.0]** nice for the
release · **[later]** post-v0.1.0 · **[deferred]** acknowledged, no owner yet.

## Language

- [x] **First-class arrays (done).** The `array.*` module now has
      `get` / `length` / `empty` / `of` / `append` / `concat` / `slice` /
      `reverse` / `contains` / `index_of`, plus `string.*` and `math.*`. You can
      grow an ordered collection as a Katari value (build a list with a `for`
      loop + `array.append`). `map` / `filter` / `reduce` are **deferred on
      purpose**: prims run ~synchronously, so a slow agent callback doesn't fit
      the prim model — and `for … next with … array.append` already expresses
      them. Revisit if a real higher-order need appears (would also want generics).
- [x] **Default / optional arguments (done).** A parameter may carry a literal
      default: `name: type = literal` (or `name = literal`, inferring the type
      as the literal's widened base type). A defaulted parameter is *optional* —
      call sites may omit it and the runtime fills the default; it is dropped
      from the schema's `required`. Same machinery covers the dynamic
      `call_agent` seam (the AI may omit optional fields). As part of this,
      **parameters were simplified to plain bindings**: the old destructuring /
      `label = pattern` rename forms are gone (destructure in the body with
      `let` / `match`), so `=` uniformly means "default". Optionality lives in
      the function type (`Parameter { type, optional }` inside the param map),
      so it is sound across module boundaries and through union (optional only
      if optional in *both*) / intersection (optional if optional in *either*).
      Defaults are **literal-only** on purpose — keeping parameters order-free,
      effect-free, and serialisable straight into the IR / JSON schema.
      Computed / param-referencing defaults would want the generics phase.
- [ ] **[v0.1.0] Single-line handler ending in an f-string fails to parse
      (K0021).** `request env_not_found(k) { break f"x: ${k}" }` reports
      `unexpected }`; the multi-line form parses. Suspect virtual-semicolon
      insertion at template-close immediately followed by `}`.
- [ ] **[v0.1.0 · big, dedicated phase] Full generics + spreading.** The single
      mechanism behind several gaps. Spec is largely settled (user-side); this is
      an implementation effort spanning parser → identifier → CG → **solver** →
      zonker, so it gets its own phase, not a side-quest. Decisions captured:
  - **Param-sig polymorphism is the core.** A function/agent is generic over its
    parameter signature `P`, return `R`, and effect set `E`:
    `agent<P, R, E>(P) -> R with E`. Katari's named params already *are* the
    "object" — no separate object type, no `agent any` / `...args` rest syntax
    needed. **Effect generics is a facet of this, not a separate ad-hoc rule** —
    avoid the one-off `call_agent` effect-extraction / effect-only constraint.
  - **Two agent-type annotation forms.** (1) labelled list
    `(label: T, label2: T2, …) -> R with E` — the callable form. (2) single
    param-type `(T) -> R with E` where `T` is usually a param-sig/object but may
    be `never` / `unknown` / etc. — *typeable but not callable* (no label map).
    e.g. a tools array is `array[agent(never) -> unknown with E]`.
  - **Spreading.** Pass a record's fields as named args — types
    `call_agent(target: agent(P) -> R with E, args: P) -> R with E` precisely.
  - **The one inherent dynamic seam:** AI tool args are `record[unknown]`, tool
    params are typed `P`. `call_agent` keeps `args: record[unknown]` statically
    and **runtime-validates the record against the target's real schema** (throws
    on mismatch). That checked cast is the only dynamic point and is correct to
    keep — generics doesn't (and shouldn't) erase it.
  - Unlocks: handler-providing combinators (`with_session` / `retry` /
    `with_timeout`), the tool-calling cleanup below, and reusable libraries over
    arbitrary effects. (`map` / `filter` / `reduce` would also want this.)
- [ ] **[v0.1.0 · needs generics inference] `use` binding + handler-as-function.**
      Decided (was an a/b fork): **direction (b)**. A semantic handler is a
      **higher-order function that takes the continuation** — `handler(args, k)`
      runs the rest of the computation `k` under its capability and returns the
      handled result. The sugar is a Gleam-style **`use` binding** that desugars
      the trailing block into that continuation:

      `{ let y = use f(x); rest }`  ⇒  `f(x, agent (y) { rest })`

      So a library ships `ai_provider` / `with_session` / `retry` / `with_timeout`
      as plain agents and the user writes
      `let provider = use ai_provider(secret_env_key = "GEMINI_API_KEY"); …`
      instead of hand-rolling `handle (var s = …) { request … }` per capability
      (the discord_bot session/capabilities are exactly this boilerplate by hand).
      **Needs generics _inference_, not just explicit type args:** a `use`-handler
      is polymorphic over the continuation's result type + effect set, and the
      ergonomic win is gone if every `use` site must spell `[R, E]`. So this wants
      **local inference of the handler's generic params at the `use`/call site**
      (synthesise the continuation's type/effects and feed them in), layered on
      the bidirectional checker. This is the ergonomic key that makes the AI
      library (below) actually writable.
- [ ] **[later · solver completeness, not soundness] Aggregate-narrow for a
      variable's composite upper bounds.** With the unified type lattice, a free
      type variable that picks up *several* var-containing composite upper bounds
      must be narrowed against the **combined** bound, not one constraint at a
      time. Two cases the current per-constraint narrowing gets wrong (both
      *reject a typeable program* — never accept an ill-typed one, so this is
      incompleteness, not unsoundness):
  - `t <: {x: a}` **and** `t <: {y: b}` → `t` should become `{x: a, y: b}`
    (merge all required fields), but narrowing from the first constraint pins
    `t := {x: a'}` and the second then fails.
  - `t <: {x: a}` **and** `t <: foo` (a `data`) → `t = foo` is a valid solution
    (`foo <: {x: a}` via `data <: object`), but narrowing the object first pins
    `t := {x: a'}` and `{x: a'} <: foo` necessarily fails.
      Fix: when narrowing a variable, gather **all** its stuck composite upper
      constraints first; if any is a `data`, narrow `t` to that `data` and emit
      the structural requirements as `data <: object` sub-constraints; otherwise
      merge the object/record uppers (union of required field labels) and narrow
      to the merged shape (symmetric join on the lower side). These var-var cases
      are rare pre-generics (they need a *free* variable at a field access;
      monomorphic code's access subject is always concrete, so `Decompose`
      handles it), so this is deferred behind the generics phase.
- [ ] **[big · under consideration] Replace the constraint solver with a
      bidirectional type checker.** Because Katari requires explicit parameter
      types everywhere, almost nothing actually needs global type-variable
      inference: parameter types are given → derived expression types →
      let/pattern-bound variable types → the match subject are all determined by
      a forward synthesise / check walk. The only cases needing more are (a)
      generic instantiation — handled by *requiring explicit type arguments* and
      then variance-aware **bound substitution** (replace a generic by its upper
      bound in covariant positions, lower bound in contravariant ones) when
      looking through it for match / exhaustiveness / field access — and (b)
      recursion: an inferred **return type** would need an annotation on a
      recursive cycle (the type lattice has infinite ascending chains, so a
      fixpoint may diverge), whereas **effect** inference can keep using a
      per-SCC fixpoint (the request-name lattice is finite, so it terminates).
      This dissolves the Solver / Zonker / all type & request variables /
      bound-pair / Branch, the aggregate-narrow item above, **and** the
      match-subject projection-direction problem below — while keeping the
      `NormalizedType` lattice (subtype / union / intersect), Identifier, and the
      per-SCC ordering. Substantial rewrite of `ConstraintGenerator`; wants a
      design doc first.
- [ ] **[blocked on the above] Match-subject component projection is
      direction-locked.** A tuple/record pattern's component types are flowed
      from the subject by a bridging subtype constraint while the subject is
      still a type variable. `subject <: tuple[fresh]` makes tuple-*prefix*
      matching work (`(a, b)` over a longer tuple, per minimum-elements) but
      makes a tuple pattern over an `array` subject a contradiction; the original
      `tuple[fresh] <: subject` does the reverse. No single direction serves both
      because the subject's shape isn't known yet — exactly what a bidirectional
      checker (subject synthesised *before* the arms) removes. Current code keeps
      the array-friendly direction; tuple-prefix exhaustiveness is therefore not
      recognised (a wildcard is required).

## SDK (`@katari-lang/port`)

- [ ] **[deferred] Tagged-value constructor helper** (`ctx.makeData(ctorQname,
      fields)` or similar). Returning a `data` value from an ext means writing
      `{ $constructor: "module.ctor", ... }` by hand — a magic string plus the
      qualified name. A helper should hide it. (We have `makeString` /
      `makeFile` / `makeAgent`, but no `makeData` / `makeTagged`.)
- [ ] **[v0.1.0] Provider-ready tool schemas.** `get_metadata(...).input` is the
      compiler's draft-07 JSON Schema, which is correct for runtime validation
      but not directly consumable by LLM providers — Gemini's
      `functionDeclarations.parameters` is a closed OpenAPI-subset proto and 400s
      on `additionalProperties` (and would on `$schema` / `$defs` / …). The
      discord_bot tool loop strips those by hand before the Gemini call. As tool
      calling becomes first-class, decide where per-provider schema adaptation
      lives (a port helper? a stdlib agent? emitted alongside the schema bundle?)
      rather than every ext re-implementing it.
- [x] **Tool-calling cleanup (mostly done, 2026-06-06).** The target shape landed:
      the ext is now a **thin stateless step** (`infer_step(client, history,
      tool_metas) -> step_final | step_call`) and the **loop + parallel dispatch
      live in Katari** — `infer_with_tools[effect E](history, tools: array[agent
      (...never) -> unknown with E], …)` derives schemas via `get_metadata`,
      dispatches each chosen tool **by value** with `call_agent[unknown, E]`, and
      tracks the tools' effect `E` honestly through its signature. The model's
      functionCall/functionResponse round-trip is replayed (turn / call_turn /
      result_turn union + Gemini thoughtSignature). Remaining nit: the ext still
      receives `tool_metas` alongside the agents because `get_metadata` runs in
      Katari and the ext can't; once the schema adaptation moves (see
      "Provider-ready tool schemas") the ext could take only `contents`.
- [ ] **[v0.1.0+ · needs generics inference + `use`/handlers] AI provider / model
      library.** Today's AI loop is Gemini-hardcoded in one sidecar. Target: a
      reusable AI library whose `infer` / `infer_with_tools` run against any
      **provider + model** the caller picks. Layering — modelled with first-class
      **agent values** (no methods-on-`data`; a "model" is a record of closures =
      a vtable), langchain-ish:
  - **Provider** — auth/config capability (api key, base url). Installed via a
    handler: `let p = use ai_provider(secret_env_key = "GEMINI_API_KEY")`. Mints
    models. Per-vendor (gemini / openai / anthropic) provider agents.
  - **Model** — a **vtable**: a record of agent closures implementing the
    provider-specific protocol over an abstract session `S` — `new_session`,
    `append_*`, `infer_step`. Built from a provider
    (`gemini(p).model("gemini-3-flash")`). The session type `S` is **tied to the
    model** (each vendor's history format differs), so a model is generic over `S`.
  - **Session** — an opaque-to-the-caller value the model's closures interpret;
    the handler appends to it. Format is model-specific (hence `S`). (langchain's
    "memory" is the analogue.)
  - **infer / infer_with_tools** — provider/model-agnostic, generic over `S` and
    the tools' effect `E`; loop + dispatch in Katari (already true for the
    Gemini-specific version above).
      Blocked on: generics over `S` / `E` **with inference**, and `use`/handler
      sugar for the provider capability (both above). Until then the discord
      example stays Gemini-specific but is **split into ai / discord / e2b
      modules** (one sidecar, package-scoped FFI) so the boundaries are already
      library-ready — each module becomes its own package (+ its own sidecar) when
      actually split out.

## Runtime / model

- [ ] **[later] A first-class long-running service / daemon.** A bot is a service,
      but it's modelled as a `main() -> never` run that simply stays `running`
      forever; the only way to stop it is to cancel the run, and a handle-scope
      exit has no cleanup hook (the ext disconnects on the cancel signal). Worth
      a real "service" concept.
- [ ] **[deferred] Error attribution for errors that escape a tracked handler.**
      An error thrown inside a handler is converted to a `throw` request and
      propagates up the delegation tree. But an error in a callback fired *off*
      the handler's async chain (a `void ctx.delegate(...)` in a `watch_*`
      listener, before any child delegation exists) has no delegation to
      attribute a `throw` to — fundamentally hard. Mitigated: the sidecar now
      logs `unhandledRejection` / `uncaughtException` to stderr so it isn't a
      silent no-op.

## Tooling

- [ ] **[deferred] `katari init` npm-resource UX.** The scaffold deliberately does
      not emit a `tsconfig.json` (or otherwise manage npm resources), so an ext
      author has no type-check / completion loop out of the box. The npm-side UX
      is intentionally out of scope for now; revisit later.
- [ ] **[deferred] vitest 4 migration.** Pinned at vitest 3; the Dependabot
      "critical" (UI-server arbitrary file read) only affects `vitest --ui`,
      which we never run (`vitest run` only), so it's not exploitable here. The
      4.x fix is a config migration: `workspace` / `defineWorkspace` → `projects`,
      and `environmentMatchGlobs` / `poolMatchGlobs` were removed (per-project
      `environment` instead). Do it when touching the test setup anyway.
- [ ] **[later] LSP hover surfaces the `@"…"` annotation.** Hover already shows a
      node's type (`Katari.Query.lookupAtPosition`); also include the declaration's
      `@"…"` annotation (the description carried into the schema bundle) so reading
      an agent / request / data in the editor shows what it's *for*, not just its
      type. The annotation is already on the AST (`annotation :: Maybe Text`).
