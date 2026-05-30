// Closure serialize / materialize — the content-addressed crossing of a
// closure between shards (Phase E / #5).
//
// A closure WITHIN a shard is a machine-local `{ kind: "closure", closureId }`
// pointing at `state.closures[closureId]` (= { blockId, scopeId }); its captured
// environment is the scope chain rooted at that scopeId. That id space is
// shard-local, so a closure cannot cross the bus as-is.
//
// When a closure escapes its home shard (a delegate target / arg routed to
// another shard), CORE *serializes* it at the bus boundary: the captured scope
// chain is frozen into a value-store blob `{ blockId, snapshot, scopes }` and the
// value becomes a content-addressed `{ kind: "closure", ref }`. The receiver
// *materializes* it: the scopes are grafted into its own shard with fresh ids and
// a local closure re-registered, after which the EXISTING `closure:N` dispatch
// (runner.resolveDelegateTarget) runs the body with its captured env.
//
// Why Value-form (not the RawValue wire codec): the blob is engine-internal —
// CORE writes it and CORE reads it; it never crosses the FFI/sidecar boundary.
// So it stores `Value`s directly (refs and all), like an engine checkpoint,
// rather than the schema-less wire form.
//
// Recursion: a recursive local agent captures *itself* (its own var bound to the
// closure) — the only cycle Katari can express (siblings cannot forward-
// reference; confirmed in Lowering.lowerBlockInto). serialize records that one
// `selfVar` and omits the binding; materialize re-binds it to the freshly
// registered closure id. No content-addressed cycle ⇒ no SCC hashing needed.
//
// Secrets: a captured `secret` would land in the value-store blob in plaintext
// (the blob is not checkpoint-encrypted). v0.1.0 refuses it loudly rather than
// leak; closure-captured secrets are a documented gap (revisit with Phase G).

import type { BlockId } from "../ir/types.js";
import type { ClosureId, ScopeId } from "./id.js";
import { createScopeId } from "./id.js";
import type { Scope } from "./scope.js";
import type { State } from "./state.js";
import type { RefRep, Value } from "./value.js";

/** Writes closure-blob bytes to the value store, returning the ref. Injected by
 *  CoreModule (owner = core, semanticKind = "closure"). */
export type PutClosureBytes = (bytes: Uint8Array) => Promise<RefRep>;

/** Fetches closure-blob bytes by ref. Injected by CoreModule. */
export type GetClosureBytes = (ref: RefRep) => Promise<Uint8Array>;

/** One captured scope, frozen for transport. Ids are the issuer's (string
 *  UUIDs); materialize remaps them to fresh ids in the receiving shard. */
type SerializedScope = {
  id: string;
  parentId: string | null;
  values: Record<number, Value>;
};

/** The full frozen closure: body block + the snapshot its code lives in + its
 *  captured scope chain. Stored as the bytes of one value-store blob. */
export type SerializedClosure = {
  v: 1;
  blockId: BlockId;
  snapshot: string;
  /** Captured scope chain, innermost (the captured scope) first up to root. */
  scopes: SerializedScope[];
  /** The scope the closure directly captured (= the body scope's parent). */
  capturedScopeId: string;
  /** Var in `capturedScopeId` bound to the closure itself (recursion), if any. */
  selfVar?: number;
};

/**
 * Freeze a machine-local closure into a content-addressed blob and return its
 * ref. Walks the captured scope chain to its root, promoting any nested local
 * closures to their own refs (a finite DAG — see header) and dropping the single
 * self-reference into `selfVar`.
 */
export async function serializeClosure(
  state: State,
  closureId: ClosureId,
  snapshot: string,
  putBytes: PutClosureBytes,
): Promise<RefRep> {
  const record = state.closures[closureId];
  if (record === undefined) {
    throw new Error(`serializeClosure: closure ${closureId} not in state.closures`);
  }
  const scopes: SerializedScope[] = [];
  let selfVar: number | undefined;
  let cursor: ScopeId | null = record.scopeId;
  const seen = new Set<ScopeId>();
  while (cursor !== null) {
    if (seen.has(cursor)) {
      throw new Error(`serializeClosure: scope cycle at ${cursor} for closure ${closureId}`);
    }
    seen.add(cursor);
    const scope: Scope | undefined = state.scopes[cursor];
    if (scope === undefined) {
      throw new Error(`serializeClosure: scope ${cursor} missing for closure ${closureId}`);
    }
    const values: Record<number, Value> = {};
    for (const [varKey, value] of Object.entries(scope.values)) {
      if (value === undefined) continue;
      const varId = Number(varKey);
      // The closure's own var bound to itself (recursion). Only ever a direct
      // binding in the captured scope; record + omit, materialize re-binds it.
      if (cursor === record.scopeId && isSelfClosure(value, closureId)) {
        selfVar = varId;
        continue;
      }
      values[varId] = await promoteValueClosures(value, state, closureId, snapshot, putBytes);
    }
    scopes.push({ id: cursor, parentId: scope.parentId, values });
    cursor = scope.parentId;
  }
  const content: SerializedClosure = {
    v: 1,
    blockId: record.blockId,
    snapshot,
    scopes,
    capturedScopeId: record.scopeId,
    selfVar,
  };
  const bytes = new TextEncoder().encode(JSON.stringify(content));
  return putBytes(bytes);
}

/** Parse + version-check a closure blob's bytes. */
export function decodeClosureBlob(bytes: Uint8Array): SerializedClosure {
  const parsed = JSON.parse(new TextDecoder().decode(bytes)) as SerializedClosure;
  if (parsed.v !== 1) {
    throw new Error(
      `decodeClosureBlob: unsupported closure blob version ${(parsed as { v: unknown }).v}`,
    );
  }
  return parsed;
}

/**
 * Graft a deserialized closure into `state`, returning the fresh local closure
 * id. Allocates new scope ids (remapping parent links), re-binds the self-
 * reference (if any) to the new closure, and registers `state.closures`. After
 * this the standard `closure:<id>` dispatch path runs the body.
 *
 * Caller resolves `content.snapshot` to the right IR and builds the shard state
 * BEFORE calling — this only touches scopes / closures, not the IR.
 */
export function materializeClosure(content: SerializedClosure, state: State): ClosureId {
  if (content.v !== 1) {
    throw new Error(`materializeClosure: unsupported version ${(content as { v: unknown }).v}`);
  }
  const idMap = new Map<string, ScopeId>();
  for (const s of content.scopes) idMap.set(s.id, createScopeId());
  for (const s of content.scopes) {
    const freshId = idMap.get(s.id)!;
    const parentId = s.parentId === null ? null : (idMap.get(s.parentId) ?? null);
    state.scopes[freshId] = { id: freshId, parentId, values: { ...s.values } };
    state.scopeCount++;
  }
  const capturedRoot = idMap.get(content.capturedScopeId);
  if (capturedRoot === undefined) {
    throw new Error("materializeClosure: capturedScopeId not present in the scope set");
  }
  const newClosureId = state.nextClosureId as ClosureId;
  state.nextClosureId = (state.nextClosureId as number) + 1;
  state.closures[newClosureId] = {
    id: newClosureId,
    blockId: content.blockId,
    scopeId: capturedRoot,
  };
  if (content.selfVar !== undefined) {
    // `capturedRoot` was just written into `state.scopes` above.
    const rootScope = state.scopes[capturedRoot];
    if (rootScope !== undefined) {
      rootScope.values[content.selfVar] = { kind: "closure", closureId: newClosureId };
    }
  }
  return newClosureId;
}

// ─── helpers ─────────────────────────────────────────────────────────────────

function isSelfClosure(value: Value, closureId: ClosureId): boolean {
  return value.kind === "closure" && "closureId" in value && value.closureId === closureId;
}

/**
 * Replace every machine-local closure reachable inside a Value with its
 * content-addressed ref (recursively serialized). Non-closure leaves pass
 * through unchanged; containers recurse. A captured `secret` is refused.
 */
async function promoteValueClosures(
  value: Value,
  state: State,
  selfId: ClosureId,
  snapshot: string,
  putBytes: PutClosureBytes,
): Promise<Value> {
  switch (value.kind) {
    case "closure": {
      if ("ref" in value) return value; // already content-addressed
      if (value.closureId === selfId) {
        // Self only ever appears as the direct binding handled in
        // serializeClosure; a nested one would be a cycle we cannot address.
        throw new Error("serializeClosure: unexpected nested self-reference closure");
      }
      const ref = await serializeClosure(state, value.closureId, snapshot, putBytes);
      return { kind: "closure", ref };
    }
    case "secret":
      throw new Error(
        "serializeClosure: closure captures a secret — unsupported in v0.1.0 (would persist plaintext at rest)",
      );
    case "array":
      return {
        kind: "array",
        elements: await Promise.all(
          value.elements.map((element) =>
            promoteValueClosures(element, state, selfId, snapshot, putBytes),
          ),
        ),
      };
    case "tagged": {
      const fields: Record<string, Value> = {};
      for (const [label, field] of Object.entries(value.fields)) {
        fields[label] = await promoteValueClosures(field, state, selfId, snapshot, putBytes);
      }
      return { kind: "tagged", ctorId: value.ctorId, fields };
    }
    case "record": {
      const entries: Record<string, Value> = {};
      for (const [key, entry] of Object.entries(value.entries)) {
        entries[key] = await promoteValueClosures(entry, state, selfId, snapshot, putBytes);
      }
      return { kind: "record", entries };
    }
    default:
      // number / boolean / null / string / file / agentLiteral — no closures.
      return value;
  }
}
