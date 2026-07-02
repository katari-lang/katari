// The stdlib sub-module primitives beyond arithmetic: `primitive.json.*` (the JSON boundary),
// `primitive.record.*` / `primitive.array.*` / `primitive.string.*` (collection and text access —
// what a program needs to traverse a parsed AI reply), and `primitive.get_metadata` (a callable
// value's name / description / schemas, as `json` values ready for an AI tool list). Preloaded into
// every `PrimRegistry` next to the arithmetic built-ins.
//
// `primitive.call_agent` deliberately has NO runnable implementation: a delegate to it is unwrapped
// at the core reactor's acceptance surface (`CoreReactor.onDelegate`) into a delegation to the
// callable its argument carries, so its body block is never summoned. The throwing stub below only
// guards the invariant.
//
// String inputs may be blob-backed (a >4KB string promotes to a `ref`); every reader here
// materialises through the context's blob store. Privacy is the prim layer's monotonic rule: any
// private part of the argument marks the whole result private, so these walks keep content.

import {
  createAgentName,
  type GenericId,
  type JSONSchema,
  type Json,
  type RequestSchema,
  type SchemaInfo,
} from "@katari-lang/types";
import type { IrSource } from "../ir.js";
import type { GenericSubstitution, Value } from "../value/types.js";
import { fillGenericSchema, typeSubstitutionOf } from "../value/validation.js";
import type { PrimContext, PrimImplementation } from "./context.js";
import {
  decodeValue,
  encodeValue,
  jsonValueFromJson,
  jsonValueToJson,
  type StringReader,
} from "./json-value.js";
import { arrayOf, field, integerOf, recordOf, stringOf } from "./prim-helpers.js";

const NULL_VALUE: Value = { kind: "null" };

/** A `StringReader` over the context's blob store (inline strings read directly). */
function stringReaderOf(context: PrimContext): StringReader {
  return async (value: Value): Promise<string> => {
    if (value.kind === "string") return value.value;
    if (value.kind === "ref" && value.semanticKind === "string") {
      const bytes = await context.blobs.get(context.projectId, value.blobId);
      return new TextDecoder().decode(bytes);
    }
    throw new Error(`expected a string, got ${value.kind}`);
  };
}

/** Read a possibly blob-backed string argument field. */
function readStringField(argument: Value, name: string, context: PrimContext): Promise<string> {
  return stringReaderOf(context)(field(argument, name));
}

export const INTEROP_PRIMITIVES: Record<string, PrimImplementation> = {
  // ─── primitive.json ─────────────────────────────────────────────────────────────────────────
  "primitive.json.parse": async (argument, context) => {
    const text = await readStringField(argument, "text", context);
    let json: Json;
    try {
      json = JSON.parse(text) as Json;
    } catch (error) {
      throw new Error(
        `json.parse: malformed JSON — ${error instanceof Error ? error.message : String(error)}`,
      );
    }
    return jsonValueFromJson(json);
  },
  "primitive.json.stringify": async (argument, context) => {
    const json = await jsonValueToJson(field(argument, "value"), stringReaderOf(context));
    return { kind: "string", value: JSON.stringify(json) };
  },
  "primitive.json.encode": (argument, context) =>
    encodeValue(field(argument, "value"), stringReaderOf(context)),
  "primitive.json.decode": (argument, context) =>
    decodeValue(field(argument, "value"), stringReaderOf(context)),

  // ─── primitive.record ───────────────────────────────────────────────────────────────────────
  "primitive.record.get": (argument) =>
    recordOf(field(argument, "target"))[stringOf(field(argument, "key"))] ?? NULL_VALUE,
  "primitive.record.set": (argument) => {
    const fields = { ...recordOf(field(argument, "target")) };
    fields[stringOf(field(argument, "key"))] = field(argument, "value");
    return { kind: "record", fields };
  },
  "primitive.record.remove": (argument) => {
    const fields = { ...recordOf(field(argument, "target")) };
    delete fields[stringOf(field(argument, "key"))];
    return { kind: "record", fields };
  },
  "primitive.record.keys": (argument) => ({
    kind: "array",
    elements: sortedKeys(recordOf(field(argument, "target"))).map((key) => ({
      kind: "string",
      value: key,
    })),
  }),
  "primitive.record.has": (argument) => ({
    kind: "boolean",
    value: recordOf(field(argument, "target"))[stringOf(field(argument, "key"))] !== undefined,
  }),
  "primitive.record.size": (argument) => ({
    kind: "integer",
    value: Object.keys(recordOf(field(argument, "target"))).length,
  }),
  "primitive.record.entries": (argument) => {
    const fields = recordOf(field(argument, "target"));
    return {
      kind: "array",
      elements: sortedKeys(fields).map((key) => ({
        kind: "array",
        elements: [{ kind: "string", value: key }, fields[key] ?? NULL_VALUE],
      })),
    };
  },
  "primitive.record.empty": () => ({ kind: "record", fields: {} }),

  // ─── primitive.array ────────────────────────────────────────────────────────────────────────
  "primitive.array.get": (argument) =>
    arrayOf(field(argument, "target"))[integerOf(field(argument, "index"))] ?? NULL_VALUE,
  "primitive.array.length": (argument) => ({
    kind: "integer",
    value: arrayOf(field(argument, "target")).length,
  }),
  "primitive.array.append": (argument) => ({
    kind: "array",
    elements: [...arrayOf(field(argument, "target")), field(argument, "value")],
  }),
  "primitive.array.concat": (argument) => ({
    kind: "array",
    elements: [...arrayOf(field(argument, "left")), ...arrayOf(field(argument, "right"))],
  }),
  "primitive.array.slice": (argument) => ({
    kind: "array",
    elements: arrayOf(field(argument, "target")).slice(
      Math.max(0, integerOf(field(argument, "start"))),
      Math.max(0, integerOf(field(argument, "end"))),
    ),
  }),
  "primitive.array.empty": () => ({ kind: "array", elements: [] }),

  // ─── primitive.string (indices are Unicode code points, per the declared contract) ───────────
  "primitive.string.length": async (argument, context) => ({
    kind: "integer",
    value: Array.from(await readStringField(argument, "value", context)).length,
  }),
  "primitive.string.split": async (argument, context) => {
    const value = await readStringField(argument, "value", context);
    const separator = await readStringField(argument, "separator", context);
    // An empty separator splits into code points (JS `split("")` would cut surrogate pairs apart).
    const parts = separator === "" ? Array.from(value) : value.split(separator);
    return {
      kind: "array",
      elements: parts.map((part) => ({ kind: "string", value: part })),
    };
  },
  "primitive.string.join": async (argument, context) => {
    const read = stringReaderOf(context);
    const parts: string[] = [];
    for (const part of arrayOf(field(argument, "parts"))) {
      parts.push(await read(part));
    }
    const separator = await readStringField(argument, "separator", context);
    return { kind: "string", value: parts.join(separator) };
  },
  "primitive.string.slice": async (argument, context) => {
    const points = Array.from(await readStringField(argument, "value", context));
    const start = Math.max(0, integerOf(field(argument, "start")));
    const end = Math.max(0, integerOf(field(argument, "end")));
    return { kind: "string", value: points.slice(start, end).join("") };
  },
  "primitive.string.contains": async (argument, context) => ({
    kind: "boolean",
    value: (await readStringField(argument, "value", context)).includes(
      await readStringField(argument, "search", context),
    ),
  }),

  // ─── AI interop ─────────────────────────────────────────────────────────────────────────────
  "primitive.ai.get_metadata": async (argument, context) => {
    const value = field(argument, "value");
    const callable = await locateCallable(value, context.ir);
    const typeSubstitution = typeSubstitutionOf(callable.schema.genericBindings, callable.generics);
    const requestSubstitution = requestSubstitutionOf(
      callable.schema.genericBindings,
      callable.generics,
    );
    const input = fillGenericSchema(typeSubstitution, callable.schema.input);
    const output = fillGenericSchema(typeSubstitution, callable.schema.output);
    return {
      kind: "record",
      ctor: createAgentName("primitive.ai.agent_metadata"),
      fields: {
        name: { kind: "string", value: callable.name },
        description: { kind: "string", value: callable.description },
        input: jsonValueFromJson(schemaToJson(input)),
        output: jsonValueFromJson(schemaToJson(output)),
        requests: jsonValueFromJson(
          requestsToJson(callable.schema.requests, typeSubstitution, requestSubstitution),
        ),
      },
    };
  },
  "primitive.ai.call_agent": () => {
    // Unreachable by construction: `CoreReactor.onDelegate` unwraps a `call_agent` delegate before
    // any instance is summoned, so this body block never runs.
    throw new Error("call_agent must be dispatched at the delegation boundary (engine bug)");
  },
};

function sortedKeys(fields: Record<string, Value>): string[] {
  return Object.keys(fields).sort();
}

/** Resolve a callable value to its agent block's schema / description (following the value's own
 *  snapshot and module — a `get_metadata` instance need not share them). A closure has no qualified
 *  name, so its `name` is empty. */
async function locateCallable(
  value: Value,
  ir: IrSource,
): Promise<{
  schema: SchemaInfo;
  description: string;
  name: string;
  generics: GenericSubstitution | undefined;
}> {
  if (value.kind === "agent") {
    await ir.preload(value.snapshot);
    const located = ir.locate(value.snapshot, value.name);
    const information = ir.access(value.snapshot, located.module).block(located.blockId);
    if (information.block.kind !== "agent") {
      throw new Error(`get_metadata: "${value.name}" is not a callable`);
    }
    return {
      schema: information.block.schema,
      description: information.block.description ?? "",
      name: String(value.name),
      generics: value.generics,
    };
  }
  if (value.kind === "closure") {
    await ir.preload(value.snapshot);
    const information = ir.access(value.snapshot, value.module).block(value.blockId);
    if (information.block.kind !== "agent") {
      throw new Error("get_metadata: the closure does not resolve to a callable block");
    }
    return {
      schema: information.block.schema,
      description: information.block.description ?? "",
      name: "",
      generics: value.generics,
    };
  }
  throw new Error(`get_metadata: expected a callable value, got ${value.kind}`);
}

/** The effect-generic substitution a callable's carried generics imply (the `requests` counterpart
 *  of `typeSubstitutionOf`). */
function requestSubstitutionOf(
  bindings: SchemaInfo["genericBindings"],
  generics: GenericSubstitution | undefined,
): Map<GenericId, RequestSchema[]> {
  const substitution = new Map<GenericId, RequestSchema[]>();
  if (generics === undefined) return substitution;
  for (const [name, genericId] of Object.entries(bindings)) {
    const argument = generics[name];
    if (argument !== undefined && argument.kind === "requests") {
      substitution.set(genericId, argument.requests);
    }
  }
  return substitution;
}

/** The `requests` metadata: one `{name, input, output}` object per concrete request; an effect
 *  generic expands through the substitution when instantiated, and otherwise surfaces as its
 *  `{"$generic": id}` placeholder. `seen` breaks a (malformed) self-referencing substitution. */
function requestsToJson(
  requests: RequestSchema[],
  typeSubstitution: ReadonlyMap<GenericId, JSONSchema>,
  requestSubstitution: ReadonlyMap<GenericId, RequestSchema[]>,
): Json {
  const out: Json[] = [];
  const expand = (entries: RequestSchema[], seen: Set<GenericId>): void => {
    for (const entry of entries) {
      if (entry.kind === "concrete") {
        out.push({
          name: String(entry.descriptor.name),
          input: schemaToJson(fillGenericSchema(typeSubstitution, entry.descriptor.input)),
          output: schemaToJson(fillGenericSchema(typeSubstitution, entry.descriptor.output)),
        });
        continue;
      }
      const bound = requestSubstitution.get(entry.generic);
      if (bound !== undefined && !seen.has(entry.generic)) {
        expand(bound, new Set(seen).add(entry.generic));
      } else {
        out.push({ $generic: entry.generic });
      }
    }
  };
  expand(requests, new Set());
  return out;
}

/** A `JSONSchema` as its standard JSON Schema document (the IR type is already the wire shape; this
 *  rebuilds it as `Json` field by field, keeping the `any`-free typing). */
function schemaToJson(schema: JSONSchema): Json {
  const out: { [key: string]: Json } = {};
  if (schema.type !== undefined) out.type = schema.type;
  if (schema.const !== undefined) out.const = schema.const;
  if (schema.items !== undefined) out.items = schemaToJson(schema.items);
  if (schema.prefixItems !== undefined) out.prefixItems = schema.prefixItems.map(schemaToJson);
  if (schema.properties !== undefined) {
    const properties: { [key: string]: Json } = {};
    for (const [key, property] of Object.entries(schema.properties)) {
      properties[key] = schemaToJson(property);
    }
    out.properties = properties;
  }
  if (schema.required !== undefined) out.required = [...schema.required];
  if (schema.additionalProperties !== undefined) {
    out.additionalProperties =
      typeof schema.additionalProperties === "boolean"
        ? schema.additionalProperties
        : schemaToJson(schema.additionalProperties);
  }
  if (schema.anyOf !== undefined) out.anyOf = schema.anyOf.map(schemaToJson);
  if (schema.not !== undefined) out.not = schemaToJson(schema.not);
  if (schema.$generic !== undefined) out.$generic = schema.$generic;
  return out;
}
