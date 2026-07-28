// Unit test for the admin console's SCHEMA-side wire recognisers
// (`admin-web/src/components/schema/wire-shape.ts`) — pinned against the shapes the compiler actually
// emits (`haskell/compiler/src/Katari/Schema.hs`).
//
// It lives in the runtime suite because `admin-web` is a Vite app with no test runner of its own, and the
// recognisers are the one part of the viewer that is pure (no JSX, no React) — so they can be exercised
// from here without pulling a second runner into the workspace. This is a straight relative import of that
// module; nothing in the runtime depends on admin-web.
//
// What is being guarded: the viewer previously hand-wrote its own discriminator checks and had silently
// drifted from the compiler — it looked for an `as: { const: "file" }` property that `Schema.hs` never
// emits, so EVERY file schema rendered as a bare "ref", and it treated a data value's `$katari_value`
// nesting as a field, burying the constructor's real fields one level down. The fix routes both through
// `@katari-lang/types`' shared discriminator constants; these cases are the fixtures that would have
// caught the drift.

import { describe, expect, test } from "vitest";
import {
  asObject,
  schemaConstructorFieldsOf,
  schemaConstructorNameOf,
  schemaWireKindOf,
} from "../../admin-web/src/components/schema/wire-shape";

/** `fileReferenceSchema` in `Schema.hs`: the slim blob handle — identity only, `$katari_semantic_kind`
 *  accepted alongside it, and the object left open. */
const fileSchema = {
  type: "object",
  properties: { $katari_ref: { type: "string" }, $katari_semantic_kind: { type: "string" } },
  required: ["$katari_ref"],
  additionalProperties: true,
};

/** `callableReferenceSchema` in `Schema.hs`: an open object requiring just the `$katari_agent`
 *  discriminator, whose value is left unconstrained. */
const agentSchema = {
  type: "object",
  properties: { $katari_agent: {} },
  required: ["$katari_agent"],
  additionalProperties: true,
};

/** The tagged object a `data` declaration lowers to in `Schema.hs`: the constructor name as a `const`
 *  discriminator, and the constructor's own fields nested under `$katari_value`. */
const dataSchema = {
  type: "object",
  properties: {
    $katari_constructor: { description: "…", const: "demo.circle" },
    $katari_value: {
      type: "object",
      properties: { radius: { type: "number" }, label: { type: "string" } },
      required: ["radius"],
      additionalProperties: true,
    },
  },
  required: ["$katari_constructor", "$katari_value"],
  additionalProperties: false,
};

describe("schema wire-shape recognisers", () => {
  test("a file schema is recognised as `file`, not as a bare reference", () => {
    // The drift this replaced: the old check required an `as: { const: "file" }` property, so every file
    // schema fell through to the generic "ref" badge.
    expect(schemaWireKindOf(asObject(fileSchema.properties))).toBe("file");
  });

  test("a callable reference schema is recognised as `agent`", () => {
    expect(schemaWireKindOf(asObject(agentSchema.properties))).toBe("agent");
  });

  test("a data schema is recognised as `data` and names its constructor", () => {
    const properties = asObject(dataSchema.properties);
    expect(schemaWireKindOf(properties)).toBe("data");
    expect(schemaConstructorNameOf(properties)).toBe("demo.circle");
  });

  test("a data schema's displayable fields come from the `$katari_value` nesting", () => {
    // The drift this replaced: the outer properties are the two reserved keys, so displaying them showed
    // a literal `$katari_value` row with the real fields buried inside it.
    const fields = schemaConstructorFieldsOf(asObject(dataSchema.properties));
    expect(fields).not.toBeNull();
    expect(Object.keys(asObject(fields?.properties) ?? {})).toEqual(["radius", "label"]);
    expect(fields?.required).toEqual(["radius"]);
  });

  test("a plain object schema carries no wire variant", () => {
    const plain = { type: "object", properties: { name: { type: "string" } } };
    expect(schemaWireKindOf(asObject(plain.properties))).toBeNull();
    expect(schemaWireKindOf(null)).toBeNull();
  });

  test("a data schema with no nesting yields no fields rather than a wrong shape", () => {
    const malformed = { properties: { $katari_constructor: { const: "demo.nullary" } } };
    const properties = asObject(malformed.properties);
    expect(schemaWireKindOf(properties)).toBe("data");
    expect(schemaConstructorFieldsOf(properties)).toBeNull();
  });
});
