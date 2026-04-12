import type { ConstVal } from "./ir.js";

// ===========================================================================
// Value type
// ===========================================================================

export type Value =
  | null
  | boolean
  | number
  | string
  | Value[]
  | { [key: string]: Value };

// ===========================================================================
// Utilities
// ===========================================================================

export function isTruthy(v: Value): boolean {
  if (v === null || v === false) return false;
  if (typeof v === "number") return v !== 0;
  if (typeof v === "string") return v !== "";
  return true; // arrays and objects are always truthy
}

export function typeName(v: Value): string {
  if (v === null) return "null";
  if (typeof v === "boolean") return "boolean";
  if (typeof v === "number") return Number.isInteger(v) ? "integer" : "number";
  if (typeof v === "string") return "string";
  if (Array.isArray(v)) return "array";
  return "object";
}

export function toDisplayString(v: Value): string {
  if (v === null) return "null";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return String(v);
  if (typeof v === "string") return v;
  return JSON.stringify(v);
}

export function constToValue(c: ConstVal): Value {
  switch (c.tag) {
    case "Null": return null;
    case "Bool": return c.value;
    case "Int": return c.value;
    case "Num": return c.value;
    case "Str": return c.value;
  }
}

export function deepClone(v: Value): Value {
  if (v === null || typeof v !== "object") return v;
  if (Array.isArray(v)) return v.map(deepClone);
  const obj: Record<string, Value> = {};
  for (const [k, val] of Object.entries(v)) obj[k] = deepClone(val);
  return obj;
}

// ===========================================================================
// Arithmetic (Integer preservation: int op int → int, otherwise → number)
// ===========================================================================

function bothInt(a: Value, b: Value): boolean {
  return typeof a === "number" && typeof b === "number" &&
    Number.isInteger(a) && Number.isInteger(b);
}

function toNum(v: Value): number {
  if (typeof v === "number") return v;
  return 0;
}

export function valueAdd(a: Value, b: Value): Value {
  const na = toNum(a), nb = toNum(b);
  const result = na + nb;
  return bothInt(a, b) && Number.isInteger(result) ? result : result;
}

export function valueSub(a: Value, b: Value): Value {
  const na = toNum(a), nb = toNum(b);
  const result = na - nb;
  return bothInt(a, b) && Number.isInteger(result) ? result : result;
}

export function valueMul(a: Value, b: Value): Value {
  const na = toNum(a), nb = toNum(b);
  const result = na * nb;
  return bothInt(a, b) && Number.isInteger(result) ? result : result;
}

export function valueDiv(a: Value, b: Value): Value {
  return toNum(a) / toNum(b); // always float
}

export function valueMod(a: Value, b: Value): Value {
  const na = toNum(a), nb = toNum(b);
  if (nb === 0) return NaN;
  const result = ((na % nb) + nb) % nb; // Euclidean modulo
  return bothInt(a, b) ? result : result;
}

export function valueNeg(v: Value): Value {
  const n = toNum(v);
  return typeof v === "number" && Number.isInteger(v) ? -n : -n;
}

// ===========================================================================
// Comparison
// ===========================================================================

export function valueEq(a: Value, b: Value): boolean {
  if (a === null && b === null) return true;
  if (a === null || b === null) return false;
  if (typeof a !== typeof b) {
    // number comparison: int vs float
    if (typeof a === "number" && typeof b === "number") return a === b;
    return false;
  }
  if (typeof a === "number" && typeof b === "number") return a === b;
  if (typeof a === "boolean" && typeof b === "boolean") return a === b;
  if (typeof a === "string" && typeof b === "string") return a === b;
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false;
    return a.every((v, i) => valueEq(v, b[i]!));
  }
  if (!Array.isArray(a) && typeof a === "object" && !Array.isArray(b) && typeof b === "object") {
    const keysA = Object.keys(a);
    const keysB = Object.keys(b);
    if (keysA.length !== keysB.length) return false;
    return keysA.every((k) => k in b && valueEq(a[k]!, b[k]!));
  }
  return false;
}

export function valueLt(a: Value, b: Value): boolean {
  return toNum(a) < toNum(b);
}

// ===========================================================================
// String/Array concat
// ===========================================================================

export function valueConcat(a: Value, b: Value): Value {
  if (typeof a === "string" && typeof b === "string") return a + b;
  if (Array.isArray(a) && Array.isArray(b)) return [...a, ...b];
  // fallback: string concat
  return toDisplayString(a) + toDisplayString(b);
}
