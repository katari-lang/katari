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
import { decryptValueTree, type EncryptedValue, encryptValueTree } from "../value-secret-codec.js";
import type { ScopeId, ThreadId } from "./id.js";
import type { Scope } from "./scope.js";
import type { State } from "./state.js";
import type { ChildRole, PendingAction, PostCancelAction, Thread } from "./thread/types.js";
import type { RefRep, Value } from "./value.js";

// `V` is the embedded value type. The in-memory / plaintext checkpoint is
// `EngineCheckpoint<Value>` (the default — `serialize` produces it); the
// encrypted-at-rest form is `EngineCheckpoint<EncryptedValue>` (=
// `EncryptedEngineCheckpoint`). Making the two genuinely distinct types is the
// point: storage only ever accepts `EncryptedEngineCheckpoint`, so "persisted a
// plaintext secret" is now a type error rather than a runtime hope. Only
// `threads` / `scopes` carry Values — every other field is value-free.
export type EngineCheckpoint<V = Value> = {
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
  threads: Record<ThreadId, Thread<V>>;
  scopes: Record<ScopeId, Scope<V>>;
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

// ─── Value mapping across the checkpoint (storage boundary) ─────────────────
//
// `mapCheckpointValues` walks the *structure* of a checkpoint — the only
// Value-bearing fields are `threads` and `scopes` — and applies `transform` to
// every embedded `Value`. The transform recurses WITHIN a Value tree (records /
// arrays / secret leaves); this walker only locates the Value SLOTS.
//
// It is TYPED end to end: `mapThreadValues<V, W>` returns `Thread<W>`, so if a
// thread variant grows a new Value-typed field that the walker fails to map,
// the result is no longer assignable to `Thread<W>` and the build breaks. The
// `encrypt` / `decrypt` instantiations pick V≠W (`Value` ↔ `EncryptedValue`),
// where any missed slot is a hard error; `promote` (V=W=Value) rides the same,
// already-verified walker. This replaces an earlier untyped walk that
// identified Values by a `kind`-tag set and so mistook a `RecordThread`
// (`kind: "record"`) for a Value record.
//
// The walker is async only because `promote` is async; `encrypt` / `decrypt`
// pass synchronous transforms (an `await` on a plain value is a noop). Both
// callers (CORE persist / load) are already async.

/** A checkpoint whose every embedded secret has been replaced by its AES-GCM
 *  envelope. A genuinely distinct type from the plaintext `EngineCheckpoint`:
 *  storage accepts only this, so a plaintext checkpoint cannot reach the DB. */
export type EncryptedEngineCheckpoint = EngineCheckpoint<EncryptedValue>;

type Transform<A, B> = (value: A) => B | Promise<B>;

async function mapRecord<K extends PropertyKey, A, B>(
  record: Record<K, A>,
  f: Transform<A, B>,
): Promise<Record<K, B>> {
  const out = {} as Record<K, B>;
  for (const [key, value] of Object.entries(record) as [K, A][]) {
    out[key] = await f(value);
  }
  return out;
}

async function mapArray<A, B>(array: A[], f: Transform<A, B>): Promise<B[]> {
  const out: B[] = [];
  for (const element of array) out.push(await f(element));
  return out;
}

async function mapOptional<A, B>(value: A | undefined, f: Transform<A, B>): Promise<B | undefined> {
  return value === undefined ? undefined : await f(value);
}

async function mapChildRole<V, W>(role: ChildRole<V>, f: Transform<V, W>): Promise<ChildRole<W>> {
  return role.kind === "thenClause"
    ? { ...role, mainResultValue: await f(role.mainResultValue) }
    : role;
}

async function mapPendingAction<V, W>(
  action: PendingAction<V>,
  f: Transform<V, W>,
): Promise<PendingAction<W>> {
  switch (action.kind) {
    case "ask":
      return { ...action, argument: await mapOptional(action.argument, f) };
    case "thenClause":
      return { ...action, mainResultValue: await f(action.mainResultValue) };
  }
}

async function mapPostCancelAction<V, W>(
  action: PostCancelAction<V>,
  f: Transform<V, W>,
): Promise<PostCancelAction<W>> {
  switch (action.kind) {
    case "finish":
      return { ...action, value: await mapOptional(action.value, f) };
    case "askComplete":
      return { ...action, value: await f(action.value) };
  }
}

/** Map every embedded Value of one thread. Exhaustive over the thread union;
 *  the `Thread<V> → Thread<W>` signature is what makes a missed Value field a
 *  compile error (the unmapped field keeps type `V`, which is not `W`). */
async function mapThreadValues<V, W>(thread: Thread<V>, f: Transform<V, W>): Promise<Thread<W>> {
  switch (thread.kind) {
    case "agent":
      return {
        ...thread,
        argument: await mapOptional(thread.argument, f),
        pendingReturn: await mapOptional(thread.pendingReturn, f),
      };
    case "handle":
      return {
        ...thread,
        childRoles: await mapRecord(thread.childRoles, (role) => mapChildRole(role, f)),
        pendingActions: await mapArray(thread.pendingActions, (action) =>
          mapPendingAction(action, f),
        ),
        postCancelActions: await mapRecord(thread.postCancelActions, (action) =>
          mapPostCancelAction(action, f),
        ),
        pendingReturn: await mapOptional(thread.pendingReturn, f),
      };
    case "for":
      return {
        ...thread,
        iterableSnapshot: await mapArray(thread.iterableSnapshot, f),
        collected: await mapRecord(thread.collected, f),
        postCancelActions: await mapRecord(thread.postCancelActions, (action) =>
          mapPostCancelAction(action, f),
        ),
        pendingReturn: await mapOptional(thread.pendingReturn, f),
      };
    case "request":
    case "delegate":
    case "prim":
    case "ctor":
      return { ...thread, argument: await mapOptional(thread.argument, f) };
    case "callAgent":
      return {
        ...thread,
        target: await f(thread.target),
        argsRecord: await mapRecord(thread.argsRecord, f),
      };
    case "tuple":
    case "record":
      return { ...thread, collected: await mapRecord(thread.collected, f) };
    case "user":
    case "match":
    case "getField":
    case "makeClosure":
      // Value-free variants — assignable to Thread<W> unchanged.
      return thread;
  }
}

async function mapScopeValues<V, W>(scope: Scope<V>, f: Transform<V, W>): Promise<Scope<W>> {
  return { ...scope, values: await mapRecord(scope.values, f) };
}

async function mapCheckpointValues<V, W>(
  checkpoint: EngineCheckpoint<V>,
  f: Transform<V, W>,
): Promise<EngineCheckpoint<W>> {
  return {
    ...checkpoint,
    threads: await mapRecord(checkpoint.threads, (thread) => mapThreadValues(thread, f)),
    scopes: await mapRecord(checkpoint.scopes, (scope) => mapScopeValues(scope, f)),
  };
}

/**
 * Encrypt every `secret` embedded in a checkpoint into its storage envelope.
 * The result type (`EncryptedEngineCheckpoint`) is distinct from the input, so
 * the boundary is enforced statically: only an encrypted checkpoint can be
 * handed to storage.
 */
export function encryptCheckpoint(
  checkpoint: EngineCheckpoint,
): Promise<EncryptedEngineCheckpoint> {
  return mapCheckpointValues(checkpoint, encryptValueTree);
}

/**
 * Inverse of `encryptCheckpoint`. Throws via `secret-crypto` if any envelope
 * fails AES-GCM authentication (= tampering or wrong key).
 */
export function decryptCheckpoint(encrypted: EncryptedEngineCheckpoint): Promise<EngineCheckpoint> {
  return mapCheckpointValues(encrypted, decryptValueTree);
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

/** Recurse a Value tree, promoting every inline `string` over the threshold to
 *  a content-addressed ref. Other kinds pass through (secret stays inline; file
 *  / ref strings are already refs). */
async function promoteValueTree(
  value: Value,
  promote: PromoteFn,
  threshold: number,
): Promise<Value> {
  switch (value.kind) {
    case "string":
      return value.rep.kind === "inline" && Buffer.byteLength(value.rep.text, "utf8") > threshold
        ? { kind: "string", rep: await promote(value.rep.text) }
        : value;
    case "array":
      return {
        kind: "array",
        elements: await mapArray(value.elements, (e) => promoteValueTree(e, promote, threshold)),
      };
    case "record": {
      const entries = await mapRecord(value.entries, (e) =>
        promoteValueTree(e, promote, threshold),
      );
      return value.ctor !== undefined
        ? { kind: "record", entries, ctor: value.ctor }
        : { kind: "record", entries };
    }
    default:
      return value;
  }
}

/**
 * Promote every large inline `string` in a checkpoint to a content-addressed
 * ref via `promote`. Returns a structurally-equivalent checkpoint. Run BEFORE
 * `encryptCheckpoint` at persist time (promotion handles strings, encryption
 * handles the remaining secrets — disjoint concerns).
 */
export function promoteCheckpoint(
  checkpoint: EngineCheckpoint,
  promote: PromoteFn,
  threshold: number = DEFAULT_PROMOTE_THRESHOLD_BYTES,
): Promise<EngineCheckpoint> {
  return mapCheckpointValues(checkpoint, (value) => promoteValueTree(value, promote, threshold));
}
