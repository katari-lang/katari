// ApiModule — ユーザー (CLI / external client) の代理 endpoint。
//
// 「API module は HTTP server ではなく、ユーザーそのもの」という設計に従い、
// HTTP route は ApiModule の特殊メソッド (startAgent / cancelAgent /
// answerEscalation / list*) を呼んで bus を kick する薄い shim。
//
// State (DB-backed):
//   - pendingDelegateOut = `agents` テーブル        (CLI 起動 agent のキュー)
//   - pendingEscalateIn  = `api_pending_escalations` (AI から user への質問待ち)
//
// per-tick instance: 1 request の中で生きる。永続化は tx 経由で書き通すので
// `persist()` / `load()` は no-op。

import {
  API_ENDPOINT,
  CORE_ENDPOINT,
  createDelegationId,
  encodeCoreAgentDefId,
  type ExternalEvent,
  type Logger,
  type Module,
  type Value,
} from "@katari-lang/runtime";

const THROW_AGENT_DEF_ID = encodeCoreAgentDefId({ kind: "qname", value: "prim.throw" });
import type { DelegationId, EscalationId } from "@katari-lang/runtime";
import type {
  AgentId,
  AgentRow,
  Storage,
  SnapshotId,
} from "../storage/types.js";

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
        // ユーザー (= API module) は agent 定義を提供しない。
        this.logger.log("warn", "api: received delegate but provides no defs", {
          delegationId: event.payload.delegationId,
        });
        return { outbound: [] };

      case "delegateAck":
        await this.completeAgent(event.payload.delegationId, event.payload.value);
        return { outbound: [] };

      case "terminate":
        this.logger.log("debug", "api: terminate dropped (no agents to cancel)", {
          delegationId: event.payload.delegationId,
        });
        return { outbound: [] };

      case "terminateAck":
        await this.markCancelled(event.payload.delegationId);
        return { outbound: [] };

      case "escalate":
        if (event.payload.agentDefId === THROW_AGENT_DEF_ID) {
          return await this.handleThrowEscalate(
            event.payload.delegationId,
            event.payload.args,
          );
        }
        // AI から user への質問。pending escalation として永続化。
        await this.tx.apiEscalations.insert({
          escalationId: event.payload.escalationId,
          delegationId: event.payload.delegationId,
          snapshotId: this.snapshotId,
          agentDefId: event.payload.agentDefId,
          args: event.payload.args,
          state: "open",
          createdAt: new Date().toISOString(),
        });
        return { outbound: [] };

      case "escalateAck":
        // ユーザー → CORE への escalate flow がないので drop with debug log。
        this.logger.log("debug", "api: stray escalateAck", {
          escalationId: event.payload.escalationId,
        });
        return { outbound: [] };
    }
  }

  async persist(_tx: unknown): Promise<void> {}
  async load(_tx: unknown): Promise<void> {}

  // ─── HTTP-facing methods (called by routes) ─────────────────────────────

  async startAgent(input: {
    bus: { push: (event: ExternalEvent) => void };
    qualifiedName: string;
    args: Record<string, Value>;
  }): Promise<{ agentId: AgentId }> {
    const delegationId = createDelegationId();
    const agentId = delegationId as unknown as AgentId;
    const now = new Date().toISOString();
    const row: AgentRow = {
      id: agentId,
      delegationId,
      snapshotId: this.snapshotId,
      qualifiedName: input.qualifiedName,
      args: input.args,
      state: "running",
      createdAt: now,
      updatedAt: now,
    };
    await this.tx.agents.insert(row);
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
    return { agentId };
  }

  async cancelAgent(input: {
    bus: { push: (event: ExternalEvent) => void };
    agentId: AgentId;
  }): Promise<{ row: AgentRow | null }> {
    const row = await this.tx.agents.get(input.agentId);
    if (row === null) return { row: null };
    if (row.state !== "running") return { row };
    const ok = await this.tx.agents.setState(
      input.agentId,
      { state: "cancelling" },
      { expectedState: "running" },
    );
    if (!ok) {
      const refreshed = await this.tx.agents.get(input.agentId);
      return { row: refreshed };
    }
    input.bus.push({
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: {
        kind: "terminate",
        delegationId: row.delegationId,
      },
    });
    const refreshed = await this.tx.agents.get(input.agentId);
    return { row: refreshed };
  }

  async answerEscalation(input: {
    bus: { push: (event: ExternalEvent) => void };
    escalationId: EscalationId;
    value: Value;
  }): Promise<{ ok: boolean }> {
    const ok = await this.tx.apiEscalations.setAnswered(
      input.escalationId,
      input.value,
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
   * Handle an unhandled `prim.throw` escalate:
   *   1. Mark all running/cancelling agents in the snapshot as `error`.
   *   2. Send `terminate` to CORE for every agent that was still running.
   *
   * The CORE AgentThreads receive the cancel, complete their cascade, and
   * emit `terminateAck`. When `markCancelled` runs for those, it attempts
   * `cancelling → cancelled` but finds `error` (expectedState mismatch) →
   * no-op, leaving the row in `error` state.
   */
  private async handleThrowEscalate(
    delegationId: DelegationId,
    args: Record<string, Value>,
  ): Promise<{ outbound: ExternalEvent[] }> {
    const msgValue = args["msg"];
    const message =
      msgValue !== undefined && msgValue.kind === "string"
        ? msgValue.value
        : "runtime error";

    // Collect running delegations before marking them all as error.
    const runningAgents = await this.tx.agents.list({
      snapshotId: this.snapshotId,
      state: "running",
    });

    await this.tx.agents.markAllRunningAsError(this.snapshotId, message);

    const outbound: ExternalEvent[] = runningAgents.map((agent) => ({
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: {
        kind: "terminate" as const,
        delegationId: agent.delegationId,
      },
    }));

    this.logger.log("info", "api: prim.throw escalate — snapshot terminated", {
      delegationId,
      message,
      terminatedCount: outbound.length,
    });

    return { outbound };
  }

  private async completeAgent(
    delegationId: DelegationId,
    value: Value,
  ): Promise<void> {
    const row = await this.tx.agents.findByDelegationId(delegationId);
    if (row === null) {
      this.logger.log("warn", "api: delegateAck for unknown delegationId", {
        delegationId,
      });
      return;
    }
    await this.tx.agents.setState(
      row.id,
      { state: "succeeded", result: value },
      { expectedState: "running" },
    );
  }

  private async markCancelled(delegationId: DelegationId): Promise<void> {
    const row = await this.tx.agents.findByDelegationId(delegationId);
    if (row === null) return;
    await this.tx.agents.setState(
      row.id,
      { state: "cancelled" },
      { expectedState: "cancelling" },
    );
  }
}

