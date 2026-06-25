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
import type { ExternalEvent, ReactorName } from "../event/types.js";
import {
  type DelegationId,
  type EscalationId,
  type InstanceId,
  newDelegationId,
  type SnapshotId,
} from "../ids.js";
import type { Value } from "../value/types.js";
import type {
  PersistedDelegation,
  PersistedRun,
  PersistedRunEscalationAudit,
  PersistenceTx,
} from "./persistence.js";
import { Reactor } from "./reactor.js";
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
  private pendingCancelReasons: Array<{ run: DelegationId; reason: string | null }> = [];
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

  /** The api root runs no engine threads — its turn writes the Layer 1 rows it owns plus the run-metadata
   *  sidecar / audit it staged this turn (so they commit atomically with the events it produced). Starting a
   *  run first ensures the api root's own `instances` row, before `flushLayer1` writes the run delegation
   *  whose caller FK points at it (the api root has no producing `delegate` turn to create it otherwise). */
  async persist(tx: PersistenceTx): Promise<void> {
    if (this.pendingRunStarts.length > 0) await tx.ensureApiRoot(this.apiRootId);
    await this.flushLayer1(tx);
    for (const run of this.pendingRunStarts) await tx.putRun(run);
    for (const { run, reason } of this.pendingCancelReasons)
      await tx.setRunCancelReason(run, reason);
    for (const audit of this.pendingAudits) await tx.putRunEscalationAudit(audit);
    this.pendingRunStarts = [];
    this.pendingCancelReasons = [];
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
    this.pendingCancelReasons = [];
    this.pendingAudits = [];
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
      // The api root owns this run delegation (it is the caller) and its metadata sidecar; recording both
      // here, before the delegate is produced, means the run survives a crash before its root is even created.
      this.openDelegation(delegation, {
        caller: this.apiRootId,
        target: { kind: "named", name: qualifiedName, snapshot },
        argument,
      });
      this.pendingRunStarts.push({
        run: delegation,
        name,
        qualifiedName,
        snapshotId: snapshot,
        argument,
      });
      this.send(
        {
          kind: "delegate",
          delegation,
          target: { kind: "named", name: qualifiedName, snapshot },
          argument,
        },
        "core",
      );
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
      if (this.runResolvers[run] !== undefined) this.cancelReasons[run] = reason;
      this.transitionDelegation(run, "cancelling");
      this.pendingCancelReasons.push({ run, reason: reason ?? null });
      this.send({ kind: "terminate", delegation: run }, "core");
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
      this.send({ kind: "escalateAck", delegation: open.run, escalation, value }, "core");
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

  /** Re-establish one user-facing open escalation on recovery (core decides which are user-facing and
   *  supplies the run delegation it belongs to). */
  rehydrateOpenEscalation(open: OpenEscalation & { run: DelegationId }): void {
    this.openEscalations[open.escalation] = open;
  }

  /** Reload the api root's live run delegation rows on recovery (those whose caller is the api root), so a
   *  recovered run can still be cancelled / can record its terminal state when it finishes. */
  loadRuns(liveDelegations: PersistedDelegation[]): void {
    for (const row of liveDelegations) {
      if (row.caller !== this.apiRootId) continue;
      this.reloadDelegation(row.delegation, {
        caller: row.caller,
        target: row.target,
        argument: row.argument,
        state: row.state,
      });
    }
  }

  // ─── reactions (a run's delegateAck / escalate / terminateAck reaching the management root) ──────

  /** React to one event a run's delegation routes back to the management root, recording the run delegation's
   *  terminal state (it owns the row). The in-process result promise settles strictly post-commit in
   *  `afterCommit`. The api root never receives a `delegate` (nobody delegates *to* it), an `escalateAck` (it
   *  never raises), or a `terminate` (nothing cancels the root). */
  react(event: ExternalEvent): void {
    switch (event.kind) {
      case "delegateAck":
        // Reown the result's captured resources to the api root (the run-root instance released them to
        // in-transit as it retired). This is the same two-step reown a core caller does for a sub-call —
        // the api root is just the local owner here — and is what keeps a run that returns a closure / blob
        // alive instead of dropping it.
        this.reownIncoming(event.value, this.apiRootId);
        this.transitionDelegation(event.delegation, "done", { result: event.value });
        break;
      case "terminateAck":
        this.transitionDelegation(event.delegation, "gone");
        break;
      case "escalate":
        this.reactEscalate(event);
        break;
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

  /** A run's escalation reaching the root: a genuine request is kept open (the run stays suspended awaiting a
   *  user's answer — the durable row was already opened by core, the raiser, so this only tracks the
   *  answerable in memory); a panic / unhandled escape fails the run — record the delegation `failed` and
   *  terminate its still-suspended root (the teardown's eventual `gone` is a sticky no-op). */
  private reactEscalate(event: Extract<ExternalEvent, { kind: "escalate" }>): void {
    const ask = event.ask;
    if (ask.kind === "request" && ask.request !== PANIC_REQUEST) {
      this.openEscalations[event.escalation] = {
        run: event.delegation,
        escalation: event.escalation,
        request: ask.request,
        argument: ask.argument,
      };
      return;
    }
    this.transitionDelegation(event.delegation, "failed", {
      errorMessage: escalationErrorMessage(event),
    });
    this.send({ kind: "terminate", delegation: event.delegation }, "core");
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
  return event.ask.kind !== "request" || event.ask.request === PANIC_REQUEST;
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
        ? argument.fields.msg.value
        : "(no message)";
    return `panic: ${message}`;
  }
  return `unhandled request "${event.ask.request}" reached the run root`;
}
