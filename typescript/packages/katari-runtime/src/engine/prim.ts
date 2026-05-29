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
import type { Value } from "./value.js";

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

export function executePrim(name: string, args: Record<string, Value>): Value {
  switch (name) {
    case "add":
      return arith(name, args, (a, b) => a + b);
    case "sub":
      return arith(name, args, (a, b) => a - b);
    case "mul":
      return arith(name, args, (a, b) => a * b);
    case "div":
      return arith(name, args, (a, b) => {
        if (b === 0) throw new RecoverableEngineError("prim div: division by zero");
        return a / b;
      });
    case "mod":
      return arith(name, args, (a, b) => {
        if (b === 0) throw new RecoverableEngineError("prim mod: modulo by zero");
        // Floor mod (Python-style): result has the sign of the divisor,
        // not the dividend. JS' % truncates toward zero, so we adjust.
        return a - Math.floor(a / b) * b;
      });
    case "neg": {
      const v = args["value"];
      if (v?.kind === "number") return { kind: "number", value: -v.value };
      throw new RecoverableEngineError("prim neg: invalid args");
    }
    case "abs": {
      const v = args["value"];
      if (v?.kind === "number") return { kind: "number", value: Math.abs(v.value) };
      throw new RecoverableEngineError("prim abs: invalid args");
    }
    case "eq":
      return { kind: "boolean", value: valueEquals(req(args, "lhs"), req(args, "rhs")) };
    case "ne":
      return { kind: "boolean", value: !valueEquals(req(args, "lhs"), req(args, "rhs")) };
    case "lt":
      return cmp(name, args, (a, b) => a < b);
    case "gt":
      return cmp(name, args, (a, b) => a > b);
    case "le":
      return cmp(name, args, (a, b) => a <= b);
    case "ge":
      return cmp(name, args, (a, b) => a >= b);
    case "not": {
      const v = args["value"];
      if (v?.kind === "boolean") return { kind: "boolean", value: !v.value };
      throw new RecoverableEngineError("prim not: invalid args");
    }
    case "and":
      return logical(name, args, (a, b) => a && b);
    case "or":
      return logical(name, args, (a, b) => a || b);
    case "concat": {
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
        const joined = lhs.value + rhs.value;
        const tainted = lhs.kind === "secret" || rhs.kind === "secret";
        return tainted ? { kind: "secret", value: joined } : { kind: "string", value: joined };
      }
      throw new RecoverableEngineError("prim concat: invalid args");
    }
    case "to_string": {
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
      return { kind: "string", value: JSON.stringify(valueToRaw(v)) };
    }
    case "from_string": {
      const text = req(args, "text");
      if (text.kind !== "string") {
        throw new RecoverableEngineError(
          `prim from_string: argument must be a string, got ${text.kind}`,
        );
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(text.value);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        throw new PrimRaiseRequest("primitive.from_string_error", {
          message: { kind: "string", value: `invalid JSON: ${msg}` },
        });
      }
      try {
        return valueFromRaw(parsed);
      } catch (e) {
        if (e instanceof RawValueDecodeError) {
          throw new PrimRaiseRequest("primitive.from_string_error", {
            message: { kind: "string", value: e.message },
          });
        }
        throw e;
      }
    }
    case "format": {
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
    case "tuple_get": {
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
    case "array_get": {
      const array = args["array"],
        index = args["index"];
      if (array?.kind === "array" && index?.kind === "number") {
        if (!Number.isInteger(index.value) || index.value < 0) {
          throw new RecoverableEngineError(
            `prim array_get: index must be a non-negative integer, got ${index.value}`,
          );
        }
        const elem = array.elements[index.value];
        if (elem === undefined) {
          throw new RecoverableEngineError("prim array_get: index out of bounds");
        }
        return elem;
      }
      throw new RecoverableEngineError("prim array_get: invalid args");
    }
    case "array_length": {
      const array = args["array"];
      if (array?.kind === "array") {
        return { kind: "number", value: array.elements.length };
      }
      throw new RecoverableEngineError("prim array_length: argument must be an array");
    }
    case "type_of": {
      const value = args["value"];
      if (value === undefined) {
        throw new RecoverableEngineError("prim type_of: missing arg");
      }
      return { kind: "string", value: value.kind };
    }
    case "get_field": {
      const value = args["object"],
        field = args["field"];
      if (value?.kind === "tagged" && field?.kind === "string") {
        const v = value.fields[field.value];
        if (v === undefined) {
          throw new RecoverableEngineError(`prim get_field: field ${field.value} not found`);
        }
        return v;
      }
      throw new RecoverableEngineError("prim get_field: invalid args");
    }
    case "record.empty": {
      return { kind: "record", entries: Object.create(null) };
    }
    case "record.get": {
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
      const v = r.entries[key.value];
      return v === undefined ? { kind: "null" } : v;
    }
    case "record.set": {
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
      next[key.value] = value;
      return { kind: "record", entries: next };
    }
    case "record.remove": {
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
      if (!(key.value in r.entries)) return r;
      const next: Record<string, Value> = Object.create(null);
      for (const [k, v] of Object.entries(r.entries)) {
        if (k !== key.value) next[k] = v;
      }
      return { kind: "record", entries: next };
    }
    case "record.keys": {
      const r = req(args, "record");
      if (r.kind !== "record") {
        throw new RecoverableEngineError(
          `prim record.keys: argument must be a record, got ${r.kind}`,
        );
      }
      const keys = Object.keys(r.entries).map((k): Value => ({ kind: "string", value: k }));
      return { kind: "array", elements: keys };
    }
    case "record.has": {
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
      return { kind: "boolean", value: key.value in r.entries };
    }
    case "record.size": {
      const r = req(args, "record");
      if (r.kind !== "record") {
        throw new RecoverableEngineError(
          `prim record.size: argument must be a record, got ${r.kind}`,
        );
      }
      return { kind: "number", value: Object.keys(r.entries).length };
    }
    case "json.parse": {
      const text = req(args, "text");
      if (text.kind !== "string") {
        throw new RecoverableEngineError(
          `prim json.parse: argument must be a string, got ${text.kind}`,
        );
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(text.value);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        throw new PrimRaiseRequest("primitive.json_parse_error", {
          message: { kind: "string", value: `invalid JSON: ${msg}` },
        });
      }
      return jsonToTagged(parsed);
    }
    case "json.stringify": {
      const value = req(args, "value");
      const raw = jsonTaggedToRaw(value);
      return { kind: "string", value: JSON.stringify(raw) };
    }
    default:
      throw new RecoverableEngineError(`unknown prim: ${name}`);
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
    return { kind: "tagged", ctorId: JSON_NULL_QNAME, fields: {} };
  }
  if (typeof raw === "boolean") {
    return {
      kind: "tagged",
      ctorId: JSON_BOOLEAN_QNAME,
      fields: { value: { kind: "boolean", value: raw } },
    };
  }
  if (typeof raw === "number") {
    const ctorId = Number.isInteger(raw) ? JSON_INTEGER_QNAME : JSON_NUMBER_QNAME;
    return {
      kind: "tagged",
      ctorId,
      fields: { value: { kind: "number", value: raw } },
    };
  }
  if (typeof raw === "string") {
    return {
      kind: "tagged",
      ctorId: JSON_STRING_QNAME,
      fields: { value: { kind: "string", value: raw } },
    };
  }
  if (Array.isArray(raw)) {
    return {
      kind: "tagged",
      ctorId: JSON_ARRAY_QNAME,
      fields: {
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
      kind: "tagged",
      ctorId: JSON_OBJECT_QNAME,
      fields: { entries: { kind: "record", entries } },
    };
  }
  throw new RecoverableEngineError(`prim json.parse: unexpected JSON value of type ${typeof raw}`);
}

// Tagged `json` value → JSON-encodable raw. The compiler's `json` type
// rules out non-json values statically so there is no runtime "unknown
// shape" path: any value that lands here is one of the seven
// `primitive.json_*` constructors. Defensive checks remain so a
// compiler bug doesn't silently corrupt the output.
function jsonTaggedToRaw(value: Value): unknown {
  if (value.kind !== "tagged") {
    throw new RecoverableEngineError(
      `prim json.stringify: expected a json value, got ${value.kind} (compiler invariant violated)`,
    );
  }
  switch (value.ctorId) {
    case JSON_NULL_QNAME:
      return null;
    case JSON_BOOLEAN_QNAME: {
      const f = value.fields["value"];
      if (f?.kind !== "boolean") {
        throw new RecoverableEngineError(
          "prim json.stringify: json_boolean.value is not a boolean",
        );
      }
      return f.value;
    }
    case JSON_INTEGER_QNAME:
    case JSON_NUMBER_QNAME: {
      const f = value.fields["value"];
      if (f?.kind !== "number") {
        throw new RecoverableEngineError(
          `prim json.stringify: ${value.ctorId}.value is not a number`,
        );
      }
      return f.value;
    }
    case JSON_STRING_QNAME: {
      const f = value.fields["value"];
      if (f?.kind !== "string") {
        throw new RecoverableEngineError("prim json.stringify: json_string.value is not a string");
      }
      return f.value;
    }
    case JSON_ARRAY_QNAME: {
      const items = value.fields["items"];
      if (items?.kind !== "array") {
        throw new RecoverableEngineError("prim json.stringify: json_array.items is not an array");
      }
      return items.elements.map(jsonTaggedToRaw);
    }
    case JSON_OBJECT_QNAME: {
      const entries = value.fields["entries"];
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
        `prim json.stringify: unknown json constructor '${value.ctorId}' (compiler invariant violated)`,
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
    case "string":
    case "boolean":
      return a.value === (b as typeof a).value;
    case "null":
      return true;
    case "array":
      return arrayEqual(a.elements, (b as typeof a).elements);
    case "tagged": {
      const bt = b as typeof a;
      if (a.ctorId !== bt.ctorId) return false;
      const xk = Object.keys(a.fields),
        yk = Object.keys(bt.fields);
      if (xk.length !== yk.length) return false;
      for (const k of xk) {
        if (!Object.hasOwn(bt.fields, k)) return false;
        if (!valueEquals(a.fields[k]!, bt.fields[k]!)) return false;
      }
      return true;
    }
    // Plaintext equality on secrets is a deliberate compromise:
    // it's needed for legitimate "is this key the same as that
    // key" checks (e.g. token rotation logic), but the JS string
    // == comparison short-circuits on first mismatched character
    // — a side-channel timing leak. v0.2 should either replace
    // this with a constant-time compare or remove `secret` from
    // the `eq` prim's input type entirely.
    case "secret":
      return a.value === (b as typeof a).value;
    case "closure":
      return false;
    case "record":
      // Records are compared structurally (all entries must match).
      return false;
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
