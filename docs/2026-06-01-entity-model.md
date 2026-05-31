# Entity model — ownership, persistence, and cascade (v0.1.0)

This document settles the domain model underneath blob GC, persistence, and the
katari protocol's execution records. It supersedes the ad-hoc "ref owner =
delegation/run/escalation id" handling sketched in the Phase G slices.

The driving realization: the system never gave the **execution unit** a
first-class identity. Ownership, cascade-delete, and escalation-belonging were
all bolted onto "delegation id", which leaks the moment you reach a unit that
was not created by a `delegate` (the operator-launched run, the project's file
library). Making the **Entity** first-class makes all of them fall out of one
parent tree + FK cascade.

## 1. The one idea: Entity (実行実体)

An **Entity** is a node in the execution tree. Every owning/executing unit is an
Entity, and Entities form a single tree per project:

```
Project
  └ project-root entity   (module=API)  ── owns user-uploaded files; the API keeps it
       └ run-root entity   (module=API)  ── one per `run`; owns the run's result; the API keeps it (+ its Run/escalations-audit)
            └ CORE root entity (module=CORE) ── the agent the run launched
                 ├ CORE sub-entity (module=CORE)
                 ├ FFI ext entity   (module=FFI)
                 └ ENV builtin       (module=ENV)
                      └ …
```

Everything hangs off Entities:

- **Ownership** of a blob ref is by Entity. Ownership only rises up the tree.
- An entity carries only a protocol `state` (`running | cancelling`) and a
  `module` (who runs it). There is no `lifecycle` / `kind` field — neither is a
  protocol concept. **Persistence is just behaviour:** an entity is normally
  deleted by its parent on terminal; the API simply *keeps* its own entities
  (the project / run roots), which is what makes uploads + run history survive.
- **Escalations belong to the entity that RAISED them** (the raiser is the
  subject; it holds the delete authority), and cascade with that raiser.
- **Drop = FK cascade**: deleting an Entity drops its still-owned refs and
  raised escalations automatically. The only explicit ownership work is the
  *ascent* (re-own escaping refs to the parent) before the Entity row is deleted.
- The richer **run** state (`done` / `error`) is NOT an entity state — it is the
  API module's separate **Run** record, reflecting the run's child CORE-root.

The protocol's `delegations` table is **kept** (the issuer-managed request edge);
a new `entities` table (the receiver-managed execution node) is added alongside
it and becomes the ownership/cascade root. They are two records with distinct
owners and nested lifetimes (§3 Delegation).
`runs_audit` does NOT fold in — it stays as the API's separate **Run** record
(§3), because the run's `done`/`error` state is API bookkeeping about the
CORE-root child, not a protocol entity state.

## 2. Identity, the bus, and ownership ascent (Option 2)

### Two distinct ids

- **delegation id `D`** — the *parent's* handle on a child it summoned.
  Allocated by the parent. It is the bus correlation id (see below) and the only
  id that travels on the bus.
- **entity id `E`** — the *execution unit's* identity, used for ownership and the
  tree. **A distinct id from `D`.** It is **minted by the receiving side when it
  processes the `delegate`** (paired with the `D` it received), and is kept
  **off the bus** (server-side only).

Every entity below the top is summoned by a delegation, so the tree is uniform:

- The **project-root entity** is the one true root — summoned by nobody
  (`delegation_id = null`, synthetic `E`), created with the project.
- The **run-root entity** is a proper child of the project root: at `startRun`
  the project-root entity **issues a delegation `D_run`** to summon it, and the
  API mints `E_run` as the receiver (`delegation_id = D_run`, `parent =
  project-root`). The run-root then issues its own delegation `D_core` to summon
  the CORE root and collects its `delegateAck`.
- **CORE / FFI entities** are summoned by their issuer's delegation as usual.

So every entity row carries both its own `id = E` and the `delegation_id = D`
that summoned it (`null` only for the project root). The bus speaks `D`; the server maps `D → E` (`entities WHERE
delegation_id = D`); ownership speaks `E`.

> **v0.2 evolution (untrusted multi-server):** `E` is already minted by its home
> (receiving) server — so the only thing v0.2 adds is the ownership-ascent
> *handshake* for the untrusted case: the child issues a transfer-request id,
> binds it to its refs, hands `(D, transfer-request id)` to the parent, and the
> parent presents `(transfer-request id, its own E)` to the ref-authority, which
> elevates ownership. The model below evolves to this *additively*; v0.1.0
> trusts the server resolving `D → issuing E` directly.

### The bus does not change

The 6 events stay exactly as today; they already form a request-reply protocol
(the `*Ack` events are the replies, correlated by id). **The entity id never
travels on the bus.**

| event           | id carried                      | direction | role |
|-----------------|----------------------------------|-----------|------|
| `delegate`      | `D`                             | parent→child | parent's summon handle |
| `delegateAck`   | `D`                             | child→parent | reply, matched by `D` |
| `terminate`     | `D`                             | parent→child | cancel by the parent's handle |
| `terminateAck`  | `D`                             | child→parent | reply |
| `escalate`      | `D` (escalator's) + `escalationId` | child→ancestor | routes up; `escalationId` correlates the reply |
| `escalateAck`   | `escalationId`                  | ancestor→child | reply |

The parent manages a child entirely through `D` (its own handle) — it never
needs the child's `E`. The server keeps the `D → E` mapping (on the receiving
side's entity row), so bus routing (`terminate`/`escalate` by `D`) resolves to
the entity without `E` ever crossing the wire.

### Ownership ascent = value-driven detach / claim (Option 2)

The hard constraint: **the child never learns its parent's `E`** — `E` is off-bus,
and the child must not read the issuer's (another server's) `delegations` row.
The insight that makes ascent need no holding owner at all: **the result value
the child returns already carries the escaping ref handles `{module,id}`, and it
travels to the parent on the bus.** So the parent can claim those exact refs by
id — it doesn't have to look them up, and nothing has to "hold" them but a brief
unowned state. **A ref is owned only ever by an Entity** (a delegation is a
request edge, never an owner):

1. A child produces refs owned by its own entity `E_child` (it knows `E_child`).
2. On terminal, the child **detaches** its **escaping** refs (the `delegateAck`
   value's, transitively via `refs_to`) — `owner_entity_id := NULL` (in-transit,
   owned by nobody) — then self-deletes `E_child`; the non-escaping refs cascade
   away, the detached ones survive. The child looked up no parent and no one
   else (a strict improvement over even a `getParent` call).
3. The parent, on the result ack, already **holds the value** — so it **claims**
   exactly the refs in `collectRefs(value)` (transitively via `refs_to`) by id,
   `owner_entity_id := E_parent` (its OWN entity, known locally), then deletes
   the delegation `D`. The parent queried no one either.

No entity id ever crosses the bus or a server boundary; each side touches only
its own `E` and the ref ids it already has. `owner_entity_id IS NULL` is the
brief (sub-second) in-transit window; because the FK forbids a ref pointing at a
non-existent entity, NULL is the *only* orphan shape, reaped by the boot sweep (a
while-live NULL sweep would wrongly catch in-transit refs, so it is never run).

Because the **run-root entity is the CORE root's parent**, the escaping refs
detach from the (ephemeral) CORE root `E_core` and the API claims them to the
persistent `E_run` on `delegateAck` — there is no special "API boundary / last
hop". Persistence is simply *being claimed by a persistent entity*.

> **v0.2 evolution (untrusted multi-server):** the only thing the untrusted case
> adds is provenance on the claim — a child can't be trusted to have detached
> only its own refs, so it binds the escaping set to a transfer-request id it
> hands the parent alongside the value, and the parent presents `(transfer-request
> id, its own E)` to the ref-authority. Additive on top of the model above (in
> v0.1.0 the trusted server claims the value's ids directly).

## 3. The concepts

### Project
The top-level deploy unit (one project = one app).

- **Data:** `id`, `name`, `description`, `readme`, `created_at`.
- **Owns (CASCADE on project delete):** the project-root entity, snapshots, env
  entries — everything project-scoped. (Deleting a project is intentionally
  destructive; projects are essentially never deleted in normal operation.)

### Entity (`entities`) — the execution node
The ownership/cascade node. It is the *execution node* (the delegation is the
*request edge*; §3 Delegation). (The run's persistent trajectory is NOT folded in
here — it stays as the API's separate **Run** record; see below.)

- **Data — only what the receiver knows from the bus event + ambient context**
  (no field requires reading the issuer's, i.e. another server's, tables):
  - `id` (= `E`, minted by the receiving side; a synthetic id for the project root)
  - `delegation_id` (= the summoning `D`, taken from the bus; `null` only for the
    project root). The `D → E` back-link for bus routing.
  - `project_id` (ambient — the receiver runs per-project)
  - `module`: `core | ffi | api | env` — the module that *runs* this entity
    (self). This is the katari-protocol concept (the 4 endpoints); there is no
    protocol "kind". `project_root` / `run_root` are just `module = api` entities
    the API issues + manages; agents run on `core`, ext calls on `ffi`, env
    builtins (`get_env` / `set_env` / …) on `env`.
  - `state`: `running | cancelling` — the ONLY entity states. (`done` / `error`
    are NOT entity states, and there is no `lifecycle` field. "Persistence" is
    just behaviour: an entity self-deletes on terminal; the API keeps its own
    entities — the project / run roots — so they survive a child's terminal.)
  - `agent_def_id`, `args` (from the bus; null for the project root)
  - timestamps

  **No `parent_entity_id` / `root_entity_id`** — the parent's `E` is off-bus and
  the receiver must not read the issuer's `delegations` row to learn it (a
  cross-server read). The parent link lives on the issuer-side `delegations` row
  (`parent_entity_id` = the issuer's OWN `E`); the tree is reconstructed by
  joining `entities.delegation_id ↔ delegations.id`, and "all entities under a
  run" is a local recursive walk done aggregator-side (not on any hot path). Run
  bookkeeping (`name` / `result` / the richer state) lives in the **Run** record.
- **Owns (CASCADE):** its `refs` (`owner_entity_id`) and `escalations`
  (`entity_id`) — local, same-server FKs. Deleting an entity drops its still-owned
  refs (→ blob refcount−−) and its raised escalations.

> **Note — there is no cross-entity cascade; teardown is protocol-driven.** An
> entity does NOT FK-link to its parent entity (that link is off-server), so
> deleting a parent does not DB-cascade its children. The *ideal* deletion is
> bottom-up over the bus: the parent sends `terminate`; the child cancels its own
> children, detaches its escaping refs, **self-deletes its own entity** (dropping
> its remaining refs + escalations by the local FK cascade), and replies
> `terminateAck`. Each entity tears *itself* down — which is exactly what
> multi-server requires (a child lives on its own server). The crash / orphan
> backstop is the boot sweep (detached `owner=NULL` refs; entities whose run is
> gone); a project delete cascades the whole project by `project_id`.
- **By module** (`module` is protocol-level; the API's two roles are just where
  `module = api` shows up):
  - **`api`, project-root role** — one per project; `delegation_id = null` (the
    one entity summoned by nobody); owns user-uploaded files; kept by the API
    (cascade-deleted only with the project).
  - **`api`, run-root role** — one per `run`; `delegation_id = D_run`
    (project-root issues it at `startRun`); claims the run's result refs
    (escalations are owned by their *raisers*, not here); itself issues the
    `D_core` delegation to the CORE root, and the API attaches a **Run** record (+
    escalations-audit) to it. Kept by the API (the run history). (project-root vs
    run-root: the project root has `delegation_id = null`; a run root's delegation
    has `parent_entity_id = ` the project root.)
  - **`core` / `ffi` / `env`** — one per agent / ext / env-builtin invocation;
    its issuing delegation's `parent_entity_id` is the issuer; owns intermediate
    refs; **self-deletes on terminal** (no replay, no retention) → its
    non-escaping refs cascade away (escaping ones were already detached + claimed
    by the parent).

### Delegation (`delegations`) — the parent-side request record
A delegation is a **separate, persistent record managed by the issuer (parent)**,
NOT a transient side-channel and NOT folded into the entity row. It is the
*request edge*; the entity is the *execution node*. They have **distinct owners
and distinct (overlapping) lifetimes**:

| record         | created by         | created when                    | deleted by         | deleted when                  |
|----------------|--------------------|---------------------------------|--------------------|-------------------------------|
| **delegation** `D` | issuer (parent) | processing is **requested** (`delegate` emit) | issuer (parent) | the **result is received** (`delegateAck` / `terminateAck`) |
| **entity** `E`     | receiver (child) | processing **begins** (the `delegate` is processed → `E` is minted) | receiver (child) | processing **completes** (terminal) |

So the lifetimes nest: **delegation ⊇ entity** — the request is born first and
dies last; the entity lives strictly inside that window. Concretely:

- **Issuer at emit:** allocate `D`, INSERT a `delegations` row (`parent_entity_id`
  = the issuer's own `E` — known locally; `target_module`, `agent_def_id`,
  `args`, `state = running`), then push `delegate(D)` on the bus.
- **Receiver at delegate-receipt:** **mint `E`** and INSERT its own `entities` row
  from the **bus event + ambient context alone** (`delegation_id = D`,
  `module = self`, `agent_def_id` / `args` from the event). It does **not** read
  the issuer's `delegations(D)` row (that would cross the server boundary) — it
  never needs the parent's `E`.
- **Receiver on terminal:** detach its escaping refs, **delete only its own
  `entities` row** (its remaining refs + raised escalations cascade), then emit
  the ack. It does **not** delete the `delegations` row.
- **Issuer on ack-receipt:** claim the result value's refs to its own `E`, then
  DELETE the `delegations(D)` row (the request is fulfilled). *The receiver
  deletes only entities; the issuer deletes the delegation.*

`delegations.id = D` is the bus correlation handle; `entities.delegation_id = D`
is the back-link the server uses to resolve **bus `D` → executing `E`** (route a
`terminate`/`escalate`). The parent link is on the `delegations` row
(`parent_entity_id`, issuer-side); the receiver's entity carries no parent —
ascent is value-driven (§2), so the receiver never reads across the boundary.

The **run-root** follows the same shape: the run-root entity issues the
`delegations` row `D_core` (`parent_entity_id = E_run`) and pushes
`delegate(D_core)`; CORE mints `E_core` and creates its entity; on completion
CORE deletes only `E_core`; the API (issuer of `D_core`) deletes `D_core` on
`delegateAck`. (The run-root entity itself is summoned by the project-root via
its own `D_run`, created inline by the API at `startRun`.)

### Escalation (`escalations`) — owned by the *raiser*
A capability request raised **by** an entity. **It belongs to the raiser**, not
to whoever handles it: the raiser is the subject and holds the *delete*
authority; an ancestor merely holds the *answer* authority.

- **Data:** `id` (= `escalationId`), `entity_id` (= the **raising** entity), the
  requested `agent_def_id` (the capability / `request` being asked — the same
  slot a `delegate` uses for its target; NOT a separate "request id"), `args`,
  `created_at`. **`state` is only `open`** — there is no stored `answered` /
  `cancelled`; both are terminal = the row is deleted (mirrors the entity's
  `running|cancelling`). No `handler` field: who catches it is resolved by
  routing (could be an in-CORE `handle` block midway, or the API at the top) and
  is transient.
- **Parent (CASCADE):** `entity_id → entities(id) ON DELETE CASCADE` — an
  escalation dies with the entity that raised it (so cancel = the raiser is
  terminated → its open escalations cascade away).
- **Teardown (protocol, not cascade):** the raiser `C` raises an escalation it
  owns → it routes up to a handler → the handler answers (`escalateAck`) → `C`
  observes the ack and **deletes its own escalation**. (Same self-teardown
  principle as entities; the handler only answered.) The handler must NOT assume
  it is the run-root — that is exactly why ownership sits on the raiser.
- **Persistence is the run's job, not the escalation's:** when a *user-facing*
  (API-handled) escalation is answered, the **Run** records it in its
  escalations-audit (§ Run) — the question + answer + any file args persisted at
  that point. In-CORE-`handle`-caught escalations are internal control flow and
  are not audited. So: live `escalations` = open only (raiser-owned), and the
  history lives under the run (`run → escalations-audit`).

> **Differs from today's code by one hop:** the current `recordEscalation` keeps
> the escalation on the *receiver* (API) side. In this model the *raiser* (a
> CORE entity) owns the live escalation; the API only answers + writes the run's
> escalations-audit.

### Ref (`refs`) — a blob handle owned by an Entity
Unifies the old `value_refs` and `api_files`: there is one ref table, and **a
ref lives exactly as long as its owner entity** (so it persists iff its owner is
one the API keeps — a project / run root).

- **Data:** `id`, `owner_entity_id`, `project_id`, `module` (produce origin:
  `core | ffi | api`, kept for wire/data-plane compatibility), `semantic_kind`
  (`string | file | secret | closure`), `origin` (`user | run | escalation |
  intermediate` — for display/filtering; derivable from the owner's kind),
  `hash`, `size`, `content_type`, `display_name` (the human file name — see
  below), `refs_to` (the refs a closure captures, for the upward drag),
  `created_at`.
- **The file *name* lives on the ref, never on the blob.** A blob is
  content-addressed (keyed by `hash`) and therefore **nameless and deduped** —
  two identical uploads collapse to one blob. The user-facing name (the original
  upload filename) is `refs.display_name`, ref-local metadata: the same blob can
  back two refs with two different names. Program-produced intermediates
  (`string_to_file`) have no name (`origin = intermediate`, `display_name` null).
  Names are a presentation concern only — the runtime `file` value (`RefRep`)
  carries no name; the data-plane uses `display_name` for `Content-Disposition`.
- **Owner (CASCADE):** `owner_entity_id → entities(id) ON DELETE CASCADE`.
  Deleting an entity drops its still-owned refs (→ blob refcount−−). A ref is
  owned by exactly one entity, or transiently by no one (`NULL`) mid-ascent — a
  delegation never owns a ref.
- **Ascent (value-driven, §2):** on the owner's terminal the escaping refs
  (transitively via `refs_to`) are **detached** (`owner_entity_id := NULL`) and
  the rest cascade away with the entity row; the parent then **claims** the
  result value's refs by id to its own entity. No holding owner, no parent
  lookup.
- **Wire form unchanged:** a value still carries `{$ref: {module, id}, as, hash,
  size}`; only the *ownership* layer is entity-based. `module = api` =
  owned by an API entity the API keeps (project-root upload, run result).
- **Closures persist for free** (no special case): a closure ref ascends like
  any ref, and the `refs_to` drag carries its captured refs with it in both the
  detach and the claim (the `owner(capture) ≥ owner(closure)` invariant). So when
  a closure escapes to a kept entity (the run-root), the whole closure DAG ends up
  owned there and persists. The closure blob is **not rewritten** — it is content-addressed, and
  its captures remain refs owned by the same entity, so they still resolve when
  the blob is later materialized (the persisted closure even stays invocable).
  (A captured `secret` persists AES-GCM-encrypted in the blob, as at any rest.)

### Blob (`value_blobs` + BlobStore)
Project-wide, content-addressed bytes — the dedup + freeing unit, keyed by
`hash`. **Nameless** (a name is ref metadata, never blob metadata — see Ref). NOT
part of the entity cascade; freed by refcount.

- **Data (ledger):** `project_id`, `hash`, `total_size`, `ref_count`, timestamps.
  The bytes live in a pluggable `BlobStore` (local FS / S3), keyed by hash.
- **Refcount:** number of refs (any entity) pointing at the hash. Freed
  (BlobStore delete) at 0. Content-addressed ⇒ dedup across refs/entities.

### Run — the API module's management record (NOT an entity state)
The API module manages, alongside each run-root entity, a **Run** record — its
own bookkeeping of a run's trajectory. This is deliberately separate from the
entity layer:

- The **run-root entity's** own (protocol) state is just `running | cancelling`,
  like any entity.
- The **Run's** state is `running | cancelling | done | error`, and it **does
  NOT reflect the run-root entity's own state — it reflects the state of its
  child, the CORE root delegation**: `done` when that child returns its
  `delegateAck`, `error` when it throws, `cancelling` while a cancel cascades.
- **Data:** the Run state above, `name`, `qualified_name`, `args`, `result`,
  `error_message`, `cancel_reason`, `completed_at`, `snapshot_id`, plus the
  run-root `entity_id` it tracks. (≈ today's `runs_audit`.)
- 1:1 with its run-root entity (which owns the result refs). The operator's
  "Runs" list = these records. They are what gives a finished run its visible
  `done` / `error` outcome even though no entity carries those states.
- **escalations-audit:** the Run also keeps the history of the run's *answered,
  user-facing* escalations (`run → escalations-audit`): the question
  (`agent_def_id` + args), the answer, and any file args persisted at answer
  time (owned by the run-root entity). Live `escalations` are raiser-owned and
  `open`-only; this audit is where answered ones live on. (In-CORE-handled
  escalations are internal control flow and are not audited.)

## 4. Cascade-delete summary

There is **no cross-entity cascade** (the parent link is off-server). Each entity
cascades only its OWN local children — refs + escalations:

```
entity ─(CASCADE)→ refs        (owner_entity_id)
       └(CASCADE)→ escalations (entity_id)
project ─(CASCADE)→ entities, delegations, refs, escalations, runs,
                    snapshots, env_entries, …  (everything by project_id)
value_blobs / BlobStore: refcounted (trigger on refs delete), freed at 0
```

- Delete a **CORE/FFI entity** (terminal self-delete) → its non-escaping refs +
  raised escalations cascade; escaping refs were already detached (`owner=NULL`)
  and are claimed by the parent from the result value. Child entities are NOT
  cascaded — they self-deleted bottom-up first (or are boot-swept).
- Delete a **run-root entity** (prune a run) → its claimed result refs cascade,
  and the Run record + escalations-audit go with it; blobs drop at refcount 0.
- Delete the **project** → the whole project's entities / delegations / refs /
  escalations / runs cascade by `project_id` (uploads included).

(These are the FK *integrity* relationships. Normal teardown is the protocol's
bottom-up self-delete (§3 NOTE); the cascade + boot sweep of detached `owner=NULL`
refs is the crash backstop.)

## 5. What this resolves

- **No "last hop / API boundary" special case** — the run-root is just the CORE
  root's parent; ownership rises there by the one ascent rule.
- **No ephemeral table holding permanent rows** — a ref lives as long as its
  owner entity; it persists because the API keeps that owner (a project / run
  root), not because of a special table or a `lifecycle` flag.
- **Escalations are raiser-owned** (delete authority on the raiser, answer
  authority on the handler) — so a handler caught midway never has to be the
  run-root. Cancelled escalations are not retained (they cascade with their
  raiser); answered *user-facing* ones persist in the run's escalations-audit.
- **Drop is mostly FK cascade**; the explicit GC code shrinks to "detach escaping
  refs + claim from the result value + boot-sweep detached (`owner=NULL`) refs".
  The FK makes a "dead owner" impossible, so the old free-form-owner reconcile is
  gone.
- **Bus is untouched**; entity ids stay server-side; the design evolves to the
  untrusted-multi-server handshake additively (Option 2).

## 6. Migration (pre-release, wipe + re-migrate)

- `delegations` is **kept** (issuer-managed request record, current lifecycle:
  created at emit, deleted at ack) but recast to entity ids: `parent_delegation_id`
  → `parent_entity_id`, `root_delegation_id` → `root_entity_id`, `owner_endpoint`
  → `target_module`; state stays `running | cancelling`.
- `entities` is **added** (receiver-managed execution node: created at delegate-
  receipt with a freshly minted `E`, deleted at terminal). Carries only
  bus/ambient data — `delegation_id` (back-link for `D → E` routing), `module`,
  `state`, `agent_def_id`, `args`. **No `parent_entity_id` / `root_entity_id`**
  (off-server; the parent link is on the `delegations` row). Refs/escalations hang
  off `E`. (delegation and entity are TWO records with distinct owners + nested
  lifetimes — see §3.)
- `runs_audit` → the **Run** record (the API's per-run management state
  `running | cancelling | done | error` reflecting the CORE-root child, +
  name/result/…), 1:1 with a run-root entity. Stays a distinct API table.
- `value_refs` + `api_files` → one `refs` (owner_entity_id, semantic_kind,
  origin).
- `escalations` → live, **raiser-owned**: `entity_id` = the raising entity,
  `state = open` only (deleted on answer/cancel; no stored answered/cancelled).
  The run keeps a separate **escalations-audit** for answered *user-facing* ones.
  (Today's receiver-side `recordEscalation` moves to: raiser owns the live row;
  API answers + writes the audit.)
- CoreModule: a shard *is* an entity; `shardId = E` (minted when the shard's
  `delegate` is processed; the summoning `D` is stored as `delegation_id`, and
  routing resolves bus `D → E`). On terminal the shard detaches its escaping refs
  (`owner=NULL`) and self-deletes its entity (no parent lookup); the parent
  claims the result value's refs on the ack. The run-root + project-root entities
  are created/kept by the API module (which also owns the Run records).
- value-store ownership API recast: `detachRefs(fromEntity, seed)` +
  `claimRefs(toEntity, seed)` + boot `sweepDetachedRefs()` replace the old
  `releaseOwner` / `transferOwnership` / `sweepRefsWithDeadOwners`; most of the
  old drop logic becomes FK cascade + the refcount trigger.
