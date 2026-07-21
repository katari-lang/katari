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
import { THROW_REQUEST } from "../engine/throw-signal.js";
import type { BlobEntry } from "../engine/types.js";
import { isUserFacingRequest } from "../escalation-filter.js";
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
  PersistedRun,
  PersistedRunEscalationAudit,
  PersistedRunOutcome,
  PersistenceTx,
} from "./persistence.js";
import { type AckContext, Reactor } from "./reactor.js";
import type { ResourcePool } from "./resource-pool.js";
import { answerStoreRequest, isStoreRequest, type StoreRows } from "./store-responder.js";

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
    this.pendingRunStarts = [];
    this.pendingRunOutcomes = [];
    this.pendingAudits = [];
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
    void answerStoreRequest(this.storeRows, this.projectId, escalate.request, escalate.argument)
      .then((value) =>
        this.commands.enqueue(() => {
          this.send({
            kind: "escalateAck",
            delegation: escalate.delegation,
            escalation: escalate.escalation,
            value,
            from: this.name,
            to: "core",
            run: escalate.run,
          });
        }),
      )
      .catch((error) =>
        this.commands.enqueue(() => this.failRunForStore(escalate, messageOf(error))),
      );
  }

  /** Fail a run whose machine-answered store request could not be served (a durable-rows failure): retire the
   *  run delegation, record the `error` outcome, and terminate the still-suspended root — exactly the failure
   *  path a panic reaching the run root takes. Guarded by the retirement so a run already terminal (a racing
   *  cancel) is untouched. */
  private failRunForStore(
    escalate: {
      delegation: DelegationId;
      run: InstanceId;
      escalation: EscalationId;
      argument: Value | null;
    },
    message: string,
  ): void {
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
  }

  // ─── reactions (a run's delegateAck / escalate / terminateAck reaching the management root) ──────

  // The api root never receives a `delegate` (nobody delegates *to* it), an `escalateAck` (it never raises),
  // or a `terminate` (nothing cancels the root); those hooks stay the base no-op. The base retires the run
  // delegation before these hooks run and passes `settled` — whether that retirement fired — so a parallel run
  // outcome inherits the same sticky-terminal protection (a second ack for an already-terminal run records
  // nothing). The in-process result promise settles strictly post-commit in `afterCommit`.

  /** A run finished: reown its result onto the run's own instance and record the `done` outcome (only if
   *  the retirement fired — a no-op means the run already reached a terminal state, whose durable outcome
   *  stands). */
  protected onDelegateAck(
    event: Extract<ExternalEvent, { kind: "delegateAck" }>,
    context: AckContext,
  ): void {
    // The same two-step reown a core caller does for a sub-call — keeps a run that returns a closure / blob
    // alive instead of dropping it (the core root released it to in-transit as it retired). The owner is the
    // *run instance* (permanent, = event.run), not the project root: the result's resources live exactly as
    // long as the run's record, so a future run deletion reclaims them by cascade.
    this.reownIncoming(event.value, event.run);
    if (context.settled) {
      this.pendingRunOutcomes.push({
        run: event.run,
        state: "done",
        result: event.value,
        errorMessage: null,
      });
    }
  }

  /** A run's cancel cascade confirmed: record `cancelled` only if the retirement fired. A *failed* run already
   *  recorded `error` and retired its delegation, so the terminateAck from tearing down its still-suspended root
   *  is a sticky no-op here — it must NOT clobber the durable `error` outcome with `cancelled`. */
  protected onTerminateAck(
    event: Extract<ExternalEvent, { kind: "terminateAck" }>,
    context: AckContext,
  ): void {
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
    }
  }

  /** Settle the in-process result promise (the non-SoT notification hook) strictly after the turn is durably
   *  committed — a finished run resolves, a cancelled run rejects with `RunCancelledError`, a failed run
   *  rejects with its error. An open escalation's `escalate` settles nothing (the run stays suspended). */
  afterCommit(event: ExternalEvent): void {
    switch (event.kind) {
      case "delegateAck":
        this.settleRun(event.run, { value: event.value });
        break;
      case "terminateAck":
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

/** Whether an escalation reaching the run root *fails* the run (rather than opening a user-facing request):
 *  a control escape (next / break / return crossing the root) or a panic. */
function isRunFailure(event: Extract<ExternalEvent, { kind: "escalate" }>): boolean {
  return !(event.ask.kind === "request" && isUserFacingRequest(event.ask.request));
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
