// ApiModule — proxy endpoint for the user (CLI / external client).
//
// Following the design "the API module is not the HTTP server, it is the
// user", HTTP routes are thin shims that call special ApiModule methods
// (startRun / cancelRun / answerEscalation / list*) and kick the bus.
//
// State (DB-backed):
//   - delegations  : ApiModule-issued live entities (= top-level / root delegations
//                    + nothing else, since API only delegates downward to CORE)
//   - escalations  : open AI→user questions awaiting operator reply (receiver=API)
//   - runs_audit   : persistent log of operator-launched root delegations;
//                    survives the live delegations row's terminal deletion so
//                    the UI can show "Run X finished with result Y"
//
// per-tick instance: lives within one request. Persistence writes through
// via tx, so `persist()` / `load()` are no-ops.

import {
  API_ENDPOINT,
  CORE_ENDPOINT,
  createDelegationId,
  type ExternalEvent,
  encodeCoreAgentDefId,
  encryptValueRecord,
  encryptValueTree,
  type Logger,
  type Module,
  type Value,
} from "@katari-lang/runtime";

const THROW_AGENT_DEF_ID = encodeCoreAgentDefId({ kind: "qname", value: "prim.throw" });

import type { DelegationId, EscalationId } from "@katari-lang/runtime";
import type { RunsAuditRow, SnapshotId, Storage } from "../storage/types.js";

/** Default `run.name` used when the caller omits one. Format pairs the
 *  agent qualified name with a wall-clock time, so the run is identifiable
 *  in the Runs list at a glance ("hello.main @ 15:42") without the user
 *  having to think up a label. The seconds are dropped because two runs
 *  fired in the same minute is rare in operator workflow; if it happens
 *  the row's id and createdAt still disambiguate. */
function defaultRunName(qualifiedName: string, now: Date): string {
  const h = String(now.getHours()).padStart(2, "0");
  const m = String(now.getMinutes()).padStart(2, "0");
  return `${qualifiedName} @ ${h}:${m}`;
}

export type ApiModuleOptions = {
  snapshotId: SnapshotId;
  tx: Storage;
  logger: Logger;
};

export class ApiModule implements Module {
  readonly endpoint = API_ENDPOINT;
  private readonly snapshotId: SnapshotId;
  private readonly tx: Storage;
  private readonly logger: Logger;

  constructor(opts: ApiModuleOptions) {
    this.snapshotId = opts.snapshotId;
    this.tx = opts.tx;
    this.logger = opts.logger;
  }

  // ─── Module interface ───────────────────────────────────────────────────

  async feed(event: ExternalEvent): Promise<{ outbound: ExternalEvent[] }> {
    switch (event.payload.kind) {
      case "delegate":
        // The user (= API module) provides no agent definitions, so any
        // delegate addressed to it is a misconfigured caller. Drop with a
        // log so the issue surfaces.
        this.logger.log("warn", "api: received delegate but provides no defs", {
          delegationId: event.payload.delegationId,
        });
        return { outbound: [] };

      case "delegateAck":
        await this.completeRun(event.payload.delegationId, event.payload.value);
        return { outbound: [] };

      case "terminate":
        this.logger.log("debug", "api: terminate dropped (no agents to cancel)", {
          delegationId: event.payload.delegationId,
        });
        return { outbound: [] };

      case "terminateAck":
        await this.handleTerminateAck(event.payload.delegationId);
        return { outbound: [] };

      case "escalate":
        if (event.payload.agentDefId === THROW_AGENT_DEF_ID) {
          return await this.handleThrowEscalate(event.payload.delegationId, event.payload.args);
        }
        await this.recordEscalation({
          from: event.from,
          payload: event.payload,
        });
        return { outbound: [] };

      case "escalateAck":
        // There is no user -> CORE escalate flow, so drop with a debug log.
        this.logger.log("debug", "api: stray escalateAck", {
          escalationId: event.payload.escalationId,
        });
        return { outbound: [] };
    }
  }

  async persist(_tx: unknown): Promise<void> {}
  async load(_tx: unknown): Promise<void> {}

  // ─── HTTP-facing methods (called by routes) ─────────────────────────────

  async startRun(input: {
    bus: { push: (event: ExternalEvent) => void };
    qualifiedName: string;
    /** Display label. When `null` / omitted, a default like
     *  `"<qualifiedName> @ HH:mm"` is substituted so the audit row always
     *  carries a non-empty name. */
    name: string | null;
    args: Record<string, Value>;
  }): Promise<{ runId: DelegationId }> {
    const delegationId = createDelegationId();
    const startedAt = new Date();
    const now = startedAt.toISOString();
    const encryptedArgs = encryptValueRecord(input.args);
    const name =
      input.name !== null && input.name !== ""
        ? input.name
        : defaultRunName(input.qualifiedName, startedAt);

    // Two-row insert: the live delegation entity (= drives runtime
    // dispatch + cancel cascade) and the persistent audit row (= survives
    // terminal state for the operator's history view).
    await this.tx.delegations.insert({
      id: delegationId,
      rootDelegationId: delegationId,
      parentDelegationId: null,
      snapshotId: this.snapshotId,
      callerEndpoint: API_ENDPOINT,
      ownerEndpoint: CORE_ENDPOINT,
      agentDefId: encodeCoreAgentDefId({
        kind: "qname",
        value: input.qualifiedName,
      }),
      args: encryptedArgs,
      state: "running",
      createdAt: now,
      updatedAt: now,
    });

    const auditRow: RunsAuditRow = {
      id: delegationId,
      snapshotId: this.snapshotId,
      name,
      qualifiedName: input.qualifiedName,
      args: encryptedArgs,
      state: "running",
      cancelReason: null,
      createdAt: now,
      updatedAt: now,
    };
    await this.tx.runsAudit.insert(auditRow);

    input.bus.push({
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: {
        kind: "delegate",
        delegationId,
        agentDefId: encodeCoreAgentDefId({
          kind: "qname",
          value: input.qualifiedName,
        }),
        args: input.args,
      },
    });
    return { runId: delegationId };
  }

  async cancelRun(input: {
    bus: { push: (event: ExternalEvent) => void };
    runId: DelegationId;
  }): Promise<{ row: RunsAuditRow | null }> {
    const auditRow = await this.tx.runsAudit.get(input.runId);
    if (auditRow === null) return { row: null };
    if (auditRow.state !== "running") return { row: auditRow };

    // 1. Mark audit row as cancelling (user-initiated).
    await this.tx.runsAudit.setState(input.runId, {
      state: "cancelling",
      cancelReason: "user",
    });

    // 2-3. Cascade through the run's tree: live delegations → cancelling,
    //      open escalations → cancelled.
    await this.tx.delegations.markAllUnderRootAsCancelling(input.runId);
    await this.tx.escalations.cancelAllUnderRoot(input.runId);

    // 4. Send terminate to CORE for the root only. The engine cascades
    //    cancel through its internal threads and emits terminateAck.
    input.bus.push({
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: {
        kind: "terminate",
        delegationId: input.runId,
      },
    });

    const refreshed = await this.tx.runsAudit.get(input.runId);
    return { row: refreshed };
  }

  async answerEscalation(input: {
    bus: { push: (event: ExternalEvent) => void };
    escalationId: EscalationId;
    value: Value;
  }): Promise<{ ok: boolean }> {
    const ok = await this.tx.escalations.setAnswered(
      input.escalationId,
      encryptValueTree(input.value),
    );
    if (!ok) return { ok: false };
    input.bus.push({
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: {
        kind: "escalateAck",
        escalationId: input.escalationId,
        value: input.value,
      },
    });
    return { ok: true };
  }

  // ─── Internal helpers ──────────────────────────────────────────────────

  /**
   * Unhandled `prim.throw` reached the API boundary. The throw originated
   * inside `delegationId`'s tree, so we cascade-cancel only that run —
   * NOT every running delegation in the snapshot, which the previous
   * implementation did.
   */
  private async handleThrowEscalate(
    delegationId: DelegationId,
    args: Record<string, Value>,
  ): Promise<{ outbound: ExternalEvent[] }> {
    const msgValue = args["msg"];
    const message =
      msgValue !== undefined && msgValue.kind === "string" ? msgValue.value : "runtime error";

    const liveRow = await this.tx.delegations.get(delegationId);
    const rootId = liveRow?.rootDelegationId ?? delegationId;

    // Mark audit row as cancelling(reason=error) + persist the message
    // so the eventual terminateAck → terminal transition keeps the cause.
    await this.tx.runsAudit.setState(rootId, {
      state: "cancelling",
      cancelReason: "error",
      errorMessage: message,
    });

    await this.tx.delegations.markAllUnderRootAsCancelling(rootId);
    await this.tx.escalations.cancelAllUnderRoot(rootId);

    this.logger.log("info", "api: prim.throw escalate — run cancelling", {
      delegationId,
      rootId,
      message,
    });

    return {
      outbound: [
        {
          from: API_ENDPOINT,
          to: CORE_ENDPOINT,
          payload: { kind: "terminate", delegationId: rootId },
        },
      ],
    };
  }

  private async recordEscalation(event: {
    from: string;
    payload: Extract<ExternalEvent["payload"], { kind: "escalate" }>;
  }): Promise<void> {
    const { delegationId, escalationId, agentDefId, args } = event.payload;
    const live = await this.tx.delegations.get(delegationId);
    const rootId = live?.rootDelegationId ?? delegationId;
    await this.tx.escalations.insert({
      id: escalationId,
      delegationId,
      rootDelegationId: rootId,
      snapshotId: this.snapshotId,
      callerEndpoint: event.from,
      receiverEndpoint: API_ENDPOINT,
      agentDefId,
      args: encryptValueRecord(args),
      state: "open",
      createdAt: new Date().toISOString(),
    });
  }

  private async completeRun(delegationId: DelegationId, value: Value): Promise<void> {
    // Audit row update only happens if this was an operator-launched
    // root. delegateAcks for child delegations don't reach the API
    // module (they're owned by CORE / FFI), but we guard with a lookup
    // anyway in case the protocol invariant is bent later.
    const auditRow = await this.tx.runsAudit.get(delegationId);
    if (auditRow !== null) {
      await this.tx.runsAudit.setState(delegationId, {
        state: "succeeded",
        result: encryptValueTree(value),
        completedAt: new Date().toISOString(),
      });
    } else {
      this.logger.log("warn", "api: delegateAck for unknown run id", {
        delegationId,
      });
    }
    // Delete the entire delegation tree (root + all children) so no
    // orphan child rows linger after the run completes.
    await this.tx.delegations.deleteAllUnderRoot(delegationId);
  }

  private async handleTerminateAck(delegationId: DelegationId): Promise<void> {
    // Resolve the eventual audit-row state from the cancel reason that
    // cancelRun / handleThrowEscalate persisted when transitioning to
    // `cancelling`. user → cancelled, error → error.
    const auditRow = await this.tx.runsAudit.get(delegationId);
    if (auditRow !== null) {
      const finalState = auditRow.cancelReason === "error" ? "error" : "cancelled";
      await this.tx.runsAudit.setState(delegationId, {
        state: finalState,
        completedAt: new Date().toISOString(),
      });
    }
    await this.tx.delegations.deleteAllUnderRoot(delegationId);
  }
}
