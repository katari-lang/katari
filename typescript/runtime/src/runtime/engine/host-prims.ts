// Host primitives: the effectful built-ins the runtime registers on the `PrimRegistry` at boot, bound to
// the stores only the host process has (today the project's `env_entries` store). They are the runtime
// half of the `prelude.env.*` declarations in the compiler's stdlib — the engine resolves the leaf by
// its qualified name and calls the implementation registered here.
//
// Unlike the pure built-ins (arithmetic / string / logic, in `prims.ts`), these touch external state and
// manage their own privacy: `env.get_secret` is a secret *source*, so it marks its result `private`
// explicitly (its `key` argument is public, so the seam's monotonic taint would not). The engine awaits
// them inline — they are the "bounded env fetch" the turn's drive loop is designed to suspend on.

import type { QualifiedName } from "@katari-lang/types";
import type { BlobId, ProjectId } from "../ids.js";
import { markPrivate } from "../value/privacy.js";
import type { Value } from "../value/types.js";
import type { PrimContext, StoreEffects } from "./context.js";
import type { PrimRegistry } from "./prims.js";
import { KatariThrow } from "./throw-signal.js";

// The domain error ctor `get_secret` throws (`prelude/env.ktr` declares it).
const MISSING_SECRET = "prelude.env.missing_secret" as QualifiedName;

// The `prelude.store` result ctors (`prelude/store.ktr` declares them).
const STORE_FOUND = "prelude.store.found" as QualifiedName;
const STORE_ABSENT = "prelude.store.absent" as QualifiedName;
const STORE_LEAF = "prelude.store.leaf" as QualifiedName;
const STORE_BRANCH = "prelude.store.branch" as QualifiedName;

const NULL_VALUE: Value = { kind: "null" };

/** The project-scoped env store the env primitives read. A consumer-defined port: the wiring (facade)
 *  supplies the real DB-backed reader, while tests stub it. */
export interface EnvReader {
  /** The decrypted value of the *secret* entry under `key`, or `null` when no secret entry is set there
   *  (a non-secret entry under the same key does not count — `get_secret` reads the secret bucket only). */
  readSecret(projectId: ProjectId, key: string): Promise<string | null>;
  /** Every *non-secret* entry as plain `key -> value` (these values are stored in plaintext). */
  readPublic(projectId: ProjectId): Promise<Record<string, string>>;
}

/** The project-scoped durable KV rows the `prelude.store` primitives read and write. A
 *  consumer-defined port like `EnvReader`: the wiring supplies the DB-backed implementation
 *  (sealing / unsealing private nodes at this seam), tests stub it. Row writes apply immediately —
 *  each is idempotent, so an at-least-once re-run of the writing turn converges; the
 *  blob-ownership half of a write goes through the actor-provided `PrimContext.storeEffects`. */
export interface StoreRows {
  /** The stored value at the full key (unsealed — private marks intact), or `undefined`. */
  read(projectId: ProjectId, key: string): Promise<Value | undefined>;
  /** Create or replace the entry (last write wins), ensuring the project's store sentinel
   *  instance row exists first (the blob rows' owner FK points at it). */
  upsert(projectId: ProjectId, key: string, value: Value): Promise<void>;
  /** Delete the entry; a missing key is a no-op. */
  remove(projectId: ProjectId, key: string): Promise<void>;
  /** Every full key strictly under `prefix` (all keys when `prefix` is ""), sorted. */
  listKeys(projectId: ProjectId, prefix: string): Promise<string[]>;
  /** Whether any entry OTHER than `exceptKey` still references the blob — the reclaim guard. */
  isBlobReferenced(projectId: ProjectId, blobId: BlobId, exceptKey: string): Promise<boolean>;
}

/** The host-side stores the effectful primitives draw on. */
export interface HostPrimStores {
  env: EnvReader;
  store: StoreRows;
}

/** Register the effectful host primitives on `prims`, bound to `stores`. Called once at boot, after the
 *  registry is built with its pure built-ins. */
export function registerHostPrims(prims: PrimRegistry, stores: HostPrimStores): void {
  prims.register("prelude.env.get_secret", async (argument, context) => {
    const key = stringArgument(argument, "key");
    const value = await stores.env.readSecret(context.projectId, key);
    if (value === null) {
      // A missing secret is an anticipated configuration failure, not a broken invariant: raise the typed
      // `env.missing_secret` (carrying the key, so a fallback handler can branch on which secret is absent).
      throw new KatariThrow({
        kind: "record",
        ctor: MISSING_SECRET,
        fields: {
          key: { kind: "string", value: key },
          message: { kind: "string", value: `env.get_secret: no secret is set under "${key}"` },
        },
      });
    }
    // A secret source: the value is tainted `private` so it cannot reach a user-facing boundary unredacted.
    return markPrivate({ kind: "string", value });
  });

  prims.register("prelude.env.get_all", async (_argument, context) => {
    const entries = await stores.env.readPublic(context.projectId);
    // A null-prototype map so an env key literally named `__proto__` / `constructor` becomes a real record
    // field rather than a silently-dropped prototype write (env key names are admin-chosen, so not trusted).
    const fields: Record<string, Value> = Object.create(null);
    for (const [key, value] of Object.entries(entries)) {
      fields[key] = { kind: "string", value };
    }
    return { kind: "record", fields };
  });

  registerStorePrims(prims, stores.store);
}

/** Register the `prelude.store` primitives: the project's durable KV store. Row I/O goes through the
 *  `StoreRows` port; the blob-ownership half of a write (adopt on set, reclaim on replace / delete)
 *  goes through the actor-provided `PrimContext.storeEffects`, so a stored file's blob moves onto the
 *  store sentinel and outlives the writing run. */
export function registerStorePrims(prims: PrimRegistry, rows: StoreRows): void {
  prims.register("prelude.store.get", async (argument, context) => {
    const key = fullKeyOf(argument);
    const value = await rows.read(context.projectId, key);
    if (value === undefined) {
      const absent: Value = {
        kind: "record",
        ctor: STORE_ABSENT,
        fields: { key: { kind: "string", value: key } },
      };
      return absent;
    }
    const found: Value = { kind: "record", ctor: STORE_FOUND, fields: { value } };
    return found;
  });

  prims.register("prelude.store.set", async (argument, context) => {
    const key = fullKeyOf(argument);
    const value = recordField(argument, "value");
    const effects = storeEffectsOf(context);
    // Ownership first, row second: a crash between them leaves a sentinel-owned blob with no row (a
    // bounded leak the re-run repairs), never a row whose blob a completing run is about to reclaim.
    effects.adoptForStore(value);
    const previous = await rows.read(context.projectId, key);
    await rows.upsert(context.projectId, key, value);
    await freeStoreOrphans(rows, effects, context.projectId, key, previous, value);
    return NULL_VALUE;
  });

  prims.register("prelude.store.delete", async (argument, context) => {
    const key = fullKeyOf(argument);
    const effects = storeEffectsOf(context);
    const previous = await rows.read(context.projectId, key);
    await rows.remove(context.projectId, key);
    await freeStoreOrphans(rows, effects, context.projectId, key, previous, undefined);
    return NULL_VALUE;
  });

  prims.register("prelude.store.list", async (argument, context) => {
    const prefix = prefixOf(recordField(argument, "target"));
    const keys = await rows.listKeys(context.projectId, prefix);
    // Project each key onto its first segment below the prefix: no further "/" means a leaf, more
    // means a branch (deduplicated). Sorted by name, a leaf before the branch of the same name.
    const leaves = new Set<string>();
    const branches = new Set<string>();
    for (const key of keys) {
      const relative = prefix === "" ? key : keyBelowPrefix(key, prefix);
      if (relative === undefined || relative === "") continue;
      const separator = relative.indexOf("/");
      if (separator === -1) leaves.add(relative);
      else branches.add(relative.slice(0, separator));
    }
    const names = [...new Set([...leaves, ...branches])].sort();
    const elements: Value[] = [];
    for (const name of names) {
      if (leaves.has(name)) {
        elements.push({
          kind: "record",
          ctor: STORE_LEAF,
          fields: { key: { kind: "string", value: name } },
        });
      }
      if (branches.has(name)) {
        elements.push({
          kind: "record",
          ctor: STORE_BRANCH,
          fields: { name: { kind: "string", value: name } },
        });
      }
    }
    return { kind: "array", elements };
  });
}

/** The key below `prefix` (after its "/"), or `undefined` when the key is not under it — the "/"
 *  boundary guard, so the prefix "memo" never matches the key "memos/a". */
function keyBelowPrefix(key: string, prefix: string): string | undefined {
  return key.startsWith(`${prefix}/`) ? key.slice(prefix.length + 1) : undefined;
}

/** Reclaim the blobs `previous` referenced that neither `next` nor any other store entry still does —
 *  the write prims' shared cleanup. Only sentinel-owned blobs actually free (the effects guard). */
async function freeStoreOrphans(
  rows: StoreRows,
  effects: StoreEffects,
  projectId: ProjectId,
  key: string,
  previous: Value | undefined,
  next: Value | undefined,
): Promise<void> {
  if (previous === undefined) return;
  const kept = next === undefined ? new Set<BlobId>() : collectBlobRefs(next);
  const orphans: BlobId[] = [];
  for (const blobId of collectBlobRefs(previous)) {
    if (kept.has(blobId)) continue;
    if (await rows.isBlobReferenced(projectId, blobId, key)) continue;
    orphans.push(blobId);
  }
  if (orphans.length > 0) effects.freeStoreBlobs(orphans);
}

/** Every blob a value tree references (records / arrays / data walked into; a closure's captured
 *  environment deliberately NOT — storing a closure keeps its blobs on their current owners). */
function collectBlobRefs(value: Value, into: Set<BlobId> = new Set()): Set<BlobId> {
  switch (value.kind) {
    case "ref":
      into.add(value.blobId);
      break;
    case "record":
      for (const child of Object.values(value.fields)) collectBlobRefs(child, into);
      break;
    case "array":
      for (const child of value.elements) collectBlobRefs(child, into);
      break;
    default:
      break;
  }
  return into;
}

/** The full key of a store operation: the target view's prefix joined to the call's `key`. */
function fullKeyOf(argument: Value): string {
  const prefix = prefixOf(recordField(argument, "target"));
  const key = stringArgument(argument, "key");
  return prefix === "" ? key : `${prefix}/${key}`;
}

/** The `prefix` field of a `store` view value. */
function prefixOf(target: Value): string {
  if (target.kind !== "record") {
    throw new Error(`store primitive expected a store record, got ${target.kind}`);
  }
  const prefix = target.fields["prefix"];
  if (prefix === undefined || prefix.kind !== "string") {
    throw new Error("store primitive expected a string `prefix` on the store value");
  }
  return prefix.value;
}

/** A required field off a primitive's record argument, any kind. */
function recordField(argument: Value, name: string): Value {
  if (argument.kind !== "record") {
    throw new Error(`store primitive expected a record argument, got ${argument.kind}`);
  }
  const field = argument.fields[name];
  if (field === undefined) {
    throw new Error(`store primitive argument "${name}" is missing`);
  }
  return field;
}

/** The actor-provided store seams, absent only in a bare unit-test context. */
function storeEffectsOf(context: PrimContext): StoreEffects {
  if (context.storeEffects === undefined) {
    throw new Error("store primitives need an instance turn (no storeEffects on this context)");
  }
  return context.storeEffects;
}

/** Read a required string field off a primitive's record argument (the shape lowering emits for a call). */
function stringArgument(argument: Value, name: string): string {
  if (argument.kind !== "record") {
    throw new Error(`env primitive expected a record argument, got ${argument.kind}`);
  }
  const field = argument.fields[name];
  if (field === undefined || field.kind !== "string") {
    throw new Error(`env primitive argument "${name}" must be a string`);
  }
  return field.value;
}
