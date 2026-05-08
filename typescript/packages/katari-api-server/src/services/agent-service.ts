// Agent lifecycle: start, cancel, query.
//
// Concurrency / consistency model (Stage B1-B8 onwards):
//   - All engine work for a given `versionId` runs inside that version's
//     `Mutex` (held by `MachineRegistry`). Within the mutex, we wrap the DB
//     operations in `Storage.withTransaction` so either every state change
//     commits or none does — a process crash between `agents.insert` and
//     `snapshots.upsert` no longer leaves a permanently-running ghost agent.
//
// Error recovery:
//   - Engine throws are split by `RecoverableEngineError` vs anything else.
//   - Recoverable: only the offending agent is marked `error`; the in-memory
//     handle is rolled back from the pre-call snapshot via
//     `versionedRollback`. Sibling agents on the same version keep running.
//   - Non-recoverable: the entire version is poisoned (legacy behaviour).
//
// Outbound FFI events still arrive but the executor isn't built yet — we
// surface a `RecoverableEngineError` for those, downgrading what used to
// poison the version into a single-agent failure.

import { v7 as uuidv7 } from "uuid";
import {
  createDelegationId,
  EntryNotFoundError,
  MachineHandle,
  RecoverableEngineError,
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

/**
 * Re-export so route handlers can `instanceof EntryNotFoundError` to map
 * "qualifiedName unknown" to HTTP 400 / 404 cleanly.
 */
export { EntryNotFoundError };

/**
 * Optional metrics interface AgentService writes to. The shape mirrors
 * `AppMetrics` from `metrics.ts` but is declared here to avoid a circular
 * import; bin.ts wires the concrete instance through.
 */
export interface AgentServiceMetrics {
  agentStartTotal: { inc(by?: number): void };
  agentCancelTotal: { inc(by?: number): void };
  applyEventDuration: { observe(seconds: number): void };
}

export class AgentService {
  private readonly metrics: AgentServiceMetrics | undefined;

  constructor(
    private readonly storage: Storage,
    private readonly registry: MachineRegistry,
    private readonly logger: Logger,
    metrics?: AgentServiceMetrics,
  ) {
    this.metrics = metrics;
  }

  /**
   * Start a new agent on `versionId`.
   *
   * Concurrency / crash safety: the entire engine + DB sequence runs inside
   * the version's mutex (so concurrent starts on the same version are
   * serialized) AND inside a Storage transaction (so a crash between
   * snapshot upsert and agent insert leaves no half-state). The pre-call
   * snapshot is captured up front; if `applyEvent` raises a
   * `RecoverableEngineError` we restore from it — the live agent row never
   * gets inserted in the first place because the surrounding transaction
   * rolls back too.
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

    this.metrics?.agentStartTotal.inc();
    const handle = await this.registry.acquire(input.versionId);
    const mutex = this.registry.getMutex(input.versionId);

    await mutex.runExclusive(async () => {
      const rollbackSnap = handle.toSnapshot();
      const startedAt = performance.now();
      try {
        await this.storage.withTransaction(async (tx) => {
          const out = handle.startAgent(
            input.qualifiedName,
            input.args,
            delegationId,
          );
          await tx.agents.insert(row);
          await this.routeOutbound(out, input.versionId, tx);
          await tx.snapshots.upsert(input.versionId, handle.toSnapshot());
        });
      } catch (err) {
        if (err instanceof EntryNotFoundError) {
          // qualifiedName isn't in the IR — this is a client mistake.
          // Surface it to the route layer as a 400 instead of persisting
          // a phantom error agent. The DB transaction rolled back, so
          // agents.insert is already gone.
          await this.versionedRollback(input.versionId, rollbackSnap);
          throw err;
        }
        if (err instanceof RecoverableEngineError) {
          // Rebuild the in-memory handle from the pre-call snapshot — the
          // engine state may have been mutated mid-event before the throw.
          // The DB transaction has already rolled back, so `agents.insert`
          // is gone too. We re-insert with state=error so the API client
          // can observe the failure.
          await this.versionedRollback(input.versionId, rollbackSnap);
          await this.storage.agents.insert({
            ...row,
            state: "error",
            errorMessage: err.message,
            updatedAt: new Date().toISOString(),
          });
          this.logger.log("info", "agent rolled back as error", {
            versionId: input.versionId,
            agentId,
            error: err.message,
            errorClass: err.name,
          });
          return; // do not throw — the agent is observable via GET /agent/:id
        }
        // Non-recoverable: poison the entire version.
        await this.poison(input.versionId, agentId, row, err);
      } finally {
        this.metrics?.applyEventDuration.observe(
          (performance.now() - startedAt) / 1000,
        );
      }
    });

    return { agentId };
  }

  /**
   * Best-effort cancel. Idempotent at the runtime level.
   *
   * Same mutex / transaction wrapping as `startAgent`. If the engine
   * throws a Recoverable while processing the terminate, we roll the
   * machine state back to before the cancel attempt and flip the
   * agent to error — the original `running`/`cancelling` state is
   * abandoned because the engine no longer believes it can drive that
   * agent forward cleanly.
   */
  async cancelAgent(agentId: AgentId): Promise<AgentRow> {
    this.metrics?.agentCancelTotal.inc();
    const row = await this.storage.agents.get(agentId);
    if (row === null) throw new AgentNotFound(agentId);
    if (isTerminal(row.state)) return row;

    const handle = await this.registry.acquire(row.versionId);
    const mutex = this.registry.getMutex(row.versionId);

    await mutex.runExclusive(async () => {
      const rollbackSnap = handle.toSnapshot();
      const startedAt = performance.now();
      try {
        await this.storage.withTransaction(async (tx) => {
          // expectedState=running gates the cancel: if a delegateAck
          // raced ahead and already flipped the agent to "succeeded",
          // we leave it alone.
          const transitioned = await tx.agents.setState(
            agentId,
            { state: "cancelling" },
            { expectedState: "running" },
          );
          if (!transitioned) {
            this.logger.log("info", "cancelAgent: agent no longer running, skipping engine cancel", {
              agentId,
              versionId: row.versionId,
            });
            return; // tx commits with no-op; outer cancelAgent returns the refreshed row
          }
          const out = handle.cancelAgent(row.delegationId);
          await this.routeOutbound(out, row.versionId, tx);
          await tx.snapshots.upsert(row.versionId, handle.toSnapshot());
        });
      } catch (err) {
        if (err instanceof RecoverableEngineError) {
          await this.versionedRollback(row.versionId, rollbackSnap);
          await this.storage.agents.setState(agentId, {
            state: "error",
            errorMessage: err.message,
          });
          this.logger.log("info", "cancelAgent rolled back as error", {
            versionId: row.versionId,
            agentId,
            error: err.message,
            errorClass: err.name,
          });
          return;
        }
        await this.poison(row.versionId, agentId, row, err);
      } finally {
        this.metrics?.applyEventDuration.observe(
          (performance.now() - startedAt) / 1000,
        );
      }
    });

    const refreshed = await this.storage.agents.get(agentId);
    return refreshed ?? row;
  }

  async getAgent(agentId: AgentId): Promise<AgentRow> {
    const row = await this.storage.agents.get(agentId);
    if (row === null) throw new AgentNotFound(agentId);
    return row;
  }

  listAgents(filter?: {
    versionId?: VersionId;
    limit?: number;
    offset?: number;
  }): Promise<AgentRow[]> {
    return this.storage.agents.list(filter);
  }

  /**
   * Recovery-only: re-issue the engine `terminate` for an agent that was
   * mid-cancel when the previous process died.
   *
   * Why we can't just call `cancelAgent` from recovery: that path's
   * `setState(..., expectedState: "running")` is a no-op on a row whose
   * state is already "cancelling", so the engine never gets the second
   * terminate and the agent remains stuck. (BUG-01 in
   * /review/02-phase2-modules.md.)
   *
   * This method skips the expectedState gate, drives `handle.cancelAgent`
   * directly, and routes the resulting outbound events. Snapshot upsert
   * inside the same transaction keeps engine state consistent with the
   * row state on disk.
   */
  async resumeCancellingOnBoot(agentId: AgentId): Promise<void> {
    const row = await this.storage.agents.get(agentId);
    if (row === null) return;
    if (row.state !== "cancelling") return;

    const handle = await this.registry.acquire(row.versionId);
    const mutex = this.registry.getMutex(row.versionId);

    await mutex.runExclusive(async () => {
      const rollbackSnap = handle.toSnapshot();
      try {
        await this.storage.withTransaction(async (tx) => {
          const out = handle.cancelAgent(row.delegationId);
          await this.routeOutbound(out, row.versionId, tx);
          await tx.snapshots.upsert(row.versionId, handle.toSnapshot());
        });
      } catch (err) {
        if (err instanceof RecoverableEngineError) {
          await this.versionedRollback(row.versionId, rollbackSnap);
          await this.storage.agents.setState(agentId, {
            state: "error",
            errorMessage: err.message,
          });
          this.logger.log("info", "resumeCancellingOnBoot: rolled back as error", {
            versionId: row.versionId,
            agentId,
            error: err.message,
          });
          return;
        }
        await this.poison(row.versionId, agentId, row, err);
      }
    });
  }

  // ─── Internal: outbound event routing ──────────────────────────────────
  //
  // `routeOutbound` walks the events the engine emitted during one
  // `applyEvent` invocation and translates them into DB writes against the
  // *same* transaction (`tx`). Currently:
  //   - delegateAck CORE→API → setState(succeeded, result=value)
  //   - terminateAck CORE→API → setState(cancelled)
  //   - any CORE→FFI event → throw RecoverableEngineError (FFI executor
  //     not yet built; the agent that triggered it errors out, but the
  //     rest of the version stays alive — see Stage B5 in the rollout
  //     plan).

  private async routeOutbound(
    events: MachineEvent[],
    versionId: VersionId,
    tx: Storage,
  ): Promise<void> {
    for (const event of events) {
      if (event.kind === "delegateAck" && event.from === "CORE" && event.to === "API") {
        const row = await tx.agents.findByDelegationId(event.delegationId);
        if (row === null) {
          this.logger.log("warn", "delegateAck for unknown delegationId", {
            versionId,
            delegationId: event.delegationId,
          });
          continue;
        }
        // Only running agents can transition to succeeded. If a concurrent
        // cancel landed first, leave its "cancelling" state alone — the
        // matching terminateAck will follow shortly.
        const updated = await tx.agents.setState(
          row.id,
          { state: "succeeded", result: event.value },
          { expectedState: "running" },
        );
        if (!updated) {
          this.logger.log("info", "delegateAck dropped: agent no longer running", {
            versionId,
            agentId: row.id,
            wasState: row.state,
          });
        }
      } else if (
        event.kind === "terminateAck" &&
        event.from === "CORE" &&
        event.to === "API"
      ) {
        const row = await tx.agents.findByDelegationId(event.delegationId);
        if (row === null) {
          this.logger.log("warn", "terminateAck for unknown delegationId", {
            versionId,
            delegationId: event.delegationId,
          });
          continue;
        }
        // Only "cancelling" agents transition to "cancelled". Anything
        // else (e.g. the agent already moved to `error` via poison) is
        // left as-is.
        const updated = await tx.agents.setState(
          row.id,
          { state: "cancelled" },
          { expectedState: "cancelling" },
        );
        if (!updated) {
          this.logger.log("info", "terminateAck dropped: agent not in cancelling state", {
            versionId,
            agentId: row.id,
            wasState: row.state,
          });
        }
      } else if (event.to === "FFI") {
        // FFI executor is not yet built. Outbound CORE→FFI events are
        // dropped on the floor here — the engine state stays valid (the
        // ExternalThread is still in `delegations`, waiting for an
        // ack), and the agent simply sits in `running` until something
        // outside this process feeds the ack back in via
        // MachineHandle.feedEvent. When the FFI executor lands, replace
        // this branch with a real dispatch.
        // TODO(katari/ffi): wire to the FFI executor.
        this.logger.log("debug", "FFI event held pending executor", {
          versionId,
          eventKind: event.kind,
        });
      } else {
        this.logger.log("debug", "ignoring outbound event", {
          eventKind: event.kind,
          from: event.from,
          to: event.to,
        });
      }
    }
  }

  /**
   * Roll the in-memory machine for `versionId` back to `snap` and put it
   * in the registry cache. The DB layer's transaction has already rolled
   * back; this method only reconciles the engine's mutated state. The
   * caller must already hold the version's mutex.
   *
   * **Awaited** — the previous fire-and-forget version released the mutex
   * before the rebuild finished, letting concurrent acquires hit the
   * still-poisoned handle. (BUG-02 in /review/02-phase2-modules.md.)
   */
  private async versionedRollback(
    versionId: VersionId,
    snap: ReturnType<MachineHandle["toSnapshot"]>,
  ): Promise<void> {
    try {
      await this.rebuildAndCache(versionId, snap);
    } catch (err) {
      // If rebuild fails (storage unavailable), evict so the next acquire
      // reloads cleanly from storage. Logging is sufficient otherwise —
      // the next acquire will see the original poisoned state replaced
      // by the persisted snapshot.
      this.logger.log("error", "versionedRollback rebuild failed", {
        versionId,
        error: err instanceof Error ? err.message : String(err),
      });
      this.registry.evict(versionId);
    }
  }

  private async rebuildAndCache(
    versionId: VersionId,
    snap: ReturnType<MachineHandle["toSnapshot"]>,
  ): Promise<void> {
    const moduleRow = await this.storage.modules.get(versionId);
    if (moduleRow === null) {
      this.registry.evict(versionId);
      return;
    }
    const fresh = MachineHandle.fromSnapshot(moduleRow.irModule, snap, this.logger);
    this.registry.replaceHandle(versionId, fresh);
  }

  private async poison(
    versionId: VersionId,
    triggeringAgentId: AgentId,
    triggeringRow: AgentRow,
    err: unknown,
  ): Promise<void> {
    const message = errorMessage(err);
    this.logger.log("error", "applyEvent threw — poisoning version", {
      versionId,
      triggeringAgentId,
      error: message,
    });
    // Best-effort: each step is idempotent / null-safe so a partial failure
    // here doesn't make things much worse than they already are.
    try {
      // The triggering agent may not be persisted yet (startAgent path
      // inserts inside the rolled-back tx). Insert-or-update via insert
      // first, swallowing any duplicate-key error.
      await this.storage.agents.insert({
        ...triggeringRow,
        state: "error",
        errorMessage: message,
        updatedAt: new Date().toISOString(),
      });
    } catch {
      // Already persisted earlier — fall through to setState.
      await this.storage.agents.setState(triggeringAgentId, {
        state: "error",
        errorMessage: message,
      });
    }
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
