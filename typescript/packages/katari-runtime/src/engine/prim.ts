// Built-in primitive registry. Pure functions: `(args) => Value`.
//
// Bad arguments raise `RecoverableEngineError` so a single agent's mistake
// doesn't poison the version. Adding a prim here means coordinating with
// the Haskell side's `Katari.Builtins` registry — names must match.

import { match, P } from "ts-pattern";
import { RecoverableEngineError } from "./errors.js";
import { valueToRaw } from "../value-codec.js";
import type { Value } from "./value.js";

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
      const lhs = args["lhs"], rhs = args["rhs"];
      if (
        (lhs?.kind === "string" || lhs?.kind === "secret") &&
        (rhs?.kind === "string" || rhs?.kind === "secret")
      ) {
        const joined = lhs.value + rhs.value;
        const tainted = lhs.kind === "secret" || rhs.kind === "secret";
        return tainted
          ? { kind: "secret", value: joined }
          : { kind: "string", value: joined };
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
      const tuple = args["tuple"], index = args["index"];
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
    case "get_field": {
      const value = args["object"], field = args["field"];
      if (value?.kind === "tagged" && field?.kind === "string") {
        const v = value.fields[field.value];
        if (v === undefined) {
          throw new RecoverableEngineError(
            `prim get_field: field ${field.value} not found`,
          );
        }
        return v;
      }
      throw new RecoverableEngineError("prim get_field: invalid args");
    }
    case "record_empty": {
      return { kind: "record", entries: Object.create(null) };
    }
    case "record_get": {
      const r = req(args, "record"), key = req(args, "key");
      if (r.kind !== "record") {
        throw new RecoverableEngineError(
          `prim record_get: first argument must be a record, got ${r.kind}`,
        );
      }
      if (key.kind !== "string") {
        throw new RecoverableEngineError(
          `prim record_get: key must be a string, got ${key.kind}`,
        );
      }
      const v = r.entries[key.value];
      return v === undefined ? { kind: "null" } : v;
    }
    case "record_set": {
      const r = req(args, "record"), key = req(args, "key"), value = req(args, "value");
      if (r.kind !== "record") {
        throw new RecoverableEngineError(
          `prim record_set: first argument must be a record, got ${r.kind}`,
        );
      }
      if (key.kind !== "string") {
        throw new RecoverableEngineError(
          `prim record_set: key must be a string, got ${key.kind}`,
        );
      }
      const next: Record<string, Value> = Object.create(null);
      for (const [k, v] of Object.entries(r.entries)) {
        next[k] = v;
      }
      next[key.value] = value;
      return { kind: "record", entries: next };
    }
    case "record_remove": {
      const r = req(args, "record"), key = req(args, "key");
      if (r.kind !== "record") {
        throw new RecoverableEngineError(
          `prim record_remove: first argument must be a record, got ${r.kind}`,
        );
      }
      if (key.kind !== "string") {
        throw new RecoverableEngineError(
          `prim record_remove: key must be a string, got ${key.kind}`,
        );
      }
      if (!(key.value in r.entries)) return r;
      const next: Record<string, Value> = Object.create(null);
      for (const [k, v] of Object.entries(r.entries)) {
        if (k !== key.value) next[k] = v;
      }
      return { kind: "record", entries: next };
    }
    case "record_keys": {
      const r = req(args, "record");
      if (r.kind !== "record") {
        throw new RecoverableEngineError(
          `prim record_keys: argument must be a record, got ${r.kind}`,
        );
      }
      const keys = Object.keys(r.entries).map(
        (k): Value => ({ kind: "string", value: k }),
      );
      return { kind: "array", elements: keys };
    }
    case "record_has": {
      const r = req(args, "record"), key = req(args, "key");
      if (r.kind !== "record") {
        throw new RecoverableEngineError(
          `prim record_has: first argument must be a record, got ${r.kind}`,
        );
      }
      if (key.kind !== "string") {
        throw new RecoverableEngineError(
          `prim record_has: key must be a string, got ${key.kind}`,
        );
      }
      return { kind: "boolean", value: key.value in r.entries };
    }
    case "record_size": {
      const r = req(args, "record");
      if (r.kind !== "record") {
        throw new RecoverableEngineError(
          `prim record_size: argument must be a record, got ${r.kind}`,
        );
      }
      return { kind: "number", value: Object.keys(r.entries).length };
    }
    case "json_parse": {
      const text = req(args, "text");
      if (text.kind !== "string") {
        throw new RecoverableEngineError(
          `prim json_parse: argument must be a string, got ${text.kind}`,
        );
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(text.value);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        throw new RecoverableEngineError(`prim json_parse: invalid JSON: ${msg}`);
      }
      return jsonToValue(parsed);
    }
    case "json_stringify": {
      const value = req(args, "value");
      const raw = valueToJsonRaw(value);
      return { kind: "string", value: JSON.stringify(raw) };
    }
    default:
      throw new RecoverableEngineError(`unknown prim: ${name}`);
  }
}

// JSON → Value: maps standard JSON shapes to native Katari runtime
// values. Integral numbers stay as integers (no separate runtime
// distinction; type-pattern `integer(x)` checks via Number.isInteger).
// Objects become records (homogeneous map; the discriminator-routing
// done at the wire boundary doesn't apply here — we're past it).
function jsonToValue(raw: unknown): Value {
  if (raw === null) return { kind: "null" };
  if (typeof raw === "boolean") return { kind: "boolean", value: raw };
  if (typeof raw === "number") return { kind: "number", value: raw };
  if (typeof raw === "string") return { kind: "string", value: raw };
  if (Array.isArray(raw)) {
    return { kind: "array", elements: raw.map(jsonToValue) };
  }
  if (typeof raw === "object") {
    const entries: Record<string, Value> = Object.create(null);
    for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
      entries[k] = jsonToValue(v);
    }
    return { kind: "record", entries };
  }
  throw new RecoverableEngineError(
    `prim json_parse: unexpected JSON value of type ${typeof raw}`,
  );
}

// Value → JSON: only values with a canonical JSON representation. The
// Plan D wire codec (`$constructor` / `$agent` / `$secret`) is **not**
// applied here — `json_stringify` is for user-visible JSON output, not
// the internal wire format. Closures, agent literals, secrets, and
// tagged values (data ctors) have no JSON shape, so they're rejected.
function valueToJsonRaw(value: Value): unknown {
  switch (value.kind) {
    case "null":
      return null;
    case "boolean":
      return value.value;
    case "number":
      return value.value;
    case "string":
      return value.value;
    case "array":
      return value.elements.map(valueToJsonRaw);
    case "record": {
      const out: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(value.entries)) {
        out[k] = valueToJsonRaw(v);
      }
      return out;
    }
    case "tagged":
      throw new RecoverableEngineError(
        `prim json_stringify: cannot encode constructor '${value.ctorId}' as JSON`,
      );
    case "closure":
      throw new RecoverableEngineError(
        "prim json_stringify: cannot encode a closure as JSON",
      );
    case "agentLiteral":
      throw new RecoverableEngineError(
        "prim json_stringify: cannot encode an agent reference as JSON",
      );
    case "secret":
      throw new RecoverableEngineError(
        "prim json_stringify: refusing to encode a secret value as JSON (would launder taint)",
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
  const lhs = args["lhs"], rhs = args["rhs"];
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
  const lhs = args["lhs"], rhs = args["rhs"];
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
  const lhs = args["lhs"], rhs = args["rhs"];
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
  return match([a, b] as const)
    .with([{ kind: "number" }, { kind: "number" }], ([x, y]) => x.value === y.value)
    .with([{ kind: "string" }, { kind: "string" }], ([x, y]) => x.value === y.value)
    .with([{ kind: "boolean" }, { kind: "boolean" }], ([x, y]) => x.value === y.value)
    .with([{ kind: "null" }, { kind: "null" }], () => true)
    .with([{ kind: "array" }, { kind: "array" }], ([x, y]) => arrayEqual(x.elements, y.elements))
    .with([{ kind: "tagged" }, { kind: "tagged" }], ([x, y]) => {
      if (x.ctorId !== y.ctorId) return false;
      const xk = Object.keys(x.fields), yk = Object.keys(y.fields);
      if (xk.length !== yk.length) return false;
      for (const k of xk) {
        if (!Object.prototype.hasOwnProperty.call(y.fields, k)) return false;
        if (!valueEquals(x.fields[k]!, y.fields[k]!)) return false;
      }
      return true;
    })
    .with(
      [{ kind: "secret" }, { kind: "secret" }],
      // Plaintext equality on secrets is a deliberate compromise:
      // it's needed for legitimate "is this key the same as that
      // key" checks (e.g. token rotation logic), but the JS string
      // == comparison short-circuits on first mismatched character
      // — a side-channel timing leak. v0.2 should either replace
      // this with a constant-time compare or remove `secret` from
      // the `eq` prim's input type entirely.
      ([x, y]) => x.value === y.value,
    )
    .with([{ kind: "closure" }, P._], () => false)
    .with([P._, { kind: "closure" }], () => false)
    // Cross-kind comparison always false.
    .otherwise(() => false);
}

function arrayEqual(xs: Value[], ys: Value[]): boolean {
  if (xs.length !== ys.length) return false;
  for (let i = 0; i < xs.length; i++) {
    if (!valueEquals(xs[i]!, ys[i]!)) return false;
  }
  return true;
}

