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
// Secrets: a captured `secret` is encrypted in the blob exactly as the shard
// checkpoint encrypts secrets (`encryptValueTree` → AES-GCM `$envelope`), so a
// closure can safely hold credentials — at rest it is ciphertext, in memory
// (after materialize) it is decrypted. The random AES nonce means a secret-
// bearing blob does not content-dedup, which is fine (the ref is a uuid handle).
//
// Metadata: the body block's compiled schema (name / description / input /
// output) is denormalized into the blob so the closure is self-describing —
// get_metadata reads it without re-resolving the block against an IR.

import type { Block, BlockId } from "../ir/types.js";
import { decryptValueTree, type EncryptedValue, encryptValueTree } from "../value-secret-codec.js";
import type { ClosureId, ScopeId } from "./id.js";
import { createScopeId } from "./id.js";
import type { Scope } from "./scope.js";
import type { State } from "./state.js";
import type { RefRep, Value } from "./value.js";

/** Writes closure-blob bytes to the value store, returning the ref. Injected by
 *  CoreModule (owner = core, semanticKind = "closure"). */
export type PutClosureBytes = (bytes: Uint8Array) => Promise<RefRep>;

/** Self-describing schema carried in the blob (the body BlockAgent's compiled
 *  metadata). Lets get_metadata answer without re-resolving the block. */
export type ClosureMetadata = {
  name: string;
  description?: string;
  inputSchema: string;
  outputSchema: string;
};

/** One captured scope, frozen for transport. Ids are the issuer's (string
 *  UUIDs); materialize remaps them to fresh ids. Values are `EncryptedValue`
 *  (a captured `secret` → `$envelope`); everything else passes through. */
type SerializedScope = {
  id: string;
  parentId: string | null;
  values: Record<number, EncryptedValue>;
};

/** The full frozen closure: body block + the snapshot its code lives in + its
 *  captured scope chain + its self-describing metadata. One value-store blob. */
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
  /** Compiled schema of the body block (denormalized for get_metadata). */
  metadata: ClosureMetadata;
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
 * Freeze a closure (its body block + captured scope chain + its compiled
 * metadata) into a content blob and return its ref. Closures captured in the
 * scope are already refs (no nested serialization); captured secrets are
 * encrypted. The blob is written via `putBytes` BEFORE the ref is returned, so
 * the ref is never dangling.
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
    const values: Record<number, EncryptedValue> = {};
    for (const [varKey, value] of Object.entries(scope.values)) {
      if (value === undefined) continue;
      // Encrypt captured secrets (AES-GCM $envelope) so the blob holds no
      // plaintext credential at rest; non-secret values pass through unchanged.
      values[Number(varKey)] = encryptValueTree(value);
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
    metadata: agentBlockMetadata(state, input.blockId),
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
    const values: Record<number, Value> = {};
    for (const [varKey, enc] of Object.entries(s.values)) {
      // Reverse the at-rest encryption — captured secrets come back to plaintext
      // Values in this shard's in-memory scope (like a loaded checkpoint).
      values[Number(varKey)] = decryptValueTree(enc);
    }
    state.scopes[freshId] = { id: freshId, parentId, values };
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

/** Read the body block's compiled schema for the blob (the block is a
 *  BlockAgent — the closure's wrapper). */
function agentBlockMetadata(state: State, blockId: BlockId): ClosureMetadata {
  const block = state.irModule.blocks[String(blockId)] as Block | undefined;
  if (block === undefined || block.kind !== "blockAgent") {
    throw new Error(`serializeClosure: block ${blockId} is not a blockAgent (${block?.kind})`);
  }
  const body = block.body;
  return {
    name: body.name,
    description: body.description,
    inputSchema: body.inputSchema,
    outputSchema: body.outputSchema,
  };
}
