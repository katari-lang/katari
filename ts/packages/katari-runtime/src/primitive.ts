import type { Value } from "./value.js";
import { toDisplayString } from "./value.js";

export type PrimitiveResult =
  | { tag: "Ok"; value: Value }
  | { tag: "RaiseRequest"; reqName: string; args: Value[] };

function ok(value: Value): PrimitiveResult {
  return { tag: "Ok", value };
}

function parseError(msg: string): PrimitiveResult {
  return { tag: "RaiseRequest", reqName: "prim.parse_error", args: [msg] };
}

export function callPrimitive(name: string, args: Value[]): PrimitiveResult {
  const a0 = args[0] ?? null;
  const a1 = args[1] ?? null;
  const a2 = args[2] ?? null;

  switch (name) {
    case "prim.to_string":
      return ok(toDisplayString(a0));

    case "prim.div": {
      if (typeof a0 === "number" && typeof a1 === "number") {
        if (a1 === 0) return ok(null);
        if (Number.isInteger(a0) && Number.isInteger(a1)) {
          // Euclidean floor division for integers
          return ok(Math.floor(a0 / a1) + (a0 % a1 !== 0 && (a0 ^ a1) < 0 ? 0 : 0));
        }
        return ok(Math.trunc(Math.floor(a0 / a1)));
      }
      return ok(null);
    }

    case "prim.mod": {
      if (typeof a0 === "number" && typeof a1 === "number") {
        if (a1 === 0) return ok(null);
        return ok(((a0 % a1) + a1) % a1);
      }
      return ok(null);
    }

    case "prim.parse_integer":
      if (typeof a0 === "string") {
        const n = parseInt(a0.trim(), 10);
        return isNaN(n) ? parseError(`failed to parse '${a0}' as integer`) : ok(n);
      }
      return parseError("parse_integer: expected string argument");

    case "prim.parse_number":
      if (typeof a0 === "string") {
        const n = parseFloat(a0.trim());
        return isNaN(n) ? parseError(`failed to parse '${a0}' as number`) : ok(n);
      }
      return parseError("parse_number: expected string argument");

    case "prim.parse_boolean":
      if (typeof a0 === "string") {
        if (a0 === "true") return ok(true);
        if (a0 === "false") return ok(false);
        return parseError(`failed to parse '${a0}' as boolean`);
      }
      return parseError("parse_boolean: expected string argument");

    case "prim.log.info":
      if (typeof a0 === "string") console.log(`[INFO] ${a0}`);
      return ok(null);

    case "prim.log.warn":
      if (typeof a0 === "string") console.warn(`[WARN] ${a0}`);
      return ok(null);

    case "prim.log.error":
      if (typeof a0 === "string") console.error(`[ERROR] ${a0}`);
      return ok(null);

    case "prim.length":
      return ok(Array.isArray(a0) ? a0.length : 0);

    case "prim.slice": {
      if (Array.isArray(a0) && typeof a1 === "number" && typeof a2 === "number") {
        const s = Math.min(Math.max(0, a1), a0.length);
        const e = Math.min(Math.max(0, a2), a0.length);
        return ok(s <= e ? a0.slice(s, e) : []);
      }
      return ok([]);
    }

    default:
      console.warn(`unknown primitive agent: ${name}`);
      return ok(null);
  }
}
