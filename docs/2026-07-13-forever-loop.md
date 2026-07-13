# `forever { … }` — the unbounded loop

2026-07-13. Katari had no way to loop without an end. `for` iterates a materialized array; recursion is a
real cross-instance delegation. So the first daemons (the failure-recovery providers, same release — now
`prelude.replay`) looped by self-recursion — and since the engine has no tail-call collapse (a caller
instance stays suspended awaiting its child's `delegateAck`, and its scopes stay live for the child's
closures and its handlers), **every retry parked one permanent frame chain in durable state**. A
`replay.forever` daemon grew by one delegation chain per failure, forever. The honest fix is not a smarter
engine but a missing language form: a loop that repeats *in place*.

## The form

```katari
forever {
  <the block, re-run each time it completes>
}
```

An expression, the unbounded sibling of the sequential `for`:

- **One iterating thread inside one instance.** Each iteration spawns the body as a fresh child thread in a
  fresh scope; when it completes, its value is **discarded** and the next iteration starts. Nothing is
  collected, no cursor exists — the loop's whole state is the one in-flight call — and the completed
  iteration's thread and scope are reclaimed by the ordinary intra-instance GC at the turn boundary. **The
  durable footprint is flat no matter how many iterations have run** (pinned by an engine test that runs
  thirty iterations and asserts the persisted thread/scope counts did not move).
- **It types as `never`.** The expression never yields a value, so it conforms anywhere, exactly like a
  `-> never` call — including being an agent body's trailing expression for any declared return.
- **The body is an ordinary block.** Its tail value is discarded per iteration (where `for` would map it
  into the output array); its effects are the loop's effects, performed every iteration, and flow to the
  enclosing row unchanged.
- **No jump target, no barrier.** `forever` owns no `next` / `break`; jumps and requests inside the body
  mean exactly what they mean outside it, as in a `match` arm.

## No built-in exit — escaping is composed

`forever` cannot stop itself; that is the type (`never`), not a limitation. The exit is the same
catch-and-break mechanism everything else uses: perform a request, and let a surrounding handler `break`
out of the handled block with the value.

```katari
request done(value: integer) -> never

agent poll_until_ready() -> integer {
  use handler {
    request done(value: integer) -> never { break value }
  }
  forever {
    match (check()) {
      case ready(value => value) -> { done(value = value) }
      case pending(_) -> { time.sleep(milliseconds = 1000.0) }
    }
  }
}
```

This is deliberately identical to how a throw is caught: control leaves the loop only by an ask unwinding
past it. Evolving per-iteration state composes the same way — a `use handler (var …)` outside the loop
holds it (the ambient-counter pattern), so the body stays stateless. `prelude.replay`'s providers
(`immediate` / `forever` / `exponential`) are exactly these compositions and nothing more.

## `forever` is a positional word, not a reserved one

`reservedWords` (Lexer.hs) deliberately does not contain `forever`. The stdlib already exports an agent
NAMED `forever` (`replay.forever`, its pinned public surface), and the lexer's own precedent covers this:
type-only words (`integer`, `never`, `array`, …) are recognised positionally and stay usable as
identifiers. `forever` follows that rule at the expression head — it is the loop **only when a `{` directly
follows**; `forever(...)` stays a call, `replay.forever` stays a name, `agent forever(...)` stays
declarable. The vscode grammar mirrors the same lookahead.

## Runtime shape (for the reader who wants the mechanism)

- IR: a `forever` block (`{ kind: "forever", body }`), the body a parameterless sequence reading the
  enclosing scope lexically (`Katari.Lowering.lowerForever`).
- Engine: a `ForeverThread` whose state is one pending call id. `create` spawns an iteration; a `callAck`
  discards the value and spawns the next; every ask proxies up unchanged; a cancel drains the in-flight
  iteration through the ordinary cascade (`thread-ops.ts`).
- Persistence: threads ride as opaque payloads, so the only schema change is the `threads_kind_check`
  member (migration `0008_forever_thread_kind`). A restart reloads the loop mid-iteration like any other
  thread tree.
- A body with no suspension point spins inside the turn — an infinite pure loop is expressible in any
  language, and a useful daemon body always suspends (a sleep, an external call, a request).

## What was deliberately not built

- **No `break` / `continue` keywords for `forever`.** A built-in exit would be a second escape mechanism
  next to catch-and-break; the composed request is the one rule. (A jump to an *enclosing* `for` / handler
  still works from inside the body — the loop adds no barrier — but that is those constructs' semantics,
  not `forever`'s.)
- **No `var` state on the loop head.** Evolving state lives in a surrounding handler (`use handler (var …)`),
  the same ambient-state pattern applications already use; a second state mechanism on the loop would
  duplicate it.
- **No `parallel forever`.** An unbounded set of concurrent iterations is unbounded resource growth by
  construction — the exact thing this form exists to rule out.
- **No iteration budget / spin guard.** A pure body loops forever, as in every language; guarding it would
  be a heuristic knob (おせっかい) with no principled threshold.
