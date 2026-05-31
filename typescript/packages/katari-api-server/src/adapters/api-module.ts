// ApiModule — the user-facing module (CLI / external client proxy).
//
// "The API module is not the HTTP server, it is the user": HTTP routes are thin
// shims that call ApiModule domain methods (startRun / cancelRun /
// answerEscalation) and the bus drains the rest. It is a warm, per-project
// module that owns its own transaction (1 quantum = 1 tx).
//
// Entity model (docs/2026-06-01-entity-model.md). The API owns the top of the
// tree + the per-run bookkeeping:
//   - project-root entity (module=api, id = projectId, delegation_id=null) —
//     owns user uploads; created lazily; kept for the project's life.
//   - run-root entity (module=api, id = E_run) — one per run; the project root
//     issues `D_run` to summon it, and it issues `D_core` to the CORE root.
//     Claims the run's result refs; kept as run history.
//   - Run record (`runs`, id = E_run) — the run's management state
//     (running/cancelling/done/error), reflecting the CORE-root child.
//
// The API issues the run-root + CORE-root delegations (and deletes them on their
// acks) and claims the result value's refs to the run-root on `delegateAck`
// (value-driven ascent). Escalations are owned by their raiser (CORE writes the
// live row); the API only answers + audits.

import {
  API_ENDPOINT,
  CORE_ENDPOINT,
  collectRefs,
  createDelegationId,
  createEntityId,
  type ExternalEvent,
  encodeCoreAgentDefId,
  encryptValueRecord,
  encryptValueTree,
  type Logger,
  type Module,
  THROW_REQUEST_QNAME,
  tryInlineString,
  type Value,
} from "@katari-lang/runtime";

// The unhandled-throw escalate's id, derived from the runtime's single source of
// truth (a hand-typed string would silently never match).
const THROW_AGENT_DEF_ID = encodeCoreAgentDefId({ kind: "qname", value: THROW_REQUEST_QNAME });

import type { DelegationId, EntityId, EscalationId } from "@katari-lang/runtime";
import { ensureProjectRootEntity } from "../entity-roots.js";
import { NoSnapshotForProject, SnapshotNotFound } from "../services/snapshot-service.js";
import type { ProjectId, RunId, RunRow, SnapshotId, Storage } from "../storage/types.js";

/** Default `run.name` — the agent qname + wall-clock ("hello.main @ 15:42"). */
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
        // A user-facing capability escalate. The raiser (CORE) owns the live
        // `escalations` row; the API records its own per-run operator view
        // (mapping the bus `delegationId = D_core` → run — its OWN tables only).
        await this.recordPendingEscalation(event.payload);
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
  }): Promise<{ runId: RunId }> {
    const runEntityId = createEntityId() as unknown as EntityId; // E_run
    const runDelegationId = createDelegationId(); // D_run (project-root → run-root)
    const coreDelegationId = createDelegationId(); // D_core (run-root → CORE root)
    const startedAt = new Date();
    const now = startedAt.toISOString();
    const encryptedArgs = encryptValueRecord(input.args);
    const name =
      input.name !== null && input.name !== ""
        ? input.name
        : defaultRunName(input.qualifiedName, startedAt);

    // Resolve + record + enqueue in one tx so the snapshot can't vanish between
    // resolve and insert.
    const snapshotId = await this.storage.withTransaction(async (tx) => {
      const resolved = input.snapshotId ?? (await tx.snapshots.latest(this.projectId)) ?? null;
      if (resolved === null) throw new NoSnapshotForProject(this.projectId);
      if ((await tx.snapshots.get(resolved)) === null) throw new SnapshotNotFound(resolved);

      const projectRoot = await this.ensureProjectRoot(tx);
      const coreAgentDefId = encodeCoreAgentDefId({
        kind: "qname",
        value: input.qualifiedName,
        snapshot: resolved,
      });

      // run-root entity (the API runs it) — the project root summons it via D_run.
      await tx.delegations.insert({
        id: runDelegationId,
        projectId: this.projectId,
        parentEntityId: projectRoot,
        targetModule: "api",
        agentDefId: coreAgentDefId,
        args: encryptedArgs,
        state: "running",
        createdAt: now,
        updatedAt: now,
      });
      await tx.entities.insert({
        id: runEntityId,
        delegationId: runDelegationId,
        projectId: this.projectId,
        module: "api",
        state: "running",
        agentDefId: null,
        args: encryptedArgs,
        createdAt: now,
        updatedAt: now,
      });
      // The run-root issues D_core to the CORE root.
      await tx.delegations.insert({
        id: coreDelegationId,
        projectId: this.projectId,
        parentEntityId: runEntityId,
        targetModule: "core",
        agentDefId: coreAgentDefId,
        args: encryptedArgs,
        state: "running",
        createdAt: now,
        updatedAt: now,
      });
      await tx.runs.insert({
        id: runEntityId as unknown as RunId,
        projectId: this.projectId,
        snapshotId: resolved,
        coreDelegationId,
        name,
        qualifiedName: input.qualifiedName,
        args: encryptedArgs,
        state: "running",
        cancelReason: null,
        createdAt: now,
        updatedAt: now,
      });
      return resolved;
    });

    input.bus.push({
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: {
        kind: "delegate",
        delegationId: coreDelegationId,
        agentDefId: encodeCoreAgentDefId({
          kind: "qname",
          value: input.qualifiedName,
          snapshot: snapshotId,
        }),
        args: input.args,
      },
    });
    return { runId: runEntityId as unknown as RunId };
  }

  async cancelRun(input: {
    bus: { push: (event: ExternalEvent) => void };
    runId: RunId;
  }): Promise<{ row: RunRow | null }> {
    const refreshed = await this.storage.withTransaction(async (tx) => {
      const run = await tx.runs.get(input.runId);
      if (run === null) return null;
      if (run.state !== "running") return run;
      await tx.runs.setState(input.runId, { state: "cancelling", cancelReason: "user" });
      await tx.entities.setState(input.runId as unknown as EntityId, "cancelling");
      return tx.runs.get(input.runId);
    });
    if (refreshed === null) return { row: null };

    // Terminate the CORE root; the engine cascades the cancel through its
    // threads and emits terminateAck.
    input.bus.push({
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: { kind: "terminate", delegationId: refreshed.coreDelegationId },
    });
    return { row: refreshed };
  }

  async answerEscalation(input: {
    bus: { push: (event: ExternalEvent) => void };
    escalationId: EscalationId;
    value: Value;
  }): Promise<{ ok: boolean }> {
    const ok = await this.storage.withTransaction((tx) =>
      tx.runEscalationsAudit.setAnswer(
        input.escalationId,
        encryptValueTree(input.value),
        new Date().toISOString(),
      ),
    );
    if (!ok) return { ok: false };
    // The raiser (CORE) deletes its own escalation row on escalateAck.
    input.bus.push({
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: { kind: "escalateAck", escalationId: input.escalationId, value: input.value },
    });
    return { ok: true };
  }

  // ─── Internal helpers ──────────────────────────────────────────────────

  /** Get-or-create the project-root entity (id = projectId). */
  private ensureProjectRoot(tx: Storage): Promise<EntityId> {
    return ensureProjectRootEntity(tx, this.projectId);
  }

  /** Record a pending operator-facing escalation. The escalate reaches the API
   *  with `delegationId = D_core` (each forward hop re-stamps it to the
   *  forwarder's delegation, so the CORE root's = the run's `coreDelegationId`),
   *  so the run resolves from the API's OWN `runs` table — no walk into CORE. */
  private async recordPendingEscalation(
    payload: Extract<ExternalEvent["payload"], { kind: "escalate" }>,
  ): Promise<void> {
    await this.storage.withTransaction(async (tx) => {
      const run = await tx.runs.getByCoreDelegation(payload.delegationId);
      if (run === null) {
        this.logger.log("warn", "api: escalate for unknown run", {
          delegationId: payload.delegationId,
          escalationId: payload.escalationId,
        });
        return;
      }
      await tx.runEscalationsAudit.insert({
        runId: run.id,
        escalationId: payload.escalationId,
        agentDefId: payload.agentDefId,
        args: encryptValueRecord(payload.args),
        createdAt: new Date().toISOString(),
      });
    });
  }

  private async handleThrowEscalate(
    delegationId: DelegationId,
    args: Record<string, Value>,
  ): Promise<{ outbound: ExternalEvent[] }> {
    const msgValue = args.msg;
    const message = (msgValue !== undefined && tryInlineString(msgValue)) || "runtime error";

    // The throw reaches the API with `delegationId = D_core` (the CORE root
    // re-stamps it on the last hop), so the run resolves from `runs` directly.
    const coreDelegationId = await this.storage.withTransaction(async (tx) => {
      const run = await tx.runs.getByCoreDelegation(delegationId);
      if (run === null) return null;
      await tx.runs.setState(run.id, {
        state: "cancelling",
        cancelReason: "error",
        errorMessage: message,
      });
      return run.coreDelegationId;
    });
    if (coreDelegationId === null) {
      this.logger.log("warn", "api: throw escalate for unknown run", { delegationId, message });
      return { outbound: [] };
    }

    this.logger.log("info", "api: prim.throw escalate — run cancelling", {
      delegationId,
      coreDelegationId,
      message,
    });
    return {
      outbound: [
        {
          from: API_ENDPOINT,
          to: CORE_ENDPOINT,
          payload: { kind: "terminate", delegationId: coreDelegationId },
        },
      ],
    };
  }

  private async completeRun(coreDelegationId: DelegationId, value: Value): Promise<void> {
    await this.storage.withTransaction(async (tx) => {
      const run = await tx.runs.getByCoreDelegation(coreDelegationId);
      if (run === null) {
        this.logger.log("warn", "api: delegateAck for unknown run", { coreDelegationId });
        await tx.delegations.delete(coreDelegationId);
        return;
      }
      // Value-driven ascent: the CORE root detached the result's escaping refs
      // (owner=NULL); claim them to the run-root (kept) so the result persists.
      const seed = collectRefs(value);
      if (seed.length > 0) {
        await tx.values.reownRefs(this.projectId, null, run.id, seed);
      }
      await tx.runs.setState(run.id, {
        state: "done",
        result: encryptValueTree(value),
        completedAt: new Date().toISOString(),
      });
      // Issuer deletes the request edge now the result is in.
      await tx.delegations.delete(coreDelegationId);
    });
  }

  private async handleTerminateAck(coreDelegationId: DelegationId): Promise<void> {
    await this.storage.withTransaction(async (tx) => {
      const run = await tx.runs.getByCoreDelegation(coreDelegationId);
      if (run !== null) {
        await tx.runs.setState(run.id, {
          // The 4-state Run model has no distinct `cancelled`; a user cancel ends
          // as `error` with cancelReason='user' (the UI labels it "cancelled").
          state: "error",
          completedAt: new Date().toISOString(),
        });
      }
      await tx.delegations.delete(coreDelegationId);
    });
  }
}
