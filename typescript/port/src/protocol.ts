// The FFI sidecar wire protocol, from the sidecar's end (the mirror of the runtime's `sidecar-protocol`).
// Both directions carry more than one conversation:
//
//   runtime → sidecar (`RuntimeMessage`): `dispatch` (run this handler), `abort` (stop an in-flight call),
//     and `delegateResult` (the outcome of an inner agent call this sidecar asked for).
//   sidecar → runtime (`SidecarMessage`): the call's outcome (`result` / `throw` / `error` / `cancelled`),
//     and `delegate` (call another agent on the in-flight handler's behalf).
//
// A call is correlated by its opaque `delegation` string, echoed back on every message about it; an inner
// agent call additionally by the sidecar-minted `call` token the runtime echoes on the `delegateResult`.
// Messages carry plain `Json` — the runtime converts its tagged value model at its own edge; the ergonomic
// wrappers a handler sees (`KatariFile` and friends) are this package's `values` layer over that wire form.
//
// Framing is one JSON object per line; `decodeRuntimeMessage` returns `null` for a line it cannot parse as
// a message (a stray non-protocol line on stdin is skipped, never fatal).

import type { Json } from "@katari-lang/types";

/** The outcome of one inner agent call: the callee's `result`, a `throw` (it raised a typed
 *  `prelude.throw` — the payload rides back so the handler catches, or rethrows, the typed error), an
 *  `error` (it panicked / could not be resolved), or `cancelled` (it was terminated — usually because the
 *  parent call is being cancelled). */
export type DelegateOutcome =
  | { kind: "result"; value: Json }
  | { kind: "throw"; error: Json }
  | { kind: "error"; message: string }
  | { kind: "cancelled" };

/** Runtime → sidecar. A dispatch always means "run it": execution is at-most-once — the runtime never
 *  re-dispatches a call after a restart (an interrupted call fails as a panic on the katari side, where the
 *  program decides whether to retry). */
export type RuntimeMessage =
  | {
      kind: "dispatch";
      delegation: string;
      key: string;
      argument: Json | null;
    }
  | { kind: "abort"; delegation: string }
  | { kind: "delegateResult"; delegation: string; call: string; outcome: DelegateOutcome };

/** What a handler's inner `delegate` calls, on the wire (mirror of the runtime's `DelegateCallee`):
 *   - `named` — a static agent NAME (`context.call`): a qualified name for the `core` reactor, or an
 *     external key for a call reactor (`ffi` / `http`); an absent `reactor` means `core`.
 *   - `value` — a first-class callable VALUE (`KatariAgent.call`): the received callable's own wire JSON
 *     (`$agent` / `$closure` / `$tool`), which the runtime resolves to a delegate target. No wired-in
 *     `call_agent` name — the callable dispatches itself. */
export type DelegateCallee =
  | { kind: "named"; agent: string; reactor?: string }
  | { kind: "value"; callable: Json };

/** Sidecar → runtime. A `throw` fails the call as a typed `prelude.throw` with `error` as its payload
 *  (caught by a katari-side handler); an `error` becomes a panic. A `delegate` runs another agent
 *  (`callee`) on the in-flight handler's behalf. */
export type SidecarMessage =
  | { kind: "result"; delegation: string; value: Json }
  | { kind: "throw"; delegation: string; error: Json }
  | { kind: "error"; delegation: string; message: string }
  | { kind: "cancelled"; delegation: string }
  | {
      kind: "delegate";
      delegation: string;
      call: string;
      callee: DelegateCallee;
      argument: Json | null;
    };

/** Frame one sidecar→runtime message as a line on the channel (one JSON object + newline). */
export function encodeSidecarMessage(message: SidecarMessage): string {
  return `${JSON.stringify(message)}\n`;
}

/** Parse one channel line as a runtime→sidecar message, or `null` if it is not well formed (the caller
 *  skips it). The `delegation` correlation and a `kind` are validated; an `argument` / `value` rides
 *  through as trusted wire Json. */
export function decodeRuntimeMessage(line: string): RuntimeMessage | null {
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
          }
        : null;
    case "abort":
      return { kind, delegation };
    case "delegateResult": {
      const outcome = decodeOutcome(record.outcome);
      return typeof record.call === "string" && outcome !== null
        ? { kind, delegation, call: record.call, outcome }
        : null;
    }
    default:
      return null;
  }
}

function decodeOutcome(value: unknown): DelegateOutcome | null {
  if (typeof value !== "object" || value === null) return null;
  const record = value as Record<string, unknown>;
  switch (record.kind) {
    case "result":
      return { kind: "result", value: (record.value ?? null) as Json };
    case "throw":
      // Same coercion as `result`'s value: an absent payload still decodes downstream.
      return { kind: "throw", error: (record.error ?? null) as Json };
    case "error":
      return typeof record.message === "string" ? { kind: "error", message: record.message } : null;
    case "cancelled":
      return { kind: "cancelled" };
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
