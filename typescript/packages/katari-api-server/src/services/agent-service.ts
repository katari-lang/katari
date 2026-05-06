// Agent lifecycle: start, cancel, query.
//
// The single SSoT for `delegationId` is this service: it mints the id when
// starting an agent, persists it as the `agents.id` row, hands it to the
// runtime, and uses the same id to terminate / receive ack events.
//
// All public methods catch exceptions thrown by the engine and either route
// them to a single agent (when there is one) or poison the whole version.

import { v7 as uuidv7 } from "uuid";
import {
  createDelegationId,
  type Logger,
  type MachineEvent,
  type Value,
} from "katari-runtime";
import {
  MachineNotFound,
  MachineRegistry,
} from "../registry.js";
import type {
  AgentId,
  AgentRow,
  AgentState,
  Storage,
  VersionId,
} from "../storage/types.js";

export class AgentNotFound extends Error {
  constructor(public readonly agentId: AgentId) {
    super(`agent ${agentId} does not exist`);
  }
}

export class AgentService {
  constructor(
    private readonly storage: Storage,
    private readonly registry: MachineRegistry,
    private readonly logger: Logger,
  ) {}

  /**
   * Start a new agent on `versionId`. Mints two distinct ids:
   *   - `agentId` (UUID v7): API-layer SSoT, returned to the caller and
   *     used in REST paths.
   *   - `delegationId`: runtime-layer SSoT, passed to the engine for
   *     this specific delegation. Outbound `delegateAck` /
   *     `terminateAck` events carry it back so we can map them to the
   *     agent row via `findByDelegationId`.
   *
   * On any internal failure both the agent row and any sibling running
   * agents in the same version are flipped to `error`, the snapshot is
   * dropped, and the machine is evicted.
   */
  async startAgent(input: {
    versionId: VersionId;
    qualifiedName: string;
    args: Record<string, Value>;
  }): Promise<{ agentId: AgentId }> {
    const agentId = uuidv7() as AgentId;
    const delegationId = createDelegationId();
    const now = new Date().toISOString();
    const row: AgentRow = {
      id: agentId,
      delegationId,
      versionId: input.versionId,
      qualifiedName: input.qualifiedName,
      args: input.args,
      state: "running",
      createdAt: now,
      updatedAt: now,
    };
    await this.storage.agents.insert(row);

    let handle;
    try {
      handle = await this.registry.acquire(input.versionId);
    } catch (err) {
      // Module not found. Mark the agent error before propagating so the
      // record is consistent with what the user just saw.
      await this.storage.agents.setState(agentId, {
        state: "error",
        errorMessage: errorMessage(err),
      });
      throw err;
    }

    try {
      const out = handle.startAgent(
        input.qualifiedName,
        input.args,
        delegationId,
      );
      await this.routeOutbound(out, input.versionId);
      await this.storage.snapshots.upsert(
        input.versionId,
        handle.toSnapshot(),
      );
    } catch (err) {
      await this.poison(input.versionId, agentId, err);
    }

    return { agentId };
  }

  /**
   * Best-effort cancel. If the agent has already moved to a terminal
   * state, returns its current row unchanged.
   */
  async cancelAgent(agentId: AgentId): Promise<AgentRow> {
    const row = await this.storage.agents.get(agentId);
    if (row === null) throw new AgentNotFound(agentId);
    if (isTerminal(row.state)) return row;

    await this.storage.agents.setState(agentId, { state: "cancelling" });

    const handle = await this.registry.acquire(row.versionId);
    try {
      const out = handle.cancelAgent(row.delegationId);
      await this.routeOutbound(out, row.versionId);
      await this.storage.snapshots.upsert(row.versionId, handle.toSnapshot());
    } catch (err) {
      await this.poison(row.versionId, agentId, err);
    }

    const refreshed = await this.storage.agents.get(agentId);
    return refreshed ?? row;
  }

  async getAgent(agentId: AgentId): Promise<AgentRow> {
    const row = await this.storage.agents.get(agentId);
    if (row === null) throw new AgentNotFound(agentId);
    return row;
  }

  listAgents(filter?: { versionId?: VersionId }): Promise<AgentRow[]> {
    return this.storage.agents.list(filter);
  }

  // ─── Internal: outbound event routing ──────────────────────────────────

  private async routeOutbound(
    events: MachineEvent[],
    versionId: VersionId,
  ): Promise<void> {
    for (const event of events) {
      if (event.kind === "delegateAck" && event.from === "CORE" && event.to === "API") {
        const row = await this.storage.agents.findByDelegationId(
          event.delegationId,
        );
        if (row === null) {
          this.logger.log("warn", "delegateAck for unknown delegationId", {
            versionId,
            delegationId: event.delegationId,
          });
          continue;
        }
        await this.storage.agents.setState(row.id, {
          state: "succeeded",
          result: event.value,
        });
      } else if (
        event.kind === "terminateAck" &&
        event.from === "CORE" &&
        event.to === "API"
      ) {
        const row = await this.storage.agents.findByDelegationId(
          event.delegationId,
        );
        if (row === null) {
          this.logger.log("warn", "terminateAck for unknown delegationId", {
            versionId,
            delegationId: event.delegationId,
          });
          continue;
        }
        await this.storage.agents.setState(row.id, { state: "cancelled" });
      } else if (event.to === "FFI") {
        // FFI executor is not yet built. The IR mentioned an external
        // call but we have nobody to dispatch to — fail loudly so the
        // version gets poisoned.
        this.logger.log("warn", "FFI dispatch not implemented", {
          versionId,
          eventKind: event.kind,
        });
        throw new Error(
          `FFI ${event.kind} not implemented (event from CORE to FFI)`,
        );
      } else {
        this.logger.log("debug", "ignoring outbound event", {
          eventKind: event.kind,
          from: event.from,
          to: event.to,
        });
      }
    }
  }

  private async poison(
    versionId: VersionId,
    triggeringAgentId: AgentId,
    err: unknown,
  ): Promise<void> {
    const message = errorMessage(err);
    this.logger.log("error", "applyEvent threw — poisoning version", {
      versionId,
      triggeringAgentId,
      error: message,
    });
    await this.storage.agents.setState(triggeringAgentId, {
      state: "error",
      errorMessage: message,
    });
    await this.storage.agents.markAllRunningAsError(
      versionId,
      "machine poisoned by sibling failure",
    );
    await this.storage.snapshots.delete(versionId);
    this.registry.evict(versionId);
  }
}

function isTerminal(state: AgentState): boolean {
  return state === "succeeded" || state === "cancelled" || state === "error";
}

function errorMessage(err: unknown): string {
  if (err instanceof MachineNotFound) return err.message;
  if (err instanceof Error) return err.message;
  return String(err);
}
