// Built-in primitive registry. Pure functions: `(args) => Value`.
//
// Two failure modes:
//   - `RecoverableEngineError` — generic recoverable error; bubbles up
//     as the universal `primitive.throw` request (see
//     `emitThrowEscalate`).
//   - `PrimRaiseRequest` — the prim wants to surface a specific
//     never-returning request (e.g. `json_parse_error`). The PrimThread
//     emits an `ask` of that request upward; whatever handler catches
//     it must `break` out of its enclosing handle scope, which in turn
//     cancels this thread. If no handler catches, the ask escalates to
//     the API Module and terminates the run.
//
// Bad arguments raise `RecoverableEngineError` so a single agent's mistake
// doesn't poison the version. Adding a prim here means coordinating with
// the Haskell side's `Katari.Builtins` registry — names must match.

import type { QualifiedName } from "../ir/types.js";
import { RawValueDecodeError, valueFromRaw, valueToRaw } from "../value-codec.js";
import { RecoverableEngineError } from "./errors.js";
import type { RefPutter } from "./step-ctx.js";
import {
  type BytesRep,
  bytesContentEqual,
  inlineText,
  mkSecret,
  mkString,
  type Value,
} from "./value.js";

/** Materialize a byte-sequence rep to bytes (inline immediate, ref fetched). */
type Materialize = (rep: BytesRep) => Promise<Uint8Array>;

/**
 * Read a byte-sequence rep as text. Inline reps return their text directly
 * (no fetch — the common case stays cheap); refs are materialized + UTF-8
 * decoded. Used by content-transform prims that combine string content.
 */
async function materializeText(rep: BytesRep, materialize: Materialize): Promise<string> {
  if (rep.kind === "inline") return rep.text;
  return new TextDecoder().decode(await materialize(rep));
}

/** Read a `string` / `secret` Value's text, materializing a ref if needed. */
async function materializeValueText(v: Value, materialize: Materialize): Promise<string> {
  if (v.kind !== "string" && v.kind !== "secret") {
    throw new RecoverableEngineError(`expected string/secret, got ${v.kind}`);
  }
  return materializeText(v.rep, materialize);
}

/**
 * Deep-materialize: replace every `string` ref nested in `value` with its
 * inline form so a subsequent `valueToRaw` / `jsonTaggedToRaw` produces the
 * real content rather than a `$ref` envelope. Used by `to_string` /
 * `json.stringify`, which serialize a whole value tree. `file` stays a ref
 * (it has no text form); `secret` stays as-is (callers reject it upstream).
 */
async function materializeValueDeep(value: Value, materialize: Materialize): Promise<Value> {
  switch (value.kind) {
    case "string":
      return value.rep.kind === "ref"
        ? mkString(new TextDecoder().decode(await materialize(value.rep)))
        : value;
    case "array":
      return {
        kind: "array",
        elements: await Promise.all(
          value.elements.map((e) => materializeValueDeep(e, materialize)),
        ),
      };
    case "record":
      return value.ctor !== undefined
        ? {
            kind: "record",
            entries: await deepFields(value.entries, materialize),
            ctor: value.ctor,
          }
        : { kind: "record", entries: await deepFields(value.entries, materialize) };
    default:
      return value;
  }
}

async function deepFields(
  fields: Record<string, Value>,
  materialize: Materialize,
): Promise<Record<string, Value>> {
  const out: Record<string, Value> = {};
  for (const [k, v] of Object.entries(fields)) out[k] = await materializeValueDeep(v, materialize);
  return out;
}

/**
 * Strings at or below this UTF-8 byte length stay inline; larger ones are
 * promoted to a content-addressed blob so they ship small across every
 * boundary (IPC to a sidecar, cross-shard messages, checkpoints) and are
 * materialized only when bytes are actually needed.
 */
const STRING_PROMOTE_THRESHOLD_BYTES = 4096;

/**
 * Build a `string` Value from freshly produced text, promoting it to a blob
 * ref when it exceeds the inline threshold and a value store is wired (`put`
 * present). This is the "promote at birth" point: a large string produced by a
 * content-transform prim (`to_string`, `concat`, `string.*`, `file_to_string`)
 * becomes a ref here, so it stays a ref everywhere downstream — scope,
 * checkpoints, and the wire — instead of being re-shipped inline each step.
 * Content-addressing dedups, so the same content never re-uploads.
 */
async function mkStringMaybePromote(text: string, put: RefPutter | undefined): Promise<Value> {
  if (put === undefined) return mkString(text);
  const bytes = new TextEncoder().encode(text);
  if (bytes.length <= STRING_PROMOTE_THRESHOLD_BYTES) return mkString(text);
  return { kind: "string", rep: await put(bytes, "string") };
}

/**
 * Thrown by a primitive to raise a specific (never-returning) request
 * instead of returning a value. The PrimThread catches this and emits
 * the corresponding `ask` upward; this thread then waits in a
 * "running, but emitted-an-ask" state until the cancel cascade from
 * whatever handler caught the request reaches it.
 *
 * Use for failure modes that should be statically visible in the prim's
 * type (`with foo_error` clause) — generic recoverable errors should
 * stay with `RecoverableEngineError`.
 */
export class PrimRaiseRequest extends Error {
  readonly reqId: QualifiedName;
  readonly args: Record<string, Value>;
  constructor(reqId: QualifiedName, args: Record<string, Value>) {
    super(`prim raised request '${reqId}'`);
    this.reqId = reqId;
    this.args = args;
  }
}

export async function executePrim(
  name: string,
  args: Record<string, Value>,
  materialize: Materialize,
  /** Persist bytes → ref. Required only by producing prims (`string_to_file`);
   *  omitted by callers / tests that exercise pure prims. */
  put?: RefPutter,
): Promise<Value> {
  switch (name) {
    case "primitive.add":
      return arith(name, args, (a, b) => a + b);
    case "primitive.sub":
      return arith(name, args, (a, b) => a - b);
    case "primitive.mul":
      return arith(name, args, (a, b) => a * b);
    case "primitive.div":
      return arith(name, args, (a, b) => {
        if (b === 0) throw new RecoverableEngineError("prim div: division by zero");
        return a / b;
      });
    case "primitive.mod":
      return arith(name, args, (a, b) => {
        if (b === 0) throw new RecoverableEngineError("prim mod: modulo by zero");
        // Floor mod (Python-style): result has the sign of the divisor,
        // not the dividend. JS' % truncates toward zero, so we adjust.
        return a - Math.floor(a / b) * b;
      });
    case "primitive.neg": {
      const v = args["value"];
      if (v?.kind === "number") return { kind: "number", value: -v.value };
      throw new RecoverableEngineError("prim neg: invalid args");
    }
    case "primitive.eq":
      return { kind: "boolean", value: valueEquals(req(args, "lhs"), req(args, "rhs")) };
    case "primitive.ne":
      return { kind: "boolean", value: !valueEquals(req(args, "lhs"), req(args, "rhs")) };
    case "primitive.lt":
      return cmp(name, args, (a, b) => a < b);
    case "primitive.gt":
      return cmp(name, args, (a, b) => a > b);
    case "primitive.le":
      return cmp(name, args, (a, b) => a <= b);
    case "primitive.ge":
      return cmp(name, args, (a, b) => a >= b);
    case "primitive.not": {
      const v = args["value"];
      if (v?.kind === "boolean") return { kind: "boolean", value: !v.value };
      throw new RecoverableEngineError("prim not: invalid args");
    }
    case "primitive.and":
      return logical(name, args, (a, b) => a && b);
    case "primitive.or":
      return logical(name, args, (a, b) => a || b);
    case "primitive.concat": {
      // Taint-aware concat (via the `using fstring_join` rule on
      // 'prim agent concat'): both operands must be string-or-secret,
      // and if EITHER operand is secret the result is secret too.
      // The type system has already narrowed each argument to
      // string ∪ secret at compile time; at runtime we just observe
      // which variant landed.
      const lhs = args["lhs"],
        rhs = args["rhs"];
      if (
        (lhs?.kind === "string" || lhs?.kind === "secret") &&
        (rhs?.kind === "string" || rhs?.kind === "secret")
      ) {
        // Content transform: needs the bytes. Inline operands resolve
        // immediately; ref operands are fetched (bounded I/O within the
        // quantum). The result is inline; persist-time promotion (Phase E1)
        // re-refs it if large.
        const joined =
          (await materializeText(lhs.rep, materialize)) +
          (await materializeText(rhs.rep, materialize));
        const tainted = lhs.kind === "secret" || rhs.kind === "secret";
        // Secrets stay inline (inline-only in v0.1.0); plain strings promote.
        return tainted ? mkSecret(joined) : await mkStringMaybePromote(joined, put);
      }
      throw new RecoverableEngineError("prim concat: invalid args");
    }
    case "primitive.to_string": {
      const v = args["value"];
      if (v === undefined) throw new RecoverableEngineError("prim to_string: missing arg");
      // 'to_string' is the **type-erasing** stringifier: by spec it
      // refuses 'secret' because that would launder taint into a
      // plain `string`. The type system rejects this statically
      // ('to_string' takes `unknown` excluding `secret`); the
      // runtime check below is defence-in-depth.
      if (v.kind === "secret") {
        throw new RecoverableEngineError(
          "prim to_string: refusing to stringify a secret value (would launder taint)",
        );
      }
      return mkStringMaybePromote(
        JSON.stringify(valueToRaw(await materializeValueDeep(v, materialize))),
        put,
      );
    }
    case "primitive.from_string": {
      const text = req(args, "text");
      if (text.kind !== "string") {
        throw new RecoverableEngineError(
          `prim from_string: argument must be a string, got ${text.kind}`,
        );
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(await materializeValueText(text, materialize));
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        throw new PrimRaiseRequest("primitive.from_string_error", {
          message: mkString(`invalid JSON: ${msg}`),
        });
      }
      try {
        return valueFromRaw(parsed);
      } catch (e) {
        if (e instanceof RawValueDecodeError) {
          throw new PrimRaiseRequest("primitive.from_string_error", {
            message: mkString(e.message),
          });
        }
        throw e;
      }
    }
    case "primitive.format": {
      // Taint-aware unary format (via `using fstring_join`). Pass
      // string and secret through verbatim — preserving the variant
      // is exactly the taint-propagation rule. Other inputs were
      // already rejected at typecheck (fstring_join restricts to
      // string ∪ secret), but we throw defensively here.
      const v = args["value"];
      if (v === undefined) throw new RecoverableEngineError("prim format: missing arg");
      if (v.kind === "string" || v.kind === "secret") return v;
      throw new RecoverableEngineError(
        `prim format: argument must be string or secret, got ${v.kind}`,
      );
    }
    case "primitive.file_to_string": {
      // Read a file's bytes back as a UTF-8 string. `file` is always a ref, so
      // this materializes (fetches) the blob. The result is an inline string;
      // persist-time promotion re-refs it if large.
      const v = args["value"];
      if (v?.kind !== "file") {
        throw new RecoverableEngineError(
          `prim file_to_string: argument must be a file, got ${v?.kind ?? "nothing"}`,
        );
      }
      return mkStringMaybePromote(new TextDecoder().decode(await materialize(v.rep)), put);
    }
    case "primitive.string_to_file": {
      // Write a string's bytes to a new content blob and hand back a `file`
      // value pointing at it. Rejects `secret` (the type system already
      // narrows the param to `string`; this is defence-in-depth against
      // laundering a credential into an opaque, re-readable file).
      const v = args["value"];
      if (v?.kind !== "string") {
        throw new RecoverableEngineError(
          `prim string_to_file: argument must be a string, got ${v?.kind ?? "nothing"}`,
        );
      }
      if (put === undefined) {
        throw new RecoverableEngineError(
          "prim string_to_file: no value store wired (cannot mint a file)",
        );
      }
      const bytes = await materialize(v.rep);
      // The bytes are a UTF-8 string, so the file is text — tag it so the data
      // plane serves a meaningful content type (the only other file producers,
      // upload + FFI, declare their own; CORE-produced files would otherwise be
      // contentless).
      const rep = await put(bytes, "file", undefined, "text/plain; charset=utf-8");
      return { kind: "file", rep };
    }
    case "primitive.tuple_get": {
      // Tuples are stored as arrays at runtime (see 'Value'); the
      // static type system already distinguishes the two. This prim
      // and 'array_get' share an implementation; both dispatch on the
      // single 'array' Value variant.
      const tuple = args["tuple"],
        index = args["index"];
      if (tuple?.kind === "array" && index?.kind === "number") {
        // Reject fractional / negative indices loudly rather than
        // silently falling into the "out of bounds" branch — `t[1.5]`
        // is a programming error, not an OOB access.
        if (!Number.isInteger(index.value) || index.value < 0) {
          throw new RecoverableEngineError(
            `prim tuple_get: index must be a non-negative integer, got ${index.value}`,
          );
        }
        const elem = tuple.elements[index.value];
        if (elem === undefined) {
          throw new RecoverableEngineError("prim tuple_get: index out of bounds");
        }
        return elem;
      }
      throw new RecoverableEngineError("prim tuple_get: invalid args");
    }
    case "primitive.array.get": {
      const array = args["array"],
        index = args["index"];
      if (array?.kind === "array" && index?.kind === "number") {
        if (!Number.isInteger(index.value) || index.value < 0) {
          throw new RecoverableEngineError(
            `prim array.get: index must be a non-negative integer, got ${index.value}`,
          );
        }
        const elem = array.elements[index.value];
        if (elem === undefined) {
          throw new RecoverableEngineError("prim array.get: index out of bounds");
        }
        return elem;
      }
      throw new RecoverableEngineError("prim array.get: invalid args");
    }
    case "primitive.array.length": {
      const array = req(args, "array");
      if (array.kind !== "array") {
        throw new RecoverableEngineError(
          `prim array.length: argument must be an array, got ${array.kind}`,
        );
      }
      return { kind: "number", value: array.elements.length };
    }
    case "primitive.array.empty":
      return { kind: "array", elements: [] };
    case "primitive.array.range": {
      const count = req(args, "count");
      if (count.kind !== "number") {
        throw new RecoverableEngineError(
          `prim array.range: count must be an integer, got ${count.kind}`,
        );
      }
      const n = Math.max(0, Math.floor(count.value));
      return {
        kind: "array",
        elements: Array.from({ length: n }, (_unused, index) => ({
          kind: "number" as const,
          value: index,
        })),
      };
    }
    case "primitive.array.of":
      return { kind: "array", elements: [req(args, "value")] };
    case "primitive.array.append": {
      const array = req(args, "array");
      if (array.kind !== "array") {
        throw new RecoverableEngineError(
          `prim array.append: first argument must be an array, got ${array.kind}`,
        );
      }
      return { kind: "array", elements: [...array.elements, req(args, "value")] };
    }
    case "primitive.array.concat": {
      const lhs = req(args, "lhs"),
        rhs = req(args, "rhs");
      if (lhs.kind !== "array" || rhs.kind !== "array") {
        throw new RecoverableEngineError("prim array.concat: both arguments must be arrays");
      }
      return { kind: "array", elements: [...lhs.elements, ...rhs.elements] };
    }
    case "primitive.array.slice": {
      const array = req(args, "array"),
        start = req(args, "start"),
        end = req(args, "end");
      if (array.kind !== "array" || start.kind !== "number" || end.kind !== "number") {
        throw new RecoverableEngineError("prim array.slice: invalid args");
      }
      return { kind: "array", elements: array.elements.slice(start.value, end.value) };
    }
    case "primitive.array.reverse": {
      const array = req(args, "array");
      if (array.kind !== "array") {
        throw new RecoverableEngineError(
          `prim array.reverse: argument must be an array, got ${array.kind}`,
        );
      }
      return { kind: "array", elements: [...array.elements].reverse() };
    }
    case "primitive.array.contains": {
      const array = req(args, "array");
      if (array.kind !== "array") {
        throw new RecoverableEngineError(
          `prim array.contains: first argument must be an array, got ${array.kind}`,
        );
      }
      const value = req(args, "value");
      return { kind: "boolean", value: array.elements.some((e) => valueEquals(e, value)) };
    }
    case "primitive.array.index_of": {
      const array = req(args, "array");
      if (array.kind !== "array") {
        throw new RecoverableEngineError(
          `prim array.index_of: first argument must be an array, got ${array.kind}`,
        );
      }
      const value = req(args, "value");
      return { kind: "number", value: array.elements.findIndex((e) => valueEquals(e, value)) };
    }
    // ── string.* (offsets / lengths in Unicode code points, not UTF-16) ──
    case "primitive.string.length": {
      const s = await materializeValueText(req(args, "value"), materialize);
      return { kind: "number", value: [...s].length };
    }
    case "primitive.string.slice": {
      const s = await materializeValueText(req(args, "value"), materialize);
      const start = req(args, "start"),
        end = req(args, "end");
      if (start.kind !== "number" || end.kind !== "number") {
        throw new RecoverableEngineError("prim string.slice: start/end must be integers");
      }
      return mkStringMaybePromote([...s].slice(start.value, end.value).join(""), put);
    }
    case "primitive.string.contains": {
      const s = await materializeValueText(req(args, "value"), materialize);
      const sub = await materializeValueText(req(args, "substring"), materialize);
      return { kind: "boolean", value: s.includes(sub) };
    }
    case "primitive.string.starts_with": {
      const s = await materializeValueText(req(args, "value"), materialize);
      const prefix = await materializeValueText(req(args, "prefix"), materialize);
      return { kind: "boolean", value: s.startsWith(prefix) };
    }
    case "primitive.string.ends_with": {
      const s = await materializeValueText(req(args, "value"), materialize);
      const suffix = await materializeValueText(req(args, "suffix"), materialize);
      return { kind: "boolean", value: s.endsWith(suffix) };
    }
    case "primitive.string.index_of": {
      const s = await materializeValueText(req(args, "value"), materialize);
      const sub = await materializeValueText(req(args, "substring"), materialize);
      const codePoints = [...s];
      const subCodePoints = [...sub];
      if (subCodePoints.length === 0) return { kind: "number", value: 0 };
      for (let i = 0; i + subCodePoints.length <= codePoints.length; i++) {
        if (codePoints.slice(i, i + subCodePoints.length).join("") === sub) {
          return { kind: "number", value: i };
        }
      }
      return { kind: "number", value: -1 };
    }
    case "primitive.string.upper": {
      const s = await materializeValueText(req(args, "value"), materialize);
      return mkStringMaybePromote(s.toUpperCase(), put);
    }
    case "primitive.string.lower": {
      const s = await materializeValueText(req(args, "value"), materialize);
      return mkStringMaybePromote(s.toLowerCase(), put);
    }
    case "primitive.string.trim": {
      const s = await materializeValueText(req(args, "value"), materialize);
      return mkStringMaybePromote(s.trim(), put);
    }
    case "primitive.string.split": {
      const s = await materializeValueText(req(args, "value"), materialize);
      const separator = await materializeValueText(req(args, "separator"), materialize);
      const parts = separator === "" ? [...s] : s.split(separator);
      return { kind: "array", elements: parts.map((part): Value => mkString(part)) };
    }
    case "primitive.string.join": {
      const parts = req(args, "parts");
      if (parts.kind !== "array") {
        throw new RecoverableEngineError("prim string.join: parts must be an array");
      }
      const separator = await materializeValueText(req(args, "separator"), materialize);
      const pieces: string[] = [];
      for (const part of parts.elements) {
        pieces.push(await materializeValueText(part, materialize));
      }
      return mkStringMaybePromote(pieces.join(separator), put);
    }
    case "primitive.string.replace": {
      const s = await materializeValueText(req(args, "value"), materialize);
      const pattern = await materializeValueText(req(args, "pattern"), materialize);
      const replacement = await materializeValueText(req(args, "replacement"), materialize);
      return mkStringMaybePromote(s.replaceAll(pattern, replacement), put);
    }
    // ── math.* ──
    case "primitive.math.abs": {
      const v = req(args, "value");
      if (v.kind !== "number") throw new RecoverableEngineError("prim math.abs: invalid args");
      return { kind: "number", value: Math.abs(v.value) };
    }
    case "primitive.math.min":
      return arith(name, args, (a, b) => Math.min(a, b));
    case "primitive.math.max":
      return arith(name, args, (a, b) => Math.max(a, b));
    case "primitive.math.floor": {
      const v = req(args, "value");
      if (v.kind !== "number") throw new RecoverableEngineError("prim math.floor: invalid args");
      return { kind: "number", value: Math.floor(v.value) };
    }
    case "primitive.math.ceil": {
      const v = req(args, "value");
      if (v.kind !== "number") throw new RecoverableEngineError("prim math.ceil: invalid args");
      return { kind: "number", value: Math.ceil(v.value) };
    }
    case "primitive.math.round": {
      const v = req(args, "value");
      if (v.kind !== "number") throw new RecoverableEngineError("prim math.round: invalid args");
      // Ties away from zero (Math.round breaks .5 toward +Infinity).
      return { kind: "number", value: Math.sign(v.value) * Math.round(Math.abs(v.value)) };
    }
    case "primitive.type_of": {
      const value = args["value"];
      if (value === undefined) {
        throw new RecoverableEngineError("prim type_of: missing arg");
      }
      return mkString(value.kind);
    }
    case "primitive.get_field": {
      // Named field access on the map layer — reads from any `record` value
      // (a bare object / record OR a `data` value, which carries a ctor).
      const value = args["object"],
        field = args["field"];
      if (value?.kind === "record" && field?.kind === "string") {
        const fieldName = await materializeValueText(field, materialize);
        const v = value.entries[fieldName];
        if (v === undefined) {
          throw new RecoverableEngineError(`prim get_field: field ${fieldName} not found`);
        }
        return v;
      }
      throw new RecoverableEngineError("prim get_field: invalid args");
    }
    case "primitive.record.empty": {
      return { kind: "record", entries: Object.create(null) };
    }
    case "primitive.record.get": {
      const r = req(args, "record"),
        key = req(args, "key");
      if (r.kind !== "record") {
        throw new RecoverableEngineError(
          `prim record.get: first argument must be a record, got ${r.kind}`,
        );
      }
      if (key.kind !== "string") {
        throw new RecoverableEngineError(`prim record.get: key must be a string, got ${key.kind}`);
      }
      const v = r.entries[await materializeValueText(key, materialize)];
      return v === undefined ? { kind: "null" } : v;
    }
    case "primitive.record.set": {
      const r = req(args, "record"),
        key = req(args, "key"),
        value = req(args, "value");
      if (r.kind !== "record") {
        throw new RecoverableEngineError(
          `prim record.set: first argument must be a record, got ${r.kind}`,
        );
      }
      if (key.kind !== "string") {
        throw new RecoverableEngineError(`prim record.set: key must be a string, got ${key.kind}`);
      }
      const next: Record<string, Value> = Object.create(null);
      for (const [k, v] of Object.entries(r.entries)) {
        next[k] = v;
      }
      next[await materializeValueText(key, materialize)] = value;
      return { kind: "record", entries: next };
    }
    case "primitive.record.remove": {
      const r = req(args, "record"),
        key = req(args, "key");
      if (r.kind !== "record") {
        throw new RecoverableEngineError(
          `prim record.remove: first argument must be a record, got ${r.kind}`,
        );
      }
      if (key.kind !== "string") {
        throw new RecoverableEngineError(
          `prim record.remove: key must be a string, got ${key.kind}`,
        );
      }
      const removeKey = await materializeValueText(key, materialize);
      if (!(removeKey in r.entries)) return r;
      const next: Record<string, Value> = Object.create(null);
      for (const [k, v] of Object.entries(r.entries)) {
        if (k !== removeKey) next[k] = v;
      }
      return { kind: "record", entries: next };
    }
    case "primitive.record.keys": {
      const r = req(args, "record");
      if (r.kind !== "record") {
        throw new RecoverableEngineError(
          `prim record.keys: argument must be a record, got ${r.kind}`,
        );
      }
      const keys = Object.keys(r.entries).map((k): Value => mkString(k));
      return { kind: "array", elements: keys };
    }
    case "primitive.record.has": {
      const r = req(args, "record"),
        key = req(args, "key");
      if (r.kind !== "record") {
        throw new RecoverableEngineError(
          `prim record.has: first argument must be a record, got ${r.kind}`,
        );
      }
      if (key.kind !== "string") {
        throw new RecoverableEngineError(`prim record.has: key must be a string, got ${key.kind}`);
      }
      return {
        kind: "boolean",
        value: (await materializeValueText(key, materialize)) in r.entries,
      };
    }
    case "primitive.record.size": {
      const r = req(args, "record");
      if (r.kind !== "record") {
        throw new RecoverableEngineError(
          `prim record.size: argument must be a record, got ${r.kind}`,
        );
      }
      return { kind: "number", value: Object.keys(r.entries).length };
    }
    case "primitive.json.parse": {
      const text = req(args, "text");
      if (text.kind !== "string") {
        throw new RecoverableEngineError(
          `prim json.parse: argument must be a string, got ${text.kind}`,
        );
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(await materializeValueText(text, materialize));
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        throw new PrimRaiseRequest("primitive.json_parse_error", {
          message: mkString(`invalid JSON: ${msg}`),
        });
      }
      return jsonToTagged(parsed);
    }
    case "primitive.json.stringify": {
      const value = req(args, "value");
      const raw = jsonTaggedToRaw(await materializeValueDeep(value, materialize));
      return mkString(JSON.stringify(raw));
    }
    case "primitive.json.of": {
      const value = req(args, "value");
      return valueToJsonTagged(await materializeValueDeep(value, materialize));
    }
    case "primitive.json.get": {
      const value = req(args, "value");
      const key = await materializeValueText(req(args, "key"), materialize);
      if (value.kind === "record" && value.ctor === JSON_OBJECT_QNAME) {
        const entries = value.entries["entries"];
        if (entries?.kind === "record") {
          const child = entries.entries[key];
          if (child !== undefined) return child;
        }
      }
      return { kind: "record", ctor: JSON_NULL_QNAME, entries: {} };
    }
    case "primitive.json.at": {
      const value = req(args, "value");
      const index = req(args, "index");
      if (value.kind === "record" && value.ctor === JSON_ARRAY_QNAME && index.kind === "number") {
        const items = value.entries["items"];
        if (items?.kind === "array" && index.value >= 0 && index.value < items.elements.length) {
          return items.elements[index.value] as Value;
        }
      }
      return { kind: "record", ctor: JSON_NULL_QNAME, entries: {} };
    }
    case "primitive.json.to_object": {
      const value = await materializeValueDeep(req(args, "value"), materialize);
      if (value.kind !== "record" || value.ctor !== JSON_OBJECT_QNAME) {
        throw new RecoverableEngineError(
          `prim json.to_object: expected a json_object, got ${value.kind === "record" ? (value.ctor ?? "record") : value.kind}`,
        );
      }
      return jsonTaggedToValue(value);
    }
    default:
      throw new RecoverableEngineError(`unknown prim: ${name}`);
  }
}

// Tagged `json` value → plain Value (the inverse of `valueToJsonTagged`):
// strip every json_* tag so nested strings / numbers / arrays / objects become
// raw values. The result carries no `json` typing — it is the value a caller
// (e.g. `call_agent`) consumes directly.
function jsonTaggedToValue(value: Value): Value {
  if (value.kind !== "record" || value.ctor === undefined) {
    throw new RecoverableEngineError(
      `prim json.to_object: expected a json value, got ${value.kind} (compiler invariant violated)`,
    );
  }
  switch (value.ctor) {
    case JSON_NULL_QNAME:
      return { kind: "null" };
    case JSON_BOOLEAN_QNAME:
    case JSON_INTEGER_QNAME:
    case JSON_NUMBER_QNAME:
    case JSON_STRING_QNAME: {
      const field = value.entries["value"];
      if (field === undefined) {
        throw new RecoverableEngineError(`prim json.to_object: ${value.ctor} missing .value`);
      }
      return field;
    }
    case JSON_ARRAY_QNAME: {
      const items = value.entries["items"];
      if (items?.kind !== "array") {
        throw new RecoverableEngineError("prim json.to_object: json_array.items is not an array");
      }
      return { kind: "array", elements: items.elements.map(jsonTaggedToValue) };
    }
    case JSON_OBJECT_QNAME: {
      const entries = value.entries["entries"];
      if (entries?.kind !== "record") {
        throw new RecoverableEngineError(
          "prim json.to_object: json_object.entries is not a record",
        );
      }
      const out: Record<string, Value> = {};
      for (const [key, child] of Object.entries(entries.entries)) {
        out[key] = jsonTaggedToValue(child);
      }
      return { kind: "record", entries: out };
    }
    default:
      throw new RecoverableEngineError(
        `prim json.to_object: unknown json constructor '${value.ctor}'`,
      );
  }
}

// Qualified-name constants for the `json` data constructors that live
// in the root `primitive` module. Kept here (rather than fed in from
// IR) because these are well-known stdlib types and the codec needs
// exact ctorId strings to construct / destructure tagged values.
const JSON_NULL_QNAME = "primitive.json_null";
const JSON_BOOLEAN_QNAME = "primitive.json_boolean";
const JSON_INTEGER_QNAME = "primitive.json_integer";
const JSON_NUMBER_QNAME = "primitive.json_number";
const JSON_STRING_QNAME = "primitive.json_string";
const JSON_ARRAY_QNAME = "primitive.json_array";
const JSON_OBJECT_QNAME = "primitive.json_object";

// Parsed JSON → tagged `json` value. The runtime wraps each JSON shape
// in its matching `primitive.json_*` constructor; the user pattern-
// matches on those names to discriminate. Integral numbers go to
// `json_integer` and fractional numbers to `json_number` so that a
// stringify-after-parse round-trip preserves the integer-vs-fractional
// form on the wire.
function jsonToTagged(raw: unknown): Value {
  if (raw === null) {
    return { kind: "record", ctor: JSON_NULL_QNAME, entries: {} };
  }
  if (typeof raw === "boolean") {
    return {
      kind: "record",
      ctor: JSON_BOOLEAN_QNAME,
      entries: { value: { kind: "boolean", value: raw } },
    };
  }
  if (typeof raw === "number") {
    const ctor = Number.isInteger(raw) ? JSON_INTEGER_QNAME : JSON_NUMBER_QNAME;
    return {
      kind: "record",
      ctor,
      entries: { value: { kind: "number", value: raw } },
    };
  }
  if (typeof raw === "string") {
    return {
      kind: "record",
      ctor: JSON_STRING_QNAME,
      entries: { value: mkString(raw) },
    };
  }
  if (Array.isArray(raw)) {
    return {
      kind: "record",
      ctor: JSON_ARRAY_QNAME,
      entries: {
        items: { kind: "array", elements: raw.map(jsonToTagged) },
      },
    };
  }
  if (typeof raw === "object") {
    const entries: Record<string, Value> = Object.create(null);
    for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
      entries[k] = jsonToTagged(v);
    }
    return {
      kind: "record",
      ctor: JSON_OBJECT_QNAME,
      entries: { entries: { kind: "record", entries } },
    };
  }
  throw new RecoverableEngineError(`prim json.parse: unexpected JSON value of type ${typeof raw}`);
}

// In-memory `Value` → tagged `json` value (the `json.of` reflection). The value
// is already materialized (refs resolved), so strings are inline. Scalars map to
// their `json_*` constructor; arrays and untagged records recurse; a value that
// is already a `json_*` tagged record passes through unchanged. Anything that
// cannot be JSON (a secret — refused to avoid laundering taint — a closure /
// agent / file, or some other tagged `data` value) raises.
const JSON_CTORS = new Set([
  JSON_NULL_QNAME,
  JSON_BOOLEAN_QNAME,
  JSON_INTEGER_QNAME,
  JSON_NUMBER_QNAME,
  JSON_STRING_QNAME,
  JSON_ARRAY_QNAME,
  JSON_OBJECT_QNAME,
]);
function valueToJsonTagged(value: Value): Value {
  switch (value.kind) {
    case "null":
      return { kind: "record", ctor: JSON_NULL_QNAME, entries: {} };
    case "boolean":
      return { kind: "record", ctor: JSON_BOOLEAN_QNAME, entries: { value } };
    case "number":
      return {
        kind: "record",
        ctor: Number.isInteger(value.value) ? JSON_INTEGER_QNAME : JSON_NUMBER_QNAME,
        entries: { value },
      };
    case "string":
      return { kind: "record", ctor: JSON_STRING_QNAME, entries: { value } };
    case "array":
      return {
        kind: "record",
        ctor: JSON_ARRAY_QNAME,
        entries: { items: { kind: "array", elements: value.elements.map(valueToJsonTagged) } },
      };
    case "record": {
      // Already a json value? Pass it through (idempotent).
      if (value.ctor !== undefined && JSON_CTORS.has(value.ctor)) return value;
      if (value.ctor !== undefined) {
        throw new RecoverableEngineError(
          `prim json.of: cannot encode a tagged '${value.ctor}' value as JSON (only json_* / plain records)`,
        );
      }
      const entries: Record<string, Value> = {};
      for (const [key, field] of Object.entries(value.entries)) {
        entries[key] = valueToJsonTagged(field);
      }
      return {
        kind: "record",
        ctor: JSON_OBJECT_QNAME,
        entries: { entries: { kind: "record", entries } },
      };
    }
    case "secret":
      throw new RecoverableEngineError(
        "prim json.of: refusing to encode a secret value (would launder taint)",
      );
    default:
      throw new RecoverableEngineError(`prim json.of: cannot encode a ${value.kind} value as JSON`);
  }
}

// Tagged `json` value → JSON-encodable raw. The compiler's `json` type
// rules out non-json values statically so there is no runtime "unknown
// shape" path: any value that lands here is one of the seven
// `primitive.json_*` constructors. Defensive checks remain so a
// compiler bug doesn't silently corrupt the output.
function jsonTaggedToRaw(value: Value): unknown {
  if (value.kind !== "record" || value.ctor === undefined) {
    throw new RecoverableEngineError(
      `prim json.stringify: expected a json value, got ${value.kind} (compiler invariant violated)`,
    );
  }
  switch (value.ctor) {
    case JSON_NULL_QNAME:
      return null;
    case JSON_BOOLEAN_QNAME: {
      const f = value.entries["value"];
      if (f?.kind !== "boolean") {
        throw new RecoverableEngineError(
          "prim json.stringify: json_boolean.value is not a boolean",
        );
      }
      return f.value;
    }
    case JSON_INTEGER_QNAME:
    case JSON_NUMBER_QNAME: {
      const f = value.entries["value"];
      if (f?.kind !== "number") {
        throw new RecoverableEngineError(
          `prim json.stringify: ${value.ctor}.value is not a number`,
        );
      }
      return f.value;
    }
    case JSON_STRING_QNAME: {
      const f = value.entries["value"];
      if (f?.kind !== "string") {
        throw new RecoverableEngineError("prim json.stringify: json_string.value is not a string");
      }
      return inlineText(f);
    }
    case JSON_ARRAY_QNAME: {
      const items = value.entries["items"];
      if (items?.kind !== "array") {
        throw new RecoverableEngineError("prim json.stringify: json_array.items is not an array");
      }
      return items.elements.map(jsonTaggedToRaw);
    }
    case JSON_OBJECT_QNAME: {
      const entries = value.entries["entries"];
      if (entries?.kind !== "record") {
        throw new RecoverableEngineError(
          "prim json.stringify: json_object.entries is not a record",
        );
      }
      const out: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(entries.entries)) {
        out[k] = jsonTaggedToRaw(v);
      }
      return out;
    }
    default:
      throw new RecoverableEngineError(
        `prim json.stringify: unknown json constructor '${value.ctor}' (compiler invariant violated)`,
      );
  }
}

// ─── helpers ───────────────────────────────────────────────────────────────

function req(args: Record<string, Value>, name: string): Value {
  const v = args[name];
  if (v === undefined) {
    throw new RecoverableEngineError(`prim: missing argument "${name}"`);
  }
  return v;
}

function arith(
  name: string,
  args: Record<string, Value>,
  op: (a: number, b: number) => number,
): Value {
  const lhs = args["lhs"],
    rhs = args["rhs"];
  if (lhs?.kind === "number" && rhs?.kind === "number") {
    return { kind: "number", value: op(lhs.value, rhs.value) };
  }
  throw new RecoverableEngineError(`prim ${name}: invalid args`);
}

function cmp(
  name: string,
  args: Record<string, Value>,
  op: (a: number, b: number) => boolean,
): Value {
  const lhs = args["lhs"],
    rhs = args["rhs"];
  if (lhs?.kind === "number" && rhs?.kind === "number") {
    return { kind: "boolean", value: op(lhs.value, rhs.value) };
  }
  throw new RecoverableEngineError(`prim ${name}: invalid args`);
}

function logical(
  name: string,
  args: Record<string, Value>,
  op: (a: boolean, b: boolean) => boolean,
): Value {
  const lhs = args["lhs"],
    rhs = args["rhs"];
  if (lhs?.kind === "boolean" && rhs?.kind === "boolean") {
    return { kind: "boolean", value: op(lhs.value, rhs.value) };
  }
  throw new RecoverableEngineError(`prim ${name}: invalid args`);
}

/**
 * Structural deep equality. Closures are never equal (no extensional
 * function equality).
 */
export function valueEquals(a: Value, b: Value): boolean {
  if (a.kind !== b.kind) {
    // Closures are never equal to anything, cross-kind is always false.
    return false;
  }
  switch (a.kind) {
    case "number":
    case "boolean":
      return a.value === (b as typeof a).value;
    case "string":
      return bytesContentEqual(a.rep, (b as typeof a).rep);
    case "file":
      // file identity = (module, id). Content is irrelevant.
      return a.rep.id === (b as typeof a).rep.id && a.rep.module === (b as typeof a).rep.module;
    case "null":
      return true;
    case "array":
      return arrayEqual(a.elements, (b as typeof a).elements);
    // Plaintext equality on secrets is a deliberate compromise:
    // it's needed for legitimate "is this key the same as that
    // key" checks (e.g. token rotation logic), but the JS string
    // == comparison short-circuits on first mismatched character
    // — a side-channel timing leak. v0.2 should either replace
    // this with a constant-time compare or remove `secret` from
    // the `eq` prim's input type entirely.
    case "secret":
      return bytesContentEqual(a.rep, (b as typeof a).rep);
    case "closure":
      return false;
    case "record": {
      // Map layer — equal iff same ctor (both bare, or the same data ctor) and
      // structurally equal entries. This subsumes the old `tagged` equality.
      const br = b as typeof a;
      if (a.ctor !== br.ctor) return false;
      const xk = Object.keys(a.entries),
        yk = Object.keys(br.entries);
      if (xk.length !== yk.length) return false;
      for (const k of xk) {
        if (!Object.hasOwn(br.entries, k)) return false;
        if (!valueEquals(a.entries[k]!, br.entries[k]!)) return false;
      }
      return true;
    }
    case "agentLiteral":
      return false;
    default: {
      const _exhaustive: never = a;
      throw new Error(`valueEquals: unknown value kind: ${(_exhaustive as Value).kind}`);
    }
  }
}

function arrayEqual(xs: Value[], ys: Value[]): boolean {
  if (xs.length !== ys.length) return false;
  for (let i = 0; i < xs.length; i++) {
    if (!valueEquals(xs[i]!, ys[i]!)) return false;
  }
  return true;
}
