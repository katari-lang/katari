// Argument-shape helpers shared by the primitive implementations (`prims.ts`, `interop-prims.ts`).
// A primitive receives its whole argument record; these read one labelled field and enforce its
// scalar kind, throwing the message the prim layer turns into a `panic`.

import type { Value } from "../value/types.js";

export function field(argument: Value, name: string): Value {
  if (argument.kind !== "record") {
    throw new Error(`primitive expected a record argument, got ${argument.kind}`);
  }
  const value = argument.fields[name];
  if (value === undefined) {
    throw new Error(`primitive argument is missing field "${name}"`);
  }
  return value;
}

export function numberOf(value: Value): number {
  if (value.kind === "integer" || value.kind === "number") return value.value;
  throw new Error(`expected a number, got ${value.kind}`);
}

export function boolOf(value: Value): boolean {
  if (value.kind === "boolean") return value.value;
  throw new Error(`expected a boolean, got ${value.kind}`);
}

export function stringOf(value: Value): string {
  if (value.kind === "string") return value.value;
  throw new Error(`expected a string, got ${value.kind}`);
}

export function integerOf(value: Value): number {
  if (value.kind === "integer") return value.value;
  throw new Error(`expected an integer, got ${value.kind}`);
}

export function arrayOf(value: Value): Value[] {
  if (value.kind === "array") return value.elements;
  throw new Error(`expected an array, got ${value.kind}`);
}

export function recordOf(value: Value): Record<string, Value> {
  if (value.kind === "record") return value.fields;
  throw new Error(`expected a record, got ${value.kind}`);
}

// ─── the scalar comparison order ──────────────────────────────────────────────────────────────
//
// The one total order behind the comparison operators (`prelude.less_than` and friends) and the sort
// prims (`prelude.array.sort` / `sort_entries`): numbers numerically, strings by Unicode code point,
// and every number before every string — so a `number | string` union instantiation stays
// deterministic instead of panicking. A key is materialised once per value (a string operand may be
// blob-backed, so the caller reads it through its string reader before comparing).

/** A comparison-ready scalar: a materialised string, or a number (`text` null). */
export type ScalarKey = { text: string | null; numeric: number };

export function scalarKeyOfNumber(value: Value): ScalarKey {
  return { text: null, numeric: numberOf(value) };
}

export function scalarKeyOfText(text: string): ScalarKey {
  return { text: text, numeric: 0 };
}

/** The usual negative / zero / positive ordering number over two keys. */
export function compareScalarKeys(left: ScalarKey, right: ScalarKey): number {
  if ((left.text === null) !== (right.text === null)) return left.text === null ? -1 : 1;
  if (left.text !== null && right.text !== null) return compareByCodePoint(left.text, right.text);
  return left.numeric < right.numeric ? -1 : left.numeric > right.numeric ? 1 : 0;
}

/** Lexicographic comparison by Unicode code point — the string prims' declared unit (`string.length`
 *  counts code points), which differs from JavaScript's UTF-16 code-unit `<` when a surrogate pair
 *  meets a BMP character at U+E000 or above. */
export function compareByCodePoint(left: string, right: string): number {
  const leftIterator = left[Symbol.iterator]();
  const rightIterator = right[Symbol.iterator]();
  for (;;) {
    const leftStep = leftIterator.next();
    const rightStep = rightIterator.next();
    if (leftStep.done === true && rightStep.done === true) return 0;
    if (leftStep.done === true) return -1;
    if (rightStep.done === true) return 1;
    const leftPoint = leftStep.value.codePointAt(0) ?? 0;
    const rightPoint = rightStep.value.codePointAt(0) ?? 0;
    if (leftPoint !== rightPoint) return leftPoint - rightPoint;
  }
}
