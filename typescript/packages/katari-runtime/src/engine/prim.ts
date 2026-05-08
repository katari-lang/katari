// Built-in primitive registry. Pure functions: `(args) => Value`.
//
// Bad arguments raise `RecoverableEngineError` so a single agent's mistake
// doesn't poison the version. Adding a prim here means coordinating with
// the Haskell side's `Katari.Builtins` registry — names must match.

import { match, P } from "ts-pattern";
import { RecoverableEngineError } from "./errors.js";
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
        return a % b;
      });
    case "negate": {
      const v = args["value"];
      if (v?.kind === "number") return { kind: "number", value: -v.value };
      throw new RecoverableEngineError("prim negate: invalid args");
    }
    case "eq":
      return { kind: "boolean", value: valueEquals(req(args, "left"), req(args, "right")) };
    case "neq":
      return { kind: "boolean", value: !valueEquals(req(args, "left"), req(args, "right")) };
    case "lt":
      return cmp(name, args, (a, b) => a < b);
    case "gt":
      return cmp(name, args, (a, b) => a > b);
    case "lte":
      return cmp(name, args, (a, b) => a <= b);
    case "gte":
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
      const left = args["left"], right = args["right"];
      if (left?.kind === "string" && right?.kind === "string") {
        return { kind: "string", value: left.value + right.value };
      }
      throw new RecoverableEngineError("prim concat: invalid args");
    }
    case "to_string": {
      const v = args["value"];
      if (v === undefined) throw new RecoverableEngineError("prim to_string: missing arg");
      return { kind: "string", value: valueToString(v) };
    }
    case "tuple_get": {
      const tuple = args["tuple"], index = args["index"];
      if (tuple?.kind === "tuple" && index?.kind === "number") {
        const elem = tuple.elements[index.value];
        if (elem === undefined) {
          throw new RecoverableEngineError("prim tuple_get: index out of bounds");
        }
        return elem;
      }
      throw new RecoverableEngineError("prim tuple_get: invalid args");
    }
    case "get_field": {
      const value = args["value"], field = args["field"];
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
    default:
      throw new RecoverableEngineError(`unknown prim: ${name}`);
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
  const left = args["left"], right = args["right"];
  if (left?.kind === "number" && right?.kind === "number") {
    return { kind: "number", value: op(left.value, right.value) };
  }
  throw new RecoverableEngineError(`prim ${name}: invalid args`);
}

function cmp(
  name: string,
  args: Record<string, Value>,
  op: (a: number, b: number) => boolean,
): Value {
  const left = args["left"], right = args["right"];
  if (left?.kind === "number" && right?.kind === "number") {
    return { kind: "boolean", value: op(left.value, right.value) };
  }
  throw new RecoverableEngineError(`prim ${name}: invalid args`);
}

function logical(
  name: string,
  args: Record<string, Value>,
  op: (a: boolean, b: boolean) => boolean,
): Value {
  const left = args["left"], right = args["right"];
  if (left?.kind === "boolean" && right?.kind === "boolean") {
    return { kind: "boolean", value: op(left.value, right.value) };
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
    .with([{ kind: "tuple" }, { kind: "tuple" }], ([x, y]) => arrayEqual(x.elements, y.elements))
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

export function valueToString(v: Value): string {
  return match(v)
    .with({ kind: "number" }, x => String(x.value))
    .with({ kind: "string" }, x => x.value)
    .with({ kind: "boolean" }, x => String(x.value))
    .with({ kind: "null" }, () => "null")
    .with({ kind: "tuple" }, x => `(${x.elements.map(valueToString).join(", ")})`)
    .with({ kind: "array" }, x => `[${x.elements.map(valueToString).join(", ")}]`)
    .with({ kind: "tagged" }, x =>
      `${x.ctorId}{${Object.entries(x.fields).map(([k, v]) => `${k}: ${valueToString(v)}`).join(", ")}}`,
    )
    .with({ kind: "closure" }, () => `<closure>`)
    .exhaustive();
}
