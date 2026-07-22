// The primitive registry: the built-in leaf operations the compiler desugars operators into (the
// `prelude.*` names) plus the stdlib sub-module prims (`interop-prims.ts` — json / record / array /
// string / get_metadata). Implementations may be async (the env / blob prims hit a store) —
// `PrimRunner.run` always returns a promise so the engine awaits uniformly. This registry is the
// seam: env / secret / file primitives are registered by the host with their stores; everything
// wired-in lives here or in `interop-prims.ts`.

import { valueEquals } from "../value/codec.js";
import type { Value } from "../value/types.js";
import type { PrimContext, PrimImplementation, PrimRunner } from "./context.js";
import { INTEROP_PRIMITIVES } from "./interop-prims.js";
import {
  boolOf,
  compareScalarKeys,
  field,
  numberOf,
  type ScalarKey,
  scalarKeyOfNumber,
  scalarKeyOfText,
  stringOf,
} from "./prim-helpers.js";

export type { PrimImplementation } from "./context.js";

/** A `PrimRunner` over a name -> implementation map; unknown names throw. The wired-in built-ins are
 *  preloaded; a host adds stateful ones (env / file) via `register` before serving. */
export class PrimRegistry implements PrimRunner {
  private readonly implementations = new Map<string, PrimImplementation>();

  constructor() {
    for (const [name, implementation] of Object.entries(BUILTIN_PRIMITIVES)) {
      this.implementations.set(name, implementation);
    }
    for (const [name, implementation] of Object.entries(INTEROP_PRIMITIVES)) {
      this.implementations.set(name, implementation);
    }
  }

  /** Register (or override) a primitive — e.g. a host-supplied `prelude.get_env` bound to its store. */
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
  "prelude.add": numeric((left, right) => left + right),
  "prelude.subtract": numeric((left, right) => left - right),
  "prelude.multiply": numeric((left, right) => left * right),
  // A zero divisor panics (fail fast) rather than minting Infinity / NaN — a non-finite number has no
  // JSON representation, so letting it through only defers the failure to a far-away encode.
  "prelude.divide": numeric((left, right) => {
    if (right === 0) throw new Error("division by zero");
    return left / right;
  }),
  "prelude.modulo": numeric((left, right) => {
    if (right === 0) throw new Error("modulo by zero");
    // The declared contract is FLOOR modulo (the result carries the divisor's sign): -1 % 12 is 11,
    // which is what calendar arithmetic (month folding, day-of-week) counts on. JS's `%` truncates
    // toward zero instead, so the quotient is floored explicitly.
    return left - Math.floor(left / right) * right;
  }),
  "prelude.negate": (argument) => {
    const value = numberOf(field(argument, "value"));
    return makeNumber(-value, field(argument, "value"));
  },
  "prelude.equal": (argument) => ({
    kind: "boolean",
    value: valueEquals(field(argument, "left"), field(argument, "right")),
  }),
  "prelude.not_equal": (argument) => ({
    kind: "boolean",
    value: !valueEquals(field(argument, "left"), field(argument, "right")),
  }),
  "prelude.less_than": comparison((ordering) => ordering < 0),
  "prelude.less_or_equal": comparison((ordering) => ordering <= 0),
  "prelude.greater_than": comparison((ordering) => ordering > 0),
  "prelude.greater_or_equal": comparison((ordering) => ordering >= 0),
  "prelude.and": (argument) => ({
    kind: "boolean",
    value: boolOf(field(argument, "left")) && boolOf(field(argument, "right")),
  }),
  "prelude.or": (argument) => ({
    kind: "boolean",
    value: boolOf(field(argument, "left")) || boolOf(field(argument, "right")),
  }),
  "prelude.not": (argument) => ({ kind: "boolean", value: !boolOf(field(argument, "value")) }),
  // Async because an operand may be a blob-backed string (a >4KB body interpolated or `++`-ed).
  "prelude.concat": async (argument, context) => ({
    kind: "string",
    value:
      (await stringContentOf(field(argument, "left"), context)) +
      (await stringContentOf(field(argument, "right"), context)),
  }),
  // ─── prelude.math ─────────────────────────────────────────────────────────────────────────
  "prelude.math.abs": (argument) => {
    const value = field(argument, "value");
    return makeNumber(Math.abs(numberOf(value)), value);
  },
  "prelude.math.min": numeric((left, right) => Math.min(left, right)),
  "prelude.math.max": numeric((left, right) => Math.max(left, right)),
  "prelude.math.floor": (argument) => ({
    kind: "integer",
    // `+ 0` normalizes negative zero (e.g. floor of -0) to plain 0.
    value: Math.floor(numberOf(field(argument, "value"))) + 0,
  }),
  "prelude.math.ceil": (argument) => ({
    kind: "integer",
    // `+ 0` normalizes negative zero (ceil of -0.5 is -0 in JS) to plain 0.
    value: Math.ceil(numberOf(field(argument, "value"))) + 0,
  }),
  "prelude.math.round": (argument) => {
    // Half away from zero (the declared grade-school rule); JS Math.round is half toward +Infinity,
    // which would send -2.5 to -2. `+ 0` keeps a rounded -0.4 from minting negative zero.
    const value = numberOf(field(argument, "value"));
    return { kind: "integer", value: Math.sign(value) * Math.round(Math.abs(value)) + 0 };
  },
  "prelude.string.to_string": async (argument, context) => {
    const value = field(argument, "value");
    // A blob-backed string renders as its content, like every other string-accepting prim.
    if (value.kind === "ref" && value.semanticKind === "string") {
      const bytes = await context.blobs.get(context.projectId, value.blobId);
      return { kind: "string", value: new TextDecoder().decode(bytes) };
    }
    return { kind: "string", value: renderString(value) };
  },
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

/** A binary comparison over the scalar order (`compareScalarKeys` — numbers numerically, strings by
 *  code point, numbers before strings), yielding a boolean. Async because a string operand may be
 *  blob-backed and needs materialising. */
function comparison(operation: (ordering: number) => boolean): PrimImplementation {
  return async (argument, context) => ({
    kind: "boolean",
    value: operation(
      compareScalarKeys(
        await comparableKeyOf(field(argument, "left"), context),
        await comparableKeyOf(field(argument, "right"), context),
      ),
    ),
  });
}

/** The comparison key of a scalar operand: a number as itself, a string — possibly blob-backed, like
 *  every string-accepting prim — as its materialised content. */
async function comparableKeyOf(value: Value, context: PrimContext): Promise<ScalarKey> {
  if (value.kind === "string" || (value.kind === "ref" && value.semanticKind === "string")) {
    return scalarKeyOfText(await stringContentOf(value, context));
  }
  return scalarKeyOfNumber(value);
}

/** A possibly blob-backed string operand, materialised (any other kind is the usual shape panic). */
async function stringContentOf(value: Value, context: PrimContext): Promise<string> {
  if (value.kind === "ref" && value.semanticKind === "string") {
    const bytes = await context.blobs.get(context.projectId, value.blobId);
    return new TextDecoder().decode(bytes);
  }
  return stringOf(value);
}

/** Re-tag a numeric result as integer or number to match the input that produced it. */
function makeNumber(result: number, like: Value): Value {
  return like.kind === "integer" && Number.isInteger(result)
    ? { kind: "integer", value: result }
    : { kind: "number", value: result };
}

/** The `to_string` rendering: exact for scalars; a composite is a type error upstream (the declared
 *  parameter is `null | boolean | number | string`) — for one, `json.stringify(json.encode(...))` is
 *  the supported path. */
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
      throw new Error(
        `to_string takes a scalar (null / boolean / number / string), got ${value.kind}`,
      );
  }
}
