# Approval as a fiber — non-blocking human approval over a region

2026-07-24 (revised twice). A resident agent that must ask a human before it acts — post to a public
channel, send an email, launch a worker — faces one hard constraint: **the human takes seconds to
minutes, and nothing serial may block that long.** In tsukasa a gated tool runs inside a sequential DESK
turn; if the tool blocked on `discord.ask`, that desk would freeze until the operator clicked, and every
later message on it would queue behind one pending button. The idiom that dissolves this is *approval as a
fiber*: the gated tool does **not** wait — it triggers a fiber that does the asking and the acting, and
returns at once.

> **The correction trail (three revisions).** This note has been wrong twice, in instructive ways:
>
> 1. An early version concluded the idiom "cannot be extracted as a library" — that a served,
>    effect-generic approval request "does not typecheck." **Wrong.** The fix is the standard discipline
>    that makes an effect-generic served request sound: a **`lacks` constraint on the tail effect
>    generic**, exactly what `time.with_deadline` does with `race_settled` and `store.serialize` with its
>    ceiling.
> 2. A second version made `serve` OWN its region and HAND its nursery back, collapsing to a **single**
>    effect tail: the use took no explicit type arguments, but a single-tail scoped provider re-emits its
>    whole ceiling as its residual, which **leaks** for a caller that handles the ceiling internally. That
>    version claimed the trade was fundamental — "a bare call site OR a precise residual, you cannot have
>    both." **Also wrong.**
> 3. This version splits the tail into **two** generics — the fiber ceiling `E` and the residual `Eouter`,
>    each with `lacks approve_async`. It gives BOTH a bare call site (no explicit type arguments) AND a
>    precise residual. The apparent conflict in revision 2 came from an incomplete continuation: the
>    residual is precise **exactly when the continuation handles the fiber-side of `E`** below its watch —
>    which tsukasa's desks already do. This note records the shipped two-tail package.

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

2. **A provider that OWNS its region, forks, and hands the nursery back.** `approval.serve` opens its
   OWN nursery under its own module-local `approval_scope` marker, serves `approve_async` by forking a
   fiber into it and returning `null` immediately — the requesting turn ends, the desk stays live — and
   HANDS the nursery to its continuation so the CALLER decides where to `region.watch` it (the
   `runST`-shaped seam `region.provide` / `mcp.provide` use). The caller mixes it into its own watch,
   e.g. `parallel [ region.watch(app_nursery), region.watch(approval_nursery) ]`:

   ```katari
   agent serve[effect E lacks approve_async, R, effect Eouter lacks approve_async](
     ask: agent (description: string) -> boolean with E,
     continuation: agent (value: region.nursery[approval_scope, E]) -> R
       with {...Eouter, approve_async[E], approval_scope, region.crashed} | io,
   ) -> R with Eouter | region.crashed | io {
     let nursery: region.nursery[approval_scope, E] = use region.provide[approval_scope, E]
     use handler {
       request approve_async(description, on_decide) {
         agent decide(input: null) -> null with E {
           on_decide(approved = ask(description = description))  // ask the human, hand over the boolean
         }
         let _ = region.fork(nursery = nursery, task = decide, argument = null, name = "approval")
         next null
       }
     }
     continuation(value = nursery)  // hand the nursery out; the caller watches it
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

## Two tails, both inferred: a bare call site AND a precise residual

`serve` carries two effect-generic tails, each with `lacks approve_async`:

- **`E` — the fiber ceiling.** What every `on_decide`, and every fiber of the handed nursery, may raise.
  `approve_async` is generic over it, so one library request serves any app's action ceiling without
  naming it. A specific action performs a SUBSET and fits by subtyping. `E` is INFERRED from the `ask`
  closure's row (and pinned, in tsukasa, by the nursery binder annotation to `bus_ceiling`).

- **`Eouter` — `serve`'s own residual.** What escalates PAST the continuation after it handles everything
  it means to. `serve` returns `R with Eouter | region.crashed | io`. `Eouter` is INFERRED from what the
  continuation actually lets escape.

The two are **distinct on purpose**, and that is the whole fix. The continuation is expected to HANDLE the
fiber-side of `E` internally — its desks serve `core_message`, `herald_message`, … below its own
`region.watch` — while the genuinely-outer effects (store ops, a fatal proxy) well up. With one tail
serving both roles (revision 2), `serve` had to re-emit the WHOLE ceiling `E` as its residual, so every
request the continuation handled internally leaked back out as a phantom. Splitting the tail makes the
residual PRECISE: `serve` re-emits only `Eouter` — exactly the part of the ceiling the continuation did
NOT handle.

Crucially, **both tails still infer at the bare call site**, because each is pinned by a *different*
argument — `E` by `ask`, `Eouter` by the continuation's body — so there is no single ambiguous row to
split. The `lacks approve_async` on each is the soundness key: factoring `approve_async[E]` out of the
continuation's row (`{...Eouter, approve_async[E], approval_scope, region.crashed} | io`) is provably
complete because `Eouter` lacks it and the concrete `approval_scope` / `region.crashed` / `io` trivially
lack it, and the payload tail `E` lacking it keeps the generic honest (no `approve_async` hides in the
ceiling it carries). Same discipline `time.with_deadline` uses for `race_settled`. The bare
`let n = use approval.serve(ask = …)` supplies **no explicit type arguments and no caller Scope**.

The one obligation the caller carries: **the continuation must handle the fiber-side of `E`** (which any
resident does — that is what its desks ARE), or that unhandled part of `E` correctly appears in `Eouter`
and escalates. That is not a leak — it is the residual telling the truth about what the caller left open.

## The tsukasa payoff, measured

The split is visible in the `katari check` escalation report. `run_session` — the whole session, wrapped
by `serve` — escalates precisely:

```
tsukasa.run_session
  escalates: agents.confirm_at_root, discord.connection,
             prelude.throw[auth_error | missing_secret],
             region.crashed, store.{get,set,delete,list}, io
```

The desk traffic the continuation handles — `core_message`, `herald_message`, `worker_message`,
`admit_worker`, `launch_watch`, `save_digest` — is **absent**. Under the single-tail version every one of
those appeared as a run-root phantom. Three concrete consequences of the split:

- **`bus_ceiling` is now a pure fiber ceiling.** It dropped its `store` ops
  (`bus_ceiling = grant_ceiling | confirm_at_root`, no `store.get/set/delete/list`). No fiber stores — a
  source raises `core_message`, an `on_decide` posts or launches, a watch reports. The desks' store
  traffic is performed in the CONTINUATION, not a fiber, and surfaces in `Eouter`, inferred, kept out of
  the ceiling. The single tail had forced the store ops into `bus_ceiling` because payload = residual.

- **The fatal boundary is narrow.** `run_session`'s residual `throw` is `throw[auth_error |
  missing_secret]` — its own classifier's fatal complement — not `bus_ceiling`'s whole throw family.
  `main`'s fatal sink still catches `unknown`, but now by DELIBERATE choice (the concrete true root's
  last-resort net for the unforeseen), not because a leak forced the widening.

- **The install site is still free.** `serve` sits outermost so a gated desk tool's `approve_async`
  reaches its handler; the bare `let approval_nursery = use approval.serve(ask = ask_operator)` needs no
  type arguments. The precision cost the single tail imposed is simply gone.

## When to use it

- A serial handler (a desk, an actor) must trigger a **slow external decision** — a human click, an OAuth
  authorization, any human-latency step — without blocking its own queue.
- The decision's outcome is an ACTION, not a value the caller needs back inline. If the caller must have
  the answer in the same turn, this is the wrong shape (you want a synchronous ask, and you must accept
  the block).
- A durable restart may drop the pending decision harmlessly. A fork mid-ask loses only the pending
  approval (the buttons go stale); the conversation is untouched. If losing the pending decision is
  unacceptable, the ask must be persisted differently.
- The continuation genuinely handles the fiber-side of its ceiling (its desks/handlers sit below its
  watch). This is the normal shape for a resident; it is what makes `Eouter` precise.

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
fiber, ask, hand back the boolean, all under the two-tail `lacks` discipline that makes the generic
request sound AND its residual precise — remains, and it is the same mechanism any resident with a
human-latency gate would write. That is why it is now a package, and this note describes the shipped
artifact rather than arguing against it.
