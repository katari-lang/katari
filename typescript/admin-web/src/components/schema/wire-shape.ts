// The Katari wire vocabulary as it appears in a JSON SCHEMA rather than in a value.
//
// The compiler renders a `data` / `file` / callable value as an object schema whose declared PROPERTIES
// are the reserved `$katari_` keys — so the very discriminators the runtime codec and the FFI port encode
// against also tell a schema's variant apart, one level up. Recognised here through `@katari-lang/types`'
// own `wireKindOf` and key constants (the same single definition `ValueViewer` reads), so the schema
// viewer cannot drift from the shapes the compiler actually emits.
//
// It HAD drifted, which is why this module exists: the viewer looked for an `as: { const: "file" }`
// property that the compiler has never emitted (the file schema carries `$katari_semantic_kind`), so every
// `file` schema rendered as a bare "ref"; and it displayed a data value's `$katari_value` nesting as if it
// were a field, burying the constructor's real fields one level down.

import { CONSTRUCTOR_KEY, VALUE_KEY, type WireKind, wireKindOf } from "@katari-lang/types";
import type { Json, JsonSchema } from "../../api/types";

/** Narrow a `Json` value to a schema object (the keyed shape), or null for a scalar / array. */
export function asObject(value: Json | undefined): JsonSchema | null {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value : null;
}

/** Which Katari wire variant an object schema describes, read off the reserved discriminator it declares
 *  as a PROPERTY. `null` means a plain JSON Schema object — no reserved key, so nothing to unwrap. */
export function schemaWireKindOf(properties: JsonSchema | null): WireKind | null {
  if (properties === null) return null;
  return wireKindOf((key) => properties[key] !== undefined) ?? null;
}

/** The constructor a `data` schema pins, taken from its discriminator property's `const`. `null` when the
 *  discriminator is not a constant (an open `data` schema), so the caller falls back to a generic label. */
export function schemaConstructorNameOf(properties: JsonSchema | null): string | null {
  const discriminator = asObject(properties?.[CONSTRUCTOR_KEY]);
  return typeof discriminator?.const === "string" ? discriminator.const : null;
}

/** The schema of a `data` value's OWN fields. They nest one level down, under `$katari_value`, so that no
 *  field name can collide with the discriminator — which means the fields a reader wants are never the
 *  outer object's properties (those are the two reserved keys) but this inner object's. `null` when the
 *  nesting is absent or not an object, leaving the caller to render the outer schema as it stands. */
export function schemaConstructorFieldsOf(properties: JsonSchema | null): JsonSchema | null {
  return asObject(properties?.[VALUE_KEY]);
}
