// The FFI sidecar wire protocol: the typed messages the ffi reactor's transport and an external (FFI)
// sidecar process exchange, and the newline-delimited-JSON framing they ride on. Both directions carry more
// than one conversation now:
//
//   runtime → sidecar: `dispatch` (run this handler against this argument), `abort` (stop an in-flight
//     call), and `delegateResult` (the outcome of an inner agent call the sidecar asked for).
//   sidecar → runtime: the call's outcome (`result` / `throw` / `error` / `cancelled`), and `delegate`
//     (call another agent on the handler's behalf — the generic agent-call channel). A delegate's `callee`
//     is either a static agent NAME (`context.call`) or a first-class callable VALUE (`KatariAgent.call` —
//     the value rides as its own wire JSON and the ffi reactor resolves it to a target; no wired-in
//     `call_agent` indirection).
//
// A call is correlated by its `delegation` — the same id core's external proxy thread and the ffi reactor's
// pending-call use — which the sidecar echoes back, so the transport never needs a separate request-id
// table. An inner agent call is additionally correlated by a sidecar-minted `call` token (unique per sidecar
// process), which the runtime echoes on the `delegateResult`.
//
// Messages carry plain `Json` — the same wire form the HTTP boundary speaks. The engine's tagged `Value`
// is converted to/from `Json` by the ffi reactor at the transport seam (`valueToJson` / `jsonToValue`), so
// the sidecar and the user's FFI function only ever see plain values. The framing is one JSON object per
// line; `decodeSidecarMessage` returns `null` for a line it cannot parse (so a stray non-protocol line on
// the channel is skipped, never fatal).

import type { DelegateCallee, DelegateOutcome, Json } from "@katari-lang/types";
import { type DelegationId, toDelegationId } from "../ids.js";

// The delegate vocabulary is defined once in `@katari-lang/types` (`wire.ts`) — shared with the port's
// `protocol.ts`, so the two ends of the wire cannot drift — and re-exported here because the ffi
// reactor and the runner import their protocol vocabulary from this file.
export type { DelegateCallee, DelegateOutcome };

/** Runtime → sidecar. `dispatch` runs the handler `key` against `argument` for one external call; `abort`
 *  asks the sidecar to stop an in-flight call; `delegateResult` settles one inner agent call the sidecar
 *  made (`call` echoes the sidecar's token). A dispatch always means "run it": execution is at-most-once —
 *  a recovery never reaches the sidecar (the transport refuses it with an `error` completion instead). */
export type RuntimeMessage =
  | {
      kind: "dispatch";
      delegation: DelegationId;
      key: string;
      argument: Json | null;
    }
  | { kind: "abort"; delegation: DelegationId }
  | { kind: "delegateResult"; delegation: DelegationId; call: string; outcome: DelegateOutcome };

/** Sidecar → runtime: the outcome of one dispatched call — its `result`, a `throw` (a typed
 *  `prelude.throw` whose payload is `error`, caught by a katari-side handler), an `error` (becomes a
 *  panic), or a `cancelled` confirmation (the abort completed) — or a `delegate`: run another agent
 *  (`callee`) on the in-flight handler's behalf. */
export type SidecarMessage =
  | { kind: "result"; delegation: DelegationId; value: Json }
  | { kind: "throw"; delegation: DelegationId; error: Json }
  | { kind: "error"; delegation: DelegationId; message: string }
  | { kind: "cancelled"; delegation: DelegationId }
  | {
      kind: "delegate";
      delegation: DelegationId;
      call: string;
      callee: DelegateCallee;
      argument: Json | null;
    };

/** Frame one runtime→sidecar message as a line on the channel (one JSON object + newline). */
export function encodeRuntimeMessage(message: RuntimeMessage): string {
  return `${JSON.stringify(message)}\n`;
}

/** Parse one channel line as a sidecar→runtime message, or `null` if it is not well formed (the caller
 *  skips it). The `delegation` correlation and a `kind` are validated; a `value` / `argument` rides through
 *  as the trusted wire `Json` (this is the transport boundary, like the DB row codecs). */
export function decodeSidecarMessage(line: string): SidecarMessage | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return null;
  }
  if (!isRecord(parsed)) return null;
  const { kind, delegation } = parsed;
  if (typeof delegation !== "string") return null;
  const id = toDelegationId(delegation);
  switch (kind) {
    case "result":
      // Coerce a missing / `undefined` value to `null`: a sidecar that returned nothing must still decode to a
      // valid `Value` downstream — `jsonToValue(undefined)` inspects the reserved keys of `undefined` and throws — rather
      // than poisoning the reactor on a dropped field.
      return { kind, delegation: id, value: (parsed.value ?? null) as Json };
    case "throw":
      // Same coercion as `result`'s value: an absent payload must still decode to a valid `Value` downstream.
      return { kind, delegation: id, error: (parsed.error ?? null) as Json };
    case "error":
      return typeof parsed.message === "string"
        ? { kind, delegation: id, message: parsed.message }
        : null;
    case "cancelled":
      return { kind, delegation: id };
    case "delegate": {
      const callee = decodeCallee(parsed.callee);
      return typeof parsed.call === "string" && callee !== null
        ? {
            kind,
            delegation: id,
            call: parsed.call,
            callee,
            argument: (parsed.argument ?? null) as Json,
          }
        : null;
    }
    default:
      return null;
  }
}

/** Parse a delegate's `callee`, or `null` if malformed. A `value` callee's `callable` rides through as
 *  trusted wire `Json` (the ffi reactor decodes it, like an argument). */
function decodeCallee(value: unknown): DelegateCallee | null {
  if (!isRecord(value)) return null;
  switch (value.kind) {
    case "named":
      return typeof value.agent === "string"
        ? {
            kind: "named",
            agent: value.agent,
            ...(typeof value.reactor === "string" ? { reactor: value.reactor } : {}),
          }
        : null;
    case "value":
      return value.callable !== undefined
        ? { kind: "value", callable: value.callable as Json }
        : null;
    default:
      return null;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

/** Accumulates raw channel chunks and yields complete newline-terminated lines, retaining any trailing
 *  partial line until the rest of it arrives (a chunk boundary can split a message). */
export class LineBuffer {
  private pending = "";

  push(chunk: string): string[] {
    this.pending += chunk;
    const parts = this.pending.split("\n");
    this.pending = parts.pop() ?? "";
    return parts.filter((line) => line.length > 0);
  }
}
