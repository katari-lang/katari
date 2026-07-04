// The typed-error channel (`prelude.throw`). A prim that meets an anticipated, domain-specific failure
// throws `KatariThrow` carrying the error payload — a `data` value tagged with its domain error ctor
// (`prelude.json.parse_error`, ...) — and the prim seam raises the `prelude.throw` request for it. Every
// other JS error out of a prim stays a panic (the runtime's own failure signal, which a program can
// neither raise nor catch). This module is import-leaf so prims and the engine share it without cycles.

import type { QualifiedName } from "@katari-lang/types";
import type { Value } from "../value/types.js";

/** The request a typed error raises. Matches the stdlib `prelude.throw[T](error: T) -> never`
 *  declaration: handlers match this name (the payload type is erased — the payload value's ctor tag is
 *  the runtime discriminator), and an unhandled one fails the run with the payload. */
export const THROW_REQUEST = "prelude.throw" as QualifiedName;

/** The `{ error }` record a `throw` request carries (the request's one parameter). */
export function throwArgument(payload: Value): Value {
  return { kind: "record", fields: { error: payload } };
}

/** A domain error payload: a `data` value of the given error constructor carrying `{ message }` —
 *  the shape every stdlib error data (`parse_error` / `fetch_error` / `call_error` / ...) shares. */
export function errorData(ctor: string, message: string): Value {
  return {
    kind: "record",
    ctor: ctor as QualifiedName,
    fields: { message: { kind: "string", value: message } },
  };
}

/** Thrown by a prim implementation to raise `prelude.throw` with `payload` instead of a panic. */
export class KatariThrow extends Error {
  readonly payload: Value;

  constructor(payload: Value) {
    // The JS-facing message is a debugging courtesy (a KatariThrow escaping the prim seam is an engine
    // bug); the katari-facing content is the payload.
    super("katari throw");
    this.name = "KatariThrow";
    this.payload = payload;
  }
}
