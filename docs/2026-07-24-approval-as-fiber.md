# Approval as a fiber — non-blocking human approval over a region

2026-07-24 (revised). A resident agent that must ask a human before it acts — post to a public channel,
send an email, launch a worker — faces one hard constraint: **the human takes seconds to minutes, and
nothing serial may block that long.** In tsukasa a gated tool runs inside a sequential DESK turn; if the
tool blocked on `discord.ask`, that desk would freeze until the operator clicked, and every later message
on it would queue behind one pending button. The idiom that dissolves this is *approval as a fiber*: the
gated tool does **not** wait — it triggers a fiber that does the asking and the acting, and returns at
once.

> **Correction (this revision).** An earlier version of this note concluded the idiom "cannot be
> extracted as a library" — that a served, effect-generic approval request "does not typecheck" and hits a
> wall in the type system. **That conclusion was wrong.** The idiom IS extractable, and it is now shipped
> as the reusable **`approval`** package (`katari-packages/approval`, `approve_async` + `serve`),
> consumed by tsukasa. The prior analysis missed the standard discipline that makes an effect-generic
> served request sound: **`lacks` constraints on the tail effect generics** — exactly what
> `time.with_deadline` does with `race_settled` and `store.serialize` does with its ceiling. This note now
> records the shipped package, the discipline that makes it work, and the one honest friction that remains
> (a use-site type-argument, not a soundness gap).

## The shape

The mechanism is three moving parts wired through a `region` nursery:

1. **A request as the seam.** A gated tool holds no nursery handle (it is deep inside a desk turn), and
   `region.fork` is scope-gated (`with Scope`, callable only inside the `provide` that opened the
   nursery). So the tool cannot fork. Instead it *performs a request* — the library's `approve_async` —
   carrying what it wants approved and, as a payload, the callback to run with the human's decision:

   ```katari
   request approve_async[effect E](
     description: string,
     on_decide: agent (approved: boolean) -> null with E,
   ) -> null
   ```

2. **A provider that forks and returns.** `approval.serve`, installed once above the desks where the
   nursery handle IS in scope. It serves `approve_async` by forking a fiber and returning `null`
   immediately — the requesting turn ends, the desk stays live:

   ```katari
   request approve_async(description, on_decide) {
     agent decide(input: null) -> null with E {
       on_decide(approved = ask(description = description))   // ask the human, hand over the boolean
     }
     let _ = region.fork(nursery = nursery, task = decide, argument = null, name = "approval")
     next null
   }
   ```

3. **The fiber does the waiting.** `ask` blocks inside the fiber ALONE. Because `region.watch` re-emits
   fibers concurrently, a handler blocked on one fiber never starves another: core keeps serving while an
   approval is pending. The gated tool, meanwhile, returned a "requested approval — carry on" note the
   model reads and moves past.

The key inversion: **the result of the human decision does not flow back to the caller.** A fiber carries
no result (`region` has no `join`). The decision arrives as DATA — the boolean handed to `on_decide` —
and everything the approval produces (the granted action, its confirmation, the denial note) leaves
through the fiber's own escalations, surfacing at `watch` and served by the handlers above it. `on_decide`
does its OWN side effects (a granted action mails its own confirmation; a denial posts its own notice), so
the caller need not be told anything; it already carried on.

## Two design choices that make it a clean library

**Return the decision as data; the app branches.** `on_decide(approved: boolean)` hands the caller the
boolean and nothing else. The app's closure does the whole branch — on `true`, the action plus a
confirmation; on `false`, a denial. This is deliberately better than a two-callback `on_grant` / `on_deny`
split baked into the library: the library owns ONLY the async-ask-over-a-region mechanism; the *app* owns
what its actions, desks and notices are. `on_decide` is a passed agent for the same reason `region.fork`'s
`task` is — the mechanism's higher-order argument, not app logic wrapped in a callback.

**The ask surface is data, so the library depends on nothing but `region`.** `serve` takes an `ask`
closure (`agent (description: string) -> boolean`) that renders the question however the app likes —
Discord buttons on an admin channel, a run-root escalation, a CLI prompt — and returns the verdict. The
package knows nothing of Discord, channels, or AI; the ask is passed in. tsukasa's `ask` closure is its
`discord.ask`-on-`ADMIN_CHANNEL`-or-`confirm_at_root` logic, handed to the library as a value.

## The ceiling discipline, and the `lacks` that makes it generic

Every fiber in a nursery shares one effect ceiling (`region.provide`'s second type argument), and the
approval fiber must fit under it. The pieces:

- **The action row `E`.** `approve_async` is effect-GENERIC in its payload row `E` — the library serves
  any app's action ceiling without naming it. `serve` fixes `E` to the nursery's fiber ceiling. A specific
  action performs a SUBSET of that ceiling and fits by subtyping. (tsukasa names its concrete rows
  `grant_ceiling` for a granted action and `bus_ceiling = grant_ceiling | confirm_at_root` for the nursery
  ceiling; a granted action's row ⊆ the served payload row, so it fits.)

- **`lacks` on BOTH tail generics is the fix the prior analysis missed.** `serve`'s continuation row is
  `{...Eouter, approve_async[E]} | Scope | io`, and BOTH tail generics carry `lacks approve_async`:

  ```katari
  agent serve[effect Scope lacks approve_async, effect E, R, effect Eouter lacks approve_async](
    nursery: region.nursery[Scope, E],
    ask: agent (description: string) -> boolean with E,
    continuation: agent (value: null) -> R with {...Eouter, approve_async[E]} | Scope | io,
  ) -> R with Eouter | Scope | io { ... }
  ```

  Factoring `approve_async[E]` out of the continuation's row and requiring the scope marker `Scope` AND
  the outer row `Eouter` to LACK `approve_async` is what tells the checker the handler discharges every
  `approve_async` and none survives the peel. This is the SAME standard discipline `time.with_deadline`
  uses to reserve `race_settled` on its task's row (`effect E lacks race_settled`) and `store.serialize`
  uses for its ceiling. A generic served request is sound exactly when its tails are constrained to lack
  it. The earlier note's claim — "a request declared `[effect E]` and served by a handler is rejected
  (K3001)" — is simply false once the `lacks` constraints are present; the probe and the shipped package
  both compile clean.

## The one honest friction: a use-site type argument

`serve` is a genuine library provider, but its USE is not the bare `serve(nursery, ask)` an
inference-only reading would expect. When the continuation's residual row OVERLAPS `E`'s payload — which
happens whenever `region.watch` re-emits the ceiling `E` (so its members appear standalone in the
continuation) AND the app's `on_decide` actions are members of that same ceiling — the checker cannot
INFER the row split `{...Eouter, approve_async[E]}`; it can only CHECK it. So the caller supplies all four
type arguments explicitly and names the residual row (a `type` synonym is the tidy way):

```katari
use approval.serve[tsukasa_scope, agents.bus_ceiling, never, approval_residual](
  nursery = nursery, ask = ask_operator)
```

where `approval_residual` is everything the continuation escalates beyond `approve_async[bus_ceiling]`,
the scope, and `io`. This is **not a soundness gap** — with the arguments supplied the split is verified —
and it is not the definition-level wall the prior analysis imagined; it is an inference limitation at the
call site. `store.serialize`'s `{...E, exclusive}` needs no such help because `exclusive` is monomorphic;
the extra effect-generic payload inside `approve_async[E]` is what the split-inference cannot resolve.
Recorded honestly so the next consumer supplies the type arguments without rediscovering the wall.

## When to use it

- A serial handler (a desk, an actor) must trigger a **slow external decision** — a human click, an OAuth
  authorization, any human-latency step — without blocking its own queue.
- The decision's outcome is an ACTION, not a value the caller needs back inline. If the caller must have
  the answer in the same turn, this is the wrong shape (you want a synchronous ask, and you must accept
  the block).
- A durable restart may drop the pending decision harmlessly. A fork mid-ask loses only the pending
  approval (the buttons go stale); the conversation is untouched. If losing the pending decision is
  unacceptable, the ask must be persisted differently.

Pair it with the deadline discipline: a gated tool is exempt from the tool-call deadline
(`unbounded_tool_names`) only if it truly waits on a human — and here it does NOT wait (it triggers the
fiber and returns), so tsukasa's gated tools need **no** exemption at all. The human wait lives in the
fiber, which no deadline races.

## What the extraction cost, and what it bought

Contrast `ai.supervise`, extracted the same week: it owns real state and control flow (backoff vars,
same-error suppression, the sleep, the loop) that every supervised resident would hand-roll identically,
and the app plugs in only DATA. `approval` is a smaller but real mechanism: it owns the fork-ask-over-a-
region and the decision-as-data seam, and the app plugs in the ask surface and the decision branch (both
data). Strip tsukasa's ask and its per-tool branches and the *mechanism* — perform-a-request, fork a
fiber, ask, hand back the boolean, all under the `lacks` discipline that makes the generic request sound —
remains, and it is the same mechanism any resident with a human-latency gate would write. That is why it
is now a package, and this note describes the shipped artifact rather than arguing against it.
