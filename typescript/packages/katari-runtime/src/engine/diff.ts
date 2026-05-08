// Diff: domain-specific change descriptors used for incremental persistence.
//
// Engine-internal updates run through Immer's `produceWithPatches`, which
// emits low-level JSON Pointer patches. We translate those into the
// higher-level `Diff` form below so the host (storage layer) can write
// per-row upserts/deletes instead of dumping the whole snapshot.

import type { ScopeId, ThreadId } from "./id.js";
import type { Scope } from "./scope.js";
import type { Thread } from "./thread/types.js";
import type { Value } from "./value.js";

export type Diff =
  | { op: "thread.create"; threadId: ThreadId; data: Thread }
  | { op: "thread.update"; threadId: ThreadId; patch: unknown /* JSON Pointer / Immer patch */ }
  | { op: "thread.delete"; threadId: ThreadId }
  | { op: "scope.create"; scopeId: ScopeId; data: Scope }
  | { op: "scope.set"; scopeId: ScopeId; varId: number; value: Value }
  | { op: "scope.delete"; scopeId: ScopeId };

/**
 * `patchesToDiffs` is implemented in a follow-up: it walks Immer's `Patch[]`
 * and produces our domain Diff[]. Stage A only declares the type so the
 * Result shape settles early; the translation lands with the engine port.
 */
