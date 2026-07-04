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
