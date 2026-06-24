# Three-layer runtime: separating the external substrate, core, and api root

Status: design + implementation plan (2026-06-25)
Supersedes the actor structure introduced in `2026-06-24-api-core-connection.md` (the *contracts* there —
external events, atomic turn commit, transactional outbox, runs-as-delegation-projection — are kept; the
*packaging* into a single `ProjectActor` god object is what this redesign replaces).

## 1. The problem

`ProjectActor` is one object doing three unrelated jobs:

1. the **external-event substrate** — the serial mailbox, the transactional outbox, `commitTurn`, the
   delegation routing graph;
2. the **core engine reaction** — `onDelegate` / `onEscalate` / `onFfiResult` / driving a turn;
3. the **api-root logic** — `startRun` / `cancelRun` / `answerEscalation`, `runResolvers`, `cancelReasons`,
   `openEscalations`, `handleApi*`.

Because all three live in one class, **api and core are not separated**: nearly every event handler branches
`caller.kind === "api"`, and the api root was modelled as a fake `ApiInstance` inside the engine's `Instance`
union purely so it could flow through `callerOf` and be branched on. The run-specific in-memory maps are
tangled into the engine actor, and they leak (a cancel of a finished run leaves `cancelReasons[run]` forever;
the failed-run path double-settles). This is the "too split, yet api/core still fused" smell.

## 2. The three concerns (one home each)

```
            ┌──────────────────────────────────────────────────────────────┐
 hono       │  EXTERNAL SUBSTRATE  (Layer 1, ephemeral, durable)           │
 services   │  • serial mailbox + transactional outbox + commitTurn        │
   │  cmd   │  • delegation / escalation / instance ENTITIES + persistence │
   ▼        │  • THE single dispatch:  event → target entity → reactor     │
 ┌────────┐ │                        │                         │           │
 │command │ │           ┌────────────┘                         └─────────┐ │
 │surface │─┼──────────▶│ resolve target id; api root? ──► api : core    │ │
 └────────┘ │           └────────────┬─────────────────────────┬────────┘ │
   ▲  read  └────────────────────────┼─────────────────────────┼──────────┘
   │  (durable Layer 1 / runs)       ▼                          ▼
   │                        ┌─────────────────┐        ┌──────────────────┐
   └────────────────────────│  API ROOT       │        │  CORE            │
     run / escalation        │  (Layer 3)      │        │  (Layer 2)       │
     projections             │ reacts to ext.  │        │ reacts to ext.   │
                             │ events on the   │        │ events on a core │
                             │ api root.       │        │ instance; owns   │
                             │ owns run +      │        │ the engine and   │
                             │ escalation audit│        │ INTERNAL events. │
                             │ (durable; no    │        │ knows nothing of │
                             │ in-memory SoT). │        │ "run".           │
                             └─────────────────┘        └──────────────────┘
```

### Layer 1 — the external substrate (`runtime/external/`)

Owns everything that connects api and core, and is **uniform** — no api/core difference in entity CRUD:

- **Entities**: `Delegation`, `Escalation`, `Instance` — their state machines, persistence, and lifecycle.
  An `Instance` *entity* here is just `{ id, kind: core|api, status, delegationId, target, snapshot }` — a
  durable Layer 1 record. It is **not** the engine's in-memory thread tree (see Layer 2). The api root is a
  perfectly ordinary instance entity that happens to run no engine.
- **The serial loop + transactional outbox**: pull one external event, dispatch it, commit its `Reaction`
  atomically (Layer 1 transitions + Layer 2 continuation + outbox consume/produce), deliver produced events.
- **The single dispatch**: resolve the event's *target entity*, branch **once** on `targetId === apiRootId`,
  and hand the event to the api reactor or the core reactor. After this branch nothing checks `kind` again.

The reactors return a uniform value:

```ts
interface Reaction {
  outbound: ExternalEvent[];          // events to durably produce
  transitions: EntityTransition[];    // Layer 1 entity state changes
  layer2: Layer2Commit;               // 'persist' a core instance graph | 'drop' it | 'none' (api root)
}
```

`Reaction` is the abstraction that lets the substrate be uniform: the same `commit(Reaction)` for both
reactors. That is "more abstraction, not more layers" — one interface generalizes both halves; the substrate
never special-cases either.

### Layer 2 — core (`runtime/core/` + the existing `engine/`)

A `CoreReactor` that reacts to external events whose target is a **core instance**:
`delegate` (summon + create instance), `delegateAck`/`escalateAck`/`terminateAck` (resume), `escalate`
(relay inward), `terminate` (cancel), and FFI completions. It owns the in-memory engine state
(`CoreInstance` = thread tree + routing) and the **internal** event world (call/ask/cancel + acks). It is the
boundary that translates external↔internal; the substrate only ever speaks external events + `Reaction`.

Core **does not know about runs**. To core, the api root is just "some caller" the substrate happens to route
a `delegateAck`/`escalate`/`terminateAck` to. The `kind === "api"` branches disappear from every core handler.

The engine's `Instance` union collapses to just `CoreInstance` — the engine never sees an api instance,
because the dispatch peeled api-targeted events off one layer up.

### Layer 3 — the api root (`runtime/api/`)

An `ApiReactor` that is the api root's **full** participation in the external-event world — symmetric to a
core instance, which both *issues* external events and *reacts* to them. It both exposes the commands the
hono services call (issuing) and reacts to events the substrate routes to it (consuming). It is the
user-facing bridge:

> **`facade` folds into `ApiReactor`; `host` shrinks to a thin `ProjectRegistry`.** The command side
> (`startRun`/`cancel`/`answer` + `Json↔Value`, `resolveSnapshot`, the `runs` sidecar write) is the api
> root *issuing* external events on a user's behalf — the exact twin of it *reacting* to them — so it belongs
> on `ApiReactor`, not in a separate `facade` shell. What does **not** fold in is `host`'s registry role:
> `Map<projectId, {substrate, coreReactor, apiReactor}>` + lazy create + boot activation is a process-global
> lookup over the *whole* per-project stack (it *creates* the `ApiReactor`), so it stays as a ~15-line
> `ProjectRegistry`, minus the command-forwarding methods that move to `ApiReactor`. Reads (GET) stay in the
> repositories (CQRS), so `ApiReactor` does not bloat into a god object — it is only "issue + react".

- **Commands (POST)** → produce external events: `startRun` → a `delegate`; `cancelRun` → a `terminate`;
  `answerEscalation` → an `escalateAck`.
- **Event reactions** → durable Layer 1 + audit writes: `delegateAck` → the run delegation is `done`;
  `escalate` → a user-facing `escalation` opens (or, for a panic/control escape, the run `failed`);
  `terminateAck` → the run is `gone` (cancelled).
- **Reads (GET)** → project from durable Layer 1: a run is its delegation row (`runs` LEFT JOIN
  `delegations`); open escalations are `escalations(open)` rows whose raiser is a run root.

**The api root needs no in-memory state.** Its reactions are pure functions of the inbound event into
durable writes; its reads are durable queries. So the redesign **drops** `runResolvers` / `runRejecters`
(the in-process `result` promise was already non-SoT and ignored by the façade), `cancelReasons` (the reason
is written durably at cancel time — `runs.cancelReason` — and read from there when settling), and the
in-memory `openEscalations` mirror (the answer flow resolves an escalation's run delegation from the durable
`escalations`→`instances` edge). This deletes an entire class of leaks and the rehydration logic, and answers
the question "does the api side need to be in-memory?" — **no**. (If an in-process caller ever wants to await a
run, that is an optional notification hook, decoupled from the SoT, not the run's identity.)

## 3. Answers to the open questions (these shaped the design)

- **C4 — failure handling / retry?** The DB commit is already atomic, so there is nothing to *roll back*
  durably. The bug is purely in-memory: the engine mutates the warm store during `drive()` *before* the
  commit, and the mailbox entry is already shifted. The principled rule: **the warm store advances only when
  the durable commit advances.** On a commit failure the substrate does not retry the operation — it treats
  the actor as poisoned, **drops the warm reactor and reactivates from durable state**; the transactional
  outbox makes that safe (the unconsumed event replays). Plus a top-level `catch` so a commit error is never
  an unhandled rejection. (The clean Layer 1/2 split is what makes "drop and reactivate" trivial.)

- **C6 — the parallel-for cancel race.** Fixed already (the simple-fix batch). The problem: in a parallel
  `for`, one iteration's `next-for` defers its collect (`postCancelCollect`) and cancels just that iteration,
  while a concurrent `break-for` cancels the *whole* loop; when the deferred iteration's `cancelAck` finally
  lands, `dispatchCancelAck` took the `postCancelCollect` branch and re-finished an already-cancelling loop.
  Your semantics — *for a thread already in `cancelling`, a `cancelAck` carries no further meaning, it is just
  "child gone"* — is now the first check in `dispatchCancelAck`, mirroring `dispatchCallAck`. Whichever
  teardown reached the parent first wins.

- **C7 — is teardown simultaneous with delegateAck, and do we lift the scope owner?** They are **not**
  simultaneous — the child's drop and the caller's re-own are two separate turns/commits, which is exactly
  the gap. We *do* lift the owner, but only in the **warm store** (`ascendResources` sets `owner = null`); the
  *drop commit* deletes the instance row and the scope's DB row cascade-deletes on the **old** owner before
  `owner = null` is ever persisted, and the caller re-inserts it only on its later turn. Fix (Layer 1/2
  commit detail): a `drop` whose value ascends scopes must **re-key those scopes to `owner = null` in the same
  commit** (persist-as-detached) instead of letting the cascade delete them — so a crash between the two turns
  cannot lose a returned closure's scope. Edge case today (only returned closures; blobs inert), folded into
  the Layer 1 work.

- **C9 — do `turn-commit` and `db-persistence` overlap?** No: `turn-commit` is the **contract** (the
  `Reaction`/transition vocabulary + the pure `outboundTransitions` derivation) — keep it. The real overlap is
  between `db-persistence` and `storing-persistence`, two hand-mirrored **executors** of that contract (the
  sticky-terminal `applyTransition` logic copied twice with different vocabularies). Unify: one
  `applyTransition` over a small storage port (get/set/delete/iterate); `Db` binds it to Drizzle, the
  in-memory twin to Maps. The decision logic exists once; only ~10 lines of row-CRUD differ. The three
  persistence classes collapse to two sharing a core.

- **C10 — control escape reaching the api root.** Right: the typechecker's escape-effect discipline makes a
  `return`/`next`/`break` reaching the api root impossible. Two consequences: (a) a control escape is **not a
  Layer 1 escalation at all** — escalations are *capability requests awaiting an answer*; a control escape is a
  one-way internal unwind that merely crosses an instance boundary, so `outboundTransitions` should record an
  `escalation-open` **only for `request` asks** (this removes the durable-row leak); (b) if one nevertheless
  reaches the api root, that is an engine/compiler invariant violation — fail the run loudly (defensive), not
  silently store it.

- **C11 — runs vs ephemeral delegations.** A run *is* the durable projection of one delegation (the api
  root's), and that is the only place run-ness lives. The ephemeral core-facing delegations and the
  user-facing run should share **identical** entity CRUD (add/remove/persist a delegation/instance/escalation
  is uniform — Layer 1) and differ **only** in who reacts (api vs core — the single dispatch). The tangle
  today is that the api reactor keeps a parallel in-memory copy of run state intertwined with engine routing.
  The redesign deletes that copy (see Layer 3): the api root holds no in-memory run state; "run" is the
  delegation row + the `runs` sidecar, read by projection. `cancelReason` is durable only.

## 4. What gets deleted

- The `ApiInstance` arm of the engine's `Instance` union, `ensureApiRoot(store, …)` in the engine, and every
  `caller.kind === "api"` / `kind !== "core"` branch in the core handlers (replaced by the single dispatch).
- `runResolvers`, `runRejecters`, in-memory `cancelReasons`, in-memory `openEscalations` (→ durable projection).
- One of `db-persistence` / `storing-persistence`'s duplicated `applyTransition` (→ shared core).
- Legacy: `activate()` (no production caller — boot resume becomes an explicit substrate concern, see C4);
  `ApiInstance.status` (never transitions); resolve `run_escalations_audit` (either wire it on
  `escalation-answered`, or delete the table + its comments — it is currently dead).
- SSoT consolidation: one `isUserFacingRequest`, one `LIVE_DELEGATION_STATES` predicate, the delegation→run
  state map in one place (already), state strings off magic literals, and an `assertNever` on the commit
  switch.

## 5. Phased implementation plan

Each phase is independently shippable with tests green. Phases 1–2 are pure refactors (no behaviour change);
3–5 carry the deletions and the remaining correctness fixes.

- **Phase 0 — simple fixes (DONE).** C1 (persist api root for the caller FK), C2 (`answerEscalation` loads
  before reading), C5 (`loaded` flips only after full reactivation), C6 (cancelling-thread `cancelAck` guard).

- **Phase 1 — dissolve `host` + `facade` along the right seam.** `facade`'s command logic (`Json↔Value`,
  `resolveSnapshot`, the `runs` sidecar write, command→external-event) folds into the api command surface
  (the `ApiReactor`-to-be — the api root issues events, the twin of reacting to them). `host` shrinks to a
  ~15-line `ProjectRegistry` (the warm `Map<projectId, …>` + lazy create + boot activation) with its
  command-forwarding methods removed. Reads stay in the repositories (CQRS). No behaviour change. (Concern #4.)

- **Phase 2 — extract the `Reaction` interface + the single dispatch.** Split `ProjectActor` into the thin
  **substrate** (mailbox/outbox/commit/dispatch + delegation graph) and two reactors (`CoreReactor`,
  `ApiReactor`) that each return a `Reaction`. The dispatch resolves the target id and branches once. Move the
  `handleApi*` logic into `ApiReactor`, the `on*` core logic into `CoreReactor`. Pure refactor — same maps,
  same behaviour — but api/core are now separated and the `kind === "api"` branches are gone. (Concerns #3,
  #4, #6.)

- **Phase 3 — make the api root stateless-over-durable; split the Instance entity from `CoreInstance`.** Drop
  the in-memory run maps; the `ApiReactor` reacts straight into Layer 1 + reads project from durable state.
  Collapse the engine `Instance` union to `CoreInstance`; the api root becomes a Layer 1 instance entity only.
  Delete `cancelReasons`, the `openEscalations` mirror, the `result` promise SoT. (Concerns C11, #2.)

- **Phase 4 — unify Layer 1 persistence + atomicity.** One `applyTransition` over a storage port (collapse the
  twin, C9). Fold the `runs` sidecar write into the same commit as the run's `delegate` produce (C3 — startRun
  becomes atomic). Add a monotonic outbox ordinal and replay by it (C8).

- **Phase 5 — remaining correctness + legacy sweep.** C4 (commit-failure → poison + reactivate, top-level
  catch). C7 (drop commit re-keys ascended scopes to detached). C10 (escalation entity = requests only;
  control escape at the api root fails loudly). Idempotency guard on `escalation-answered`. Delete
  `activate()`, `ApiInstance.status`; decide `run_escalations_audit`. SSoT/magic-literal consolidation.

## 6. Non-goals / explicitly kept

- The external-event contract (delegate/escalate/terminate ± acks), the atomic turn commit, the transactional
  outbox, and runs-as-delegation-projection — all validated, all retained.
- The intra-instance engine internals (thread-ops, the internal-event world) — out of scope here; this
  redesign is about the api/core boundary, not the engine.
- The CQRS read/write split — kept (reads must reflect durable Layer 1 to survive eviction/recovery), only
  renamed so it stops looking like a half-API.
