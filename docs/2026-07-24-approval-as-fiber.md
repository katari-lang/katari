# Approval as a fiber — non-blocking human approval over a region

2026-07-24. A resident agent that must ask a human before it acts — post to a public channel, send an
email, launch a worker — faces one hard constraint: **the human takes seconds to minutes, and nothing
serial may block that long.** In tsukasa a gated tool runs inside a sequential DESK turn; if the tool
blocked on `discord.ask`, that desk would freeze until the operator clicked, and every later message on
it would queue behind one pending button. The idiom that dissolves this is *approval as a fiber*: the
gated tool does **not** wait — it FORKS a fiber that does the asking and the acting, and returns at once.

This note records the idiom, the ceiling discipline it rides on, and — the reason it is written as
knowledge rather than shipped as a package — **why it stays app code**. It is reusable as a PATTERN; it
is not extractable as a library, and that conclusion is a property of the type system, not a matter of
taste.

## The shape

The mechanism is three moving parts wired through a `region` nursery:

1. **A request as the seam.** A gated tool holds no nursery handle (it is deep inside a desk turn), and
   `region.fork` is scope-gated (`with Scope`, callable only inside the `provide` that opened the
   nursery). So the tool cannot fork. Instead it *performs a request* — tsukasa's `request_approval` —
   carrying what it wants approved and, as a payload, the action to run on approval:

   ```katari
   request request_approval(
     description: string,
     requester: string,
     on_grant: agent (value: null) -> null with grant_ceiling,
   ) -> null
   ```

2. **A handler that forks and returns.** Installed once, above the desks, where the nursery handle IS in
   scope. It forks an approval fiber and returns `null` immediately — the requesting turn ends, the desk
   stays live:

   ```katari
   request request_approval(description, requester, on_grant) {
     agent approval_fiber(input: null) -> null {
       let granted = if (admin_channel == "") {
         confirm_at_root(description = description)          // run-root fallback, unserved
       } else {
         discord.ask(channel = admin_channel, prompt = ...) == "approve"
       }
       if (granted) { on_grant(value = null) }              // the action AND its confirmation mail
       else { /* mail the requester a denial note */ }
     }
     let _ = region.fork(nursery = nursery, task = approval_fiber, argument = null, name = ...)
     next null
   }
   ```

3. **The fiber does the waiting.** `discord.ask` blocks inside the fiber ALONE. Because `region.watch`
   re-emits fibers concurrently, a handler blocked on one fiber never starves another: core keeps
   serving while an approval is pending. The gated tool, meanwhile, returned a "requested approval —
   carry on" note the model reads and moves past.

The key inversion: **the result of the human decision does not flow back to the caller.** A fiber
carries no result (`region` has no `join`). Everything the approval produces — the granted action, its
confirmation, the denial note — leaves through the fiber's own escalations, surfacing at `watch` and
served by the handlers above it. `on_grant` both *does* the action and *mails its own confirmation*, so
the caller need not be told anything; it already carried on.

## The ceiling discipline

Every fiber in a nursery shares one effect ceiling (`region.provide`'s second type argument), and
`on_grant` must fit under it. tsukasa names that row once, as `grant_ceiling`, and types `on_grant`
against it exactly:

- `on_grant`'s row is the **named concrete** `grant_ceiling` — every effect a granted action may raise
  (message any desk, register a worker, start a watch, write the digest, reach Discord, resolve the
  Google credential, plus the throws those calls carry). A specific action performs a SUBSET and fits by
  subtyping.
- It deliberately **excludes the approval plumbing** (`request_approval` / `confirm_at_root`), so a
  granted action cannot itself re-enter the gate. The nursery ceiling is `grant_ceiling |
  request_approval | confirm_at_root`; the action row is `grant_ceiling` alone.
- The row is a NAMED synonym, not a generic payload row, precisely because request payloads cannot carry
  an inferred effect row (see below). Naming it is what makes the handler, the fork, and every gated
  tool agree on one checkable contract.

## When to use it

- A serial handler (a desk, an actor) must trigger a **slow external decision** — a human click, an
  OAuth authorization, any human-latency step — without blocking its own queue.
- The decision's outcome is an ACTION, not a value the caller needs back. If the caller must have the
  answer inline, this is the wrong shape (you want a synchronous ask, and you must accept the block).
- A durable restart may drop the pending decision harmlessly. A fork mid-ask loses only the pending
  approval (the buttons go stale); the conversation is untouched. If losing the pending decision is
  unacceptable, the ask must be persisted differently.

Pair it with the deadline discipline: a gated tool is exempt from the tool-call deadline
(`unbounded_tool_names`) only if it truly waits on a human — and here it does NOT wait (it forks and
returns), so tsukasa's gated tools need **no** exemption at all. The human wait lives in the fiber,
which no deadline races.

## Why it stays app code — the extraction that does not close

The tempting refactor is to lift this into a package: a library `approve_async(description, on_grant,
on_deny)` request, served by a handler the app installs with `(nursery, ask)`. It does not typecheck,
and the reason is structural.

**A served request cannot be effect-generic.** For a library to host the request without naming the
app's ceiling, `on_grant` would have to be effect-*polymorphic* — `agent () -> null with E` for a
per-app `E`. A request declared `[effect E]` and served by a handler is rejected (K3001): a handler
fixes ONE `E`, but a universally-quantified request could be performed at a different ceiling the
handler never covers, so the peel is unsound. This is the same wall that made tsukasa name a CONCRETE
`grant_ceiling` in the first place — there is no request-payload effect to infer and pin. And that
concrete row is inherently app-specific (`core_message | herald_message | save_digest | …`), which a
library cannot write.

**The seam is the request, and the request is irreducibly the app's.** The request is not incidental —
it is the ONLY way a scope-gated `fork` becomes reachable from an unscoped tool. Remove it and there is
nothing to extract but the fiber body itself.

**What is left extracts, but only as commonization.** A plain effect-generic AGENT
`fork_approval(nursery, ask, on_grant, on_deny)` DOES compile (agents, unlike request payloads, may be
effect-polymorphic). But it hosts exactly `region.fork(fiber { if ask then on_grant else on_deny })` —
one fork and one branch. The app still writes its own `request_approval` + `grant_ceiling`, still
installs the nursery-holding handler, still supplies the `ask` closure (which chooses `discord.ask` vs
`confirm_at_root`) and the `on_deny` closure (which routes herald-vs-core). Calling a library agent for
the two-line fork-and-branch buys a package, a dependency, and an indirection in exchange for deleting
two lines — and it is the textbook "app code wrapped in a callback" that a real abstraction is not. The
app does not get thinner; it gets a seam it did not need.

Contrast the supervisor extracted the same day (`ai.supervise`), which *is* an abstraction: it owns real
state and control flow (the backoff vars, the same-error suppression, the sleep, the unbounded loop)
that every supervised resident would hand-roll identically, and the app plugs in only DATA (the session
body, the notice sink, the numbers). The mechanism has substance independent of any app. The approval
"mechanism" has none: strip the app's ask, its two branches, and its named ceiling, and nothing general
remains. So the idiom is the reusable artifact — and it lives here, not in a package.
