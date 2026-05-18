// Engine entry point: applyEvent.
//
// Pure function: `(State, Event) => Result`. State is updated via Immer;
// outbound events / errors / logs / diffs are accumulated separately and
// returned in the Result.
//
// The engine ignores events whose payload is *external* (delegate /
// delegateAck / terminate / terminateAck / escalate / escalateAck) — the
// host layer is expected to translate those into internal `create` /
// `done` / etc. events before feeding them to the engine.

import { produceWithPatches, type Patch } from "immer";
import { CORE_ENDPOINT, endpoint, type Endpoint } from "./endpoint.js";
import type { Event } from "./event.js";
import { collectGarbage, shouldGc } from "./gc.js";
import type { IRModule } from "../ir/types.js";
import type { Result } from "./result.js";
import { drive, patchesToDiffs } from "./runner.js";
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
    ffiTargetEndpoint: options.ffiEndpoint ?? DEFAULT_FFI_ENDPOINT,
    lastGcScopeCount: 0,
  };
}

// ─── Apply ─────────────────────────────────────────────────────────────────

/**
 * Process one event against `state`. Returns the new state plus the
 * accumulated outbound events, errors, logs, and diffs.
 *
 * No I/O; no logger injection. Logs accumulate in `Result.logs` and the
 * host writes them out (or wraps applyEvent in an Effect that pipes them
 * to a Logger service).
 */
export function applyEvent(state: State, event: Event): Result {
  const driven = drive(state, event);
  let finalState = driven.state;
  const allPatches: Patch[] = [...driven.patches];

  // Run GC if the heuristic says so. The GC produces its own patches
  // which we merge into the diff list.
  if (shouldGc(finalState)) {
    const [next, gcPatches] = produceWithPatches(finalState, (draft) => {
      collectGarbage(draft);
    });
    finalState = next;
    allPatches.push(...gcPatches);
  }

  const diffs = patchesToDiffs(allPatches);
  return {
    state: finalState,
    outbound: driven.buffers.outbound,
    logs: driven.buffers.logs,
    diffs,
  };
}
