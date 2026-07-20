// The stdlib sub-module primitives beyond arithmetic: `prelude.json.*` (the JSON boundary),
// `prelude.record.*` / `prelude.array.*` / `prelude.string.*` (collection and text access —
// what a program needs to traverse a parsed AI reply), and `prelude.get_metadata` (a callable
// value's name / description / schemas, as document values ready for an AI tool list). Preloaded into
// every `PrimRegistry` next to the arithmetic built-ins.
//
// `prelude.call_agent` deliberately has NO runnable implementation: a delegate to it is unwrapped
// at the core reactor's acceptance surface (`CoreReactor.onDelegate`) into a delegation to the
// callable its argument carries, so its body block is never summoned. The throwing stub below only
// guards the invariant.
//
// String inputs may be blob-backed (a >4KB string promotes to a `ref`); every reader here
// materialises through the context's blob store. Privacy is the prim layer's monotonic rule: any
// private part of the argument marks the whole result private, so these walks keep content.

import { createHash } from "node:crypto";
import {
  type Block,
  createAgentName,
  type GenericId,
  type JSONSchema,
  type Json,
  type RequestSchema,
  type SchemaInfo,
} from "@katari-lang/types";
import { newBlobId } from "../ids.js";
import type { IrSource } from "../ir.js";
import { jsonToValue, valueEquals, valueToJson } from "../value/codec.js";
import { schemaToJson } from "../value/schema-json.js";
import type { BlobRefValue, GenericSubstitution, Value } from "../value/types.js";
import {
  type ConformFailure,
  conformValue,
  fillGenericSchema,
  renderConformFailures,
  typeSubstitutionOf,
} from "../value/validation.js";
import type { PrimContext, PrimImplementation } from "./context.js";
import { blobStoreStringReader, literalLift, type StringReader } from "./json-value.js";
import { arrayOf, field, integerOf, recordOf, stringOf } from "./prim-helpers.js";
import { errorData, KatariThrow } from "./throw-signal.js";
import type { BlobEntry } from "./types.js";

// The domain error ctors the json prims throw (`prelude/json.ktr` declares them). `stringify` is total,
// so it declares none.
const PARSE_ERROR = "prelude.json.parse_error";
const VALIDATION_ERROR = "prelude.json.validation_error";

// The domain error ctors the file prims throw (`prelude/files.ktr` declares them): a reader meeting a handle
// whose blob is gone (freed, or a made-up id), and `from_base64` meeting content that is not base64.
const FILE_GONE = "prelude.files.gone";
const MALFORMED_BASE64 = "prelude.files.malformed_base64";

// The largest array `range` will materialise. `range` allocates the whole array synchronously on the
// actor's serial turn, so an unbounded (possibly AI-supplied) bound would stall the event loop or exhaust
// memory, taking down every concurrent run in the project. The ceiling is far above any real orchestration
// range; crossing it is a logic error, so it panics (fail-safe) rather than trying to run.
const MAX_RANGE_LENGTH = 10_000_000;

const NULL_VALUE: Value = { kind: "null" };

/** A `StringReader` over the context's blob store (the shared implementation in `json-value.ts`). */
function stringReaderOf(context: PrimContext): StringReader {
  return blobStoreStringReader(context.projectId, context.blobs);
}

/** Read a possibly blob-backed string argument field. */
function readStringField(argument: Value, name: string, context: PrimContext): Promise<string> {
  return stringReaderOf(context)(field(argument, name));
}

/** Read a `file` argument field: a blob ref whose semantic kind is `file` (the surface `file` type). */
function fileArgument(argument: Value, name: string): BlobRefValue {
  const value = field(argument, name);
  if (value.kind === "ref" && value.semanticKind === "file") return value;
  throw new Error(`expected a file, got ${value.kind}`);
}

/** The blob row behind a file value. A missing row means the handle is gone — the blob was `free`d / deleted,
 *  or the id was made up (an AI hallucinating a `$katari_ref`). The two are indistinguishable from a slim
 *  handle and a program reacts to both the same way, so this is ONE catchable `files.gone` (not a panic):
 *  naming both causes, it lets an AI loop's guard feed a correctable message back to the model, or a converter
 *  select the failure for replay. */
function blobRowOf(context: PrimContext, file: BlobRefValue): BlobEntry {
  const entry = context.blobEntryOf(file.blobId);
  if (entry === undefined) {
    throw new KatariThrow(
      errorData(
        FILE_GONE,
        `file ${file.blobId} is gone (freed, or an id that never named a blob in this project)`,
      ),
    );
  }
  return entry;
}

/** The turn-scoped blob write capability, or an engine error if it is absent — the two effectful file prims
 *  (`from_base64` / `free`) only ever run inside an instance turn (where the reactor supplies it), so its
 *  absence is a wiring bug, not a program-anticipatable failure. */
function blobEffectsOf(
  context: PrimContext,
  label: string,
): NonNullable<PrimContext["blobEffects"]> {
  if (context.blobEffects === undefined) {
    throw new Error(
      `${label}: blob write capability is unavailable outside an instance turn (engine bug)`,
    );
  }
  return context.blobEffects;
}

/** Decode a strict, canonical base64 string to bytes, or raise the catchable `malformed_base64`. `Buffer.from`
 *  is lax — it silently skips invalid characters and stops at bad padding, so a corrupt payload would decode
 *  to truncated bytes; validating the standard alphabet + padding first makes bad input a typed error rather
 *  than a silently wrong file. */
function decodeBase64OrThrow(content: string): Buffer {
  if (content.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(content)) {
    throw new KatariThrow(
      errorData(MALFORMED_BASE64, "from_base64: the content is not valid base64"),
    );
  }
  return Buffer.from(content, "base64");
}

export const INTEROP_PRIMITIVES: Record<string, PrimImplementation> = {
  // ─── prelude.json ─────────────────────────────────────────────────────────────────────────
  "prelude.json.parse": async (argument, context) => {
    // Parse the text, then read it through the value codec (`jsonToValue`): a `$katari_` marker is
    // interpreted (a `$katari_ref` becomes a real `file`), records / arrays / scalars become ordinary
    // values. External JSON never carries a `$katari_` key, so a document round-trips faithfully.
    const text = await readStringField(argument, "text", context);
    let json: Json;
    try {
      json = JSON.parse(text) as Json;
    } catch (error) {
      throw new KatariThrow(
        errorData(
          PARSE_ERROR,
          `json.parse: malformed JSON — ${error instanceof Error ? error.message : String(error)}`,
        ),
      );
    }
    return jsonToValue(json);
  },
  "prelude.json.stringify": (argument) => {
    // TOTAL and CANONICAL: render ANY value as the text of its wire form (`valueToJson`) — a document
    // records key-for-key (so `stringify(parse(s)) == s`), a data value nests under `$katari_value`, and a
    // file / agent / closure / tool becomes its handle object. `reveal` keeps content; the prim layer's
    // monotonic taint marks the whole result private whenever any input part is.
    return {
      kind: "string",
      value: JSON.stringify(valueToJson(field(argument, "value"), "reveal")),
    };
  },
  "prelude.json.validate": (argument, context) => {
    // The value-plane typed boundary: check `value` against T's schema and return it unchanged, or raise
    // the declared, catchable `validation_error` naming the offending path. Never rewrites the value.
    const schema = instantiatedSchema(context, "json.validate");
    return conformedOrThrow(field(argument, "value"), schema, "json.validate");
  },

  // ─── prelude.record ─────────────────────────────────────────────────────────────────────── //
  // Every access is by *own* key (`Object.hasOwn`) and every rewrite copies into a prototype-less map,
  // so an inherited key (`toString`) never reads as present and a `__proto__` key is an ordinary field —
  // consistent with `record.keys` / `record.size`, which are own-only.
  "prelude.record.get": (argument) => {
    const fields = recordOf(field(argument, "target"));
    const key = stringOf(field(argument, "key"));
    return Object.hasOwn(fields, key) ? (fields[key] ?? NULL_VALUE) : NULL_VALUE;
  },
  "prelude.record.set": (argument) => {
    const fields: Record<string, Value> = Object.assign(
      Object.create(null),
      recordOf(field(argument, "target")),
    );
    fields[stringOf(field(argument, "key"))] = field(argument, "value");
    return { kind: "record", fields };
  },
  "prelude.record.remove": (argument) => {
    const fields: Record<string, Value> = Object.assign(
      Object.create(null),
      recordOf(field(argument, "target")),
    );
    delete fields[stringOf(field(argument, "key"))];
    return { kind: "record", fields };
  },
  "prelude.record.keys": (argument) => ({
    kind: "array",
    elements: sortedKeys(recordOf(field(argument, "target"))).map((key) => ({
      kind: "string",
      value: key,
    })),
  }),
  "prelude.record.has": (argument) => ({
    kind: "boolean",
    value: Object.hasOwn(recordOf(field(argument, "target")), stringOf(field(argument, "key"))),
  }),
  "prelude.record.size": (argument) => ({
    kind: "integer",
    value: Object.keys(recordOf(field(argument, "target"))).length,
  }),
  "prelude.record.entries": (argument) => {
    const fields = recordOf(field(argument, "target"));
    return {
      kind: "array",
      elements: sortedKeys(fields).map((key) => ({
        kind: "array",
        elements: [{ kind: "string", value: key }, fields[key] ?? NULL_VALUE],
      })),
    };
  },
  "prelude.record.merge": (argument) => ({
    kind: "record",
    // Right wins on a shared key (the declared override direction). Null-prototype like `set`, so a
    // merged key named like an Object.prototype member stays an ordinary field.
    fields: Object.assign(
      Object.create(null),
      recordOf(field(argument, "left")),
      recordOf(field(argument, "right")),
    ),
  }),
  "prelude.record.empty": () => ({ kind: "record", fields: {} }),

  // ─── prelude.array ────────────────────────────────────────────────────────────────────────
  "prelude.array.get": (argument) =>
    arrayOf(field(argument, "target"))[integerOf(field(argument, "index"))] ?? NULL_VALUE,
  "prelude.array.length": (argument) => ({
    kind: "integer",
    value: arrayOf(field(argument, "target")).length,
  }),
  "prelude.array.append": (argument) => ({
    kind: "array",
    elements: [...arrayOf(field(argument, "target")), field(argument, "value")],
  }),
  "prelude.array.concat": (argument) => ({
    kind: "array",
    elements: [...arrayOf(field(argument, "left")), ...arrayOf(field(argument, "right"))],
  }),
  "prelude.array.slice": (argument) => ({
    kind: "array",
    elements: arrayOf(field(argument, "target")).slice(
      Math.max(0, integerOf(field(argument, "start"))),
      Math.max(0, integerOf(field(argument, "end"))),
    ),
  }),
  "prelude.array.contains": (argument) => ({
    kind: "boolean",
    value: arrayOf(field(argument, "target")).some((element) =>
      valueEquals(element, field(argument, "value")),
    ),
  }),
  "prelude.array.index_of": (argument) => {
    const index = arrayOf(field(argument, "target")).findIndex((element) =>
      valueEquals(element, field(argument, "value")),
    );
    return index === -1 ? NULL_VALUE : { kind: "integer", value: index };
  },
  "prelude.array.flatten": (argument) => ({
    kind: "array",
    elements: arrayOf(field(argument, "target")).flatMap((element) => arrayOf(element)),
  }),
  "prelude.array.reverse": (argument) => ({
    kind: "array",
    elements: [...arrayOf(field(argument, "target"))].reverse(),
  }),
  "prelude.array.range": (argument) => {
    const start = integerOf(field(argument, "start"));
    const end = integerOf(field(argument, "end"));
    if (end - start > MAX_RANGE_LENGTH) {
      throw new Error(
        `range(${start}, ${end}) would produce ${end - start} elements, exceeding the ${MAX_RANGE_LENGTH} limit`,
      );
    }
    const elements: Value[] = [];
    for (let value = start; value < end; value += 1) elements.push({ kind: "integer", value });
    return { kind: "array", elements };
  },
  "prelude.array.empty": () => ({ kind: "array", elements: [] }),

  // ─── prelude.string (indices are Unicode code points, per the declared contract) ───────────
  "prelude.string.length": async (argument, context) => ({
    kind: "integer",
    value: Array.from(await readStringField(argument, "value", context)).length,
  }),
  "prelude.string.split": async (argument, context) => {
    const value = await readStringField(argument, "value", context);
    const separator = await readStringField(argument, "separator", context);
    // An empty separator splits into code points (JS `split("")` would cut surrogate pairs apart).
    const parts = separator === "" ? Array.from(value) : value.split(separator);
    return {
      kind: "array",
      elements: parts.map((part) => ({ kind: "string", value: part })),
    };
  },
  "prelude.string.join": async (argument, context) => {
    const read = stringReaderOf(context);
    const parts: string[] = [];
    for (const part of arrayOf(field(argument, "parts"))) {
      parts.push(await read(part));
    }
    const separator = await readStringField(argument, "separator", context);
    return { kind: "string", value: parts.join(separator) };
  },
  "prelude.string.slice": async (argument, context) => {
    const points = Array.from(await readStringField(argument, "value", context));
    const start = Math.max(0, integerOf(field(argument, "start")));
    const end = Math.max(0, integerOf(field(argument, "end")));
    return { kind: "string", value: points.slice(start, end).join("") };
  },
  "prelude.string.contains": async (argument, context) => ({
    kind: "boolean",
    value: (await readStringField(argument, "value", context)).includes(
      await readStringField(argument, "search", context),
    ),
  }),
  "prelude.string.starts_with": async (argument, context) => ({
    kind: "boolean",
    value: (await readStringField(argument, "value", context)).startsWith(
      await readStringField(argument, "search", context),
    ),
  }),
  "prelude.string.ends_with": async (argument, context) => ({
    kind: "boolean",
    value: (await readStringField(argument, "value", context)).endsWith(
      await readStringField(argument, "search", context),
    ),
  }),
  "prelude.string.index_of": async (argument, context) => {
    const value = await readStringField(argument, "value", context);
    const unitIndex = value.indexOf(await readStringField(argument, "search", context));
    if (unitIndex === -1) return NULL_VALUE;
    // The declared contract counts code points; convert the UTF-16 unit index of the hit.
    return { kind: "integer", value: Array.from(value.slice(0, unitIndex)).length };
  },
  "prelude.string.replace": async (argument, context) => {
    const value = await readStringField(argument, "value", context);
    const search = await readStringField(argument, "search", context);
    if (search === "") return { kind: "string", value };
    // split/join rather than replaceAll: the replacement is literal text, so a `$&` in it must not
    // be read as a substitution pattern.
    return {
      kind: "string",
      value: value.split(search).join(await readStringField(argument, "replacement", context)),
    };
  },
  "prelude.string.trim": async (argument, context) => ({
    kind: "string",
    value: (await readStringField(argument, "value", context)).trim(),
  }),
  "prelude.string.to_upper": async (argument, context) => ({
    kind: "string",
    value: (await readStringField(argument, "value", context)).toUpperCase(),
  }),
  "prelude.string.to_lower": async (argument, context) => ({
    kind: "string",
    value: (await readStringField(argument, "value", context)).toLowerCase(),
  }),
  "prelude.string.to_integer": async (argument, context) => {
    const text = await readStringField(argument, "value", context);
    // The canonical base-10 form only, and only a magnitude the number model holds exactly — a lossy
    // read must be null, never a silently rounded integer.
    if (!/^[+-]?[0-9]+$/.test(text)) return NULL_VALUE;
    const value = Number(text);
    return Number.isSafeInteger(value) ? { kind: "integer", value } : NULL_VALUE;
  },
  "prelude.string.to_number": async (argument, context) => {
    const text = await readStringField(argument, "value", context);
    // Exactly JSON's number grammar (the declared contract): no hex / "Infinity" forms that
    // `Number(...)` would admit, and no surrounding whitespace either (JSON.parse tolerates it, but
    // padded input is `trim`'s job — consistent with `to_integer`).
    if (text !== text.trim()) return NULL_VALUE;
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      return NULL_VALUE;
    }
    return typeof parsed === "number" && Number.isFinite(parsed)
      ? { kind: "number", value: parsed }
      : NULL_VALUE;
  },

  // ─── prelude.files ──────────────────────────────────────────────────────────────────────────
  // A `file` value is a slim blob handle (identity only); content comes from the byte store and
  // metadata from the project's blob catalog (the `blobs` rows — the source of truth). Privacy is
  // the prim layer's monotonic rule, like every reader here: a private file taints the result.
  "prelude.files.read_base64": async (argument, context) => {
    const file = fileArgument(argument, "value");
    // Check the catalog row FIRST: a `free`d blob's row is gone the instant it is freed, but its bytes are
    // deleted only after the commit — so `blobs.get` might still find them. Reading the row makes a freed
    // handle report `gone` this turn, not stale bytes.
    blobRowOf(context, file);
    const bytes = await context.blobs.get(context.projectId, file.blobId);
    return { kind: "string", value: Buffer.from(bytes).toString("base64") };
  },
  "prelude.files.content_type": async (argument, context) => ({
    kind: "string",
    value: blobRowOf(context, fileArgument(argument, "value")).contentType ?? "",
  }),
  "prelude.files.size": async (argument, context) => ({
    kind: "integer",
    value: blobRowOf(context, fileArgument(argument, "value")).size,
  }),
  "prelude.files.from_base64": async (argument, context) => {
    const content = await readStringField(argument, "content", context);
    const contentType = await readStringField(argument, "content_type", context);
    const bytes = decodeBase64OrThrow(content);
    // A fresh UUID id, NOT a content hash: a `file` is a resource, not a literal, so two `from_base64`s of
    // the same bytes must be different files (distinct `==`, distinct custody chains — one's `free` must not
    // kill the other's ref). A retry re-running this mints a new file each attempt, which is the same "two
    // productions are two files" rule; Katari's replay is plain re-execution, so no id needs to be stable.
    const blobId = newBlobId();
    const hash = createHash("sha256").update(bytes).digest("hex");
    // Bytes first, then register the (small) row — mirrors the FFI / upload producer (`mintAndStoreBlob`).
    await context.blobs.put(context.projectId, blobId, bytes);
    blobEffectsOf(context, "from_base64").produce(blobId, {
      hash,
      size: bytes.byteLength,
      semanticKind: "file",
      // "" records no MIME type (the read side degrades a missing type to ""), matching the upload path.
      ...(contentType !== "" ? { contentType } : {}),
    });
    return { kind: "ref", semanticKind: "file", blobId };
  },
  "prelude.files.free": (argument, context) => {
    // Idempotent and silent: the pool frees the blob only when the current run owns it, else a no-op (an
    // uploaded file or another run's blob is untouched). Returns null regardless — a program cannot observe
    // whether anything was freed, so a retried block frees the same handle twice with identical behaviour.
    blobEffectsOf(context, "free").freeInRun(fileArgument(argument, "value").blobId);
    return NULL_VALUE;
  },

  // ─── AI interop ─────────────────────────────────────────────────────────────────────────────
  "prelude.reflection.get_metadata": async (argument, context) => {
    const metadata = await callableMetadata(field(argument, "value"), context.ir);
    return {
      kind: "record",
      ctor: createAgentName("prelude.reflection.agent_metadata"),
      fields: {
        name: { kind: "string", value: metadata.name },
        description: { kind: "string", value: metadata.description },
        input: literalLift(schemaToJson(metadata.input)),
        output: literalLift(schemaToJson(metadata.output)),
        requests: literalLift(metadata.requests),
      },
    };
  },
  "prelude.reflection.call_agent": () => {
    // Unreachable by construction: `CoreReactor.onDelegate` unwraps a `call_agent` delegate before
    // any instance is summoned, so this body block never runs.
    throw new Error("call_agent must be dispatched at the delegation boundary (engine bug)");
  },
};

function sortedKeys(fields: Record<string, Value>): string[] {
  return Object.keys(fields).sort();
}

/** The schema the call site's `[T]` instantiation carried (a schema-directed prim's contract: T is
 *  its only generic). Absent means the delegate carried no substitution — IR from a compiler
 *  predating inferred-instantiation stamping — so fail loud rather than skip validation. */
function instantiatedSchema(context: PrimContext, label: string): JSONSchema {
  const bound = context.generics?.T;
  if (bound === undefined) {
    throw new Error(
      `${label}: the [T] instantiation did not reach the runtime (recompile the program with a current compiler)`,
    );
  }
  if (bound.kind !== "type") {
    throw new Error(`${label}: the [T] instantiation is not a type argument`);
  }
  return bound.schema;
}

/** Check a value against T, returning it unchanged when it conforms, or raising the catchable
 *  `validation_error` naming the offending path. Validation only checks — it never rewrites the value. */
function conformedOrThrow(value: Value, schema: JSONSchema, label: string): Value {
  const result = conformValue(value, schema);
  if (!result.ok) {
    throw new KatariThrow(
      errorData(
        VALIDATION_ERROR,
        `${label}: the value does not conform to T — ${renderConformFailures(result.failures)}`,
      ),
    );
  }
  return value;
}

/** A callable value's public metadata, ready for `agent_metadata`. A `tool` (a reactor-backed agent)
 *  presents the runtime-decided signature it was minted with: the provider-declared name / description
 *  / input schema, its output schema when the provider declared one (`{}` — unknown — otherwise), and
 *  no requests (a reactor call performs io, not katari requests). Exported because `mcp.serve`
 *  advertises a served agent's tool listing from exactly this metadata — one reflection source, so the
 *  MCP listing and `reflection.get_metadata` can never drift. */
export async function callableMetadata(
  value: Value,
  ir: IrSource,
): Promise<{
  name: string;
  description: string;
  input: JSONSchema;
  output: JSONSchema;
  requests: Json;
}> {
  if (value.kind === "tool") {
    return {
      name: value.name,
      description: value.description,
      input: value.inputSchema,
      output: value.outputSchema ?? {},
      requests: [],
    };
  }
  const callable = await locateCallable(value, ir);
  const typeSubstitution = typeSubstitutionOf(callable.schema.genericBindings, callable.generics);
  const requestSubstitution = requestSubstitutionOf(
    callable.schema.genericBindings,
    callable.generics,
  );
  return {
    name: callable.name,
    description: callable.description,
    input: fillGenericSchema(typeSubstitution, callable.schema.input),
    output: fillGenericSchema(typeSubstitution, callable.schema.output),
    requests: requestsToJson(callable.schema.requests, typeSubstitution, requestSubstitution),
  };
}

/** Whether `argument` conforms to `value`'s DECLARED input schema — the pure pre-validation the async input
 *  boundaries (`mcp.serve`, `webhook.inbound`, and the run-start API) run before dispatching, so a malformed
 *  external argument is caught as each boundary's own error (invalid-params / HTTP 400) and never reaches the
 *  acceptance surface (whose mismatch is a defensive panic). Resolves the input schema through the SAME
 *  `callableMetadata` seam the listing uses — so the validated schema can never drift from the advertised one
 *  — and checks it (generics already filled by `callableMetadata`). Returns the mismatches, or `null` when the
 *  argument conforms. Only this pure predicate is shared; each boundary renders a failure into its own error
 *  shape. (The engine's synchronous `call_agent` path validates separately — it cannot await a preload.) */
export async function conformCallableArgument(
  value: Value,
  argument: Value | null,
  ir: IrSource,
): Promise<ConformFailure[] | null> {
  const metadata = await callableMetadata(value, ir);
  const check = conformValue(argument ?? { kind: "record", fields: {} }, metadata.input);
  return check.ok ? null : check.failures;
}

/** The SYNCHRONOUS twin of `conformCallableArgument`, for the hot dynamic-dispatch paths that cannot await a
 *  preload — the engine's `call_agent` and the FFI reactor's inner call. It pre-validates an agent / closure
 *  callee's argument against its declared input schema, resolved from the ALREADY-LOADED snapshot the way
 *  `resolveLeafBody` does (a foreign / unloaded snapshot, or a non-agent block, falls back to `null`: no
 *  pre-check, leaving the acceptance surface as the guard). A `tool` value (validated by `dispatchCallable`)
 *  and a non-callable value (a dispatch error) also fall through to `null`. Returns the mismatches, or `null`
 *  when the argument conforms (or cannot be pre-checked). The input schema resolves from the callee's OWN
 *  carried generics — a dynamic caller's generics never rebind the callee's input params. */
export function conformCallableArgumentSync(
  value: Value,
  argument: Value | null,
  irSource: IrSource,
): ConformFailure[] | null {
  if (value.kind !== "agent" && value.kind !== "closure") return null;
  const inputSchema = dynamicInputSchemaOf(value, irSource);
  if (inputSchema === null) return null; // an unloaded / foreign snapshot or non-agent — the acceptance surface guards it
  const check = conformValue(argument ?? { kind: "record", fields: {} }, inputSchema);
  return check.ok ? null : check.failures;
}

/** The DECLARED input schema of a callable value, resolved synchronously the way `conformCallableArgumentSync`
 *  does — for an agent / closure from its already-loaded snapshot block (generics filled from the callee's own
 *  carried substitution), for a `tool` from its attached `inputSchema`, and `null` for a non-callable, an
 *  unloaded / foreign snapshot, or a non-agent block. The sync `call_agent` pre-validation reads it to check a
 *  dynamic argument against the target's declared input before dispatching. */
function dynamicInputSchemaOf(value: Value, irSource: IrSource): JSONSchema | null {
  if (value.kind === "tool") return value.inputSchema;
  if (value.kind !== "agent" && value.kind !== "closure") return null;
  let block: Block;
  try {
    if (value.kind === "agent") {
      const located = irSource.locate(value.snapshot, value.name);
      block = irSource.access(value.snapshot, located.module).block(located.blockId).block;
    } else {
      block = irSource.access(value.snapshot, value.module).block(value.blockId).block;
    }
  } catch {
    return null; // an unloaded / foreign snapshot — the acceptance surface guards it
  }
  if (block.kind !== "agent") return null; // not an agent body — the acceptance surface guards it
  const substitution = typeSubstitutionOf(block.schema.genericBindings, value.generics);
  return fillGenericSchema(substitution, block.schema.input);
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
