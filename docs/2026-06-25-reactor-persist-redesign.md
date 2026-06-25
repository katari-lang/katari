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
- **(c) the two-step reown** on the shared resource pool (§4). Symmetric and uniform:
  - on **sending** a value-carrying event (`delegate` arg, `delegateAck` result, `escalate` arg,
    `escalateAck` answer): **release** the value's captured resources from the local owner → *in-transit*.
  - on **receiving** one: **reown** the in-transit resources to the local owner.
  The owner each side uses is the local owner the base class already tracks per delegation/escalation, so the
  api root reowns a run result to itself exactly like a core caller reowns a sub-call result. No reactor
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
- **Keep**: `ExternalThread` / `ExternalRunner` (external stays in CORE); the api root as a permanent durable
  instance (the FK owner of run delegations + escaped resources); `ensureApiRoot`.

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
- **P4** — the shared resource pool view + base-class two-step reown; fix the run-result drop.
- **P5** — sweep the deferred correctness items (C3/C4/C7/C8, audit wiring) on the new shape.
