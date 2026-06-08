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

import type { IRModule } from "../ir/types.js";
import { CORE_ENDPOINT, type Endpoint, endpoint } from "./endpoint.js";
import type { Event } from "./event.js";
import { collectGarbage, shouldGc } from "./gc.js";
import { createEntityId, type EntityId } from "./id.js";
import type { Result } from "./result.js";
import { drive } from "./runner.js";
import type { State } from "./state.js";
import type { RefFetcher, RefPutter } from "./step-ctx.js";
import type { CoreStore } from "./store.js";

const DEFAULT_FFI_ENDPOINT = endpoint("ext://ffi");
const DEFAULT_ENV_ENDPOINT = endpoint("ext://env");

// ─── State construction ────────────────────────────────────────────────────

/** Build a fresh empty State for an IR module. */
export function createState(
  irModule: IRModule,
  options: {
    selfEndpoint?: Endpoint;
    ffiEndpoint?: Endpoint;
    envEndpoint?: Endpoint;
    /** Snapshot this shard runs. Stamped into closures created here. */
    snapshot?: string;
    /** The entity this shard runs as (`shardId = E`). A fresh id when omitted. */
    selfEntity?: EntityId;
  } = {},
): State {
  return {
    selfEndpoint: options.selfEndpoint ?? CORE_ENDPOINT,
    selfEntity: options.selfEntity ?? createEntityId(),
    irModule,
    snapshot: options.snapshot ?? "",
    threads: {},
    delegations: {},
    pendingDelegateOut: {},
    delegationSenders: {},
    escalationOwners: {},
    ffiTargetEndpoint: options.ffiEndpoint ?? DEFAULT_FFI_ENDPOINT,
    envTargetEndpoint: options.envEndpoint ?? DEFAULT_ENV_ENDPOINT,
    lastGcScopeCount: 0,
    threadCount: 0,
  };
}

// ─── Apply ─────────────────────────────────────────────────────────────────

/**
 * Process one event against `state`. Returns the new state plus the
 * accumulated outbound events and logs.
 *
 * Async because the engine may materialize ref bytes for content-transform
 * prims (concat / format) — a bounded, deterministic content-addressed fetch
 * awaited inline within the quantum (runtime-architecture §5). `fetchRef` is
 * the host's ValueStore-backed fetcher; omitted (v0.1.0 pre-promotion) it
 * defaults to one that throws if a ref unexpectedly appears. The state
 * transition stays deterministic: fetch is a pure function of the content
 * hash. No logger injection; logs accumulate in `Result.logs`.
 */
export async function applyEvent(
  state: State,
  store: CoreStore,
  event: Event,
  fetchRef?: RefFetcher,
  putRef?: RefPutter,
): Promise<Result> {
  const driven = await drive(state, store, event, fetchRef, putRef);
  // drive() mutates `state` + `store` in place and returns the same references.
  if (shouldGc(driven.state, store)) {
    collectGarbage(driven.state, store);
  }
  return {
    state: driven.state,
    outbound: driven.buffers.outbound,
    logs: driven.buffers.logs,
  };
}
