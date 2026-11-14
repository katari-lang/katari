# Reactor + persist: the converged actor design

Status: design (2026-06-25). **Supersedes** `2026-06-25-reactor-bus-redesign.md`'s `Reaction` / `commitTurn`
machinery and its from/to-deferral. Keeps the durable contracts: typed external events, one atomic commit per
turn, the transactional outbox, runs-as-delegation-projection, `LIVE_DELEGATION_STATES`, the C10 request-only
escalation rule, the cancelReasons fix.

## 0. Guiding principle

**The complexity is inside CORE (the engine). Everything else is thin wiring.** Don't add layers; don't
over-abstract persistence. If CORE is cleanly separated, the substrate / reactors / persistence stay simple.

## 1. External events carry `from` / `to`

Every `ExternalEvent` carries `from` and `to` (a `ReactorName` = `core | api | …`). The substrate routes
**purely by `to`**. A reply inverts from/to: a callee remembers the `from` of the `delegate` it received and
addresses its eventual `delegateAck` / `escalate` to that reactor. So routing is self-contained — no global
routing oracle, and the dispatcher never knows the api|core distinction (it just looks up `registry[to]`).

## 2. The Reactor base class — the external-event protocol layer

The base class is the *single* place that implements the delegation/escalation protocol, **uniformly for
every reactor**:

- **(a) its own delegations / escalations.** Each reactor holds the delegations it *issued* (caller side) and
  *handles* (callee side), keyed by id, each carrying its **local owner-id** and the **peer reactor**. Every
  reactor holds its OWN — there is no cross-reactor injection. (This kills the current smell where the api
  root injects its run delegations into CORE's `delegationCaller` map via `openRunDelegation`.)
- **(b) from/to send / receive.** `send(event)` stamps `from = self`; `to` is the target (a fresh delegate's
  callee, resolved from the IR; a reply's remembered `from`). Received events route in by the substrate.
- **(c) the two-step reown** on the shared resource pool (§4). It applies to the two **upward** value flows
  — a result (`delegateAck`) and an escalation's carried value (`escalate`) — both of which leave their
  raiser/child and may outlive it:
  - on **sending** one: **release** the value's captured resources from the local owner → *in-transit*.
  - on **receiving** one: **reown** the in-transit resources to the local owner.
  The **downward** legs (`delegate` argument, `escalateAck` answer) do **not** reown: the sender (the caller /
  answerer) stays live and the child/raiser reads the value in place, so its resources stay owned by the
  still-live sender. The owner each side uses is the local owner the base class already tracks, so the api
  root reowns a run result to itself exactly like a core caller reowns a sub-call result. No reactor
  special-case, no api-root "drop".
- **persist(tx).** Snapshot the reactor's own warm state (its instances / run-state + its delegations /
  escalations). In-memory is the SoT during operation; persist is just a time-slice snapshot for recovery.

The concrete reactor **only supplies its owner-id and reacts** — it never re-implements delegation tracking,
routing, or reown.

## 3. Concrete reactors

- **CoreReactor** — the engine. Instances + IR turns. The local owner of a delegation is the **instance**.
  Engine internals are untouched; **`ExternalThread` stays** (an external agent is a separate Block / thread
  kind that merely *behaves* like a `DelegateThread`; it is not deleted).
- **ApiReactor** — the management root. Run delegations + open escalations + (non-SoT) in-process result
  promises. The local owner is the **api root**.
- ffi / env fold in identically when needed.

## 4. The resource pool — an independent resource

scopes / blobs (+ ownership) are an **independent resource** with their own DB tables — *not* CORE-owned.
CORE manages instances and the instance↔scope ownership association (allocate / teardown / own); the **scope
resource itself is external to CORE**. The pool:

- is **shared** — every reactor's base class reowns within it, so a run's cross-reactor transfer (CORE
  releases the result, the api root reowns it) just works. (Physically the scopes still live in the engine's
  `ProjectStore`; the base class touches them through a narrow reown/release/free view, so the engine code is
  unchanged.)
- **persists itself** (`pool.persist(tx)` → its own tables; in-memory is SoT, persist = snapshot).
- **GC**: a scope whose owner is gone and is referenced by nobody is freed.

## 5. The Substrate — the bus

Responsibilities, and *only* these:

1. **route by `to`** — `registry[event.to].react(event)`.
2. **outbox persistence** — consume the inbound row, produce the turn's `send`s, atomically.
3. **drive per-turn persistence** — open the turn's tx and call the reacting reactor's `persist(tx)` and the
   pool's `persist(tx)`.

No engine state, no routing graph, no ascent. (The old `EntityTransition` / `Layer2Commit` / `Reaction`
vocabulary is gone — the reactor persists itself; the substrate doesn't model *what* it persists.)

## 6. SoT per datum

Each datum's source of truth is decided explicitly:

- **in-memory SoT** (persist = time-slice snapshot): instances, scopes/blobs, delegations, escalations.
- **DB SoT** (append / projection, read directly via CQRS): run records, escalation audit.

## 7. One turn = one atomic tx

```
substrate.loop:
  (event, seq) = mailbox.pull()                 // inbound: an outbox row, or an ephemeral FFI completion
  reactor      = registry[event.to]
  await reactor.react(event)                     // mutate warm state; send()=buffer; reown on the pool
  await tx(async (t) => {                         // ★ the only commit of the turn
    await reactor.persist(t)                      //   its instances/run-state + its delegations/escalations
    await pool.persist(t)                         //   scopes/blobs touched this turn (no-op if untouched)
    await outbox.consume(t, seq)                  //   delete the inbound row
    await outbox.produce(t, reactor.drainSends()) //   insert the buffered sends
  })
  mailbox.deliver(sends)                         // in-memory, AFTER commit
  reactor.afterCommit?.(...)                      // strictly-post-commit side effects (FFI dispatch)
```

For the in-memory persistence (warm store = truth, used by most tests) every `persist(tx)` is a no-op; only
the DB persistence writes. So `tx` is a thin transaction handle the persistence backend supplies.

## 8. Migration / cleanup (from the current R1–R2 code)

- **Delete**: `turn-commit.ts`'s `Reaction` / `EntityTransition` / `Layer2Commit` / `TurnCommit` /
  `outboundTransitions`; the `Persistence.commitTurn(TurnCommit)` method (→ per-component `persist(tx)`).
- **Fix (required)**: the mixed `delegationCaller` map — the api root no longer injects into CORE; each
  reactor holds its own delegations/escalations in the base class.
- **Add**: `from`/`to` on events; the substrate registry + route-by-`to`; the base-class two-step reown on the
  shared pool (fixes the run-result resource drop — see `2026-06-25-reactor-bus-redesign.md` §4.2 / `ascent.ts`).
- **Keep**: the api root as a permanent durable instance (the FK owner of run delegations + escaped
  resources); `ensureApiRoot`. (`ExternalThread` / `ExternalRunner` were *kept for the staged phases* but are
  reworked in §11 — the FFI-reactor phase — once landed.)

## 9. Staged implementation (each ships green; engine internals untouched)

- **P1 (done, `5bc68e2`)** — `from`/`to` on `ExternalEvent`; `ReactorName`; substrate registry + route-by-`to`.
  The reactors stamp `to` on send. (Reaction still present; pure routing change.)
- **P2 + P3 (done, `5662a5c`)** — landed together (the base class owning the rows *is* the persistence change).
  The Reactor base class is the single delegation/escalation protocol layer: each reactor holds the Layer 1
  rows it owns (caller-side delegations, raiser-side escalations) as the in-memory SoT and `send`s follow-on
  events directly — `Reaction.outbound` and the `openRunDelegation` injection into CORE are gone, and core no
  longer references the api root at all (a reply routes to `api` iff the delegation has no in-core caller).
  One turn = one `transaction`: the reactor writes itself through a `PersistenceTx`
  (putDelegation/putEscalation/putInstance/dropInstance), the substrate writes the outbox, all atomically;
  `turn-commit.ts` and `Persistence.commitTurn` are deleted. State transitions are caller-owned (open /
  cancelling on issue, done / gone on receipt), terminal rows are written once then evicted (sticky-terminal
  for free), and `startRun` opens the run row atomically with producing its delegate.
  **Deviations**: (1) the *pool* did not split out — scopes still ride with the core instance's Layer 2
  (`putInstance`); the shared resource pool view + the run-result-drop fix move to P4 with the reown. (2)
  per the doc, `ExternalThread` / `reactFfi` stay until the FFI reactor phase. (3) api commands run as serial
  *command turns* on the bus (a thunk that mutates + sends, committed like any reaction) rather than a direct
  out-of-band commit.
- **P4 (done, `ca6f5a5`)** — scopes / blob-ownership are an independent `ResourcePool` (over the engine's
  `ProjectStore`, in place) instead of riding inside an instance's Layer 2: `serializeInstance` drops scopes,
  `putInstance` stops writing them, and `putScope` + `pool.persist(tx)` flush the scopes a turn touched. The
  base-class two-step reown is on the bus — `send(delegateAck)` releases the result's resources to in-transit,
  the receiver reowns them to its local owner; the api root reowns a *run* result by the same path a core
  caller reowns a sub-call, which **fixes the run-result drop** (`ascendReturnedResources` / `ascendResources`
  / `reownResources` removed, folded into `pool.release` / `pool.reown`). A still-running instance flushes its
  scopes wholesale (`markOwnedDirty`); an in-transit scope survives its instance's drop because the pool
  re-writes it after the drop cascade in the same commit.
  **Deviations / follow-ups**: (1) scope reclamation on a *finished* instance stays the drop cascade — full
  reference-based GC is not implemented; in particular **api-root-owned run-result scopes are not yet GC'd**
  (the api root never goes away), so a run that returns a closure leaks its scopes until reclaimed. (2) blob
  ownership is updated in memory but still not persisted, and blob *bytes* are never freed — the same two
  blob follow-ups noted in `engine/ascent.ts`.
- **P5 (done)** — sweep the deferred correctness items + the GC follow-ups, on the new shape.
  - **GC (done, `2d5dfdd`)** — intra-instance scope GC (`engine/gc.ts`): per core instance, at its turn
    boundary, mark the scopes reachable from its threads (scope chains + closures captured in thread values /
    bindings) and free the ones it OWNS that are unmarked; the pool's `free` + `deleteScope` make the durable
    delete. Scopes owned by another instance or in transit (incl. a run result reowned to the api root) are
    never touched — the returned-closure / api-root scopes are intentionally NOT reclaimed for now.
  - **C4 (done, `90ef251`)** — poison a failed commit, drop the warm state, reactivate from durable (the
    unconsumed outbox replays); a commit / load error is never an unhandled rejection.
  - **C7 (done in P4)** — the pool re-writes an in-transit scope after the instance's drop cascade in the same
    commit, so a crash between the drop turn and the reown turn cannot lose a returned closure's scope.
  - **C8 — not needed.** Routing recovers from the engine threads, so the outbox replay order only needs to be
    stable (the seq + `createdAt` ordering already is), not a strict monotonic ordinal.
  - **C3 (done, `0706a4a`)** — the engine writes the `runs` metadata sidecar in the same commit as the run's
    `delegate` (atomic startRun) and the cancel reason with the `terminate`; `startRun` returns `started` (the
    façade awaits it for immediate visibility), and the façade's `runRepository.start` / `setCancelReason`
    writes are gone (the engine owns all `runs` writes; the repository is read-only now).
  - **Audit (done, `0706a4a`)** — answering a user-facing escalation appends a `run_escalations_audit` row in
    the same commit as the relayed `escalateAck`. New `PersistenceTx` methods, implemented by the Drizzle
    backend and the in-memory twin (which now stores runs + audits for unit tests).
  - **Whole redesign (P1–P5) is landed.** The standing follow-ups (not P5 scope) are: api-root-owned
    run-result scope GC (intentionally deferred — returned-closure scopes are not reclaimed), blob ownership
    persistence + blob-byte freeing, and the FFI-reactor phase — **now landed, see §11** (it reverses §3 /
    §8's "`ExternalThread` stays in CORE" hold).

## 10. Post-P5: the load-side SoT completion (`ensureApiRoot` fold + per-reactor load)

P2–P5 dissolved the *write*-side god-blob (`commitTurn` → per-component `persist(tx)`) but left the *load*
side as its twin: `loadProject` returned a `ProjectSnapshot` that `reactivate` hand-distributed, classifying
user-facing escalations through the `caller === apiRootId` sentinel + core's rebuilt routing graph (a `core
hydrate → classify for api` barrier). Two follow-ups finished §6's intent (delete `ProjectSnapshot` /
`loadProject` too) and §8's stated cleanups:

- **`ensureApiRoot` fold (done, `894f42d`)** — the api root is an `instances` row the **ApiReactor owns**, so
  it moved off the `Persistence` boundary onto `PersistenceTx`: the api reactor ensures it in the same commit
  as a run's `delegate`, before the run delegation's caller FK. `Persistence` collapses to `load` +
  `transaction`.
- **Per-reactor self-selecting load (done, `b5fc04c`)** — each Layer 1 edge records its reactors on its
  durable row (`delegations` / `escalations` gain `from_reactor` = issuer, `to_reactor` = peer; an escalation
  also gains its `delegation` = the raiser's, which for `to = api` IS the run). The opener stamps them. Then
  each reactor self-selects on load — core: engine graph + `from = core`; api: delegations `from = api` +
  open escalations `to = api` (rebuilt from the row alone). `loadProject` / `ProjectSnapshot` /
  `userFacingOpenEscalations` are replaced by a `Loader` read-surface + `reactor.load(loader)` symmetric to
  `persist(tx)`. No cross-reactor classification, no apiRoot sentinel at load. (`caller_instance_id` /
  `raiser_instance_id` stay — FK + the proxy-lookup routing rebuilt from `DelegateThread`s; the reactor
  columns are purely additive. The emit-side `routeOf` is unchanged.)

## 11. The FFI-reactor phase (done, `168b82c`)

The staged phases kept FFI as a private side channel on the external thread (`reactFfi` / `ExternalRunner`
inside CORE). This phase folds it in as a real reactor — the move §3 promised ("ffi / env fold in
identically") and §8 deferred. **An external (FFI) call is now a `delegate` to the `ffi` reactor**, routed and
tracked exactly like a core self-delegate; only its `to` differs. No ad-hoc FFI branch survives in core.

- **The event vocabulary.** `ReactorName += "ffi"`; `DelegateTarget += { kind: "external"; key }` (it carries
  no snapshot — it runs against its key, not the IR; `agentSnapshot` makes reaching for one a loud bug). The
  old `FfiResult` union is gone — a completion is a normal `delegateAck` / `escalate` / `terminateAck`.
- **The engine.** `ExternalThread` is no longer a side-channel: it is a **caller-side proxy** (`delegationId`
  + `relays`) with the *same* mechanics as `DelegateThread`. `createExternal` emits a `delegate` to ffi;
  dispatch / cancel / answer group external WITH delegate (one `delegateProxyOf`); `StepContext.external` and
  the in-CORE `reactFfi` / `resumeInFlightExternals` are deleted.
- **Core routing (unchanged in spirit).** `routeOf` sends a `delegate` to `ffi` iff its target is external,
  a reply to `instance.callerReactor`, and a `terminate` / `escalateAck` to `peerOf(delegation)` (the callee
  the delegation was opened against — `ffi` for an ffi call). `recordOutbound` peers an external delegate to
  `ffi`. `resolveTarget` / `moduleOf` reject an external target (core never summons one as an instance).
- **The FfiReactor.** ffi is delegated *to*, so each call is its OWN per-delegation callee instance (minted
  `newInstanceId`, the issuer stamped on the replies it produces) — NOT a shared root. Lifecycle mirrors a
  core sub-call: `running` (transport in flight) → `result` (→ delegateAck) / `cancelled` (→ terminateAck) /
  `error` → it escalates a panic and waits (`awaitingAnswer`) for either an `escalateAck` (a handler caught
  it — the answer becomes the call's result, → delegateAck) or a `terminate` (unhandled — → terminateAck).
  Its in-flight calls are durable `ffi_calls` rows (its callee-side Layer 1, owned solely by ffi);
  re-dispatched / re-aborted on recovery by `status`. It owns no delegations / escalations (those are core's).
- **The transport.** `FfiTransport` (`onComplete` / `dispatch(FfiCall)` / `abort(delegation)`) +
  `FfiCompletion`, all keyed by `delegation`. `SubprocessFfiTransport` (the long-lived sidecar over the
  newline-JSON `sidecar-protocol`, crash = panic every in-flight call), `InProcessFfiTransport` (handler map,
  for tests / pure-JS FFI), `StubFfiTransport` (loud default). A completion re-enters through the actor's
  serial mailbox as a ffi-reactor turn (durable-first: dispatch / abort is `afterCommit`).
- **Persistence.** New `ffi_calls` table (delegation PK, its own `instance_id` — NOT an FK, like the outbox
  issuer — `key`, `argument`, `caller_reactor`, `status`); `PersistenceTx.putFfiCall` / `dropFfiCall` +
  `Loader.ffiCalls()`, in the Drizzle backend, the storing twin, and the no-op seam. The project actor wires
  the ffi reactor into the registry, registers its completion sink, and resets + loads it on reactivation.

**Deviations / follow-ups.** The `port` / `bundle` packages (the user-facing FFI authoring + bundling) are
out of scope here and come next. An FFI result is a plain wire `Value` (it captures no engine scopes), so the
two-step reown on its `delegateAck` is effectively a no-op today — correct, but untested for an FFI value that
would reference a blob (not expressible until `port` lands).
