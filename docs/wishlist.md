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
- [ ] **[later] Generics (even limited).** Lets a library ship handler-providing
      combinators — `with_session(initial, body)`, `retry(body)`,
      `with_timeout(body)`. Without polymorphism over a body's return type these
      can't be factored; today the discord_bot session is a hand-written state
      cell, and the request/handle wiring is copied per capability.

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
