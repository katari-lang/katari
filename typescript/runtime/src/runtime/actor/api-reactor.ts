// ApiReactor: the api management root's participation in the external-event world — the user-facing bridge.
// Symmetric to a core instance, it both *issues* external events on a user's behalf (startRun -> delegate,
// cancel -> terminate, answer -> escalateAck) and *reacts* to the events a run's delegation routes back to
// the root (delegateAck -> the run finished, escalate -> a user-facing open escalation or a run failure,
// terminateAck -> the run was cancelled). It owns only the api root's own state — the in-process run-result
// promises and the open user escalations; the substrate owns the mailbox, outbox, and delegation routing,
// exposed through the narrow `ApiHost`. The core engine never appears here, and this never drives a turn.
//
// NB (three-layer plan, docs/2026-06-25-three-layer-runtime.md): the api root needs no in-memory SoT — a
// run's outcome is its durable delegation row and an open escalation is a durable `escalations` row. The
// in-process maps below are a transitional convenience (the `result` promise is not the SoT — the façade
// ignores it); a later phase projects them from durable Layer 1 and these maps disappear.

import type { QualifiedName } from "@katari-lang/types";
import { PANIC_REQUEST } from "../engine/common.js";
import type { ExternalEvent } from "../event/types.js";
import {
  type DelegationId,
  type EscalationId,
  type InstanceId,
  newDelegationId,
  type OutboxSeq,
  type SnapshotId,
} from "../ids.js";
import type { Value } from "../value/types.js";
import type { Reaction } from "./turn-commit.js";

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

/** The narrow slice of the substrate the api root drives. The substrate owns the mailbox, the transactional
 *  outbox, and the delegation routing graph; the api root only describes its (engine-less) turns as
 *  `Reaction`s for the bus to commit, and opens / closes the routing edge for a run delegation it issues /
 *  finishes. */
export interface ApiHost {
  readonly apiRootId: InstanceId;
  /** Reactivate the project before reading warm state (so a cold actor rehydrates its open escalations). */
  ensureLoaded(): Promise<void>;
  /** Commit one api-root turn atomically (the bus mints outbox seqs, writes Layer 1 + outbox, delivers): its
   *  Reaction plus the inbound row it consumes — `null` for a command the api root injects (start / cancel /
   *  answer), the escalate's `seq` for a reaction to one. */
  commit(reaction: Reaction, consumed: OutboxSeq | null): Promise<void>;
  /** Record the delegation routing edge for a run the api root issues. */
  openRunDelegation(delegation: DelegationId): void;
  /** Drop the routing edge for a run the api root has finished. */
  closeRunDelegation(delegation: DelegationId): void;
}

export class ApiReactor {
  /** The in-process run-result *notification hook* (NOT the source of truth — a run's outcome is its durable
   *  delegation row, which the API reads by projection). It lets an in-process caller `await` a run it started
   *  in this process: a delegateAck resolves it, a panic / unhandled escape rejects it, a terminate (cancel)
   *  rejects it with `RunCancelledError`. Absent for a recovered run (no in-process caller is awaiting it). */
  private readonly runResolvers: Record<DelegationId, (value: Value) => void> = {};
  private readonly runRejecters: Record<DelegationId, (error: Error) => void> = {};
  /** Run-root requests the engine could not handle, kept open (their run-root instance stays suspended)
   *  until a user answers — keyed by the escalation id, which also names the run delegation it belongs to. */
  private readonly openEscalations: Record<EscalationId, OpenEscalation & { run: DelegationId }> =
    {};
  /** A cancelling run's reason — held only to decorate the in-process `RunCancelledError` (the durable cancel
   *  reason is recorded separately, on `runs.cancelReason`, and is the source of truth). Kept only while we
   *  are still tracking the run in-process, so it cannot outlive the run it belongs to (see `cancelRun`). */
  private readonly cancelReasons: Record<DelegationId, string | undefined> = {};

  constructor(private readonly host: ApiHost) {}

  // ─── commands (the api root issuing external events on a user's behalf) ─────────────────────────

  /** Start a run: summon a root instance for `qualifiedName@snapshot`. Returns the run delegation (the
   *  handle for `cancelRun`) and a promise that settles with the result (or rejects: a panic / unhandled
   *  escape fails it, a cancel rejects it with `RunCancelledError`). */
  startRun(
    qualifiedName: QualifiedName,
    snapshot: SnapshotId,
    argument: Value | null,
  ): { run: DelegationId; result: Promise<Value> } {
    // A run is a `delegate` the api root issues to a `core` instance. Record the root as the delegation's
    // caller (it is the issuer) — this routes the run's delegateAck / escalate / terminateAck back here. The
    // delegate is produced durably (an outbox row), so the run survives a crash before its root is created.
    const delegation = newDelegationId();
    this.host.openRunDelegation(delegation);
    const result = new Promise<Value>((resolve, reject) => {
      this.runResolvers[delegation] = resolve;
      this.runRejecters[delegation] = reject;
    });
    void this.host.commit(
      {
        instanceId: this.host.apiRootId,
        layer2: { kind: "none" },
        transitions: [],
        outbound: [
          {
            kind: "delegate",
            delegation,
            target: { kind: "named", name: qualifiedName, snapshot },
            argument,
          },
        ],
      },
      null,
    );
    return { run: delegation, result };
  }

  /** Request a run's cancellation: terminate its root instance. The cascade tears the tree down and the
   *  terminateAck rejects the run with `RunCancelledError`; a no-op in the engine if the run already finished.
   *  Always produce the terminate (so a recovered, still-live run is cancellable too — it has no in-process
   *  handlers). Record the in-process reason only while this run is still tracked here: if it already settled
   *  (or this is a recovered run with no in-process awaiter), there is nothing to decorate and no terminateAck
   *  will arrive to clear the entry, so storing it would leak — the durable `runs.cancelReason` holds it. */
  cancelRun(run: DelegationId, reason?: string): void {
    if (this.runResolvers[run] !== undefined) this.cancelReasons[run] = reason;
    void this.host.commit(
      {
        instanceId: this.host.apiRootId,
        layer2: { kind: "none" },
        transitions: [],
        outbound: [{ kind: "terminate", delegation: run }],
      },
      null,
    );
  }

  /** Answer an open run-root escalation: relay the value back to its suspended raiser, which resumes. Loads
   *  first, so a cold / freshly-recovered actor rehydrates its open escalations before the lookup (otherwise
   *  a valid answer would be silently dropped); the in-memory entry is cleared only after the `escalateAck`
   *  is durably produced, so a commit failure leaves it answerable. */
  async answerEscalation(escalation: EscalationId, value: Value): Promise<void> {
    await this.host.ensureLoaded();
    const open = this.openEscalations[escalation];
    if (open === undefined) return;
    await this.host.commit(
      {
        instanceId: this.host.apiRootId,
        layer2: { kind: "none" },
        transitions: [],
        outbound: [{ kind: "escalateAck", delegation: open.run, escalation, value }],
      },
      null,
    );
    delete this.openEscalations[escalation];
  }

  /** The run-root escalations currently awaiting an answer. */
  listOpenEscalations(): OpenEscalation[] {
    return Object.values(this.openEscalations).map(({ escalation, request, argument }) => ({
      escalation,
      request,
      argument,
    }));
  }

  /** Re-establish one user-facing open escalation on recovery (the substrate decides which are user-facing
   *  and supplies the run delegation it belongs to). */
  rehydrateOpenEscalation(open: OpenEscalation & { run: DelegationId }): void {
    this.openEscalations[open.escalation] = open;
  }

  // ─── reactions (a run's delegateAck / escalate / terminateAck reaching the management root) ──────

  /** A run finished: settle its result. */
  onDelegateAck(delegation: DelegationId, value: Value): void {
    this.host.closeRunDelegation(delegation);
    this.settleRun(delegation, { value });
  }

  /** A run's escalation reached the root unhandled: a genuine request is kept open for a user to answer (the
   *  run stays suspended); a panic / unhandled escape fails the run. Consumes the escalate's outbox row. */
  async onEscalate(
    event: Extract<ExternalEvent, { kind: "escalate" }>,
    seq: OutboxSeq | null,
  ): Promise<void> {
    const ask = event.ask;
    if (ask.kind === "request" && ask.request !== PANIC_REQUEST) {
      this.openEscalations[event.escalation] = {
        run: event.delegation,
        escalation: event.escalation,
        request: ask.request,
        argument: ask.argument,
      };
      // Just consume the escalate's row: the escalation already opened durably in the raiser's turn; the api
      // root only keeps it in memory so it can be answered.
      await this.host.commit(
        {
          instanceId: this.host.apiRootId,
          layer2: { kind: "none" },
          transitions: [],
          outbound: [],
        },
        seq,
      );
      return;
    }
    // The run failed (a panic / unhandled escape reached the root). In one api-root commit (no engine
    // threads): record the run delegation's terminal `failed` state and durably produce the `terminate`
    // that tears its still-suspended root down (so it does not leak). The teardown's eventual `gone` is a
    // no-op against the now-terminal `failed` (terminal states are sticky). Then settle the result promise.
    const errorMessage = escalationErrorMessage(event);
    await this.host.commit(
      {
        instanceId: this.host.apiRootId,
        layer2: { kind: "none" },
        transitions: [{ kind: "delegation-failed", delegation: event.delegation, errorMessage }],
        outbound: [{ kind: "terminate", delegation: event.delegation }],
      },
      seq,
    );
    this.settleRun(event.delegation, { error: new Error(errorMessage) });
  }

  /** A run's terminate cascade confirmed: settle it as cancelled. */
  onTerminateAck(delegation: DelegationId): void {
    this.host.closeRunDelegation(delegation);
    this.settleRun(delegation, { error: new RunCancelledError(this.cancelReasons[delegation]) });
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

/** A human message for an escalation that reached the run root unhandled (it fails the run). A panic
 *  reports its `{ msg }`; any other unhandled request / control escape reports its name. */
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
