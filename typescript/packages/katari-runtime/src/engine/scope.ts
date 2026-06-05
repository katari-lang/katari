// Scope: lexical-binding tree node. Stored as plain data (Immer-friendly).
//
// Scopes form a tree via `parentId`. Variable lookup walks the parent chain.
// Closures capture a scopeId; the GC traces those refs through Value to
// keep captured scopes alive.

import type { Json } from "../json.js";
import type { ScopeId } from "./id.js";
import type { Value } from "./value.js";

export type Scope = {
  id: ScopeId;
  parentId: ScopeId | null;
  /**
   * VarId → Value map, stored as a plain object so Immer can treat it as
   * structural data. `Map` would also work but adds friction with Immer's
   * draft producers.
   */
  values: Record<number, Value>;
  /**
   * The ambient generic substitution of the enclosing agent activation, set on
   * an agent's root scope from the inbound `delegate` event's `generics`. Inner
   * (inline) bodies inherit it via the scope chain; a `statementApplyGenerics`
   * fills its template `$generic` placeholders against the nearest one.
   */
  ambientGenerics?: Record<string, Json>;
};
