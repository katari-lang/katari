// The FFI sidecar wire protocol, from the sidecar's end (the mirror of the runtime's `sidecar-protocol`).
// The runtime sends a `dispatch` (run this handler) or an `abort` (stop an in-flight call); the sidecar
// replies with the `result`, an `error`, or a `cancelled` confirmation. A call is correlated by its opaque
// `delegation` string, echoed back on the reply. Messages carry plain `Json` — the runtime converts its
// tagged value model at its own edge, so a handler here only ever sees plain values.
//
// Framing is one JSON object per line; `decodeRequest` returns `null` for a line it cannot parse as a
// request (a stray non-protocol line on stdin is skipped, never fatal).

import type { Json } from "@katari-lang/types";

/** Runtime → sidecar. */
export type SidecarRequest =
  | {
      kind: "dispatch";
      delegation: string;
      key: string;
      argument: Json | null;
      /** True on a recovery re-dispatch — the runtime restarted with this call in flight. */
      redispatch: boolean;
    }
  | { kind: "abort"; delegation: string };

/** Sidecar → runtime. */
export type SidecarReply =
  | { kind: "result"; delegation: string; value: Json }
  | { kind: "error"; delegation: string; message: string }
  | { kind: "cancelled"; delegation: string };

/** Frame one reply as a line on the channel (one JSON object + newline). */
export function encodeReply(reply: SidecarReply): string {
  return `${JSON.stringify(reply)}\n`;
}

/** Parse one channel line as a request, or `null` if it is not a well-formed request (the caller skips it).
 *  The `delegation` correlation and a `kind` are validated; `argument` rides through as trusted wire Json. */
export function decodeRequest(line: string): SidecarRequest | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null) return null;
  const record = parsed as Record<string, unknown>;
  const { kind, delegation } = record;
  if (typeof delegation !== "string") return null;
  switch (kind) {
    case "dispatch":
      return typeof record.key === "string"
        ? {
            kind,
            delegation,
            key: record.key,
            argument: (record.argument ?? null) as Json | null,
            redispatch: record.redispatch === true,
          }
        : null;
    case "abort":
      return { kind, delegation };
    default:
      return null;
  }
}

/** Accumulates raw channel chunks and yields complete newline-terminated lines, holding any trailing
 *  partial line until the rest arrives (a chunk boundary can split a message). */
export class LineBuffer {
  private pending = "";

  push(chunk: string): string[] {
    this.pending += chunk;
    const parts = this.pending.split("\n");
    this.pending = parts.pop() ?? "";
    return parts.filter((line) => line.length > 0);
  }
}
