// Round-trip + structural tests for the raw ↔ Value codec.

import { describe, expect, it } from "vitest";
import { mkSecret, mkString, type Value } from "../src/engine/value.js";
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
    expect(rt(mkString(""))).toEqual(mkString(""));
    expect(rt(mkString("hi"))).toEqual(mkString("hi"));
    expect(rt({ kind: "boolean", value: true })).toEqual({ kind: "boolean", value: true });
    expect(rt({ kind: "null" })).toEqual({ kind: "null" });
  });

  it("round-trips a closure as a `$agent` callable handle (machine-local id)", () => {
    // A closure is a callable, so it serialises under `$agent` (uniform with a
    // top-level agent) — NOT as a `$ref` envelope. The dispatch handle is the
    // closure's machine-local id (`closure:<closureId>`), preserved on round-trip.
    const closure: Value = { kind: "closure", closureId: "abc" as never };
    const raw = valueToRaw(closure) as Record<string, unknown>;
    expect(raw[CALLABLE_DISCRIMINATOR]).toBe("closure:abc"); // the id, not JSON
    expect(raw.$ref).toBeUndefined(); // not a $ref
    expect(rt(closure)).toEqual({ kind: "closure", closureId: "abc" });
  });

  it("encodes data values with $constructor + fields", () => {
    const v: Value = {
      kind: "record",
      ctor: "main.point",
      entries: {
        x: { kind: "number", value: 3 },
        y: { kind: "number", value: 4 },
      },
    };
    expect(valueToRaw(v)).toEqual({ [CTOR_DISCRIMINATOR]: "main.point", x: 3, y: 4 });
    expect(rt(v)).toEqual(v);
  });

  it("encodes nested data values recursively", () => {
    const v: Value = {
      kind: "record",
      ctor: "main.line",
      entries: {
        from: {
          kind: "record",
          ctor: "main.point",
          entries: {
            x: { kind: "number", value: 0 },
            y: { kind: "number", value: 0 },
          },
        },
        to: {
          kind: "record",
          ctor: "main.point",
          entries: {
            x: { kind: "number", value: 5 },
            y: { kind: "number", value: 7 },
          },
        },
      },
    };
    expect(rt(v)).toEqual(v);
  });

  it("encodes agentLiteral as $agent string", () => {
    const v: Value = { kind: "agentLiteral", qualifiedName: "main.foo" };
    expect(valueToRaw(v)).toEqual({ [CALLABLE_DISCRIMINATOR]: "main.foo" });
    expect(rt(v)).toEqual(v);
  });

  it("decodes a $agent: closure:<id> as a machine-local closure value", () => {
    // The closure wire form is `$agent: closure:<closureId>` — a machine-local
    // id into the CORE-global store (the content-ref form was retired).
    expect(valueFromRaw({ [CALLABLE_DISCRIMINATOR]: "closure:c7" })).toEqual({
      kind: "closure",
      closureId: "c7",
    });
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
      elements: [{ kind: "number", value: 1 }, mkString("a")],
    };
    expect(valueToRaw(v)).toEqual([1, "a"]);
    expect(rt(v)).toEqual(v);
  });

  it("decodes a discriminator-less object as a record (Plan D fallback)", () => {
    // Plan D: discriminator-less objects map to the homogeneous `record`
    // value variant. Tagged ctor / callable / secret are routed by their
    // respective discriminators; bare objects fall through here.
    expect(valueFromRaw({ x: 1, y: 2 })).toEqual({
      kind: "record",
      entries: {
        x: { kind: "number", value: 1 },
        y: { kind: "number", value: 2 },
      },
    });
  });

  it("rejects malformed $agent", () => {
    expect(() => valueFromRaw({ [CALLABLE_DISCRIMINATOR]: 5 })).toThrow(
      RawValueDecodeError,
    );
    // An empty closure id is malformed.
    expect(() => valueFromRaw({ [CALLABLE_DISCRIMINATOR]: "closure:" })).toThrow(
      RawValueDecodeError,
    );
  });

  it("rejects malformed $constructor", () => {
    expect(() => valueFromRaw({ [CTOR_DISCRIMINATOR]: 42 })).toThrow(
      RawValueDecodeError,
    );
  });

  it("rejects undefined as a top-level raw", () => {
    expect(() => valueFromRaw(undefined)).toThrow(RawValueDecodeError);
  });

  it("encodes a secret as { $secret: <plaintext> } on outbound wire", () => {
    const v: Value = mkSecret("sk-live-abc");
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

  it("a secret nested inside a data value still triggers the inbound refusal", () => {
    expect(() =>
      valueFromRaw({
        [CTOR_DISCRIMINATOR]: "main.payload",
        token: { [SECRET_DISCRIMINATOR]: "x" },
      }),
    ).toThrow(RawValueDecodeError);
  });
});
