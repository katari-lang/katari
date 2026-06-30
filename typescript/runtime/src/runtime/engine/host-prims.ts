// Host primitives: the effectful built-ins the runtime registers on the `PrimRegistry` at boot, bound to
// the stores only the host process has (today the project's `env_entries` store). They are the runtime
// half of the `primitive.env.*` declarations in the compiler's stdlib — the engine resolves the leaf by
// its qualified name and calls the implementation registered here.
//
// Unlike the pure built-ins (arithmetic / string / logic, in `prims.ts`), these touch external state and
// manage their own privacy: `env.get_secret` is a secret *source*, so it marks its result `private`
// explicitly (its `key` argument is public, so the seam's monotonic taint would not). The engine awaits
// them inline — they are the "bounded env fetch" the turn's drive loop is designed to suspend on.

import type { ProjectId } from "../ids.js";
import { markPrivate } from "../value/privacy.js";
import type { Value } from "../value/types.js";
import type { PrimRegistry } from "./prims.js";

/** The project-scoped env store the env primitives read. A consumer-defined port: the wiring (facade)
 *  supplies the real DB-backed reader, while tests stub it. */
export interface EnvReader {
  /** The decrypted value of the *secret* entry under `key`, or `null` when no secret entry is set there
   *  (a non-secret entry under the same key does not count — `get_secret` reads the secret bucket only). */
  readSecret(projectId: ProjectId, key: string): Promise<string | null>;
  /** Every *non-secret* entry as plain `key -> value` (these values are stored in plaintext). */
  readPublic(projectId: ProjectId): Promise<Record<string, string>>;
}

/** The host-side stores the effectful primitives draw on. */
export interface HostPrimStores {
  env: EnvReader;
}

/** Register the effectful host primitives on `prims`, bound to `stores`. Called once at boot, after the
 *  registry is built with its pure built-ins. */
export function registerHostPrims(prims: PrimRegistry, stores: HostPrimStores): void {
  prims.register("primitive.env.get_secret", async (argument, context) => {
    const key = stringArgument(argument, "key");
    const value = await stores.env.readSecret(context.projectId, key);
    if (value === null) {
      // A missing secret is a deterministic failure; the thrown error becomes the prim's declared `panic`.
      throw new Error(`env: no secret is set under "${key}"`);
    }
    // A secret source: the value is tainted `private` so it cannot reach a user-facing boundary unredacted.
    return markPrivate({ kind: "string", value });
  });

  prims.register("primitive.env.get_all", async (_argument, context) => {
    const entries = await stores.env.readPublic(context.projectId);
    const fields: Record<string, Value> = {};
    for (const [key, value] of Object.entries(entries)) {
      fields[key] = { kind: "string", value };
    }
    return { kind: "record", fields };
  });
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
