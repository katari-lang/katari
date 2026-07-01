// ApiReactor: the api management root's participation in the external-event world — the user-facing bridge.
// Symmetric to a core instance, it both *issues* external events on a user's behalf (startRun -> delegate,
// cancel -> terminate, answer -> escalateAck) and *reacts* to the events a run's delegation routes back to
// the root (delegateAck -> the run finished, escalate -> a user-facing open escalation or a run failure,
// terminateAck -> the run was cancelled). It owns its run delegation rows (it is their caller) and persists
// them through the base class; the in-process run-result promises and the answerable open escalations are a
// non-SoT convenience on top. The core engine never appears here, and this never drives an engine turn.
//
// Commands originate *outside* the substrate's react loop (a façade / test calls them), so each enqueues a
// serial command thunk on the bus: the mutation (open / cancel / answer) and its `send` run inside a normal
// serial turn, committed atomically like any reaction. The in-process `result` promise's resolvers are
// captured synchronously (so a fast run cannot settle before they exist); the durable outcome is the
// delegation row the API reads by projection — the promise is only an in-process notification hook.

import type { QualifiedName } from "@katari-lang/types";
import { PANIC_REQUEST } from "../engine/common.js";
import type { BlobEntry } from "../engine/types.js";
import { isUserFacingRequest } from "../escalation-filter.js";
import type { ExternalEvent, ReactorName } from "../event/types.js";
import {
  type BlobId,
  type DelegationId,
  type EscalationId,
  type InstanceId,
  newDelegationId,
  type SnapshotId,
} from "../ids.js";
import { isTainted } from "../value/privacy.js";
import type { Value } from "../value/types.js";
import type {
  Loader,
  PersistedRun,
  PersistedRunEscalationAudit,
  PersistedRunOutcome,
  PersistenceTx,
} from "./persistence.js";
import { type AckContext, Reactor } from "./reactor.js";
import type { ResourcePool } from "./resource-pool.js";

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
   *  delegation row, read by projection). It lets an in-process caller `await` a run it started: a
   *  delegateAck resolves it, a panic / unhandled escape rejects it, a terminate (cancel) rejects it with
   *  `RunCancelledError`. Absent for a recovered run (no in-process caller is awaiting it). */
  private readonly runResolvers: Record<DelegationId, (value: Value) => void> = {};
  private readonly runRejecters: Record<DelegationId, (error: Error) => void> = {};
  /** Run-root requests the engine could not handle, kept open (their run-root instance stays suspended)
   *  until a user answers. The durable escalation row is owned by core (the raiser); this is the answering
   *  projection, rehydrated on recovery from core's user-facing open escalations. */
  private readonly openEscalations: Record<EscalationId, OpenEscalation & { run: DelegationId }> =
    {};
  /** A cancelling run's reason — held only to decorate the in-process `RunCancelledError` (the durable
   *  reason is `runs.cancelReason`). Kept only while the run is tracked in-process, so it cannot leak. */
  private readonly cancelReasons: Record<DelegationId, string | undefined> = {};
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
  ) {
    super(pool);
  }

  currentTurnOwner(): InstanceId {
    return this.apiRootId;
  }

  /** The api root runs no engine threads — its turn writes the run delegations it owns plus the run-metadata
   *  sidecar / audit it staged this turn (so they commit atomically with the events it produced). Starting a
   *  run first ensures the api root's own `instances` envelope, before `flushDelegations` writes the run
   *  delegation whose caller FK points at it (the api root has no producing `delegate` turn to create it). */
  async persist(tx: PersistenceTx): Promise<void> {
    // Always stage the api root's envelope (an idempotent upsert), so the generic half is present before any FK
    // that points at it — a run delegation's caller, or a file-upload blob's owner. The api root is the
    // project's permanent management root, so ensuring it every turn is correct and needs no per-FK flag; the
    // base then writes that envelope plus the run delegations it owns. It raises no escalations and drops
    // nothing; the run-metadata sidecar is the api's own data.
    // The api root is summoned by nobody, so its ambient summoner is `null`.
    this.markInstance(this.apiRootId, {
      delegationId: null,
      callerReactor: null,
      status: "running",
    });
    await this.persistBase(tx.base);
    // The run launch row first (a later outcome update targets it); then this turn's state / outcome updates
    // (the durable SoT, since the run delegation row was just deleted by the base on its terminal). A cancel's
    // reason rides on its `cancelling` outcome, so the cancel is one UPDATE, not two.
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
    for (const key of Object.keys(this.cancelReasons))
      delete this.cancelReasons[key as DelegationId];
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

  /** Reject and drop every in-process run-result promise after a poisoned commit: the run continues durably
   *  and the API reads its outcome by projection, but this non-SoT notification hook cannot survive the
   *  reactivation, so its caller is told to re-query rather than left hanging. */
  poisonRunPromises(error: Error): void {
    for (const reject of Object.values(this.runRejecters)) reject(error);
    for (const key of Object.keys(this.runResolvers)) delete this.runResolvers[key as DelegationId];
    for (const key of Object.keys(this.runRejecters)) delete this.runRejecters[key as DelegationId];
  }

  // ─── commands (the api root issuing external events on a user's behalf) ─────────────────────────

  /** Start a run: summon a root instance for `qualifiedName@snapshot`, recording its `runs` metadata sidecar
   *  atomically with the run's `delegate` (so the API never sees a run without its launch metadata, nor vice
   *  versa). Returns the run delegation (the `cancelRun` handle), an in-process `result` promise (a non-SoT
   *  notification hook), and `started` — which resolves once the launch commit is durable (the façade awaits
   *  it so a just-returned run is immediately visible). The resolvers are captured now so a fast run cannot
   *  settle before they exist. */
  startRun(
    qualifiedName: QualifiedName,
    snapshot: SnapshotId,
    argument: Value | null,
    name: string,
  ): { run: DelegationId; result: Promise<Value>; started: Promise<void> } {
    const delegation = newDelegationId();
    const result = new Promise<Value>((resolve, reject) => {
      this.runResolvers[delegation] = resolve;
      this.runRejecters[delegation] = reject;
    });
    const started = this.commands.enqueue(() => {
      // Record the run's metadata sidecar before the delegate is produced, so the run survives a crash before
      // its root is even created. The run delegation row itself is opened by the base from the `send` below (the
      // api root is its caller), atomically in the same commit — so metadata and delegation land together.
      this.pendingRunStarts.push({
        run: delegation,
        name,
        qualifiedName,
        snapshotId: snapshot,
        argument,
      });
      // The api root only ever talks to core (a run is a delegate to a core instance), so it stamps `to` here.
      this.send({
        kind: "delegate",
        delegation,
        target: { kind: "named", name: qualifiedName, snapshot },
        argument,
        from: this.name,
        to: "core",
      });
    });
    return { run: delegation, result, started };
  }

  /** Request a run's cancellation: move it to `cancelling`, record the cancel reason on its `runs` row, and
   *  terminate its root — all in one commit. The cascade tears the tree down; the terminateAck moves it to
   *  `gone` and rejects the run with `RunCancelledError`. Always produce the terminate (so a recovered,
   *  still-live run is cancellable). The in-process reason (to decorate the error) is kept only while the run
   *  is tracked here, so it cannot leak. Returns when the cancel commit is durable. */
  cancelRun(run: DelegationId, reason?: string): Promise<void> {
    return this.commands.enqueue(() => {
      // A run that already reached a terminal state (done / failed / gone) cannot be cancelled — its row is
      // gone from the live map, so do not stamp a cancel reason or emit a redundant terminate for it.
      if (!this.hasLiveDelegation(run)) return;
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
      this.send({ kind: "terminate", delegation: run, from: this.name, to: "core" });
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
        delegation: open.run,
        escalation,
        value,
        from: this.name,
        to: "core",
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

  /** The run-root escalations currently awaiting an answer. */
  listOpenEscalations(): OpenEscalation[] {
    return Object.values(this.openEscalations).map(({ escalation, request, argument }) => ({
      escalation,
      request,
      argument,
    }));
  }

  /** Reload the api root's warm state from durable rows. The run delegations it issued (`from = api`, so a
   *  recovered run is cancellable and can record its terminal state) reload through the base. Its *answerable*
   *  set — escalations addressed to it (`to = api`, raised by a run root) — is its own data: every such row is
   *  user-facing by construction (core opens a row only for an answerable request; a panic / control escape
   *  reaching the run root fails the run, it is never an open escalation), so no re-classification is needed. */
  async load(loader: Loader): Promise<void> {
    await this.loadBase(loader.base);
    for (const open of await loader.api.answerableEscalations()) {
      this.openEscalations[open.escalation] = {
        run: open.delegation,
        escalation: open.escalation,
        request: open.request as QualifiedName,
        argument: open.argument,
      };
    }
  }

  // ─── reactions (a run's delegateAck / escalate / terminateAck reaching the management root) ──────

  // The api root never receives a `delegate` (nobody delegates *to* it), an `escalateAck` (it never raises),
  // or a `terminate` (nothing cancels the root); those hooks stay the base no-op. The base retires the run
  // delegation before these hooks run and passes `settled` — whether that retirement fired — so a parallel run
  // outcome inherits the same sticky-terminal protection (a second ack for an already-terminal run records
  // nothing). The in-process result promise settles strictly post-commit in `afterCommit`.

  /** A run finished: reown its result to the api root and record the `done` outcome (only if the retirement
   *  fired — a no-op means the run already reached a terminal state, whose durable outcome stands). */
  protected onDelegateAck(
    event: Extract<ExternalEvent, { kind: "delegateAck" }>,
    context: AckContext,
  ): void {
    // The same two-step reown a core caller does for a sub-call — keeps a run that returns a closure / blob
    // alive instead of dropping it (the run-root instance released it to in-transit as it retired).
    this.reownIncoming(event.value, this.apiRootId);
    if (context.settled) {
      this.pendingRunOutcomes.push({
        run: event.delegation,
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
        run: event.delegation,
        state: "cancelled",
        result: null,
        errorMessage: null,
      });
    }
  }

  /** A run's escalation reaching the root: a genuine request is kept open (the run stays suspended awaiting a
   *  user's answer — the durable row was already opened by core, the raiser, so this only tracks the answerable
   *  in memory); a panic / unhandled escape fails the run — retire the run delegation and, if that fired, record
   *  `error` and terminate its still-suspended root (the teardown's eventual terminateAck is a sticky no-op). */
  protected onEscalate(event: Extract<ExternalEvent, { kind: "escalate" }>): void {
    const ask = event.ask;
    if (ask.kind === "request" && isUserFacingRequest(ask.request)) {
      // Reown the question's resources to the api root: the raiser released them on send, and the root now
      // holds the open escalation across an arbitrary wait for the user's answer.
      if (ask.argument !== null) this.reownIncoming(ask.argument, this.apiRootId);
      this.openEscalations[event.escalation] = {
        run: event.delegation,
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
        run: event.delegation,
        state: "error",
        result: null,
        errorMessage: escalationErrorMessage(event),
      });
      this.send({ kind: "terminate", delegation: event.delegation, from: this.name, to: "core" });
    }
  }

  /** Settle the in-process result promise (the non-SoT notification hook) strictly after the turn is durably
   *  committed — a finished run resolves, a cancelled run rejects with `RunCancelledError`, a failed run
   *  rejects with its error. An open escalation's `escalate` settles nothing (the run stays suspended). */
  afterCommit(event: ExternalEvent): void {
    switch (event.kind) {
      case "delegateAck":
        this.settleRun(event.delegation, { value: event.value });
        break;
      case "terminateAck":
        this.settleRun(event.delegation, {
          error: new RunCancelledError(this.cancelReasons[event.delegation]),
        });
        break;
      case "escalate":
        if (isRunFailure(event)) {
          this.settleRun(event.delegation, { error: new Error(escalationErrorMessage(event)) });
        }
        break;
    }
  }

  /** Settle a run-root delegation either way and drop its handlers + any of its still-open escalations. */
  private settleRun(delegation: DelegationId, outcome: { value: Value } | { error: Error }): void {
    const resolver = this.runResolvers[delegation];
    const rejecter = this.runRejecters[delegation];
    delete this.runResolvers[delegation];
    delete this.runRejecters[delegation];
    delete this.cancelReasons[delegation];
    for (const [escalation, open] of Object.entries(this.openEscalations)) {
      if (open.run === delegation) delete this.openEscalations[escalation as EscalationId];
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
 *  its `{ msg }`; any other unhandled request / control escape reports its name. */
function escalationErrorMessage(event: Extract<ExternalEvent, { kind: "escalate" }>): string {
  if (event.ask.kind !== "request") {
    return `unhandled "${event.ask.kind}" reached the run root`;
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
