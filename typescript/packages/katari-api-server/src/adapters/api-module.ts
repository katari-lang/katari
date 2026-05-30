// ApiModule — the user-facing module (CLI / external client proxy).
//
// "The API module is not the HTTP server, it is the user": HTTP routes are thin
// shims that call ApiModule domain methods (startRun / cancelRun /
// answerEscalation) and the bus drains the rest. Phase E makes it a warm,
// per-project module that owns its own transaction: each domain method + each
// `feed` opens its own tx over the root storage (1 quantum = 1 tx).
//
// State (DB-backed):
//   - delegations  : the live run tree (protocol entity, project-scoped — the
//                    snapshot a delegation runs is CORE-private state, not here)
//   - escalations  : open AI→user questions awaiting an operator reply
//   - runs_audit   : ApiModule's OWN audit log of operator-launched roots. A
//                    "run" is bound to a snapshot (which version was launched),
//                    so runs_audit keeps the snapshot id — that is API-private
//                    state, not the protocol delegations row.

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
  tryInlineString,
  type Value,
} from "@katari-lang/runtime";

const THROW_AGENT_DEF_ID = encodeCoreAgentDefId({ kind: "qname", value: "prim.throw" });

import type { DelegationId, EscalationId } from "@katari-lang/runtime";
import { NoSnapshotForProject, SnapshotNotFound } from "../services/snapshot-service.js";
import type { ProjectId, RunsAuditRow, SnapshotId, Storage } from "../storage/types.js";

/** Default `run.name` — pairs the agent qname with a wall-clock time so the run
 *  is identifiable in the Runs list at a glance ("hello.main @ 15:42"). */
function defaultRunName(qualifiedName: string, now: Date): string {
  const h = String(now.getHours()).padStart(2, "0");
  const m = String(now.getMinutes()).padStart(2, "0");
  return `${qualifiedName} @ ${h}:${m}`;
}

export type ApiModuleOptions = {
  projectId: ProjectId;
  /** Root storage — domain methods + feed open their own tx over it. */
  storage: Storage;
  logger: Logger;
};

export class ApiModule implements Module {
  readonly endpoint = API_ENDPOINT;
  private readonly projectId: ProjectId;
  private readonly storage: Storage;
  private readonly logger: Logger;

  constructor(opts: ApiModuleOptions) {
    this.projectId = opts.projectId;
    this.storage = opts.storage;
    this.logger = opts.logger;
  }

  // ─── Module interface ───────────────────────────────────────────────────

  async feed(event: ExternalEvent): Promise<{ outbound: ExternalEvent[] }> {
    switch (event.payload.kind) {
      case "delegate":
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
        await this.recordEscalation({ from: event.from, payload: event.payload });
        return { outbound: [] };

      case "escalateAck":
        this.logger.log("debug", "api: stray escalateAck", {
          escalationId: event.payload.escalationId,
        });
        return { outbound: [] };
    }
  }

  // ─── HTTP-facing methods (called by routes) ─────────────────────────────

  async startRun(input: {
    bus: { push: (event: ExternalEvent) => void };
    /** When omitted, the project's latest snapshot is used. */
    snapshotId?: SnapshotId;
    qualifiedName: string;
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

    // Resolve + record + enqueue in one tx so the snapshot can't vanish between
    // resolve and insert. The root delegate is stamped with the resolved
    // snapshot (a CORE agent → snapshot-dependent target) so CORE starts the
    // agent on the right IR version.
    const snapshotId = await this.storage.withTransaction(async (tx) => {
      const resolved = input.snapshotId ?? (await tx.snapshots.latest(this.projectId)) ?? null;
      if (resolved === null) throw new NoSnapshotForProject(this.projectId);
      if ((await tx.snapshots.get(resolved)) === null) throw new SnapshotNotFound(resolved);

      await tx.delegations.insert({
        id: delegationId,
        rootDelegationId: delegationId,
        parentDelegationId: null,
        projectId: this.projectId,
        callerEndpoint: API_ENDPOINT,
        ownerEndpoint: CORE_ENDPOINT,
        agentDefId: encodeCoreAgentDefId({
          kind: "qname",
          value: input.qualifiedName,
          snapshot: resolved,
        }),
        args: encryptedArgs,
        state: "running",
        createdAt: now,
        updatedAt: now,
      });

      const auditRow: RunsAuditRow = {
        id: delegationId,
        snapshotId: resolved,
        name,
        qualifiedName: input.qualifiedName,
        args: encryptedArgs,
        state: "running",
        cancelReason: null,
        createdAt: now,
        updatedAt: now,
      };
      await tx.runsAudit.insert(auditRow);
      return resolved;
    });

    input.bus.push({
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: {
        kind: "delegate",
        delegationId,
        agentDefId: encodeCoreAgentDefId({
          kind: "qname",
          value: input.qualifiedName,
          snapshot: snapshotId,
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
    const refreshed = await this.storage.withTransaction(async (tx) => {
      const auditRow = await tx.runsAudit.get(input.runId);
      if (auditRow === null) return null;
      if (auditRow.state !== "running") return auditRow;

      await tx.runsAudit.setState(input.runId, { state: "cancelling", cancelReason: "user" });
      await tx.delegations.markAllUnderRootAsCancelling(input.runId);
      await tx.escalations.cancelAllUnderRoot(input.runId);
      return tx.runsAudit.get(input.runId);
    });
    if (refreshed === null) return { row: null };

    // Send terminate to CORE for the root only; the engine cascades the cancel
    // through its threads and emits terminateAck.
    input.bus.push({
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: { kind: "terminate", delegationId: input.runId },
    });
    return { row: refreshed };
  }

  async answerEscalation(input: {
    bus: { push: (event: ExternalEvent) => void };
    escalationId: EscalationId;
    value: Value;
  }): Promise<{ ok: boolean }> {
    const ok = await this.storage.withTransaction((tx) =>
      tx.escalations.setAnswered(input.escalationId, encryptValueTree(input.value)),
    );
    if (!ok) return { ok: false };
    input.bus.push({
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: { kind: "escalateAck", escalationId: input.escalationId, value: input.value },
    });
    return { ok: true };
  }

  // ─── Internal helpers ──────────────────────────────────────────────────

  private async handleThrowEscalate(
    delegationId: DelegationId,
    args: Record<string, Value>,
  ): Promise<{ outbound: ExternalEvent[] }> {
    const msgValue = args["msg"];
    const message = (msgValue !== undefined && tryInlineString(msgValue)) || "runtime error";

    const rootId = await this.storage.withTransaction(async (tx) => {
      const liveRow = await tx.delegations.get(delegationId);
      const root = liveRow?.rootDelegationId ?? delegationId;
      await tx.runsAudit.setState(root, {
        state: "cancelling",
        cancelReason: "error",
        errorMessage: message,
      });
      await tx.delegations.markAllUnderRootAsCancelling(root);
      await tx.escalations.cancelAllUnderRoot(root);
      return root;
    });

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
    await this.storage.withTransaction(async (tx) => {
      const live = await tx.delegations.get(delegationId);
      const rootId = live?.rootDelegationId ?? delegationId;
      await tx.escalations.insert({
        id: escalationId,
        delegationId,
        rootDelegationId: rootId,
        projectId: this.projectId,
        callerEndpoint: event.from,
        receiverEndpoint: API_ENDPOINT,
        agentDefId,
        args: encryptValueRecord(args),
        state: "open",
        createdAt: new Date().toISOString(),
      });
    });
  }

  private async completeRun(delegationId: DelegationId, value: Value): Promise<void> {
    await this.storage.withTransaction(async (tx) => {
      const auditRow = await tx.runsAudit.get(delegationId);
      if (auditRow !== null) {
        await tx.runsAudit.setState(delegationId, {
          state: "succeeded",
          result: encryptValueTree(value),
          completedAt: new Date().toISOString(),
        });
      } else {
        this.logger.log("warn", "api: delegateAck for unknown run id", { delegationId });
      }
      await tx.delegations.deleteAllUnderRoot(delegationId);
    });
  }

  private async handleTerminateAck(delegationId: DelegationId): Promise<void> {
    await this.storage.withTransaction(async (tx) => {
      const auditRow = await tx.runsAudit.get(delegationId);
      if (auditRow !== null) {
        const finalState = auditRow.cancelReason === "error" ? "error" : "cancelled";
        await tx.runsAudit.setState(delegationId, {
          state: finalState,
          completedAt: new Date().toISOString(),
        });
      }
      await tx.delegations.deleteAllUnderRoot(delegationId);
    });
  }
}
