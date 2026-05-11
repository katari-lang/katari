// Round-trip + structural tests for the raw ↔ Value codec.

import { describe, expect, it } from "vitest";
import type { Value } from "../src/engine/value.js";
import type { ClosureId } from "../src/engine/id.js";
import {
  CALLABLE_DISCRIMINATOR,
  CTOR_DISCRIMINATOR,
  RawValueDecodeError,
  valueFromRaw,
  valueToRaw,
} from "../src/value-codec.js";

function rt(v: Value): Value {
  return valueFromRaw(valueToRaw(v));
}

describe("value-codec", () => {
  it("round-trips primitive values", () => {
    expect(rt({ kind: "number", value: 0 })).toEqual({ kind: "number", value: 0 });
    expect(rt({ kind: "number", value: -3.5 })).toEqual({ kind: "number", value: -3.5 });
    expect(rt({ kind: "string", value: "" })).toEqual({ kind: "string", value: "" });
    expect(rt({ kind: "string", value: "hi" })).toEqual({ kind: "string", value: "hi" });
    expect(rt({ kind: "boolean", value: true })).toEqual({ kind: "boolean", value: true });
    expect(rt({ kind: "null" })).toEqual({ kind: "null" });
  });

  it("encodes tagged values with $ctor + fields", () => {
    const v: Value = {
      kind: "tagged",
      ctorId: "main.point",
      fields: {
        x: { kind: "number", value: 3 },
        y: { kind: "number", value: 4 },
      },
    };
    expect(valueToRaw(v)).toEqual({ [CTOR_DISCRIMINATOR]: "main.point", x: 3, y: 4 });
    expect(rt(v)).toEqual(v);
  });

  it("encodes nested tagged values recursively", () => {
    const v: Value = {
      kind: "tagged",
      ctorId: "main.line",
      fields: {
        from: {
          kind: "tagged",
          ctorId: "main.point",
          fields: {
            x: { kind: "number", value: 0 },
            y: { kind: "number", value: 0 },
          },
        },
        to: {
          kind: "tagged",
          ctorId: "main.point",
          fields: {
            x: { kind: "number", value: 5 },
            y: { kind: "number", value: 7 },
          },
        },
      },
    };
    expect(rt(v)).toEqual(v);
  });

  it("encodes agentLiteral as $callable string", () => {
    const v: Value = { kind: "agentLiteral", qualifiedName: "main.foo" };
    expect(valueToRaw(v)).toEqual({ [CALLABLE_DISCRIMINATOR]: "main.foo" });
    expect(rt(v)).toEqual(v);
  });

  it("encodes closure as $callable closure:N", () => {
    const v: Value = { kind: "closure", closureId: 7 as ClosureId };
    expect(valueToRaw(v)).toEqual({ [CALLABLE_DISCRIMINATOR]: "closure:7" });
    expect(rt(v)).toEqual(v);
  });

  it("encodes arrays element-wise", () => {
    const v: Value = {
      kind: "array",
      elements: [
        { kind: "number", value: 1 },
        { kind: "number", value: 2 },
        { kind: "number", value: 3 },
      ],
    };
    expect(valueToRaw(v)).toEqual([1, 2, 3]);
    expect(rt(v)).toEqual(v);
  });

  it("tuple round-trips as array (schema-less ambiguity)", () => {
    const v: Value = {
      kind: "tuple",
      elements: [
        { kind: "number", value: 1 },
        { kind: "string", value: "a" },
      ],
    };
    // Encoding is array-shaped; decoding without schema produces `array`.
    expect(valueToRaw(v)).toEqual([1, "a"]);
    expect(rt(v)).toEqual({
      kind: "array",
      elements: [
        { kind: "number", value: 1 },
        { kind: "string", value: "a" },
      ],
    });
  });

  it("decodes a discriminator-less object as anonymous record", () => {
    const decoded = valueFromRaw({ x: 1, y: 2 });
    expect(decoded).toEqual({
      kind: "tagged",
      ctorId: "<anonymous>.record",
      fields: {
        x: { kind: "number", value: 1 },
        y: { kind: "number", value: 2 },
      },
    });
  });

  it("rejects malformed $callable", () => {
    expect(() => valueFromRaw({ [CALLABLE_DISCRIMINATOR]: 5 })).toThrow(
      RawValueDecodeError,
    );
    expect(() => valueFromRaw({ [CALLABLE_DISCRIMINATOR]: "closure:abc" })).toThrow(
      RawValueDecodeError,
    );
  });

  it("rejects malformed $ctor", () => {
    expect(() => valueFromRaw({ [CTOR_DISCRIMINATOR]: 42 })).toThrow(
      RawValueDecodeError,
    );
  });

  it("rejects undefined as a top-level raw", () => {
    expect(() => valueFromRaw(undefined)).toThrow(RawValueDecodeError);
  });
});
