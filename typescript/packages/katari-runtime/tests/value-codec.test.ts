// Round-trip + structural tests for the raw ↔ Value codec.

import { describe, expect, it } from "vitest";
import type { Value } from "../src/engine/value.js";
import type { ClosureId } from "../src/engine/id.js";
import {
  CALLABLE_DISCRIMINATOR,
  CTOR_DISCRIMINATOR,
  RawValueDecodeError,
  SECRET_DISCRIMINATOR,
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

  it("heterogeneous array (formerly 'tuple') round-trips", () => {
    // Tuples are stored as 'kind: array' at runtime (heterogeneous
    // arity is enforced by static typing, not by the Value variant).
    // The codec therefore just round-trips an array.
    const v: Value = {
      kind: "array",
      elements: [
        { kind: "number", value: 1 },
        { kind: "string", value: "a" },
      ],
    };
    expect(valueToRaw(v)).toEqual([1, "a"]);
    expect(rt(v)).toEqual(v);
  });

  it("rejects a discriminator-less object", () => {
    // Every object-shaped Value is either a tagged ctor instance or a
    // callable reference; a bare object means the wire violated the
    // schema and we want to surface that at the boundary.
    expect(() => valueFromRaw({ x: 1, y: 2 })).toThrow(RawValueDecodeError);
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

  it("encodes a secret as { $secret: <plaintext> } on outbound wire", () => {
    const v: Value = { kind: "secret", value: "sk-live-abc" };
    expect(valueToRaw(v)).toEqual({ [SECRET_DISCRIMINATOR]: "sk-live-abc" });
  });

  it("refuses to decode '$secret' on inbound (sidecar→runtime is one-way)", () => {
    // Sidecar IPC trust direction is outbound-only for secrets; the
    // runtime would happily round-trip if we allowed it, so the
    // refusal is what guards against a misbehaving / malicious
    // sidecar trying to inject cleartext back.
    expect(() =>
      valueFromRaw({ [SECRET_DISCRIMINATOR]: "leaked" }),
    ).toThrow(RawValueDecodeError);
  });

  it("a secret nested inside a tagged value still triggers the inbound refusal", () => {
    expect(() =>
      valueFromRaw({
        [CTOR_DISCRIMINATOR]: "main.payload",
        token: { [SECRET_DISCRIMINATOR]: "x" },
      }),
    ).toThrow(RawValueDecodeError);
  });
});
