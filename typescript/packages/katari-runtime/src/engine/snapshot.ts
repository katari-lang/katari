// EngineCheckpoint: pure JSON conversion for engine `State`.
//
// On naming: "Snapshot" refers to the user-facing deploy unit (= IR +
// sidecar JS + schema bundle), represented as `Snapshot` on the
// `katari-api-server` side. This engine-internal freeze is called
// **EngineCheckpoint** to avoid collision.
//
// State is plain data (Record-of-data, no class instances, no non-JSON
// values), so serialize is equivalent to structuredClone, and deserialize
// is the inverse. IRModule is not included here (the host provides it
// from the deploy unit).
//
// **Secret encryption**: `encryptCheckpoint` / `decryptCheckpoint`
// transform the checkpoint at the storage boundary. They walk the
// JSON tree, detect every `Value`-shaped node (= `kind` ∈ the set of
// runtime Value variants), and pass it through 'encryptValueTree' /
// 'decryptValueTree'. Non-Value objects are recursed through
// structurally. This keeps the storage layer completely unaware of
// what counts as a secret — CoreModule encrypts before save and
// decrypts after load; storage just sees an opaque JSON blob.

import type { IRModule } from "../ir/types.js";
import { decryptValueTree, encryptValueTree } from "../value-secret-codec.js";
import type { State } from "./state.js";
import type { RefRep } from "./value.js";

export type EngineCheckpoint = {
  /**
   * Engine checkpoint layout version. v0.1.0 ships as v1 — the
   * pre-release version numbers (3, 4) used during development were
   * reset since there are no production checkpoints to migrate.
   * Bump on any breaking layout change AFTER v0.1.0.
   */
  schemaVersion: 1;
  selfEndpoint: string;
  ffiTargetEndpoint: string;
  envTargetEndpoint: string;
  threads: State["threads"];
  scopes: State["scopes"];
  closures: State["closures"];
  nextClosureId: number;
  delegations: State["delegations"];
  pendingDelegateOut: State["pendingDelegateOut"];
  delegationSenders: State["delegationSenders"];
  escalationOwners: State["escalationOwners"];
  lastGcScopeCount: number;
};

export function serialize(state: State): EngineCheckpoint {
  return {
    schemaVersion: 1,
    selfEndpoint: state.selfEndpoint,
    ffiTargetEndpoint: state.ffiTargetEndpoint,
    envTargetEndpoint: state.envTargetEndpoint,
    threads: structuredClone(state.threads),
    scopes: structuredClone(state.scopes),
    closures: structuredClone(state.closures),
    nextClosureId: state.nextClosureId,
    delegations: structuredClone(state.delegations),
    pendingDelegateOut: structuredClone(state.pendingDelegateOut),
    delegationSenders: structuredClone(state.delegationSenders),
    escalationOwners: structuredClone(state.escalationOwners),
    lastGcScopeCount: state.lastGcScopeCount,
  };
}

export function deserialize(irModule: IRModule, snap: EngineCheckpoint): State {
  if (snap.schemaVersion !== 1) {
    throw new Error(`engine.checkpoint: unsupported schemaVersion ${snap.schemaVersion}`);
  }
  const threads = structuredClone(snap.threads);
  const scopes = structuredClone(snap.scopes);
  return {
    selfEndpoint: snap.selfEndpoint as State["selfEndpoint"],
    irModule,
    // CORE-private (not in the checkpoint) — the host re-supplies it from
    // engine_shards.current_snapshot right after load.
    snapshot: "",
    threads,
    scopes,
    closures: structuredClone(snap.closures),
    nextClosureId: snap.nextClosureId,
    delegations: structuredClone(snap.delegations),
    pendingDelegateOut: structuredClone(snap.pendingDelegateOut),
    delegationSenders: structuredClone(snap.delegationSenders),
    escalationOwners: structuredClone(snap.escalationOwners),
    ffiTargetEndpoint: snap.ffiTargetEndpoint as State["ffiTargetEndpoint"],
    envTargetEndpoint: snap.envTargetEndpoint as State["envTargetEndpoint"],
    lastGcScopeCount: snap.lastGcScopeCount,
    scopeCount: Object.keys(scopes).length,
    threadCount: Object.keys(threads).length,
  };
}

// ─── Secret encryption at the storage boundary ─────────────────────────────

/**
 * Nominal marker for checkpoints whose secret values have been encrypted.
 * Currently structurally identical to EngineCheckpoint — the encryption
 * guarantee is enforced at runtime by walkValuesInTree, not by the type
 * system. A branded type should replace this in v0.2.0.
 */
export type EncryptedEngineCheckpoint = Omit<EngineCheckpoint, never>;

/** Runtime tag set used by 'walkValuesInTree' to identify a
 * 'Value'-shaped object inside the otherwise unstructured JSON
 * tree of a checkpoint. Kept in sync with the 'Value' tagged union
 * in 'value.ts'. */
const VALUE_KIND_TAGS: ReadonlySet<string> = new Set([
  "number",
  "string",
  "file",
  "boolean",
  "null",
  "array",
  "tagged",
  "record",
  "closure",
  "agentLiteral",
  "secret",
]);

/**
 * Encrypt every 'secret' Value embedded in a checkpoint. Returns a
 * structurally-equivalent JSON tree where each former 'secret' Value
 * has been replaced by the storage-only 'EncryptedSecret' envelope.
 * Idempotent on checkpoints that have no secrets.
 */
export function encryptCheckpoint(checkpoint: EngineCheckpoint): EncryptedEngineCheckpoint {
  return walkValuesInTree(checkpoint, encryptValueTree) as EncryptedEngineCheckpoint;
}

/**
 * Inverse of 'encryptCheckpoint'. Throws via 'secret-crypto' if any
 * envelope fails AES-GCM authentication (= tampering or wrong key).
 */
export function decryptCheckpoint(encrypted: EncryptedEngineCheckpoint): EngineCheckpoint {
  return walkValuesInTree(encrypted, decryptValueTree) as EngineCheckpoint;
}

/**
 * Walk a JSON tree, calling `transform` on every node whose shape
 * matches a 'Value' variant (= `kind` field in 'VALUE_KIND_TAGS').
 * Other objects are recursed structurally. Pure: returns a fresh
 * tree without mutating the input.
 *
 * Untyped on purpose: the checkpoint structure threads `Value` through
 * deeply nested Thread variants whose full type-level enumeration
 * would be both verbose and brittle to internal refactors. The
 * 'VALUE_KIND_TAGS' set is the single source of truth — extending the
 * 'Value' union elsewhere requires only updating that set.
 *
 * The transform's input/output relationship (Value→EncryptedValue or
 * EncryptedValue→Value) is enforced by the typed wrappers
 * 'encryptCheckpoint' / 'decryptCheckpoint', not by this internal
 * helper.
 */
function walkValuesInTree(
  node: unknown,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  transform: (v: any) => unknown,
): unknown {
  if (node === null || typeof node !== "object") return node;
  if (Array.isArray(node)) {
    return node.map((n) => walkValuesInTree(n, transform));
  }
  const obj = node as Record<string, unknown>;
  // Match BOTH the plaintext Value shape (= kind ∈ VALUE_KIND_TAGS) and
  // the encrypted-storage envelope (= '$envelope' marker). 'encryptValueTree'
  // is fed only plaintext Values during encrypt (no envelopes exist at
  // that point); 'decryptValueTree' is fed both shapes during decrypt
  // (plaintext Values pass through unchanged, envelopes decrypt back).
  // Keeping the match here — not in two separate walkers — means a
  // checkpoint that mixes plaintext and encrypted nodes (e.g. an
  // already-encrypted checkpoint re-encrypted) still round-trips.
  if (
    (typeof obj.kind === "string" && VALUE_KIND_TAGS.has(obj.kind)) ||
    typeof obj.$envelope === "string"
  ) {
    return transform(obj);
  }
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj)) {
    out[k] = walkValuesInTree(v, transform);
  }
  return out;
}

// ─── Persist-time promotion (inline string → content-addressed ref) ─────────
//
// The motivating problem: a large `string` (e.g. an accumulated AI
// conversation) sits inline in CORE state and is copied to the DB on every
// persist, bloating the checkpoint. Promotion writes the bytes once to the
// value store and replaces the inline rep with a `ref`, so the checkpoint
// carries only a small handle. On reload the value is a ref; `==` / `match`
// compare by hash (no fetch) and `concat` / `format` materialize on demand
// (Phase E0) — so promotion is observationally transparent (E-design
// invariant #8).
//
// Only `string` inline reps over a byte threshold are promoted. `secret` stays
// inline (secret refs are unsupported in v0.1.0); `file` is already a ref;
// already-ref strings pass through unchanged (so a value promoted once keeps a
// stable ref id across persists rather than churning a new ref each time).

/** Writes bytes to the value store and returns the resulting ref. Injected. */
export type PromoteFn = (text: string) => Promise<RefRep>;

/** Default 4 KiB: below this an inline string is cheap to keep in the checkpoint. */
export const DEFAULT_PROMOTE_THRESHOLD_BYTES = 4096;

function inlineTextOverThreshold(
  rep: unknown,
  threshold: number,
): rep is { kind: "inline"; text: string } {
  return (
    typeof rep === "object" &&
    rep !== null &&
    (rep as { kind?: unknown }).kind === "inline" &&
    typeof (rep as { text?: unknown }).text === "string" &&
    Buffer.byteLength((rep as { text: string }).text, "utf8") > threshold
  );
}

async function promoteInTree(
  node: unknown,
  promote: PromoteFn,
  threshold: number,
): Promise<unknown> {
  if (node === null || typeof node !== "object") return node;
  if (Array.isArray(node)) {
    return Promise.all(node.map((n) => promoteInTree(n, promote, threshold)));
  }
  const obj = node as Record<string, unknown>;
  // A `string` Value whose inline text exceeds the threshold → promote.
  if (obj.kind === "string" && inlineTextOverThreshold(obj.rep, threshold)) {
    return { kind: "string", rep: await promote((obj.rep as { text: string }).text) };
  }
  // Everything else (non-Value structure, composite Values, secret/file/ref
  // strings, small strings) recurses structurally so nested strings promote.
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj)) {
    out[k] = await promoteInTree(v, promote, threshold);
  }
  return out;
}

/**
 * Promote every large inline `string` in a checkpoint to a content-addressed
 * ref via `promote`. Returns a structurally-equivalent checkpoint. Run BEFORE
 * `encryptCheckpoint` at persist time (promotion handles strings, encryption
 * handles the remaining secrets — disjoint concerns).
 */
export async function promoteCheckpoint(
  checkpoint: EngineCheckpoint,
  promote: PromoteFn,
  threshold: number = DEFAULT_PROMOTE_THRESHOLD_BYTES,
): Promise<EngineCheckpoint> {
  return (await promoteInTree(checkpoint, promote, threshold)) as EngineCheckpoint;
}
