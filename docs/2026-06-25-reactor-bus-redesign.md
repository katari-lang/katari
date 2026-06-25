# Reactor + bus redesign: modules over a typed, transactional bus

Status: design (2026-06-25)
Supersedes the single-`ProjectActor` packaging of `2026-06-24-api-core-connection.md` and
`2026-06-25-three-layer-runtime.md`. The **contracts** those established are kept verbatim — the typed
external-event vocabulary (delegate / escalate / terminate ± acks), the atomic turn commit, the transactional
outbox, runs-as-delegation-projection. What changes is the **packaging**: instead of one god-object with
`kind` branches, the runtime is a set of sibling **reactors** (modules) registered on a thin **substrate**
(the bus). This restores the prototype's API / CORE / FFI / ENV module separation, but over a far better bus
(typed events + one atomic commit + crash-safe outbox) instead of a generic message bus.

## 1. The shape

```
 hono services ──cmd──▶ ┌──────────────────────────────────────────────────────────┐
                        │  SUBSTRATE  (the bus — thin, the only DB owner)           │
                        │   • serial persisted mailbox                              │
                        │   • register(name, reactor)                               │
                        │   • route one event to reactor[event.to]                  │
                        │   • commit(Reaction) atomically; deliver produced events  │
                        └───────┬───────────────┬───────────────┬──────────────────┘
                                │ feed           │ feed           │ feed
                        ┌───────▼──────┐ ┌───────▼──────┐ ┌───────▼─────────────────┐
                        │ CORE reactor │ │ API reactor  │ │ FFI reactor             │
                        │ runs IR;     │ │ runs/escal.; │ │ external calls;         │
                        │ instances =  │ │ no instances │ │ instances = pending     │
                        │ thread trees │ │ (caller-only)│ │ calls; one executor port│
                        └──────────────┘ └──────────────┘ └─────────┬───────────────┘
                                                                    │ dispatch / abort
                                                          ┌─────────▼───────────┐
                                                          │ FFI executor (port) │  ← the one layer
                                                          │  → sidecar / process │
                                                          └─────────────────────┘
```

Reactors are **siblings on the bus**, not stacked layers. Depth is shallow: `service → substrate → reactor`,
plus `ffi reactor → executor → sidecar` for the one place that genuinely needs a port. "More modules, not more
layers."

## 2. The load-bearing rule: one atomic commit per turn

Everything below depends on this. A turn **never persists more than once**, and that one persist is the
substrate's atomic commit. Reactors compute their whole turn *in memory* and hand back a description; the
substrate writes it.

```
substrate.loop:
  (message, seq) = mailbox.pull()                 // inbound: an outbox row (durable) or an ephemeral trigger
  reactor        = registry[message.to]
  reaction       = reactor.feed(message)          // runs the turn in memory; issue() only buffers
  await substrate.commit({                          // ★ the only tx of the turn
    consume:     seq,                               // Layer 3: delete the inbound outbox row (null if ephemeral)
    transitions: reaction.transitions,              // Layer 1: delegation / escalation state changes
    layer2:      reaction.layer2,                   // Layer 2: the reactor's own instance state (persist|drop|none)
    produce:     reaction.outbound,                 // Layer 3: new outbox rows
  })
  mailbox.deliver(reaction.outbound)              // in-memory, AFTER commit
  reactor.afterCommit(reaction)                   // post-commit side effects (FFI dispatch); durable-first
```

Why this dissolves every tx worry raised so far:

- **"send-persist then mailbox-persist, crash between"** — there is no send-persist. `issue()` mints ids and
  buffers; the single `commit` writes the Layer 1 transition *and* the outbox produce *and* the inbound
  consume together. No window.
- **"consume + persist, then crash before the instance is created"** — the instance is created in memory
  during `feed`, and its Layer 2 persist is in the *same* commit as the consume. Crash before commit ⇒ the
  inbound row is untouched and replays; the instance was never persisted. Crash after ⇒ both done. No torn
  state, and **no "carry the tx across steps" mechanism is needed** — nothing is persisted mid-turn.
- **Side effects are strictly post-commit** (`afterCommit`): an FFI call is dispatched only after its pending
  record is durable, so recovery can always re-dispatch it. Mailbox delivery is likewise post-commit.

Consequence: **reactors hold no DB.** They return `Reaction`s; the substrate is the sole DB owner and the sole
committer. This is what makes the cross-reactor tx atomic (the inbound row is the substrate's, the transitions
are the reactor's — one handle, one tx) and makes reactors unit-testable without Postgres.

## 3. Core abstractions

### 3.1 External event — now self-addressing (`from` / `to`)

Every external event carries `from` (issuing reactor) and `to` (target reactor). The substrate routes purely
on `to`; `from` is what a reply inverts.

```ts
type ExternalEvent =
  | { from; to; kind: "delegate";     delegation; target; argument }   // to resolved from the target's nature
  | { from; to; kind: "delegateAck";  delegation; value }              // to = the delegation's caller reactor
  | { from; to; kind: "escalate";     delegation; escalation; ask }    // to = the delegation's caller reactor
  | { from; to; kind: "escalateAck";  delegation; escalation; value }  // to = the escalation's raiser reactor
  | { from; to; kind: "terminate";    delegation }                     // to = the delegation's callee reactor
  | { from; to; kind: "terminateAck"; delegation }                     // to = the delegation's caller reactor
```

**Request/reply inversion**: when a reactor receives `delegate` (`from = X`), it remembers `X` on the
instance/delegation it creates; its eventual `delegateAck` / `escalate` sets `to = X`. So addressing is
self-contained per reactor — nobody needs a global routing oracle. The `to` of a fresh `delegate` is resolved
from the target: a normal agent ⇒ `core`, an external agent ⇒ `ffi` (§5). That resolution needs the IR, which
the issuing reactor has.

### 3.2 `Reaction` — the unit the substrate commits

```ts
interface Reaction {
  transitions: EntityTransition[];   // Layer 1: delegation-open/done/cancelling/gone/failed, escalation-open/answered
  layer2: Layer2Commit;              // 'persist' this reactor's instance graph | 'drop' it | 'none'
  outbound: ExternalEvent[];         // Layer 3: events to produce as outbox rows
}
```

`layer2` is reactor-specific: `core` persists/drops a thread tree, `ffi` persists/drops a pending-call record,
`api` is always `none`. The substrate treats it opaquely (it serialises the reactor's own state through the
codec the reactor provides).

### 3.3 Reactor base class

```ts
abstract class Reactor {
  constructor(protected readonly bus: Substrate, readonly name: string) {
    bus.register(name, this);
  }

  /** The substrate hands one inbound message here; the base runs the turn and collects a Reaction. */
  feed(message: Inbound): Reaction {
    const turn = this.beginTurn();              // fresh outbound + transition buffer
    this.dispatch(message, turn);               // → onDelegate / onDelegateAck / … (abstract)
    return turn.toReaction(this.layer2For(message, turn));
  }

  /** Issue an external event from inside a turn: mint a new delegation/escalation id when the kind needs one,
   *  stamp from/to, buffer the event AND its Layer 1 transition into the turn. Returns the (possibly minted)
   *  id. Does NOT persist — the substrate commits the turn. The single chokepoint for external-event birth. */
  protected issue(turn: Turn, spec: IssueSpec): DelegationId | EscalationId | void;

  /** Rebuild in-memory state from this reactor's durable rows on boot (core: threads; ffi: re-dispatch calls;
   *  api: open escalations). Called once per reactor at substrate startup. */
  abstract reactivate(durable: ReactorDurableState): Promise<void>;

  /** Strictly-post-commit side effects (durable-first). Default no-op; the FFI reactor dispatches calls here. */
  afterCommit(_reaction: Reaction): void {}

  // Concrete reactors implement only the legs they participate in; the rest default to "consume, no effect".
  protected onDelegate(_e, _turn): void {}
  protected onDelegateAck(_e, _turn): void {}
  protected onEscalate(_e, _turn): void {}
  protected onEscalateAck(_e, _turn): void {}
  protected onTerminate(_e, _turn): void {}
  protected onTerminateAck(_e, _turn): void {}
}
```

Each reactor also keeps an in-memory view of **its own** entities (the delegations it issued / the escalations
it raised / its instances) for its own logic; the durable rows are the recovery source.

### 3.4 Substrate (the bus)

```ts
class Substrate {
  private readonly registry: Record<ReactorName, Reactor> = {};
  register(name: ReactorName, reactor: Reactor): void { this.registry[name] = reactor; }

  /** The only entry from outside (an API command) or from a reactor producing follow-on events lands here as
   *  outbox rows at commit; this is the *external injection* door (e.g. startRun's first delegate). */
  feed(message: Inbound, seq: OutboxSeq | null): void { /* push to mailbox; pump */ }

  /** Serial loop: pull → route to registry[message.to] → commit its Reaction atomically → deliver. */
  private async pump(): Promise<void> { /* §2 loop */ }

  /** The single atomic commit (Layer 1 + 2 + 3). The only place that touches the DB. */
  async commit(c: TurnCommit): Promise<void> { /* one tx */ }
}
```

`Substrate.register` + the reactor-constructor-takes-`bus` wiring is the DI the user proposed — endorsed.
**Refinement**: a reactor's `issue()` does *not* call `bus.feed` mid-turn; its outbound events ride in the
Reaction and become mailbox rows at commit. `bus.feed` is for *external* injection (API commands), which is a
produce-only turn (`consume: null`).

## 4. The reactors

### 4.1 `core` — the engine

Unchanged engine internals (thread-ops, the internal-event world, drive). As a reactor:

- `onDelegate(delegate)` → create a core **instance** (a thread tree), record `delegation-open`
  (caller reactor = `delegate.from`), seed + drive the agent root. `layer2 = persist | drop`.
- `onDelegateAck` / `onEscalateAck` / `onTerminateAck` → resume the proxying `DelegateThread` (callAck /
  askAck / cancelAck), drive, commit.
- `onEscalate` → relay inward from the proxy toward a handle.
- `onTerminate` → cancel the instance subtree; emit `terminateAck` once torn down.
- A normal sub-call inside an agent uses `issue(delegate)`, which resolves `to` from the target (core or ffi).

The engine `Instance` union is already collapsed to `CoreInstance` (done, commit `eede0bf`); here it simply
becomes "the core reactor's instance type".

### 4.2 `api` — the management root (one permanent instance; routing by name, not by id)

The api reactor is the user-facing bridge — it **issues** runs and **reacts** to their replies. It owns
**exactly one permanent instance**, the api root (`id = apiRootIdOf(project)`, `kind = api`), created once by
`ensureApiRoot`. That instance is a **durable Layer 1 entity, but not a warm engine instance** (it runs no IR,
holds no thread tree). It exists for **ownership**, which routing-by-name does not provide:

- it is the **caller of every run delegation** (`delegations.caller_instance_id` → the api root) — without it
  the run-delegation caller FK has no referent (this is exactly C1, and the api root instance is its fix);
- it is the **durable owner of resources that escape in a run result** (`blobs`/`scopes.owner_instance_id` →
  the api root). A run-root core instance retires when the run completes; a blob/closure in its result must
  outlive it, so it **ascends to the api root** (a permanent owner) instead of dropping. (See the change to
  `ascendReturnedResources` — today run-result resources are dropped, which is a latent dangling-reference bug
  once blobs are real.)

What the reactor model **does** change is only the **dispatch**: an ack/escalate/terminate for a run routes by
**reactor name** (`event.to === "api"`), replacing the `caller === apiRootId` sentinel branch. `apiRootIdOf`
stays — but as the api root instance's **id** (an FK referent), not as a routing key.

- `startRun` (a command) → `bus.feed` a produce-only turn that `issue(delegate)`s the run (`from = api`,
  `to = core`). The run delegation's caller is the api root instance.
- `onDelegateAck` → the run finished (durable delegation `done`); settle the optional in-process hook.
- `onEscalate` → a user-facing request opens (durable `escalation`, raiser = the run-root **core** instance —
  the api reactor only tracks it in memory to answer it; it does not own the row), or a panic/escape fails the
  run.
- `onTerminateAck` → the run was cancelled (`gone`).
- Reads (GET) project from durable Layer 1 (CQRS), unchanged.

So the api reactor's single permanent instance is the degenerate case of "every reactor owns instances": core
has many ephemeral ones (activations), ffi many (pending calls), api exactly one (permanent, no
`reactor_state`). The in-process run maps stay only as the non-SoT notification hook (per the narrowed Phase 3).

### 4.3 `ffi` — external calls as a first-class reactor

The current FFI layer (`ExternalRunner` as a top-level actor dependency, the `ExternalThread` engine kind, and
`resumeInFlightExternals`) is **deleted and redesigned**. An external call becomes an ordinary delegate whose
`to` resolves to `ffi`:

- `onDelegate(delegate)` → create an **ffi instance** = a durable pending-call record
  (`reactor_state = { key, argument }`), record `delegation-open` (caller = `delegate.from`). `layer2 = persist`.
  No call is dispatched inside the turn.
- `afterCommit` → dispatch every pending-call instance not yet dispatched *in this process* through the
  executor port. Because the pending record is already durable, this is identical on the first turn and on
  recovery — there is no separate "redispatch" path.
- Completion (an ephemeral trigger from the executor, `seq = null`, `to = ffi`) → run a turn:
  - success → `issue(delegateAck)` + drop the ffi instance.
  - error → `issue(escalate)` with a panic ask (it bubbles to a handler / fails the run, exactly like a
    core panic).
- `onTerminate` → `executor.abort(callId)`; the abort's confirmation (a cancelled completion) runs a turn that
  `issue(terminateAck)`s + drops the instance — preserving today's *graceful* cancel (wait for the abort
  confirmation before settling).
- `reactivate` → load the ffi instances; `afterCommit`'s dispatch logic re-fires the in-flight calls.

The executor port — **the one layer between the ffi reactor and the sidecar**:

```ts
interface FfiExecutor {
  dispatch(call: { callId: CallId; key: string; argument: Value | null }): void; // fire-and-forget
  abort(callId: CallId): void;
  onComplete(cb: (callId: CallId, outcome: { value: Value } | { error: string } | { aborted: true }) => void): void;
}
```

Implementations sit behind it (an in-process function map for tests; an IPC/subprocess bridge to the real
sidecar for production). The port is **not durable** — the ffi reactor's instances are the durable handle, so
the side channel can be lossy and recovery re-dispatches.

## 5. `external` ≈ `delegate`: deleting the ExternalThread

An external agent is still an agent; what changes is that **calling it is a plain delegate to the `ffi`
reactor**, so the engine needs no special `ExternalThread`:

- The caller's `issue(delegate)` resolves the target — if the target agent's body is external, `to = ffi`.
- The caller holds an ordinary `DelegateThread` (proxy) awaiting `delegateAck` — identical to delegating to a
  normal sub-agent. The "externalness" lives entirely on the callee side (the ffi reactor).
- `completeExternalAbort`, the `external` thread kind, `ExternalThread.externalState`, and the engine's direct
  knowledge of FFI all go away. Cancel of an in-flight external is just `terminate` of its delegation (§4.3).

So the engine's thread kinds reduce to the structural set + `DelegateThread`. One fewer special case in the
hottest part of the code.

## 6. Persistence model (generalised, mostly already there)

- **`instances`**: `kind` generalises from `core|api` to the **reactor name** (`core | api | ffi`). Every
  reactor owns instances — core many (activations), ffi many (pending calls), **api exactly one** (the
  permanent root). An instance's **`kind` *is* its reactor**, so routing's `to` for an ack/escalate is the
  caller/raiser instance's `kind` — no separate `*_reactor` column is needed. `engine_state` generalises to
  **`reactor_state`** (opaque per-reactor JSONB: core's bookkeeping, ffi's call descriptor, `null` for the api
  root). `threads` stays a core-only spill of its reactor_state for queryability.
- **`delegations`**: `caller_instance_id` is **always set** now — a sub-call's caller is a core instance, a
  run's caller is the api root instance (so the caller FK always has a referent; this *is* the C1 fix). The
  ack's `to` derives from that instance's `kind`. The state machine + sticky-terminal rules +
  `LIVE_DELEGATION_STATES` (already a single source of truth) are unchanged.
- **`escalations`**: still ephemeral (cascades with the raiser **core** instance). The durable user-facing Q&A
  history is `run_escalations_audit`, **wired on `escalation-answered`** for user-facing escalations (resolving
  the earlier open question — the audit is *needed* precisely because escalations are ephemeral).
- **`blobs` / `scopes`**: `owner_instance_id` may now be the **api root** (a resource that escapes in a run
  result ascends to it, instead of dropping — see §4.2). The api root being a permanent instance is what gives
  these escaped resources a durable owner.
- **`outbox`** / **`runs`** / **`run_escalations_audit`**: unchanged in spirit; each outbox row's event already
  carries its `to`.
- **Kept (NOT deleted)**: `Persistence.ensureApiRoot`, the api root `instances` row, `apiRootIdOf` — these are
  the api root **instance** (the durable owner). Only the sentinel *dispatch* (`caller === apiRootId`) goes
  away, replaced by `event.to === "api"`.

## 7. Recovery — uniform, no special cases

On startup the substrate, for each registered reactor: loads that reactor's durable rows (its instances +
the Layer 1 edges it owns) and calls `reactor.reactivate(...)`; then replays the undrained outbox into the
mailbox (each row routed by its `to`). Per reactor:

- `core.reactivate` → rebuild thread trees + routing from instances/delegations (today's `reactivate`).
- `ffi.reactivate` → re-dispatch pending calls (the `afterCommit` dispatch path; no bespoke
  `resumeInFlightExternals`).
- `api.reactivate` → rehydrate open user-facing escalations (or read them durably).

FFI completions remain an **ephemeral** trigger (not an outbox row): a crash mid-call is recovered by
re-dispatch from the durable pending instance, so external calls must be idempotent under redispatch — the
same assumption as today, now localised in the ffi reactor.

## 8. What gets deleted

- `ExternalRunner` as a top-level dependency; the `external` engine thread kind; `completeExternalAbort`;
  `resumeInFlightExternals`. (→ ffi reactor + executor port.)
- Only the **sentinel dispatch** (`caller === apiRootId` / `kind === "api"` branching). (→ routing by reactor
  name.) `Persistence.ensureApiRoot`, the api root `instances` row, and `apiRootIdOf` **stay** — they are the
  api root instance (the durable owner of run delegations + escaped run-result resources).
- The `ProjectActor` god-object: split into `Substrate` + `Reactor` base + `core`/`api`/`ffi` reactors.
- Carried over as keepers: the typed event vocabulary, the atomic `commitTurn`, the transactional outbox,
  runs-as-projection, `LIVE_DELEGATION_STATES`/`isLiveDelegationState`, the C10 request-only escalation rule,
  the cancelReasons leak fix.

## 9. Migration plan

Each phase ships green; the engine internals (thread-ops) are untouched throughout.

- **R1 — Substrate + Reactor base + Reaction. ✅ done** (commits `3c546e9` R1.1, `11c2dd0` R1.2, `4c96d7a`
  R1.3). R1.1: the `Reaction {instanceId, layer2, transitions, outbound}` type + the single `commit(reaction,
  consumed)` funnel. R1.2: the `Reactor` base class — `react(event) → Reaction` (compute the turn in memory)
  plus a strictly-post-commit `afterCommit` hook; `ApiReactor extends Reactor`, its three reaction methods
  folded into one `react`, the in-process result promise now settling durable-first in `afterCommit`. R1.3:
  the `Substrate` class (serial mailbox + pump, lazy load-gate, serial commit chain, the atomic `commit`
  funnel) extracted from `ProjectActor`, which composes it as host.
  **Deviation from the original sketch (deliberate):** the **reactor registry + route-by-name** are *not* in
  R1.3 — without `from`/`to` on events the substrate cannot route by `to`, and a registry nothing reads is
  dead code. Instead the substrate routes via a transitional `SubstrateHost.dispatch` callback (and reloads
  domain state via `reactivate`); R2 adds `from`/`to` + the registry and collapses `dispatch` into
  `registry[event.to].react`. Likewise `issue()` was not introduced (the api root mints its own ids and the
  outbound→transition mapping is `outboundTransitions`); it lands with the core reactor in R2/R3 if it earns
  its keep. Pure refactor; 33 tests green throughout.
- **R2 — Core reactor. ✅ core done** (commits `fc25040` R2.1, `a7b2e86` R2.2). R2.1: every core handler made
  pure — drive the turn, then *return* a Reaction; the seq/consumed threading collapses to `handle`, now the
  single commit funnel for both core and api (`route → substrate.commit → after`, the api result promise
  settling durable-first in `after`). R2.2: the engine extracted into `CoreReactor extends Reactor` — it owns
  the `ProjectStore` + the delegation routing graph + the turn machinery + all handlers, reacting through one
  `react(event) → Reaction` (caller-side legs resolve their caller from its own graph) plus `reactFfi`;
  `loadState`/`userFacingOpenEscalations`/`resumeInFlightExternals` rebuild it. `ProjectActor` is now a thin
  composition root (~190 lines): wire substrate + core + api, route, commit, reactivate.
  **Two deliberate deviations:** (1) **No per-event `from`/`to`; no substrate registry route-by-name.** The
  api|core decision is genuine *engine* knowledge (a delegation's caller is the api root), so it stays as the
  dispatcher querying the core reactor's `isRunDelegation` sentinel rather than moving into the substrate as a
  reactor-name route. The substrate stays reactor-agnostic via the `dispatch` seam; pushing the routing graph
  into it (and a registry) would only relocate the same sentinel, adding indirection. (2) **The run-result
  resource ascent moves to R4.** It is *not* self-contained: an api-root-owned scope/blob needs the
  persistence layer to persist it and rebuild it on reactivate, but the api root runs no `persist` turn — so
  it belongs with R4's persistence generalisation. It is latent meanwhile (blobs are inert; a clean drop today
  beats a warm-only reown that vanishes on restart). 33 tests green throughout.
- **R3 — FFI reactor.** Introduce `FfiReactor` + the `FfiExecutor` port; reroute external-agent delegates to
  `to = ffi`; delete `ExternalThread` / `ExternalRunner` / `resumeInFlightExternals`. Recovery via re-dispatch.
- **R4 — generalise persistence.** `kind → reactor name` (an instance's kind *is* its reactor, so no separate
  `*_reactor` columns), `engine_state → reactor_state`; one `applyTransition` over the shared vocabulary (the
  executors stay native — Maps vs SQL). Wire `run_escalations_audit` on `escalation-answered`. **Also folds in
  R2's deferred ascend fix:** make the api root a durable owner of escaped run-result resources (persist
  api-root-owned scopes/blobs + rebuild on reactivate), then have `ascendReturnedResources` reown a run
  result's captured resources to the api root instead of dropping them.
- **R5 — the deferred correctness items on the new structure.** C4 (commit-failure → drop & reactivate — now
  trivial: the substrate drops warm reactors and re-runs `reactivate`), C7 (drop re-keys ascended scopes), C8
  (outbox ordinal), C3 (atomic startRun). These are cheaper here than on the old shape, which is why they were
  deferred.

## 10. Decisions (resolved 2026-06-25)

All confirmed with the user; the design is final.

1. **api root is one permanent durable instance** (the owner of run delegations + escaped run-result
   resources); **routing is by reactor name.** Routing-by-name replaces only the sentinel *dispatch*;
   `ensureApiRoot` and the api root instance row **stay** (they are the FK referent / cascade owner).
2. **FFI completion stays ephemeral** (idempotent-under-redispatch) — not a durable mailbox event. Matches
   today; a durable completion would require the sidecar itself to be transactional, which is out of scope.
3. **`reactor_state` is one opaque JSONB per reactor** (uniform load/persist); ffi's descriptor is tiny, so it
   needs no table of its own.
4. **ENV is not modelled now** (no current consumer). When env effects return, an `EnvReactor` folds in the
   same way `ffi` does — no further design work needed.
