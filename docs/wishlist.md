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
- [ ] **[v0.1.0] Default / optional arguments.** Every parameter is required and
      labelled. A config-heavy API (an AI call with temperature / system /
      max_tokens / …) forces every call site to pass everything, and adding a
      parameter breaks all of them. Today's workaround is a handle-scope wrapper
      or a record.
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
- [ ] **[later · needs full generics] Tool-calling cleanup.** Today's discord
      `infer_with_tools` ext owns the whole tool-call loop, which forces three
      compromises: (1) the ktr passes **both** `tools` and `tool_metas` (the ext
      can't call `get_metadata`); (2) the loop / multi-round logic is hidden in TS,
      not Katari; (3) the ext **delegates the tools and so actually raises their
      effects, but its type can't say so** — `get_e2b_key` is hardcoded into the
      array element type and isn't generic. Target shape once generics land:
      a **thin ext** = one stateless inference step (`ai_step(client, contents,
      schemas) -> text | tool_call`), and the **loop + dispatch in Katari** —
      `run_tools<E>(history, tools: array[agent(args) -> string with E]) -> … with E`
      dispatches the chosen tool by value (`call_agent` taking an agent value, not
      a name string), so the effect `E` is recovered from the tool's static type
      and tracked honestly. Pass just the agents (schemas derived in Katari via
      `get_metadata`), no parallel `tool_metas`.

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
