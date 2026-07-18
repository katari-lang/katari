// The value <-> bare-JSON wire codec (`valueToJson` / `jsonToValue`): a total, schema-blind bijection.
// Every value shape round-trips (`jsonToValue(valueToJson(v, "reveal")) === v` structurally), the
// discriminator namespace is disjoint from record keys (escaping), `__proto__` is inert, and non-finite
// numbers and a redacted subtree are handled at the boundary.

import { createAgentName, escapeRecordKey, unescapeRecordKey } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import type { BlobId, ScopeId, SnapshotId } from "../src/runtime/ids.js";
import { jsonToValue, valueToJson } from "../src/runtime/value/codec.js";
import type { Value } from "../src/runtime/value/types.js";

const SNAPSHOT = "snap-codec" as SnapshotId;

/** Round-trip a value through the reveal-policy wire form and back. */
function roundTrip(value: Value): Value {
  return jsonToValue(valueToJson(value, "reveal"));
}

describe("valueToJson / jsonToValue — total bijection", () => {
  test("scalars, arrays, and nested bare records", () => {
    const values: Value[] = [
      { kind: "null" },
      { kind: "boolean", value: true },
      { kind: "integer", value: 42 },
      { kind: "number", value: 3.5 },
      { kind: "string", value: "hi" },
      { kind: "array", elements: [{ kind: "integer", value: 1 }, { kind: "string", value: "x" }] },
      {
        kind: "record",
        fields: {
          a: { kind: "integer", value: 1 },
          nested: { kind: "record", fields: { b: { kind: "boolean", value: false } } },
        },
      },
    ];
    for (const value of values) expect(roundTrip(value)).toEqual(value);
  });

  test("a data value nests its fields under `value` and round-trips", () => {
    const box: Value = {
      kind: "record",
      ctor: createAgentName("main.box"),
      fields: { n: { kind: "integer", value: 7 } },
    };
    // The wire form is the disjoint nested shape.
    expect(valueToJson(box, "reveal")).toEqual({ $constructor: "main.box", value: { n: 7 } });
    expect(roundTrip(box)).toEqual(box);
  });

  test("a record key beginning with `$` is escaped, so it is never read as a discriminator", () => {
    const record: Value = {
      kind: "record",
      fields: {
        $constructor: { kind: "string", value: "not a tag" },
        $ref: { kind: "integer", value: 1 },
        plain: { kind: "boolean", value: true },
      },
    };
    const wire = valueToJson(record, "reveal");
    // On the wire the keys are doubled, so this is unambiguously a bare record, not a data / file value.
    expect(wire).toEqual({ $$constructor: "not a tag", $$ref: 1, plain: true });
    expect(roundTrip(record)).toEqual(record);
  });

  test("a `__proto__` key from untrusted JSON is an own field, never a prototype write", () => {
    // The real vector: a hostile document parsed at the boundary. `JSON.parse` gives `__proto__` as an
    // own key; the codec must keep it an own field of a prototype-less map, not reassign the prototype.
    const decoded = jsonToValue(JSON.parse('{"__proto__": {"polluted": true}, "y": 2}'));
    expect(decoded.kind).toBe("record");
    if (decoded.kind === "record") {
      expect(Object.getPrototypeOf(decoded.fields)).toBe(null);
      expect(Object.hasOwn(decoded.fields, "__proto__")).toBe(true);
      expect(Object.hasOwn(decoded.fields, "y")).toBe(true);
    }
    // No global prototype pollution occurred.
    const probe: Record<string, unknown> = {};
    expect(probe.polluted).toBeUndefined();
  });

  test("an agent reference round-trips its name AND snapshot", () => {
    const agent: Value = { kind: "agent", name: createAgentName("main.tool"), snapshot: SNAPSHOT };
    expect(valueToJson(agent, "reveal")).toEqual({ $agent: "main.tool", snapshot: SNAPSHOT });
    expect(roundTrip(agent)).toEqual(agent);
  });

  test("a closure round-trips its captured scope ids", () => {
    const closure: Value = {
      kind: "closure",
      blockId: 3,
      scopeId: 9 as ScopeId,
      snapshot: SNAPSHOT,
      module: "main",
    };
    expect(roundTrip(closure)).toEqual(closure);
  });

  test("a file handle round-trips as identity only ({ $ref, semanticKind })", () => {
    const file: Value = {
      kind: "ref",
      semanticKind: "file",
      blobId: "blob-7" as BlobId,
    };
    // The wire form is deliberately slim: metadata lives on the blob row, never on the handle.
    expect(valueToJson(file, "reveal")).toEqual({ $ref: "blob-7", semanticKind: "file" });
    expect(roundTrip(file)).toEqual(file);
  });

  test("a bare { $ref } handle (what an AI replays) lifts to a file ref", () => {
    expect(jsonToValue({ $ref: "blob-8" })).toEqual({
      kind: "ref",
      semanticKind: "file",
      blobId: "blob-8",
    });
    // Stale metadata a wire happens to carry is ignored, not trusted.
    expect(jsonToValue({ $ref: "blob-8", size: 999, hash: "forged" })).toEqual({
      kind: "ref",
      semanticKind: "file",
      blobId: "blob-8",
    });
  });

  test("a non-finite number has no wire form", () => {
    expect(() => valueToJson({ kind: "number", value: Number.POSITIVE_INFINITY }, "reveal")).toThrow();
    expect(() => valueToJson({ kind: "number", value: Number.NaN }, "reveal")).toThrow();
  });
});

describe("privacy policy", () => {
  test("redact collapses a private subtree; reveal emits it", () => {
    const value: Value = {
      kind: "record",
      fields: {
        public: { kind: "string", value: "ok" },
        secret: { kind: "string", value: "hunter2", private: true },
      },
    };
    expect(valueToJson(value, "redact")).toEqual({ public: "ok", secret: { $redacted: true } });
    expect(JSON.stringify(valueToJson(value, "redact"))).not.toContain("hunter2");
    expect(valueToJson(value, "reveal")).toEqual({ public: "ok", secret: "hunter2" });
  });

  test("a redacted document cannot be decoded back", () => {
    expect(() => jsonToValue({ $redacted: true })).toThrow();
  });
});

// The `$`-key escape is what keeps the value plane's `$`-keys from colliding with the wire discriminators.
// `escapeRecordKey` (value -> wire) must be INJECTIVE so a value key round-trips; `unescapeRecordKey`
// (wire -> value) is its left inverse for every value key, but is DELIBERATELY non-injective the other way
// — a single-`$` wire key (an external literal) and a doubled one both land on the same value key, the
// documented asymmetry that lets an outside document keep its literal `$defs` / `$schema` key.
describe("$-key escape injectivity (value <-> wire discriminator namespace)", () => {
  const keys = ["x", "plain", "$", "$x", "$$x", "$$$x", "$ref", "$constructor", "$$ref", ""];

  test("escapeRecordKey doubles a leading `$` and is injective", () => {
    expect(escapeRecordKey("$x")).toBe("$$x");
    expect(escapeRecordKey("$$x")).toBe("$$$x");
    expect(escapeRecordKey("plain")).toBe("plain");
    expect(escapeRecordKey("$")).toBe("$$");
    // Injective: distinct inputs map to distinct outputs.
    const images = keys.map(escapeRecordKey);
    expect(new Set(images).size).toBe(new Set(keys).size);
  });

  test("unescape ∘ escape is the identity for EVERY value key (the value round-trip)", () => {
    for (const key of keys) {
      expect(unescapeRecordKey(escapeRecordKey(key))).toBe(key);
    }
  });

  test("unescape strips ONE `$` from a doubled key and preserves a single-`$` external literal", () => {
    expect(unescapeRecordKey("$$x")).toBe("$x");
    expect(unescapeRecordKey("$$$x")).toBe("$$x");
    // A single-`$` key is an outside literal (`$defs`, `$schema`) — preserved, NOT stripped.
    expect(unescapeRecordKey("$ref")).toBe("$ref");
    expect(unescapeRecordKey("plain")).toBe("plain");
    // The documented non-injectivity: a single- and a doubled- key collapse onto the same value key.
    expect(unescapeRecordKey("$x")).toBe(unescapeRecordKey("$$x"));
  });

  test("a value-plane `$`-key round-trips through valueToJson/jsonToValue as itself", () => {
    const record: Value = {
      kind: "record",
      fields: { $ref: { kind: "string", value: "literal" }, $$deep: { kind: "integer", value: 1 } },
    };
    const wire = valueToJson(record, "reveal");
    // On the wire each `$`-key gains one `$` (so it can never forge a discriminator).
    expect(wire).toEqual({ $$ref: "literal", $$$deep: 1 });
    // And back exactly — a consumer that reads the value never sees the doubled form.
    expect(jsonToValue(wire)).toEqual(record);
  });
});
