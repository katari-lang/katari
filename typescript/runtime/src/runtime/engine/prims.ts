// The primitive registry: the built-in leaf operations the compiler desugars operators into (the
// `primitive.*` names) plus a few core helpers. A primitive receives the whole argument record and
// returns a value; binary ops read `left` / `right`, unary ops read `value` (the shape lowering emits).
// Implementations may be async (the env / blob primitives hit a store) — `PrimRunner.run` always returns
// a promise so the engine awaits uniformly. This registry is the seam: env / secret / file primitives
// are registered by the host with their stores; the pure arithmetic / string / logic set lives here.

import { valueEquals } from "../value/codec.js";
import type { Value } from "../value/types.js";
import type { PrimContext, PrimRunner } from "./context.js";

export type PrimImplementation = (argument: Value, context: PrimContext) => Value | Promise<Value>;

/** A `PrimRunner` over a name -> implementation map; unknown names throw. The pure built-ins are
 *  preloaded; a host adds stateful ones (env / file) via `register` before serving. */
export class PrimRegistry implements PrimRunner {
  private readonly implementations = new Map<string, PrimImplementation>();

  constructor() {
    for (const [name, implementation] of Object.entries(BUILTIN_PRIMITIVES)) {
      this.implementations.set(name, implementation);
    }
  }

  /** Register (or override) a primitive — e.g. a host-supplied `primitive.get_env` bound to its store. */
  register(name: string, implementation: PrimImplementation): void {
    this.implementations.set(name, implementation);
  }

  async run(name: string, argument: Value, context: PrimContext): Promise<Value> {
    const implementation = this.implementations.get(name);
    if (implementation === undefined) {
      throw new Error(`unknown primitive: ${name}`);
    }
    return implementation(argument, context);
  }
}

// ─── built-in pure primitives ─────────────────────────────────────────────────────────────────

const BUILTIN_PRIMITIVES: Record<string, PrimImplementation> = {
  "primitive.add": numeric((left, right) => left + right),
  "primitive.subtract": numeric((left, right) => left - right),
  "primitive.multiply": numeric((left, right) => left * right),
  "primitive.divide": numeric((left, right) => left / right),
  "primitive.modulo": numeric((left, right) => left % right),
  "primitive.negate": (argument) => {
    const value = numberOf(field(argument, "value"));
    return makeNumber(-value, field(argument, "value"));
  },
  "primitive.equal": (argument) => ({
    kind: "boolean",
    value: valueEquals(field(argument, "left"), field(argument, "right")),
  }),
  "primitive.not_equal": (argument) => ({
    kind: "boolean",
    value: !valueEquals(field(argument, "left"), field(argument, "right")),
  }),
  "primitive.less_than": comparison((left, right) => left < right),
  "primitive.less_or_equal": comparison((left, right) => left <= right),
  "primitive.greater_than": comparison((left, right) => left > right),
  "primitive.greater_or_equal": comparison((left, right) => left >= right),
  "primitive.and": (argument) => ({
    kind: "boolean",
    value: boolOf(field(argument, "left")) && boolOf(field(argument, "right")),
  }),
  "primitive.or": (argument) => ({
    kind: "boolean",
    value: boolOf(field(argument, "left")) || boolOf(field(argument, "right")),
  }),
  "primitive.not": (argument) => ({ kind: "boolean", value: !boolOf(field(argument, "value")) }),
  "primitive.concat": (argument) => ({
    kind: "string",
    value: stringOf(field(argument, "left")) + stringOf(field(argument, "right")),
  }),
  "primitive.to_string": (argument) => ({
    kind: "string",
    value: renderString(field(argument, "value")),
  }),
};

// ─── shape helpers ────────────────────────────────────────────────────────────────────────────

/** A binary numeric op, preserving integer-ness when both inputs are integers. */
function numeric(operation: (left: number, right: number) => number): PrimImplementation {
  return (argument) => {
    const left = field(argument, "left");
    const right = field(argument, "right");
    const result = operation(numberOf(left), numberOf(right));
    const integral =
      left.kind === "integer" && right.kind === "integer" && Number.isInteger(result);
    return integral ? { kind: "integer", value: result } : { kind: "number", value: result };
  };
}

/** A binary numeric comparison yielding a boolean. */
function comparison(operation: (left: number, right: number) => boolean): PrimImplementation {
  return (argument) => ({
    kind: "boolean",
    value: operation(numberOf(field(argument, "left")), numberOf(field(argument, "right"))),
  });
}

/** Re-tag a numeric result as integer or number to match the input that produced it. */
function makeNumber(result: number, like: Value): Value {
  return like.kind === "integer" && Number.isInteger(result)
    ? { kind: "integer", value: result }
    : { kind: "number", value: result };
}

function field(argument: Value, name: string): Value {
  if (argument.kind !== "record") {
    throw new Error(`primitive expected a record argument, got ${argument.kind}`);
  }
  const value = argument.fields[name];
  if (value === undefined) {
    throw new Error(`primitive argument is missing field "${name}"`);
  }
  return value;
}

function numberOf(value: Value): number {
  if (value.kind === "integer" || value.kind === "number") return value.value;
  throw new Error(`expected a number, got ${value.kind}`);
}

function boolOf(value: Value): boolean {
  if (value.kind === "boolean") return value.value;
  throw new Error(`expected a boolean, got ${value.kind}`);
}

function stringOf(value: Value): string {
  if (value.kind === "string") return value.value;
  throw new Error(`expected a string, got ${value.kind}`);
}

/** A display rendering for `to_string` — exact for scalars, a compact form for composites. */
function renderString(value: Value): string {
  switch (value.kind) {
    case "null":
      return "null";
    case "boolean":
    case "integer":
    case "number":
      return String(value.value);
    case "string":
      return value.value;
    default:
      return JSON.stringify(value);
  }
}
