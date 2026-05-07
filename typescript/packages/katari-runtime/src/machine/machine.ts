import Denque from "denque";
import type { IRModule } from "../ir/types.js";
import { noopLogger, type Logger } from "../runtime/logger.js";
import { type DelegationId, type ScopeId, type ThreadId } from "./id.js";
import { collectGarbage, type Scope } from "./scope.js";
import type { MachineEvent } from "./events.js";
import { processQueue } from "./runner.js";
import type { QueueEvent, Thread } from "./thread/types.js";
import { ExternalThread } from "./thread/external.js";
import { APIThread } from "./thread/api.js";

// ─── MachineState ───────────────────────────────────────────────────────────

/**
 * Complete machine state.
 * Mutated in-place during event processing.
 */
export type MachineState = {
  irModule: IRModule;
  /** All live threads (for GC root scanning). */
  threads: Map<ThreadId, Thread>;
  /** Scope storage (GC sweep target). */
  scopes: Map<ScopeId, Scope>;
  /** FFI delegation routing (ExternalThread registers here). */
  delegations: Map<DelegationId, ExternalThread>;
  /** API delegation routing (APIThread registers here). */
  apiDelegations: Map<DelegationId, APIThread>;
  /**
   * Outbound events produced during the current `applyEvent` invocation.
   *
   * Transient buffer: cleared at the start of every `applyEvent` and
   * returned at the end. Thread modules push directly into it during
   * `processQueue`. Not part of the persistent machine state — it is
   * stored on `MachineState` only because thread code needs a stable
   * place to write to without threading a context object through every
   * call site.
   */
  pendingOutEvents: MachineEvent[];
  /**
   * Event queue for the main loop.
   *
   * Backed by `Denque` (amortized O(1) shift / push) — Array.shift is O(n)
   * and showed up as the dominant cost on machines with large per-event
   * fan-out (parallel array literals with thousands of elements would
   * spend most of `processQueue` time in shift). Snapshot/serialize never
   * touches the queue: every applyEvent drains it before returning, so
   * the on-disk shape is unaffected.
   */
  queue: Denque<QueueEvent>;
  /**
   * Diagnostic logger. Stale-event drops, future-feature placeholders
   * (escalate/escalateAck), and idempotent ack absorption all log here so
   * the api-server can attach an injected structured logger and surface
   * these signals to ops. Defaults to noop so tests / ad-hoc usage of
   * `createMachine` need not pass one.
   *
   * Not serialized — re-attached on every `MachineHandle.fromSnapshot`.
   */
  logger: Logger;

  /**
   * `scopes.size` at the end of the most recent GC pass. Used by the GC
   * trigger heuristic in {@link applyEvent}: we only sweep when scope
   * count has grown past a multiplicative threshold (or when no threads
   * are left, in which case the entire scope arena is unreachable). This
   * keeps small / mostly-idle machines from paying for a full mark&sweep
   * after every external ack.
   *
   * Not serialized — recomputing it on the first applyEvent after restore
   * just means the next sweep may be slightly earlier than it would have
   * been on the original process. That is harmless.
   */
  lastGcScopeCount: number;
};

// ─── Initialization ─────────────────────────────────────────────────────────

/**
 * Create a fresh machine state from an IR module. `logger` defaults to
 * `noopLogger`; callers that want diagnostics (notably {@link MachineHandle})
 * should pass their own.
 */
export function createMachine(irModule: IRModule, logger: Logger = noopLogger): MachineState {
  return {
    irModule,
    threads: new Map(),
    scopes: new Map(),
    delegations: new Map(),
    apiDelegations: new Map(),
    pendingOutEvents: [],
    queue: new Denque<QueueEvent>(),
    logger,
    lastGcScopeCount: 0,
  };
}

/**
 * Multiplicative growth factor that gates GC. Sweep when scope count has
 * grown past `lastGcScopeCount * GC_GROWTH_FACTOR + GC_MIN_DELTA`.
 */
const GC_GROWTH_FACTOR = 1.5;
/** Lower bound on the scope-count delta that triggers GC. */
const GC_MIN_DELTA = 32;

// ─── Event Processing ───────────────────────────────────────────────────────

/**
 * Process an inbound event and return outbound events.
 */
export function applyEvent(
  state: MachineState,
  event: MachineEvent,
): MachineEvent[] {
  state.pendingOutEvents = [];

  switch (event.kind) {
    case "delegate": {
      if (event.from === "API" && event.to === "CORE") {
        APIThread.handleDelegateFromAPI(
          state,
          event.qualifiedName,
          event.args,
          event.delegationId,
        );
      }
      break;
    }

    case "delegateAck": {
      if (event.from === "FFI" && event.to === "CORE") {
        ExternalThread.handleDelegateAckFromFFI(state, event.delegationId, event.value);
      }
      break;
    }

    case "terminate": {
      if (event.from === "API" && event.to === "CORE") {
        APIThread.handleTerminateFromAPI(state, event.delegationId);
      }
      break;
    }

    case "terminateAck": {
      if (event.from === "FFI" && event.to === "CORE") {
        ExternalThread.handleTerminateAckFromFFI(state, event.delegationId);
      }
      break;
    }

    case "escalate":
    case "escalateAck":
      // Future feature — not yet implemented. We log instead of silently
      // dropping so operators see when an unsupported event slips in
      // (either from a sidecar that's ahead of the runtime or from
      // misuse of `MachineHandle.feedEvent`).
      state.logger.log("warn", "machine.applyEvent: escalate/escalateAck not implemented; event dropped", {
        kind: event.kind,
        from: event.from,
        to: event.to,
      });
      break;
  }

  // Process all queued events
  processQueue(state);

  // Batched GC. We sweep only when:
  //  - All threads are gone (the entire scope arena is unreachable, leaving
  //    it lying around delays cleanup until the next event arrives), or
  //  - scope count has grown enough to make a sweep worth the walk.
  // The previous unconditional sweep on every applyEvent showed up as
  // dominant cost on small machines that take many short events.
  const scopeCount = state.scopes.size;
  if (
    state.threads.size === 0 ||
    scopeCount > state.lastGcScopeCount * GC_GROWTH_FACTOR + GC_MIN_DELTA
  ) {
    collectGarbage(state);
    state.lastGcScopeCount = state.scopes.size;
  }

  return state.pendingOutEvents;
}
