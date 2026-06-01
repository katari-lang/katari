# Wishlist / known gaps

Language, SDK, and tooling gaps surfaced mostly while dogfooding (writing the
`e2e/samples` and `examples/discord_bot`). This is the running backlog — items
move out as they're built or proven moot. Resolved findings are kept in the
git history / design docs, not here.

Priority tags: **[blocking]** wanted before v0.1.0 · **[v0.1.0]** nice for the
release · **[later]** post-v0.1.0 · **[deferred]** acknowledged, no owner yet.

## Language

- [ ] **[blocking] First-class lists / arrays.** stdlib only has `array_get` /
      `array_length`; there is no `append` / `concat` / `map` / `filter`, and
      `++` is string-only. You can't grow an ordered collection as a Katari
      value, so a conversation history (discord_bot) has to live in the sidecar
      instead of in the language. This is the single biggest gap.
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
