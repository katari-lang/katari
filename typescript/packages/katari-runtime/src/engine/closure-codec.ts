// Closure serialize / materialize — the content-addressed crossing of a
// closure between shards (Phase E / #5).
//
// A closure value is ALWAYS a content-addressed ref (`{ kind: "closure", ref }`).
// At a closure literal (`StatementMakeClosure`) the engine freezes the captured
// scope chain into a value-store blob via `ctx.putBlob` and hands back the ref —
// the blob exists before the ref does, so a ref never dangles. Invoking a
// closure delegates by that ref; the receiver materializes the blob into its own
// shard (grafting the captured scopes with fresh ids + registering a local
// dispatch record) and the standard `closure:N` path runs the body.
//
// Why Value-form (not the RawValue wire codec): the blob is engine-internal —
// CORE writes it and CORE reads it; it never crosses the FFI/sidecar boundary.
// So it stores `Value`s directly (refs and all), like an engine checkpoint.
//
// Snapshot: the blob carries the snapshot its body block lives in — a (blockId,
// snapshot) pair uniquely identifies the code to run, independent of whoever
// invokes it later. make-closure reads it from `state.snapshot`.
//
// Recursion: a recursive local agent self-references through the var the closure
// binds itself to (`selfVar`). That var is bound only AFTER the literal (so it is
// absent from the captured scope at serialize time); materialize re-binds it to
// the closure's own ref, so a self-call simply re-materializes (a fresh shard per
// recursion level). No self-cycle in the blob.
//
// Secrets: a captured `secret` would land in the blob in plaintext (the blob is
// not checkpoint-encrypted). v0.1.0 refuses it loudly rather than leak; closure-
// captured secrets are a documented gap (revisit with Phase G).

import type { BlockId } from "../ir/types.js";
import type { ClosureId, ScopeId } from "./id.js";
import { createScopeId } from "./id.js";
import type { Scope } from "./scope.js";
import type { State } from "./state.js";
import type { RefRep, Value } from "./value.js";

/** Writes closure-blob bytes to the value store, returning the ref. Injected by
 *  CoreModule (owner = core, semanticKind = "closure"). */
export type PutClosureBytes = (bytes: Uint8Array) => Promise<RefRep>;

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
  /** Var the closure binds itself to (recursion); materialize re-binds it. */
  selfVar: number;
};

/** Inputs to {@link serializeClosure}. */
export type SerializeClosureInput = {
  /** Body block (BlockAgent) the closure runs. */
  blockId: BlockId;
  /** The scope the closure captures (its chain to root is frozen). */
  scopeId: ScopeId;
  /** Snapshot the body block lives in (= the creating shard's `state.snapshot`). */
  snapshot: string;
  /** Var the closure binds itself to (self-reference). */
  selfVar: number;
  /** Content-store writer. */
  putBytes: PutClosureBytes;
};

/**
 * Freeze a closure (its body block + captured scope chain) into a content blob
 * and return its ref. Closures captured in the scope are already refs (no nested
 * serialization). A captured secret is refused. The blob is written via
 * `putBytes` BEFORE the ref is returned, so the ref is never dangling.
 */
export async function serializeClosure(
  state: State,
  input: SerializeClosureInput,
): Promise<RefRep> {
  const scopes: SerializedScope[] = [];
  let cursor: ScopeId | null = input.scopeId;
  const seen = new Set<ScopeId>();
  while (cursor !== null) {
    if (seen.has(cursor)) {
      throw new Error(`serializeClosure: scope cycle at ${cursor}`);
    }
    seen.add(cursor);
    const scope: Scope | undefined = state.scopes[cursor];
    if (scope === undefined) {
      throw new Error(`serializeClosure: scope ${cursor} missing`);
    }
    const values: Record<number, Value> = {};
    for (const [varKey, value] of Object.entries(scope.values)) {
      if (value === undefined) continue;
      // A captured secret would be frozen plaintext in the blob — refuse it.
      assertNoSecret(value);
      values[Number(varKey)] = value;
    }
    scopes.push({ id: cursor, parentId: scope.parentId, values });
    cursor = scope.parentId;
  }
  const content: SerializedClosure = {
    v: 1,
    blockId: input.blockId,
    snapshot: input.snapshot,
    scopes,
    capturedScopeId: input.scopeId,
    selfVar: input.selfVar,
  };
  const bytes = new TextEncoder().encode(JSON.stringify(content));
  return input.putBytes(bytes);
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
 * Graft a deserialized closure into `state`, returning the fresh local dispatch
 * id. Allocates new scope ids (remapping parent links), registers
 * `state.closures`, and re-binds the self-reference var to the closure's own ref
 * (`selfRef`) so a recursive body self-call re-materializes. After this the
 * standard `closure:<id>` dispatch path (resolveDelegateTarget) runs the body.
 *
 * Caller resolves `content.snapshot` to the right IR and builds the shard state
 * BEFORE calling — this only touches scopes / closures, not the IR.
 */
export function materializeClosure(
  content: SerializedClosure,
  state: State,
  selfRef: RefRep,
): ClosureId {
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
  // Re-bind the self var to the closure's own ref (recursive body self-calls
  // re-materialize from the same blob). `capturedRoot` was just written above.
  const rootScope = state.scopes[capturedRoot];
  if (rootScope !== undefined) {
    rootScope.values[content.selfVar] = { kind: "closure", ref: selfRef };
  }
  return newClosureId;
}

// ─── helpers ─────────────────────────────────────────────────────────────────

/** Throw if a `secret` Value is reachable inside `value` (closures must not
 *  freeze secrets to a value-store blob in plaintext). */
function assertNoSecret(value: Value): void {
  switch (value.kind) {
    case "secret":
      throw new Error(
        "serializeClosure: closure captures a secret — unsupported in v0.1.0 (would persist plaintext at rest)",
      );
    case "array":
      for (const element of value.elements) assertNoSecret(element);
      return;
    case "tagged":
      for (const field of Object.values(value.fields)) assertNoSecret(field);
      return;
    case "record":
      for (const entry of Object.values(value.entries)) assertNoSecret(entry);
      return;
    default:
      return;
  }
}
