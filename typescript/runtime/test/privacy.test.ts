// The privacy taint helpers and the `valueToJson` redact / reveal policies — the value-level half of the
// secret information flow (the engine propagation is exercised end-to-end in `secret-flow.test.ts`).

import { describe, expect, test } from "vitest";
import { valueToJson } from "../src/runtime/value/codec.js";
import { isTainted, liftPrivacy, markPrivate } from "../src/runtime/value/privacy.js";
import type { Value } from "../src/runtime/value/types.js";

const secretString: Value = { kind: "string", value: "sk-123", private: true };
const publicString: Value = { kind: "string", value: "hello" };

describe("markPrivate", () => {
  test("sets the marker and is idempotent, preserving the rest of the node", () => {
    const marked = markPrivate(publicString);
    expect(marked).toEqual({ kind: "string", value: "hello", private: true });
    // Idempotent: a value already private is returned unchanged (same reference).
    expect(markPrivate(secretString)).toBe(secretString);
  });
});

describe("liftPrivacy", () => {
  test("marks the child only when the container is private", () => {
    expect(liftPrivacy(true, publicString)).toEqual({ ...publicString, private: true });
    expect(liftPrivacy(false, publicString)).toBe(publicString);
    expect(liftPrivacy(undefined, publicString)).toBe(publicString);
  });
});

describe("isTainted", () => {
  test("folds the marker over a composite", () => {
    expect(isTainted(publicString)).toBe(false);
    expect(isTainted(secretString)).toBe(true);
    // A public record with one private field is tainted.
    expect(
      isTainted({ kind: "record", fields: { a: publicString, b: secretString } }),
    ).toBe(true);
    // A public array with one private element is tainted.
    expect(isTainted({ kind: "array", elements: [publicString, secretString] })).toBe(true);
    // Deeply nested.
    expect(
      isTainted({
        kind: "record",
        fields: { outer: { kind: "array", elements: [{ kind: "record", fields: { x: secretString } }] } },
      }),
    ).toBe(true);
    // Wholly public.
    expect(
      isTainted({ kind: "record", fields: { a: publicString, b: { kind: "integer", value: 1 } } }),
    ).toBe(false);
  });
});

describe("valueToJson redact policy", () => {
  test("redact is the default (fail-closed); reveal is the explicit opt-in for the real value", () => {
    // A caller that forgets to choose a policy must not leak a secret.
    expect(valueToJson(secretString)).toEqual({ $redacted: true });
    expect(valueToJson(secretString, "redact")).toEqual({ $redacted: true });
    expect(valueToJson(secretString, "reveal")).toBe("sk-123");
    // A public value is identical under either policy.
    expect(valueToJson(publicString)).toBe("hello");
  });

  test("redact is structural: a private field collapses, public siblings survive", () => {
    const record: Value = {
      kind: "record",
      fields: { name: publicString, apiKey: secretString },
    };
    expect(valueToJson(record, "redact")).toEqual({
      name: "hello",
      apiKey: { $redacted: true },
    });
  });

  test("redact reaches into arrays and nested records", () => {
    const value: Value = {
      kind: "array",
      elements: [publicString, { kind: "record", fields: { token: secretString } }],
    };
    expect(valueToJson(value, "redact")).toEqual(["hello", { token: { $redacted: true } }]);
  });
});
