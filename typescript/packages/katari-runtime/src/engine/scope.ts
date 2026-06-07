// Scope: lexical-binding tree node. Stored as plain data (Immer-friendly).
//
// Scopes form a tree via `parentId`. Variable lookup walks the parent chain.
// Closures capture a scopeId; the GC traces those refs through Value to
// keep captured scopes alive.

import type { Json } from "../json.js";
import type { ScopeId } from "./id.js";
import type { Value } from "./value.js";

// `V` parameterises the embedded `Value` so the storage boundary can
// instantiate `Scope<EncryptedValue>` for the encrypted checkpoint form. The
// live engine uses the default `Scope = Scope<Value>`; only `engine/snapshot.ts`
// picks a different `V`. See `mapScopeValues` there.
export type Scope<V = Value> = {
  id: ScopeId;
  parentId: ScopeId | null;
  /**
   * VarId → Value map, stored as a plain object so Immer can treat it as
   * structural data. `Map` would also work but adds friction with Immer's
   * draft producers.
   */
  values: Record<number, V>;
  /**
   * The ambient generic substitution of the enclosing agent activation, set on
   * an agent's root scope from the inbound `delegate` event's `generics`. Inner
   * (inline) bodies inherit it via the scope chain; a `statementApplyGenerics`
   * fills its template `$generic` placeholders against the nearest one.
   */
  ambientGenerics?: Record<string, Json>;
};
