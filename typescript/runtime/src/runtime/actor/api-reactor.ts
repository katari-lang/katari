// ApiReactor: the api-side management instances' participation in the external-event world — the
// user-facing bridge. It manages two kinds of `api` instance:
//
//   - The permanent *api root* (one per project, id = the project id): the owner of project-scoped
//     resources (uploaded file blobs). It issues nothing and belongs to no run.
//   - One permanent *run instance* per run: the run's identity (`runs.id` IS its instance id) and the
//     durable node the run's world hangs off. It issues the run's `delegate` (so it is the caller the
//     delegation row names), receives the replies (delegateAck -> the run finished, escalate -> an open
//     escalation or a run failure, terminateAck -> cancelled), and OWNS the resources the run's result
//     ascends (scopes / blobs reown onto it, not onto the root) — so a future run deletion is one instance
//     drop whose cascade reclaims the run's record, trace, and resources together. Unlike an execution
//     instance it is NOT dropped at the run's terminal; its envelope `status` stays `running` (the run's
//     real lifecycle lives on `runs.state`).
//
// Commands originate *outside* the substrate's react loop (a façade / test calls them), so each enqueues a
// serial command thunk on the bus: the mutation (open / cancel / answer) and its `send` run inside a normal
// serial turn, committed atomically like any reaction. The in-process `result` promise's resolvers are
// captured synchronously (so a fast run cannot settle before they exist); the durable outcome is the `runs`
// row — the promise is only an in-process notification hook. The core engine never appears here, and this
// never drives an engine turn.

import type { QualifiedName } from "@katari-lang/types";
import { PANIC_REQUEST } from "../engine/common.js";
import { dispatchCallable } from "../engine/dynamic-dispatch.js";
import { THROW_REQUEST } from "../engine/throw-signal.js";
import type { BlobEntry } from "../engine/types.js";
import { isFailureRequest, isUserFacingRequest } from "../escalation-filter.js";
import { type ExternalEvent, escalateValue, type ReactorName } from "../event/types.js";
import {
  type BlobId,
  type DelegationId,
  type EscalationId,
  type InstanceId,
  newDelegationId,
  newInstanceId,
  type ProjectId,
  type SnapshotId,
} from "../ids.js";
import { valueToJson } from "../value/codec.js";
import { isTainted, markPrivate } from "../value/privacy.js";
import type { Value } from "../value/types.js";
import { messageOf } from "./failure.js";
import type {
  Loader,
  PersistedExclusiveTask,
  PersistedRun,
  PersistedRunEscalationAudit,
  PersistedRunOutcome,
  PersistenceTx,
} from "./persistence.js";
import { type AckContext, Reactor } from "./reactor.js";
import type { ResourcePool } from "./resource-pool.js";
import {
  answerStoreRequest,
  isExclusiveRequest,
  isStoreRequest,
  type StoreRows,
} from "./store-responder.js";

/** The parameter record every serial-domain task is called with: `store.exclusive`'s `task` is typed
 *  `agent (value: null) -> unknown`, so it receives `{ value: null }` (the same by-name parameter convention
 *  region's continuation `{ value: nursery }` and fork's `{ input: ... }` use). */
const EXCLUSIVE_TASK_INPUT: Value = { kind: "record", fields: { value: { kind: "null" } } };

/** One run-root request the engine could not handle internally, awaiting a user's answer. */
export interface OpenEscalation {
  escalation: EscalationId;
  request: QualifiedName;
  argument: Value | null;
}

/** Why a run's `result` promise rejected: it was cancelled (vs failed). Lets the run layer settle the
 *  durable run record as `cancelled` rather than `error`. */
export class RunCancelledError extends Error {
  constructor(public readonly reason?: string) {
    super(reason !== undefined ? `run cancelled: ${reason}` : "run cancelled");
    this.name = "RunCancelledError";
  }
}

/** How the api reactor schedules a command (start / cancel / answer) onto the substrate's serial loop: the
 *  thunk runs inside a normal turn (after the project is loaded) and its mutations + `send` commit atomically.
 *  The returned promise settles after that turn commits. */
export interface CommandSink {
  enqueue(thunk: () => void | Promise<void>): Promise<void>;
}

export class ApiReactor extends Reactor {
  readonly name: ReactorName = "api";

  /** The in-process run-result *notification hook* (NOT the source of truth — a run's outcome is its durable
   *  `runs` row, read by projection). Keyed by the run's id (its run instance id). It lets an in-process
   *  caller `await` a run it started: a delegateAck resolves it, a panic / unhandled escape rejects it, a
   *  terminate (cancel) rejects it with `RunCancelledError`. Absent for a recovered run (no in-process
   *  caller is awaiting it). */
  private readonly runResolvers: Record<InstanceId, (value: Value) => void> = {};
  private readonly runRejecters: Record<InstanceId, (error: Error) => void> = {};
  /** Run-root requests the engine could not handle, kept open (their run-root instance stays suspended)
   *  until a user answers. The durable escalation row is owned by core (the raiser); this is the answering
   *  projection, rehydrated on recovery from core's user-facing open escalations. `delegation` routes the
   *  `escalateAck` back down; `run` attributes the audit row (and cleans up on the run's settle). */
  private readonly openEscalations: Record<
    EscalationId,
    OpenEscalation & { run: InstanceId; delegation: DelegationId }
  > = {};
  /** A cancelling run's reason — held only to decorate the in-process `RunCancelledError` (the durable
   *  reason is `runs.cancelReason`). Kept only while the run is tracked in-process, so it cannot leak. */
  private readonly cancelReasons: Record<InstanceId, string | undefined> = {};
  /** This turn's `runs`-table writes — the api root owns the metadata sidecar (it persists them atomically
   *  with the run's `delegate` / `terminate` / `escalateAck`, so the API never sees a run without metadata).
   *  Flushed and cleared by `persist`. */
  private pendingRunStarts: PersistedRun[] = [];
  /** This turn's run state / outcome updates — the durable SoT for a run's outcome (the run delegation row is
   *  deleted on terminal). Written to `runs` in `persist`. */
  private pendingRunOutcomes: PersistedRunOutcome[] = [];
  private pendingAudits: PersistedRunEscalationAudit[] = [];

  // ─── serial domain (root-served `store.exclusive`) ────────────────────────────────────────────────
  //
  // The runtime serves the OUTERMOST serial domain (the root workspace) when no `serialize` / `workspace`
  // handler in the program catches an `exclusive`: it runs the task closure as a critical section of a
  // PROJECT-WIDE durable FIFO — at most one task runs at a time across the whole project (the root domain's
  // permanent semantics; a per-workspace domain is a future additive API). A task is a `core` delegate ISSUED
  // BY THE API ROOT (not the run instance), so its own `get` / `set` / `delete` / `list` escalations reach the
  // api root and are machine-answered by the store branch unchanged (routing is by delegation id). The durable
  // `run_exclusive_tasks` queue is the source of truth — a completed critical section must never be blind
  // re-driven like a `store.get` (it would double its writes) — so recovery rebuilds this warm state from it.

  /** The FIFO, keyed by escalation, in arrival order (a Map iterates insertion order, which IS the order;
   *  reloaded in `seq` order). Every queued / running task lives here until it settles or its run is torn down. */
  private readonly exclusiveTasks: Map<EscalationId, PersistedExclusiveTask> = new Map();
  /** The running task's `core` delegate → its escalation, so an ack / failure escalate reaching the api root is
   *  recognised as a TASK's (its run is NOT settled by it) rather than a run's. */
  private readonly exclusiveTaskDelegations: Map<DelegationId, EscalationId> = new Map();
  /** Task delegates whose run has terminated: we terminated the task (a child of the api root, outside the
   *  run's subtree), so its eventual ack — a raced `delegateAck`, or the teardown `terminateAck` — is dropped
   *  (the escalation is never answered; its raiser cascaded with the run). */
  private readonly abandonedTaskDelegations: Set<DelegationId> = new Set();
  /** Task delegates whose ack `onDelegateAck` / `onTerminateAck` handled this batch — consulted (and cleared)
   *  by `afterCommit` to suppress the run-promise settlement its kind would otherwise trigger (a task's result
   *  is not the run's terminal). Warm-only; a poisoned batch clears it, and a replay re-adds it. */
  private readonly settledTaskAcks: Set<DelegationId> = new Set();
  /** This turn's `run_exclusive_tasks` writes, flushed by `persist`: enqueues (as queued), queued → running
   *  delegate stamps, and deletes. Disjoint per escalation within a turn (an enqueue never also deletes). */
  private pendingExclusiveInserts: PersistedExclusiveTask[] = [];
  private pendingExclusiveDelegations: Array<{
    escalation: EscalationId;
    taskDelegation: DelegationId;
  }> = [];
  private pendingExclusiveDeletes: EscalationId[] = [];

  constructor(
    private readonly apiRootId: InstanceId,
    private readonly commands: CommandSink,
    pool: ResourcePool,
    /** The project whose durable rows a machine-answered `prelude.store.*` escalation reads / writes. */
    private readonly projectId: ProjectId,
    /** The durable KV rows the runtime answers an unhandled `prelude.store.*` request against. */
    private readonly storeRows: StoreRows,
  ) {
    super(pool);
  }

  /** The api reactor runs no engine threads — its turn writes the instance envelopes it staged (the root's
   *  idempotent upsert + any run instance created this turn), the run delegations those instances own, and
   *  the run-metadata / audit rows it staged (so they commit atomically with the events it produced). The
   *  base's FK order does the rest: envelopes flush before the delegation rows whose caller FK points at a
   *  run instance, and `putRun` runs after `persistBase`, so the `runs` row's FK to its instance is
   *  satisfied within the same commit. */
  async persist(tx: PersistenceTx): Promise<void> {
    // Always stage the api root's envelope (an idempotent upsert), so the generic half is present before any
    // FK that points at it — a file-upload blob's owner. The root is summoned by nobody and belongs to no
    // single run, so both ambients are `null`. Run instances are staged by `startRun`'s command turn, not
    // here — their envelopes are immutable after creation.
    this.markInstance(this.apiRootId, {
      delegationId: null,
      callerReactor: null,
      runId: null,
      status: "running",
    });
    await this.persistBase(tx.base);
    // The run launch row first (a later outcome update targets it, and its `id` FK needs the run instance
    // envelope persistBase just wrote); then this turn's state / outcome updates (the durable SoT, since the
    // run delegation row was just deleted by the base on its terminal). A cancel's reason rides on its
    // `cancelling` outcome, so the cancel is one UPDATE, not two.
    for (const run of this.pendingRunStarts) await tx.api.putRun(run);
    for (const outcome of this.pendingRunOutcomes) await tx.api.setRunOutcome(outcome);
    for (const audit of this.pendingAudits) await tx.api.putRunEscalationAudit(audit);
    // The serial-domain queue, in dependency order: enqueue rows first (as queued), then the queued → running
    // delegate stamps (an enqueue that spawned in the same turn writes the row then stamps it), then deletes.
    for (const task of this.pendingExclusiveInserts) await tx.api.putExclusiveTask(task);
    for (const update of this.pendingExclusiveDelegations)
      await tx.api.setExclusiveTaskDelegation(update.escalation, update.taskDelegation);
    for (const escalation of this.pendingExclusiveDeletes)
      await tx.api.deleteExclusiveTask(escalation);
    this.pendingRunStarts = [];
    this.pendingRunOutcomes = [];
    this.pendingAudits = [];
    this.pendingExclusiveInserts = [];
    this.pendingExclusiveDelegations = [];
    this.pendingExclusiveDeletes = [];
  }

  /** Drop the api root's durable-derived warm state so reactivation rebuilds it (idempotent — safe on a cold
   *  start, where these are already empty). Does NOT touch the in-process run-result promises: those are
   *  registered synchronously by `startRun` *before* the first reactivation, so clearing them here would
   *  orphan a freshly-started run. They are handled only on a poison, by `poisonRunPromises`. */
  reset(): void {
    super.reset();
    for (const key of Object.keys(this.openEscalations)) {
      delete this.openEscalations[key as EscalationId];
    }
    for (const key of Object.keys(this.cancelReasons)) delete this.cancelReasons[key as InstanceId];
    this.pendingRunStarts = [];
    this.pendingRunOutcomes = [];
    this.pendingAudits = [];
    // Serial-domain warm state is rebuilt from `run_exclusive_tasks` on the next `load`, so drop it here.
    this.exclusiveTasks.clear();
    this.exclusiveTaskDelegations.clear();
    this.abandonedTaskDelegations.clear();
    this.settledTaskAcks.clear();
    this.pendingExclusiveInserts = [];
    this.pendingExclusiveDelegations = [];
    this.pendingExclusiveDeletes = [];
  }

  /** Register a freshly uploaded file as an api-root-owned blob (its bytes already in the BlobStore). Owned
   *  by the api root, it is retained until an explicit user delete — never reclaimed by GC. Resolves when the
   *  blob row is durably committed (the pool flushes it in the same turn, after `persist` has ensured the api
   *  root's envelope the blob's owner FK points at). */
  registerUploadedBlob(blobId: BlobId, entry: Omit<BlobEntry, "owner">): Promise<void> {
    return this.commands.enqueue(() => {
      this.pool.registerBlob(blobId, { owner: this.apiRootId, ...entry });
    });
  }

  /** Delete an uploaded file on the user's explicit request: free its api-root-owned blob row this turn (the
   *  bytes are deleted from the `BlobStore` strictly after the commit, by the substrate). Resolves once the
   *  delete commit is durable — to whether the blob existed as a file (`false` for an unknown id, or for a
   *  blob owned by an engine instance, which is not a file and is reclaimed by its owner's lifecycle). */
  deleteUploadedBlob(blobId: BlobId): Promise<boolean> {
    let deleted = false;
    return this.commands
      .enqueue(() => {
        deleted = this.pool.deleteBlobOwnedBy(blobId, this.apiRootId);
      })
      .then(() => deleted);
  }

  /** Reject and drop every in-process run-result promise after a poisoned commit: the run continues durably
   *  and the API reads its outcome by projection, but this non-SoT notification hook cannot survive the
   *  reactivation, so its caller is told to re-query rather than left hanging. */
  poisonRunPromises(error: Error): void {
    for (const reject of Object.values(this.runRejecters)) reject(error);
    for (const key of Object.keys(this.runResolvers)) delete this.runResolvers[key as InstanceId];
    for (const key of Object.keys(this.runRejecters)) delete this.runRejecters[key as InstanceId];
  }

  // ─── commands (the api root issuing external events on a user's behalf) ─────────────────────────

  /** Start a run: mint its permanent run instance (whose id IS the run's id), record its `runs` metadata
   *  extension, and summon a core root for `qualifiedName@snapshot` — the instance envelope, the `runs` row,
   *  the run delegation and its `delegate` all land in one commit (so the API never sees a run without its
   *  metadata, nor vice versa). Returns the run id, an in-process `result` promise (a non-SoT notification
   *  hook), and `started` — which resolves once the launch commit is durable (the façade awaits it so a
   *  just-returned run is immediately visible). The resolvers are captured now so a fast run cannot settle
   *  before they exist. */
  startRun(
    qualifiedName: QualifiedName,
    snapshot: SnapshotId,
    argument: Value | null,
    name: string,
  ): { run: InstanceId; result: Promise<Value>; started: Promise<void> } {
    const run = newInstanceId();
    const delegation = newDelegationId();
    const result = new Promise<Value>((resolve, reject) => {
      this.runResolvers[run] = resolve;
      this.runRejecters[run] = reject;
    });
    const started = this.commands.enqueue(() => {
      // The run instance: permanent (never dropped at the run's terminal), summoned by nobody (both routing
      // ambients null), and its own trace root (`runId` = itself). Its envelope is immutable after this turn.
      this.markInstance(run, {
        delegationId: null,
        callerReactor: null,
        runId: run,
        status: "running",
      });
      // The run's metadata extension (`runs`, keyed by the instance id) rides in the same commit.
      this.pendingRunStarts.push({
        run,
        name,
        qualifiedName,
        snapshotId: snapshot,
        argument,
      });
      // The api reactor only ever talks to core (a run is a delegate to a core instance), so it stamps `to`
      // here. The delegation is issued by (caller-owned by) the run instance — the base opens the row from
      // this send — and the delegate seeds the run's trace: every event in its causal tree inherits `run`.
      this.send(
        {
          kind: "delegate",
          delegation,
          target: { kind: "named", name: qualifiedName, snapshot },
          argument,
          from: this.name,
          to: "core",
          run,
        },
        run,
      );
    });
    return { run, result, started };
  }

  /** The run's single live delegation (a run instance issues exactly one), or `undefined` once the run is
   *  terminal (the row is retired with the outcome). Read from the base's caller-owned rows, so it survives
   *  recovery (loadBase reloads them) without any run-local bookkeeping. */
  private liveRunDelegation(run: InstanceId): DelegationId | undefined {
    return this.issuedDelegationsOf(run)[0]?.delegation;
  }

  /** Request a run's cancellation: move it to `cancelling`, record the cancel reason on its `runs` row, and
   *  terminate its root — all in one commit. The cascade tears the tree down; the terminateAck retires the
   *  delegation and rejects the run with `RunCancelledError`. Always produce the terminate (so a recovered,
   *  still-live run is cancellable). The in-process reason (to decorate the error) is kept only while the run
   *  is tracked here, so it cannot leak. Returns when the cancel commit is durable. */
  cancelRun(run: InstanceId, reason?: string): Promise<void> {
    return this.commands.enqueue(() => {
      // A run that already reached a terminal state cannot be cancelled — its delegation is gone from the
      // live rows, so do not stamp a cancel reason or emit a redundant terminate for it.
      const delegation = this.liveRunDelegation(run);
      if (delegation === undefined) return;
      if (this.runResolvers[run] !== undefined) this.cancelReasons[run] = reason;
      // The run delegation is moved to `cancelling` by the base from the `send(terminate)` below.
      // The cancel reason rides on the `cancelling` outcome, so the run's state + reason commit as one UPDATE.
      this.pendingRunOutcomes.push({
        run,
        state: "cancelling",
        result: null,
        errorMessage: null,
        cancelReason: reason ?? null,
      });
      this.send({ kind: "terminate", delegation, from: this.name, to: "core", run });
    });
  }

  /** Fail a run whose event a reactor threw on and the substrate dropped (poison containment) — so the run is
   *  observable as `error` instead of hanging forever, its only other trace a log line. Retire the run
   *  delegation, record the `error` outcome, and terminate the still-live root — the same terminal a machine-
   *  answered store failure (`failRunForStore`) takes, minus the audit (a dropped poison is a runtime defect,
   *  not a resolved escalation). Runs as a serial command turn; the substrate enqueues it after the drop's
   *  reload has rehydrated the run's delegation. Guarded by the retirement: a run already terminal (its
   *  delegation gone — the dropped event was a late duplicate, e.g. the terminate this very path emitted
   *  reaching the same poisoned reactor) is untouched, so its durable outcome stands. Returns when the failure
   *  commit is durable. */
  failRun(run: InstanceId, message: string): Promise<void> {
    return this.commands.enqueue(() => {
      const delegation = this.liveRunDelegation(run);
      if (delegation === undefined || !this.retireDelegation(delegation)) return;
      this.pendingRunOutcomes.push({
        run,
        state: "error",
        result: null,
        errorMessage: message,
      });
      this.send({ kind: "terminate", delegation, from: this.name, to: "core", run });
      this.cleanupExclusiveTasksForRun(run);
    });
  }

  /** Answer an open run-root escalation: relay the value back to its suspended raiser, which resumes, and
   *  record the answered escalation in the run's history — atomically with the `escalateAck`. The command
   *  turn runs after the project is loaded, so a freshly-recovered actor has rehydrated its open escalations
   *  before the lookup; the in-memory entry is cleared once the `escalateAck` is produced. The durable
   *  `escalations` row is marked answered by core (the raiser) when it receives the escalateAck. */
  answerEscalation(escalation: EscalationId, value: Value): Promise<void> {
    return this.commands.enqueue(() => {
      const open = this.openEscalations[escalation];
      if (open === undefined) return;
      this.send({
        kind: "escalateAck",
        delegation: open.delegation,
        escalation,
        value,
        from: this.name,
        to: "core",
        run: open.run,
      });
      this.pendingAudits.push({
        run: open.run,
        escalation,
        question: open.argument,
        answer: value,
      });
      delete this.openEscalations[escalation];
    });
  }

  /** Machine-answer an unhandled `prelude.store.*` escalation: compute the answer against the durable rows
   *  (async — a DB round-trip, OUTSIDE the react loop), then reply on a serial command turn with the same
   *  `escalateAck` an operator answer sends. No open question is tracked (it never surfaces to a human), and
   *  no audit is written (a machine environment interaction, not a user Q&A). Called live from `onEscalate`
   *  and, on reload, from `load` for a store answer a crash interrupted before its `escalateAck` committed —
   *  re-running is idempotent (a re-read yields the same value, a re-write is last-write-wins). A rows failure
   *  fails the run (a defect the program did not anticipate — the store request declares no throw), the same
   *  terminal a panic reaching the run root gets. */
  private answerStoreEscalation(escalate: {
    delegation: DelegationId;
    escalation: EscalationId;
    run: InstanceId;
    request: QualifiedName;
    argument: Value | null;
  }): void {
    // Only a ROWS failure takes the failure arm (the two-handler `then`): a rejection of the reply
    // command's own commit must NOT fail the run — nothing durable was lost (the open escalation row
    // survives), and the reactivation's machine-answer re-drive replays this same answer. Both commands
    // swallow their commit rejection for that same reason: recovery re-drives from durable state (a rows
    // failure that recurs on the re-drive re-enqueues the failure arm, so a genuine failure still lands).
    void answerStoreRequest(
      this.storeRows,
      this.projectId,
      escalate.request,
      escalate.argument,
    ).then(
      (value) =>
        this.commands
          .enqueue(() => {
            this.send({
              kind: "escalateAck",
              delegation: escalate.delegation,
              escalation: escalate.escalation,
              value,
              from: this.name,
              to: "core",
              run: escalate.run,
            });
          })
          .catch(() => undefined),
      (error: unknown) =>
        this.commands
          .enqueue(() => this.failRunForStore(escalate, messageOf(error)))
          .catch(() => undefined),
    );
  }

  /** Fail a run whose machine-answered store request could not be served (a durable-rows failure): retire the
   *  run delegation, record the `error` outcome, and terminate the still-suspended root — exactly the failure
   *  path a panic reaching the run root takes. Guarded by the retirement so a run already terminal (a racing
   *  cancel) is untouched. A store request raised by a serial-domain TASK arrives on the TASK delegation, not
   *  the run's — retiring that leg would strand the run root suspended under its exclusive — so it reroutes
   *  through the task failure path, which fails the run on its own delegation and tears the section down. */
  private failRunForStore(
    escalate: {
      delegation: DelegationId;
      run: InstanceId;
      escalation: EscalationId;
      argument: Value | null;
    },
    message: string,
  ): void {
    const taskEscalation = this.exclusiveTaskDelegations.get(escalate.delegation);
    if (taskEscalation !== undefined) {
      const task = this.exclusiveTasks.get(taskEscalation);
      if (task !== undefined) {
        this.failExclusiveTask(task, `store: ${message}`, escalate.argument);
      }
      return;
    }
    if (!this.retireDelegation(escalate.delegation)) return;
    this.pendingRunOutcomes.push({
      run: escalate.run,
      state: "error",
      result: null,
      errorMessage: `store: ${message}`,
    });
    this.pendingAudits.push({
      run: escalate.run,
      escalation: escalate.escalation,
      question: escalate.argument,
      answer: null,
    });
    this.send({
      kind: "terminate",
      delegation: escalate.delegation,
      from: this.name,
      to: "core",
      run: escalate.run,
    });
    this.cleanupExclusiveTasksForRun(escalate.run);
  }

  // ─── the serial domain's mechanics (enqueue / spawn / settle / teardown) ─────────────────────────

  /** Enqueue one `store.exclusive` on the project FIFO (warm map + the durable row, committed atomically with
   *  consuming the escalate that raised it) and, when no critical section holds the domain, spawn it in this
   *  same turn — so the enqueue and its spawn are one atomic unit. Idempotent per escalation (the replay
   *  backstop; a re-set would also lose a stamped running delegation). */
  private enqueueExclusiveTask(task: PersistedExclusiveTask): void {
    if (this.exclusiveTasks.has(task.escalation)) return;
    this.exclusiveTasks.set(task.escalation, task);
    this.pendingExclusiveInserts.push(task);
    this.spawnExclusiveHeadIfIdle();
  }

  /** Spawn the FIFO head if the domain is idle. ONE critical section at a time, project-wide: a RUNNING task
   *  (the delegation mapping) blocks it, and so does a terminated task whose teardown has not yet confirmed
   *  (the abandoned set — the fence that keeps a dying section's tail from overlapping the next). The fence is
   *  warm-only: after a crash the queue spawns its head immediately, accepting the (already-terminated,
   *  storeless) zombie teardown window rather than parking the domain on an ack that may never replay. */
  private spawnExclusiveHeadIfIdle(): void {
    if (this.exclusiveTaskDelegations.size > 0 || this.abandonedTaskDelegations.size > 0) return;
    const head = this.exclusiveTasks.values().next();
    if (head.done === true) return;
    this.spawnExclusiveTask(head.value);
  }

  /** Spawn one queued task: resolve its closure through the ONE value→target dispatch every runtime-decided
   *  callable uses, stamp the minted delegation onto the durable row (queued → running, atomic with the
   *  `delegate`), and summon it. The delegate is ISSUED BY THE API ROOT, not the run instance — the run's
   *  single live delegation (`liveRunDelegation`) must stay the run's own — while `run` stays the task's run,
   *  so its events belong to that run's trace and its instance carries that ambient. The task instance's
   *  caller reactor is `api`, so its own store escalations flow back here and machine-answer unchanged
   *  (routing is by delegation id). A non-callable task fails its run (the dispatch error is the failure). */
  private spawnExclusiveTask(task: PersistedExclusiveTask): void {
    const dispatched = dispatchCallable(task.task, EXCLUSIVE_TASK_INPUT);
    if ("error" in dispatched) {
      this.failExclusiveTask(task, `the task is ${dispatched.error}`, null);
      return;
    }
    const delegation = newDelegationId();
    task.taskDelegation = delegation;
    this.exclusiveTaskDelegations.set(delegation, task.escalation);
    this.pendingExclusiveDelegations.push({
      escalation: task.escalation,
      taskDelegation: delegation,
    });
    this.send(
      {
        kind: "delegate",
        delegation,
        target: dispatched.target,
        argument: dispatched.argument,
        ...(dispatched.generics !== undefined ? { generics: dispatched.generics } : {}),
        from: this.name,
        to: dispatched.to,
        run: task.run,
      },
      this.apiRootId,
    );
  }

  /** A task settled with a result: answer its exclusive down the run's own delegation (the raiser resumes
   *  from its suspension) and delete the queue row — atomically with consuming the task's `delegateAck` — then
   *  let the next section take the domain. The result's resources reown onto the RUN instance (the answer
   *  descends into the run's world and must outlive this commit; the run's eventual deletion reclaims them). */
  private completeExclusiveTask(
    escalation: EscalationId,
    event: Extract<ExternalEvent, { kind: "delegateAck" }>,
  ): void {
    this.exclusiveTaskDelegations.delete(event.delegation);
    const task = this.exclusiveTasks.get(escalation);
    if (task === undefined) {
      // Torn down while the ack was in flight (a racing run terminal already cleaned the row): the answer
      // has no waiter, so only the domain moves on.
      this.spawnExclusiveHeadIfIdle();
      return;
    }
    this.reownIncoming(event.value, task.run);
    this.exclusiveTasks.delete(escalation);
    this.pendingExclusiveDeletes.push(escalation);
    this.send({
      kind: "escalateAck",
      delegation: task.escalationDelegation,
      escalation,
      value: event.value,
      from: this.name,
      to: "core",
      run: task.run,
    });
    this.spawnExclusiveHeadIfIdle();
  }

  /** A task failed (its panic / throw escalated, its closure was not callable, or it nested an exclusive):
   *  fail ITS OWN RUN through the run delegation its exclusive escalated on — the same terminal
   *  `failRunForStore` takes, sticky if the run already reached one — and tear down every task of that run.
   *  Other runs' sections are untouched; the next queued one proceeds. */
  private failExclusiveTask(
    task: PersistedExclusiveTask,
    message: string,
    question: Value | null,
  ): void {
    if (this.retireDelegation(task.escalationDelegation)) {
      this.pendingRunOutcomes.push({
        run: task.run,
        state: "error",
        result: null,
        errorMessage: `store.exclusive: ${message}`,
      });
      this.pendingAudits.push({
        run: task.run,
        escalation: task.escalation,
        question,
        answer: null,
      });
      this.send({
        kind: "terminate",
        delegation: task.escalationDelegation,
        from: this.name,
        to: "core",
        run: task.run,
      });
    }
    this.cleanupExclusiveTasksForRun(task.run);
  }

  /** Drop every serial-domain task belonging to a run that reached a terminal: delete the queue rows, and
   *  TERMINATE a running task's delegate (the task is the api root's child, OUTSIDE the run's own teardown
   *  cascade, so nothing else reclaims it). The caller-side delegation row is retired NOW (the `failRun`
   *  pattern): a post-recovery ack for it then finds no row (`settled` stays false) and can never record an
   *  outcome over the run's durable terminal. Idempotent; ends by offering the domain to the next run's head. */
  private cleanupExclusiveTasksForRun(run: InstanceId): void {
    let removed = false;
    for (const [escalation, task] of this.exclusiveTasks) {
      if (task.run !== run) continue;
      this.exclusiveTasks.delete(escalation);
      this.pendingExclusiveDeletes.push(escalation);
      removed = true;
      if (task.taskDelegation !== null) {
        this.exclusiveTaskDelegations.delete(task.taskDelegation);
        this.retireDelegation(task.taskDelegation);
        this.abandonedTaskDelegations.add(task.taskDelegation);
        this.send({
          kind: "terminate",
          delegation: task.taskDelegation,
          from: this.name,
          to: "core",
          run,
        });
      }
    }
    if (removed) this.spawnExclusiveHeadIfIdle();
  }

  /** The run-root escalations currently awaiting an answer. */
  listOpenEscalations(): OpenEscalation[] {
    return Object.values(this.openEscalations).map(({ escalation, request, argument }) => ({
      escalation,
      request,
      argument,
    }));
  }

  /** Reload the api reactor's warm state from durable rows. The run delegations its run instances issued
   *  (`from = api`, so a recovered run is cancellable and can record its terminal state) reload through the
   *  base. Its *answerable* set — escalations addressed to it (`to = api`) — now carries FAILURE rows too (a
   *  panic / throw / control escape reaching the run root is also a `to = api` escalate, since the base opens
   *  a row for every escalate uniformly), so the loader's `answerableEscalations` filters to the user-facing
   *  rows (the classification lives at this handler's read, not the base): a reloaded failure never re-enters
   *  the answerable set. The run instances themselves need no warm reload — they are pure durable structure
   *  (FK anchors); everything warm about a run hangs off its delegation and these rows. */
  async load(loader: Loader): Promise<void> {
    await this.loadBase(loader.base);
    for (const open of await loader.api.answerableEscalations()) {
      this.openEscalations[open.escalation] = {
        run: open.run,
        delegation: open.delegation,
        escalation: open.escalation,
        request: open.request as QualifiedName,
        argument: open.argument,
      };
    }
    // Re-answer any store escalation whose runtime answer a crash interrupted before its `escalateAck`
    // committed (its open row is durable, its run suspended). These never entered `openEscalations`, so they
    // are re-driven from the durable rows, not the answerable set. Re-answering is idempotent; a store answer
    // that already landed left no open row here to reload, and a still-pending outbox `escalate` that also
    // re-drives it converges (last-write-wins, one stray ack core ignores).
    for (const open of await loader.api.machineAnswerableEscalations()) {
      this.answerStoreEscalation({
        delegation: open.delegation,
        escalation: open.escalation,
        run: open.run,
        request: open.request as QualifiedName,
        argument: open.argument,
      });
    }
    // The serial-domain FIFO — the durable queue is the SoT, deliberately NOT a blind re-drive of open
    // `store.exclusive` escalation rows (unlike a store answer, re-running a completed critical section would
    // double its writes; a completed task's row is gone, so it can never re-spawn). A RUNNING task (its
    // `taskDelegation` stamped) only re-registers its routing — its instance resumes from its durable core
    // frames; a still-QUEUED head spawns on a fresh command turn once the reload completes.
    for (const task of await loader.api.exclusiveTasks()) {
      this.exclusiveTasks.set(task.escalation, task);
      if (task.taskDelegation !== null) {
        this.exclusiveTaskDelegations.set(task.taskDelegation, task.escalation);
      }
    }
    if (this.exclusiveTasks.size > 0) {
      void this.commands.enqueue(() => this.spawnExclusiveHeadIfIdle());
    }
  }

  // ─── reactions (a run's delegateAck / escalate / terminateAck reaching the management root) ──────

  // The api root never receives a `delegate` (nobody delegates *to* it), an `escalateAck` (it never raises),
  // or a `terminate` (nothing cancels the root); those hooks stay the base no-op. The base retires the run
  // delegation before these hooks run and passes `settled` — whether that retirement fired — so a parallel run
  // outcome inherits the same sticky-terminal protection (a second ack for an already-terminal run records
  // nothing). The in-process result promise settles strictly post-commit in `afterCommit`.

  /** A delegateAck reaching the api reactor is EITHER a run's terminal or a serial-domain TASK's settlement —
   *  told apart by the delegation, never the run (a task's ack carries its run's trace stamp too). A task's
   *  ack answers its exclusive and spawns the next section; it must NOT record the run outcome `done` (the run
   *  is alive, suspended under the exclusive). A RUN's ack reowns its result onto the run's own instance and
   *  records the `done` outcome (only if the retirement fired — a no-op means the run already reached a
   *  terminal state, whose durable outcome stands). */
  protected onDelegateAck(
    event: Extract<ExternalEvent, { kind: "delegateAck" }>,
    context: AckContext,
  ): void {
    const taskEscalation = this.exclusiveTaskDelegations.get(event.delegation);
    if (taskEscalation !== undefined) {
      this.settledTaskAcks.add(event.delegation);
      this.completeExclusiveTask(taskEscalation, event);
      return;
    }
    if (this.abandonedTaskDelegations.delete(event.delegation)) {
      // A torn-down task raced its terminate with a result: the outcome is discarded (its run is already
      // terminal, its exclusive never answered), but the value's resources land on the run instance — an
      // owner whose deletion reclaims them — rather than dangling in transit. The teardown fence lifts.
      this.settledTaskAcks.add(event.delegation);
      this.reownIncoming(event.value, event.run);
      this.spawnExclusiveHeadIfIdle();
      return;
    }
    // The same two-step reown a core caller does for a sub-call — keeps a run that returns a closure / blob
    // alive instead of dropping it (the core root released it to in-transit as it retired). The owner is the
    // *run instance* (permanent, = event.run), not the project root: the result's resources live exactly as
    // long as the run's record, so a future run deletion reclaims them by cascade.
    this.reownIncoming(event.value, event.run);
    this.cleanupExclusiveTasksForRun(event.run);
    if (context.settled) {
      this.pendingRunOutcomes.push({
        run: event.run,
        state: "done",
        result: event.value,
        errorMessage: null,
      });
    }
  }

  /** A terminateAck reaching the api reactor: a serial-domain TASK's teardown confirmation is only the fence
   *  lifting (never the run's `cancelled` — the task was terminated because its run already reached a
   *  terminal, whose durable outcome stands). A RUN's cancel cascade records `cancelled` only if the
   *  retirement fired: a *failed* run already recorded `error` and retired its delegation, so the terminateAck
   *  from tearing down its still-suspended root is a sticky no-op here — it must NOT clobber the durable
   *  `error` outcome with `cancelled`. */
  protected onTerminateAck(
    event: Extract<ExternalEvent, { kind: "terminateAck" }>,
    context: AckContext,
  ): void {
    if (
      this.exclusiveTaskDelegations.delete(event.delegation) ||
      this.abandonedTaskDelegations.delete(event.delegation)
    ) {
      this.settledTaskAcks.add(event.delegation);
      this.spawnExclusiveHeadIfIdle();
      return;
    }
    this.cleanupExclusiveTasksForRun(event.run);
    if (context.settled) {
      this.pendingRunOutcomes.push({
        run: event.run,
        state: "cancelled",
        result: null,
        errorMessage: null,
      });
    }
  }

  /** A run's escalation reaching the root — the api reactor is the terminal handler, and this is the ONE site
   *  that classifies (a handler's local judgment, not the base's): a genuine user-facing request is kept open
   *  (the run stays suspended awaiting a user's answer — the durable row was already opened by its raiser, so
   *  this only tracks the answerable in memory); a failure (panic / throw) or unhandled control escape FAILS
   *  the run — retire the run delegation, record `error`, audit it, and terminate the still-suspended root
   *  (the teardown's eventual terminateAck is a sticky no-op). The failure row is NOT retired here: every
   *  failure escalate is raised by a MORTAL instance (a core / ffi instance in the run's subtree — a run-start
   *  failure never reaches core, being rejected at the run-start boundary), so its row cascades when the run
   *  teardown drops that raiser. The api owns no ephemeral escalation row and never cleans one up. */
  protected onEscalate(event: Extract<ExternalEvent, { kind: "escalate" }>): void {
    const ask = event.ask;
    if (ask.kind === "request" && isStoreRequest(ask.request)) {
      // The store is the run's MACHINE-answering environment: an unhandled `prelude.store.*` request is
      // answered by the runtime against the durable rows, never surfaced as an operator question (it is not
      // in `openEscalations`, so `listOpenEscalations` / `katari ls escalations` never show it). Reown the
      // argument onto the api ROOT (not the run, like a user question): a stored value's `file` blob thereby
      // lands api-root-owned — the file library — so it outlives the run, exactly the landing an upload gets.
      // Then compute the answer (async rows I/O) and reply on the same downward path an operator answer takes.
      if (ask.argument !== null) this.reownIncoming(ask.argument, this.apiRootId);
      this.answerStoreEscalation({
        delegation: event.delegation,
        escalation: event.escalation,
        run: event.run,
        request: ask.request,
        argument: ask.argument,
      });
      return;
    }
    if (ask.kind === "request" && isExclusiveRequest(ask.request)) {
      // The runtime IS the outermost serial domain (the root workspace): an unhandled `store.exclusive` is
      // SERVED here — its task runs as a critical section of the project-wide durable FIFO — never surfaced
      // as an operator question. Reown the carried task closure onto the RUN instance first (the raiser
      // released it on send and now suspends across an arbitrary FIFO wait — the same landing a user-facing
      // question's resources get), so its captured scopes have a durable owner whatever branch runs below.
      if (ask.argument !== null) this.reownIncoming(ask.argument, event.run);
      const raisingTask = this.exclusiveTaskDelegations.get(event.delegation);
      if (raisingTask !== undefined) {
        // A critical section performed a NESTED exclusive: it would queue behind its own raiser and
        // deadlock the whole domain, so fail the raising task (which fails its run) instead of enqueueing.
        const outer = this.exclusiveTasks.get(raisingTask);
        if (outer !== undefined) {
          this.failExclusiveTask(
            outer,
            "a critical section performed a nested exclusive — the task's row is fixed to the store operations",
            escalateValue(ask),
          );
        }
        return;
      }
      // A dead leg: the run (or an abandoned task) reached its terminal while this escalate was in flight,
      // so nothing waits for the answer — do not enqueue (the reowned resources reclaim with the run).
      if (!this.hasLiveDelegation(event.delegation)) return;
      const task = ask.argument?.kind === "record" ? ask.argument.fields.task : undefined;
      if (task === undefined) {
        this.failRunForStore(
          {
            delegation: event.delegation,
            run: event.run,
            escalation: event.escalation,
            argument: ask.argument,
          },
          "exclusive: the task is missing (compiler/runtime drift — a bug)",
        );
        return;
      }
      this.enqueueExclusiveTask({
        escalation: event.escalation,
        run: event.run,
        escalationDelegation: event.delegation,
        task,
        taskDelegation: null,
      });
      return;
    }
    if (ask.kind === "request" && isUserFacingRequest(ask.request)) {
      // Reown the question's resources onto the run's instance: the raiser released them on send, and the
      // run now holds the open escalation across an arbitrary wait for the user's answer.
      if (ask.argument !== null) this.reownIncoming(ask.argument, event.run);
      this.openEscalations[event.escalation] = {
        run: event.run,
        delegation: event.delegation,
        escalation: event.escalation,
        request: ask.request,
        argument: ask.argument,
      };
      return;
    }
    // A failure raised by a serial-domain TASK (its panic / throw escalates under the TASK delegation, not the
    // run's): fail the task's OWN run through the run delegation its exclusive escalated on — never suspend or
    // touch any other run's world — and let the next queued section proceed.
    const failingTask = this.exclusiveTaskDelegations.get(event.delegation);
    if (failingTask !== undefined) {
      const task = this.exclusiveTasks.get(failingTask);
      if (task !== undefined) {
        this.failExclusiveTask(task, escalationErrorMessage(event), escalateValue(ask));
      }
      return;
    }
    // Fail the run: retire its delegation (the policy retirement the base exposes). A second escalate reaching
    // an already-terminal run retires nothing (its outcome is already durable), so guard the outcome + teardown.
    if (this.retireDelegation(event.delegation)) {
      this.pendingRunOutcomes.push({
        run: event.run,
        state: "error",
        result: null,
        errorMessage: escalationErrorMessage(event),
      });
      // Record the resolved failure in the run's history: the audit is the complete log of resolved
      // escalations (answered + failed / cancelled), so a failure records its question with a null answer.
      this.pendingAudits.push({
        run: event.run,
        escalation: event.escalation,
        question: escalateValue(ask),
        answer: null,
      });
      // Terminate the still-suspended root. Its teardown cascades the whole run subtree — INCLUDING the
      // mortal instance that raised this failure escalate, whose escalation row goes with it (no explicit
      // retire needed: the row's raiser is never the permanent run instance).
      this.send({
        kind: "terminate",
        delegation: event.delegation,
        from: this.name,
        to: "core",
        run: event.run,
      });
      // The failing run's serial-domain tasks (queued or running) die with it; the next run's head proceeds.
      this.cleanupExclusiveTasksForRun(event.run);
    }
  }

  /** Settle the in-process result promise (the non-SoT notification hook) strictly after the turn is durably
   *  committed — a finished run resolves, a cancelled run rejects with `RunCancelledError`, a failed run
   *  rejects with its error. An open escalation's `escalate` settles nothing (the run stays suspended), and a
   *  serial-domain TASK's ack settles nothing either (the hooks marked it — its run is alive under the
   *  exclusive, or already settled by its own terminal event): without that guard a task's result would
   *  resolve a live run's promise with the wrong value. */
  afterCommit(event: ExternalEvent): void {
    switch (event.kind) {
      case "delegateAck":
        if (this.settledTaskAcks.delete(event.delegation)) break;
        this.settleRun(event.run, { value: event.value });
        break;
      case "terminateAck":
        if (this.settledTaskAcks.delete(event.delegation)) break;
        this.settleRun(event.run, {
          error: new RunCancelledError(this.cancelReasons[event.run]),
        });
        break;
      case "escalate":
        if (isRunFailure(event)) {
          this.settleRun(event.run, { error: new Error(escalationErrorMessage(event)) });
        }
        break;
    }
  }

  /** Settle a run either way and drop its handlers + any of its still-open escalations. */
  private settleRun(run: InstanceId, outcome: { value: Value } | { error: Error }): void {
    const resolver = this.runResolvers[run];
    const rejecter = this.runRejecters[run];
    delete this.runResolvers[run];
    delete this.runRejecters[run];
    delete this.cancelReasons[run];
    for (const [escalation, open] of Object.entries(this.openEscalations)) {
      if (open.run === run) delete this.openEscalations[escalation as EscalationId];
    }
    if ("value" in outcome) resolver?.(outcome.value);
    else rejecter?.(outcome.error);
  }
}

/** Whether an escalation reaching the run root *fails* the run: a control escape (next / break / return
 *  crossing the root) or a failure channel (panic / throw / replay-interrupted). NOT the complement of
 *  user-facing: a runtime-SERVED request (a machine-answered `prelude.store.*` read / write, a root-served
 *  `store.exclusive`) is neither user-facing nor a failure — the run continues under it, so it must never
 *  settle the in-process result promise. */
function isRunFailure(event: Extract<ExternalEvent, { kind: "escalate" }>): boolean {
  return event.ask.kind !== "request" || isFailureRequest(event.ask.request);
}

/** A human message for an escalation that reached the run root unhandled (it fails the run). A panic reports
 *  its `{ msg }`, a `prelude.throw` its serialized payload; any other unhandled request / control escape
 *  reports its name. */
function escalationErrorMessage(event: Extract<ExternalEvent, { kind: "escalate" }>): string {
  if (event.ask.kind !== "request") {
    return `unhandled "${event.ask.kind}" reached the run root`;
  }
  if (event.ask.request === THROW_REQUEST) {
    const argument = event.ask.argument;
    const payload = argument?.kind === "record" ? argument.fields.error : undefined;
    if (payload === undefined) return "throw: (no payload)";
    // The run's error message is neither sealed at rest nor redacted at the wire, so serialize through
    // the redacting codec: a tainted payload (itself, or through its container record) degrades to
    // `$katari_redacted` subtrees rather than leaking — the same fail-closed boundary as run results.
    const effective = argument?.private === true ? markPrivate(payload) : payload;
    return `throw: ${JSON.stringify(valueToJson(effective, "redact"))}`;
  }
  if (event.ask.request === PANIC_REQUEST) {
    const argument = event.ask.argument;
    const message =
      argument?.kind === "record" && argument.fields.msg?.kind === "string"
        ? argument.fields.msg
        : null;
    if (message === null) return "panic: (no message)";
    // The run's error message is neither sealed at rest nor redacted at the wire, so a secret panic message
    // would leak as plaintext. Redact it when the message — itself, or through its container record — is
    // private (the same marker the run argument / result boundary honours).
    const tainted = argument?.private === true || isTainted(message);
    return tainted ? "panic: [redacted]" : `panic: ${message.value}`;
  }
  return `unhandled request "${event.ask.request}" reached the run root`;
}
