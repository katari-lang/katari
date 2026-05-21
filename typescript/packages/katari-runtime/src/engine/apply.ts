// Engine entry point: applyEvent.
//
// `(State, Event) => Result`. State is mutated in place (= no Immer);
// outbound events and logs are accumulated separately and returned in
// the Result. The host (orchestrator) constructs a fresh `CoreModule`
// per tick and reloads state from the DB at tick start, so an op
// throwing partway through leaves the in-memory state half-modified
// but observably discarded (= overwritten by the next tick's load).
//
// The engine ignores events whose payload is *external* (delegate /
// delegateAck / terminate / terminateAck / escalate / escalateAck) — the
// host layer is expected to translate those into internal `create` /
// `done` / etc. events before feeding them to the engine.

import { CORE_ENDPOINT, endpoint, type Endpoint } from "./endpoint.js";
import type { Event } from "./event.js";
import { collectGarbage, shouldGc } from "./gc.js";
import type { IRModule } from "../ir/types.js";
import type { Result } from "./result.js";
import { drive } from "./runner.js";
import type { State } from "./state.js";

const DEFAULT_FFI_ENDPOINT = endpoint("ext://ffi");

// ─── State construction ────────────────────────────────────────────────────

/** Build a fresh empty State for an IR module. */
export function createState(
  irModule: IRModule,
  options: { selfEndpoint?: Endpoint; ffiEndpoint?: Endpoint } = {},
): State {
  return {
    selfEndpoint: options.selfEndpoint ?? CORE_ENDPOINT,
    irModule,
    threads: {},
    scopes: {},
    closures: {},
    nextClosureId: 0,
    delegations: {},
    pendingDelegateOut: {},
    delegationSenders: {},
    escalationOwners: {},
    ffiTargetEndpoint: options.ffiEndpoint ?? DEFAULT_FFI_ENDPOINT,
    lastGcScopeCount: 0,
  };
}

// ─── Apply ─────────────────────────────────────────────────────────────────

/**
 * Process one event against `state`. Returns the new state plus the
 * accumulated outbound events and logs.
 *
 * No I/O; no logger injection. Logs accumulate in `Result.logs` and the
 * host writes them out.
 */
export function applyEvent(state: State, event: Event): Result {
  const driven = drive(state, event);
  // drive() mutates `state` in place and returns the same reference.
  if (shouldGc(driven.state)) {
    collectGarbage(driven.state);
  }
  return {
    state: driven.state,
    outbound: driven.buffers.outbound,
    logs: driven.buffers.logs,
  };
}
