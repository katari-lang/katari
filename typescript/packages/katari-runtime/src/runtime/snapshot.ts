// Pure JSON conversion for `MachineState`.
//
// `katari-runtime` core stops here: the engine gets snapshotted and restored
// in pure code. The `katari-api-server` package is responsible for actually
// persisting and re-loading these JSON blobs.
//
// Restoration is two-pass:
//
//   1. For every serialized thread, instantiate an empty skeleton via
//      `Object.create(<Class>.prototype)` and assign its own (non-ref) state.
//      Register the skeleton in the id-keyed map *before* any link step so
//      that forward references resolve.
//   2. Walk the snapshot a second time, calling each variant's `link` to
//      resolve cross-thread references (parent / children / handlers /
//      boundaries / asker refs).
//
// Scopes are restored in pass 1 (they have no Thread refs).

import type { IRModule } from "../ir/types.js";
import type {
  DelegationId,
  ScopeId,
  ThreadId,
} from "../machine/id.js";
import {
  applyEvent,
  createMachine,
  type MachineState,
} from "../machine/machine.js";
import {
  deserializeScope,
  serializeScope,
  type SerializedScope,
} from "../machine/scope.js";
import { APIThread, type SerializedAPIThread } from "../machine/thread/api.js";
import {
  ArrayThread,
  type SerializedArrayThread,
} from "../machine/thread/array.js";
import {
  CtorThread,
  type SerializedCtorThread,
} from "../machine/thread/ctor.js";
import {
  ExternalThread,
  type SerializedExternalThread,
} from "../machine/thread/external.js";
import {
  ForThread,
  type SerializedForThread,
} from "../machine/thread/for.js";
import {
  HandleThread,
  type SerializedHandleThread,
} from "../machine/thread/handle.js";
import {
  MatchThread,
  type SerializedMatchThread,
} from "../machine/thread/match.js";
import {
  PrimThread,
  type SerializedPrimThread,
} from "../machine/thread/prim.js";
import {
  RequestThread,
  type SerializedRequestThread,
} from "../machine/thread/request.js";
import {
  TupleThread,
  type SerializedTupleThread,
} from "../machine/thread/tuple.js";
import { UserThread, type SerializedUserThread } from "../machine/thread/user.js";
import type { Thread } from "../machine/thread/types.js";

/** Discriminated union of every concrete thread snapshot variant. */
export type SerializedThread =
  | SerializedAPIThread
  | SerializedUserThread
  | SerializedHandleThread
  | SerializedForThread
  | SerializedMatchThread
  | SerializedRequestThread
  | SerializedExternalThread
  | SerializedArrayThread
  | SerializedTupleThread
  | SerializedPrimThread
  | SerializedCtorThread;

/** Top-level on-disk shape. `schemaVersion` lets us evolve the format. */
export type MachineSnapshot = {
  schemaVersion: 1;
  threads: SerializedThread[];
  scopes: SerializedScope[];
  delegations: { delegationId: DelegationId; threadId: ThreadId }[];
  apiDelegations: { delegationId: DelegationId; threadId: ThreadId }[];
};

// ─── Serialize ─────────────────────────────────────────────────────────────

export function serializeMachine(state: MachineState): MachineSnapshot {
  return {
    schemaVersion: 1,
    threads: [...state.threads.values()].map(
      (thread) => thread.serialize() as SerializedThread,
    ),
    scopes: [...state.scopes.values()].map(serializeScope),
    delegations: [...state.delegations.entries()].map(([delegationId, ext]) => ({
      delegationId,
      threadId: ext.id,
    })),
    apiDelegations: [...state.apiDelegations.entries()].map(
      ([delegationId, api]) => ({ delegationId, threadId: api.id }),
    ),
  };
}

// ─── Deserialize ───────────────────────────────────────────────────────────

export function deserializeMachine(
  irModule: IRModule,
  snap: MachineSnapshot,
): MachineState {
  if (snap.schemaVersion !== 1) {
    throw new Error(
      `deserializeMachine: unsupported snapshot schemaVersion ${snap.schemaVersion}`,
    );
  }

  const state = createMachine(irModule);

  // Pass 1: scopes
  for (const sc of snap.scopes) {
    state.scopes.set(sc.id, deserializeScope(sc));
  }

  // Pass 1: thread skeletons
  const threadsById = new Map<ThreadId, Thread>();
  for (const ser of snap.threads) {
    const thread = restoreSkeleton(ser);
    threadsById.set(ser.id, thread);
    state.threads.set(ser.id, thread);
  }

  // Pass 2: link cross-thread refs
  for (const ser of snap.threads) {
    const thread = threadsById.get(ser.id);
    if (thread === undefined) {
      throw new Error(`deserializeMachine: missing skeleton for ${ser.id}`);
    }
    linkThread(thread, ser, threadsById);
  }

  // Restore delegation maps (FFI / API).
  for (const { delegationId, threadId } of snap.delegations) {
    const thread = threadsById.get(threadId);
    if (!(thread instanceof ExternalThread)) {
      throw new Error(
        `deserializeMachine: delegations[${delegationId}] does not point to ExternalThread`,
      );
    }
    state.delegations.set(delegationId, thread);
  }
  for (const { delegationId, threadId } of snap.apiDelegations) {
    const thread = threadsById.get(threadId);
    if (!(thread instanceof APIThread)) {
      throw new Error(
        `deserializeMachine: apiDelegations[${delegationId}] does not point to APIThread`,
      );
    }
    state.apiDelegations.set(delegationId, thread);
  }

  return state;
}

function restoreSkeleton(ser: SerializedThread): Thread {
  switch (ser.kind) {
    case "api":
      return APIThread.restoreSkeleton(ser);
    case "user":
      return UserThread.restoreSkeleton(ser);
    case "handle":
      return HandleThread.restoreSkeleton(ser);
    case "for":
      return ForThread.restoreSkeleton(ser);
    case "match":
      return MatchThread.restoreSkeleton(ser);
    case "request":
      return RequestThread.restoreSkeleton(ser);
    case "external":
      return ExternalThread.restoreSkeleton(ser);
    case "array":
      return ArrayThread.restoreSkeleton(ser);
    case "tuple":
      return TupleThread.restoreSkeleton(ser);
    case "prim":
      return PrimThread.restoreSkeleton(ser);
    case "ctor":
      return CtorThread.restoreSkeleton(ser);
  }
}

function linkThread(
  thread: Thread,
  ser: SerializedThread,
  threadsById: ReadonlyMap<ThreadId, Thread>,
): void {
  switch (ser.kind) {
    case "api":
      (thread as APIThread).link(ser, threadsById);
      return;
    case "user":
      (thread as UserThread).link(ser, threadsById);
      return;
    case "handle":
      (thread as HandleThread).link(ser, threadsById);
      return;
    case "for":
      (thread as ForThread).link(ser, threadsById);
      return;
    case "match":
      (thread as MatchThread).link(ser, threadsById);
      return;
    case "request":
      (thread as RequestThread).link(ser, threadsById);
      return;
    case "external":
      (thread as ExternalThread).link(ser, threadsById);
      return;
    case "array":
      (thread as ArrayThread).link(ser, threadsById);
      return;
    case "tuple":
      (thread as TupleThread).link(ser, threadsById);
      return;
    case "prim":
      (thread as PrimThread).link(ser, threadsById);
      return;
    case "ctor":
      (thread as CtorThread).link(ser, threadsById);
      return;
  }
}

// Re-export commonly bundled helpers so api-server only has to import from
// runtime/snapshot.
export { applyEvent, createMachine };
export type { ScopeId };
