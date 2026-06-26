// The FFI sidecar wire protocol: the typed messages the ffi reactor's transport and an external (FFI)
// sidecar process exchange, and the newline-delimited-JSON framing they ride on. The runtime sends a
// `dispatch` (run this handler against this argument) or an `abort` (stop an in-flight call); the sidecar
// replies with the `result`, an `error`, or a `cancelled` confirmation. A call is correlated by its
// `delegation` — the same id core's external proxy thread and the ffi reactor's pending-call use — which the
// sidecar echoes back, so the transport never needs a separate request-id table.
//
// Messages carry plain `Json` — the same wire form the HTTP boundary speaks. The engine's tagged `Value`
// is converted to/from `Json` by the ffi reactor at the transport seam (`valueToJson` / `jsonToValue`), so
// the sidecar and the user's FFI function only ever see plain values. The framing is one JSON object per
// line; `decodeReply` returns `null` for a line it cannot parse as a reply (so a stray non-protocol line on
// the channel is skipped, never fatal).

import type { Json } from "@katari-lang/types";
import { type DelegationId, toDelegationId } from "../ids.js";

/** Runtime → sidecar. `dispatch` runs the handler `key` against `argument` for one external call; `abort`
 *  asks the sidecar to stop an in-flight call. `redispatch` marks a recovery re-dispatch of a call that was
 *  already in flight before a crash (so a handler can dedupe a side effect). */
export type SidecarRequest =
  | {
      kind: "dispatch";
      delegation: DelegationId;
      key: string;
      argument: Json | null;
      redispatch: boolean;
    }
  | { kind: "abort"; delegation: DelegationId };

/** Sidecar → runtime, the outcome of one dispatched call: its `result`, an `error` (becomes a panic), or a
 *  `cancelled` confirmation (the abort completed). */
export type SidecarReply =
  | { kind: "result"; delegation: DelegationId; value: Json }
  | { kind: "error"; delegation: DelegationId; message: string }
  | { kind: "cancelled"; delegation: DelegationId };

/** Frame one request as a line on the channel (one JSON object + newline). */
export function encodeRequest(request: SidecarRequest): string {
  return `${JSON.stringify(request)}\n`;
}

/** Parse one channel line as a reply, or `null` if it is not a well-formed reply (the caller skips it). The
 *  `delegation` correlation and a `kind` are validated; the `value` rides through as the trusted wire `Json`
 *  (this is the transport boundary, like the DB row codecs). */
export function decodeReply(line: string): SidecarReply | null {
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
      // valid `Value` downstream — `jsonToValue(undefined)` runs `"$ref" in undefined` and throws — rather
      // than poisoning the reactor on a dropped field.
      return { kind, delegation: id, value: (parsed.value ?? null) as Json };
    case "error":
      return typeof parsed.message === "string"
        ? { kind, delegation: id, message: parsed.message }
        : null;
    case "cancelled":
      return { kind, delegation: id };
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
