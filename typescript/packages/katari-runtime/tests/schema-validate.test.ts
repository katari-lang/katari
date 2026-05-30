// Rep-aware schema validation (#5): a runtime value can be carried as a content
// ref where the schema describes the logical type. `relaxSchemaForRefs` lets a
// `{type:"string"}` node also accept a `$ref as:"string"` envelope; closures
// need no relaxation because they serialise as `$agent` (uniform with agents),
// matching the callable schema directly.

import { describe, expect, it } from "vitest";
import {
  relaxSchemaForRefs,
  validateAgainstSchema,
} from "../src/engine/schema-validate.js";
import type { RefRep, Value } from "../src/engine/value.js";
import type { Json } from "../src/json.js";
import { valueToRaw } from "../src/value-codec.js";

const refString = (): Json =>
  ({ $ref: { module: "core", id: "x" }, as: "string", hash: "h", size: 5 }) as Json;

describe("rep-aware schema validation", () => {
  it("relaxed string node accepts both an inline string and a $ref-as-string", () => {
    const schema = {
      type: "object",
      properties: { name: { type: "string" } },
      required: ["name"],
      additionalProperties: false,
    } as Json;
    const relaxed = relaxSchemaForRefs(schema);

    expect(validateAgainstSchema({ name: "hi" }, relaxed)).toEqual([]);
    expect(validateAgainstSchema({ name: refString() }, relaxed)).toEqual([]);
    // Without the relaxation a ref-string would (wrongly) be rejected.
    expect(validateAgainstSchema({ name: refString() }, schema).length).toBeGreaterThan(0);
    // The relaxation only adds the ref branch — a number is still rejected.
    expect(validateAgainstSchema({ name: 42 }, relaxed).length).toBeGreaterThan(0);
  });

  it("relaxation reaches strings nested in arrays / objects", () => {
    const schema = {
      type: "object",
      properties: { items: { type: "array", items: { type: "string" } } },
      required: ["items"],
      additionalProperties: false,
    } as Json;
    const relaxed = relaxSchemaForRefs(schema);
    expect(validateAgainstSchema({ items: ["plain", refString()] }, relaxed)).toEqual([]);
  });

  it("a closure validates against the $agent callable schema with no relaxation", () => {
    // callableRefCore: { type:object, properties:{$agent:string}, required:[$agent], additionalProperties:false }
    const callableSchema = {
      type: "object",
      properties: { $agent: { type: "string" } },
      required: ["$agent"],
      additionalProperties: false,
    } as Json;

    const ref: RefRep = { kind: "ref", module: "core", id: "c", hash: "h", size: 3 };
    const closure: Value = { kind: "closure", ref };
    // valueToRaw(closure) is { $agent: "closureref:..." } — a callable handle.
    expect(validateAgainstSchema(valueToRaw(closure), callableSchema)).toEqual([]);

    const agent: Value = { kind: "agentLiteral", qualifiedName: "m.foo" };
    expect(validateAgainstSchema(valueToRaw(agent), callableSchema)).toEqual([]);
  });
});
