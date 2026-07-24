// The value <-> bare-JSON wire codec (`valueToJson` / `jsonToValue`): a total, schema-blind bijection.
// Every value shape round-trips (`jsonToValue(valueToJson(v, "reveal")) === v` structurally), the reserved
// `$katari_` discriminator namespace is disjoint from record keys (which travel verbatim), `__proto__` is
// inert, and non-finite numbers and a redacted subtree are handled at the boundary.

import { createAgentName, type DefaultValue } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import type { BlobId, ScopeId, SnapshotId } from "../src/runtime/ids.js";
import {
  defaultValueToValue,
  jsonToValue,
  valueEquals,
  valueToJson,
} from "../src/runtime/value/codec.js";
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

  test("a data value nests its fields under `$katari_value` and round-trips", () => {
    const box: Value = {
      kind: "record",
      ctor: createAgentName("main.box"),
      fields: { n: { kind: "integer", value: 7 } },
    };
    // The wire form is the disjoint nested shape.
    expect(valueToJson(box, "reveal")).toEqual({
      $katari_constructor: "main.box",
      $katari_value: { n: 7 },
    });
    expect(roundTrip(box)).toEqual(box);
  });

  test("a record key beginning with `$` travels verbatim, never read as a discriminator", () => {
    const record: Value = {
      kind: "record",
      fields: {
        $constructor: { kind: "string", value: "not a tag" },
        $ref: { kind: "integer", value: 1 },
        plain: { kind: "boolean", value: true },
      },
    };
    const wire = valueToJson(record, "reveal");
    // A program never authors a `$katari_`-prefixed key, so these `$` keys collide with nothing: they go on
    // the wire verbatim and read back as an ordinary bare record.
    expect(wire).toEqual({ $constructor: "not a tag", $ref: 1, plain: true });
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
    expect(valueToJson(agent, "reveal")).toEqual({
      $katari_agent: "main.tool",
      $katari_snapshot: SNAPSHOT,
    });
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

  test("a file handle round-trips as identity only ({ $katari_ref, $katari_semantic_kind })", () => {
    const file: Value = {
      kind: "ref",
      semanticKind: "file",
      blobId: "blob-7" as BlobId,
    };
    // The wire form is deliberately slim: metadata lives on the blob row, never on the handle.
    expect(valueToJson(file, "reveal")).toEqual({
      $katari_ref: "blob-7",
      $katari_semantic_kind: "file",
    });
    expect(roundTrip(file)).toEqual(file);
  });

  test("a bare { $katari_ref } handle (what an AI replays) lifts to a file ref", () => {
    expect(jsonToValue({ $katari_ref: "blob-8" })).toEqual({
      kind: "ref",
      semanticKind: "file",
      blobId: "blob-8",
    });
    // Stale metadata a wire happens to carry is ignored, not trusted.
    expect(jsonToValue({ $katari_ref: "blob-8", size: 999, hash: "forged" })).toEqual({
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
    expect(valueToJson(value, "redact")).toEqual({
      public: "ok",
      secret: { $katari_redacted: true },
    });
    expect(JSON.stringify(valueToJson(value, "redact"))).not.toContain("hunter2");
    expect(valueToJson(value, "reveal")).toEqual({ public: "ok", secret: "hunter2" });
  });

  test("a redacted document cannot be decoded back", () => {
    expect(() => jsonToValue({ $katari_redacted: true })).toThrow();
  });
});

describe("the doc-let naming stamp (`naming`)", () => {
  const NAMING = { name: "herald_view", description: "the herald's window on the operator" };

  test("an agent reference round-trips its stamp as `$katari_naming`", () => {
    const stamped: Value = {
      kind: "agent",
      name: createAgentName("main.read_digest"),
      snapshot: SNAPSHOT,
      naming: NAMING,
    };
    expect(valueToJson(stamped, "reveal")).toEqual({
      $katari_agent: "main.read_digest",
      $katari_snapshot: SNAPSHOT,
      $katari_naming: NAMING,
    });
    expect(roundTrip(stamped)).toEqual(stamped);
  });

  test("a closure and a tool round-trip their stamps too", () => {
    const closure: Value = {
      kind: "closure",
      blockId: 3,
      scopeId: 9 as ScopeId,
      snapshot: SNAPSHOT,
      module: "main",
      naming: NAMING,
    };
    expect(roundTrip(closure)).toEqual(closure);
    const tool: Value = {
      kind: "tool",
      reactor: "mcp",
      name: "weather",
      description: "minted description",
      context: { kind: "record", fields: {} },
      snapshot: SNAPSHOT,
      inputSchema: {},
      naming: NAMING,
    };
    expect(roundTrip(tool)).toEqual(tool);
  });

  test("a malformed wire stamp is dropped, never structural", () => {
    // The stamp is annotation: a wire an AI mangled decodes to the plain reference, not an error.
    expect(jsonToValue({ $katari_agent: "main.a", $katari_snapshot: SNAPSHOT, $katari_naming: 7 })).toEqual({
      kind: "agent",
      name: createAgentName("main.a"),
      snapshot: SNAPSHOT,
    });
  });

  test("valueEquals ignores the stamp on every structurally-compared kind", () => {
    expect(
      valueEquals({ kind: "string", value: "x", naming: NAMING }, { kind: "string", value: "x" }),
    ).toBe(true);
    const record: Value = { kind: "record", fields: { a: { kind: "integer", value: 1 } } };
    expect(valueEquals({ ...record, naming: NAMING }, record)).toBe(true);
    const array: Value = { kind: "array", elements: [{ kind: "integer", value: 2 }] };
    expect(valueEquals({ ...array, naming: NAMING }, array)).toBe(true);
    const file: Value = { kind: "ref", semanticKind: "file", blobId: "blob-7" as BlobId };
    expect(valueEquals({ ...file, naming: NAMING }, file)).toBe(true);
  });
});

// An agent block's parameter default is a constant literal tree (`AgentBlock.defaults`): scalars share
// the IR `Literal` kinds, containers nest. `applyDefaults` lifts each omitted parameter's tree through
// this conversion, so the shapes here are exactly what a filled argument record receives.
describe("defaultValueToValue — the parameter-default tree lifts structurally", () => {
  test("a scalar default lifts exactly like an IR literal", () => {
    expect(defaultValueToValue({ kind: "string", value: "x" })).toEqual({
      kind: "string",
      value: "x",
    });
    expect(defaultValueToValue({ kind: "null" })).toEqual({ kind: "null" });
  });

  test("an empty array default lifts to an empty array value", () => {
    expect(defaultValueToValue({ kind: "array", elements: [] })).toEqual({
      kind: "array",
      elements: [],
    });
  });

  test("a nested record/array tree lifts structurally", () => {
    const tree: DefaultValue = {
      kind: "record",
      fields: {
        point: {
          kind: "record",
          fields: { x: { kind: "integer", value: 1 } },
        },
        tags: { kind: "array", elements: [{ kind: "string", value: "a" }] },
      },
    };
    expect(defaultValueToValue(tree)).toEqual({
      kind: "record",
      fields: {
        point: { kind: "record", fields: { x: { kind: "integer", value: 1 } } },
        tags: { kind: "array", elements: [{ kind: "string", value: "a" }] },
      },
    });
  });
});

// A record key is disjoint from the reserved wire namespace: a program never authors a `$katari_`-prefixed
// key, so any key it does write — including a `$`-prefixed one like an external `$ref` / `$defs` / `$schema`
// keyword — travels verbatim and round-trips as itself, never forging a discriminator.
describe("record keys travel verbatim (disjoint from the reserved namespace)", () => {
  test("a value-plane `$`-key round-trips through valueToJson/jsonToValue as itself", () => {
    const record: Value = {
      kind: "record",
      fields: {
        $ref: { kind: "string", value: "literal" },
        $defs: { kind: "integer", value: 1 },
      },
    };
    const wire = valueToJson(record, "reveal");
    expect(wire).toEqual({ $ref: "literal", $defs: 1 });
    expect(jsonToValue(wire)).toEqual(record);
  });
});
