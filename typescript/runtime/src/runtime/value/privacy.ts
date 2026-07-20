// Privacy taint operations over the runtime `Value` model. The `private` marker (`PrivacyMarker`) is the
// single source of truth for "this value is secret". The compiler tracks the same information statically as
// the `private` attribute (a Comonad: a value observed through a private handle is itself private); the
// runtime mirrors it dynamically — the IR is type-erased, so the marker is how persistence (encrypt-at-rest),
// transport (reveal to FFI / redact at the user API), and logging know which values to protect.
//
// Propagation is monotonic: a value derived from any private input is itself private, and there is no pure
// way to launder it. These helpers are the primitives the engine uses to keep the marker faithful as values
// are read out of a private container, destructured, and fed through pure primitives.

import type { Value } from "./types.js";

/** Mark a value private at its top node (idempotent). Nested children keep their own markers; sealing /
 *  redaction fold over the whole tree, so marking the outermost node is enough to protect the value. */
export function markPrivate(value: Value): Value {
  return value.private === true ? value : { ...value, private: true };
}

/** Lift a child by a container's privacy: reading through a private handle yields a private value (the
 *  comonad's field projection). A no-op when the container is not private, so the child keeps its own marker. */
export function liftPrivacy(containerPrivate: boolean | undefined, child: Value): Value {
  return containerPrivate === true ? markPrivate(child) : child;
}

/** Whether any node in the value tree carries the private marker — the taint fold over a composite. A pure
 *  primitive whose argument record `isTainted` produces a private result (one secret input taints the output). */
export function isTainted(value: Value): boolean {
  if (value.private === true) return true;
  switch (value.kind) {
    case "record":
      return Object.values(value.fields).some(isTainted);
    case "array":
      return value.elements.some(isTainted);
    case "tool":
      return isTainted(value.context);
    default:
      return false;
  }
}
