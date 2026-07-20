// The value-wire conventions: how the engine's tagged value model is rendered to / read from bare `Json` at
// the HTTP + FFI boundary. Defined ONCE here and shared by both sides that must agree byte-for-byte — the
// runtime codec (`runtime/value/codec.ts`) and the FFI port (`@katari-lang/port`'s `values.ts`) — so the two
// can never drift.
//
// Every reserved key lives in the `$katari_` namespace, so the wire vocabulary is disjoint from any key a
// program authors. A JSON object is exactly one variant, chosen by which reserved discriminator key it
// carries:
//
//   data value      { "$katari_constructor": name, "$katari_value": { …fields } }
//   file handle     { "$katari_ref": blobId, "$katari_semantic_kind": … }   (identity only; metadata lives runtime-side)
//   agent reference { "$katari_agent": name, "$katari_snapshot": …, "$katari_generics"? }
//   closure         { "$katari_closure": blockId, "$katari_scope_id": …, "$katari_snapshot": …, "$katari_module": …, "$katari_generics"? }
//   tool            { "$katari_tool": name, "$katari_reactor": …, "$katari_context": <value>, "$katari_snapshot": …,
//                     "$katari_description": …, "$katari_input_schema": …, "$katari_output_schema"? }
//   bare record     { …keys }                       (no reserved key present)
//
// A data value's fields nest under `VALUE_KEY`, so no field name can collide with a discriminator. A bare
// record carries its keys verbatim: a program never authors a `$katari_`-prefixed key, so the reserved
// namespace is exclusive and needs no escaping. `$katari_redacted` marks a subtree the `redact` policy
// withheld — a one-way sink, not part of the bijection.
//
// The FFI delegate vocabulary (`DelegateCallee` / `DelegateOutcome`, at the bottom) lives here for the
// same reason: both ends of the sidecar wire import the one definition instead of mirroring it by hand.

import type { Json } from "./json";

/** A `data` value's constructor name; its fields ride under `VALUE_KEY`. */
export const CONSTRUCTOR_KEY = "$katari_constructor";
/** A `file` value's blob id; its metadata rides in the plain sibling keys. */
export const FILE_KEY = "$katari_ref";
/** A top-level agent reference's qualified name. */
export const AGENT_KEY = "$katari_agent";
/** A closure reference's block id. */
export const CLOSURE_KEY = "$katari_closure";
/** A runtime-minted tool agent's runtime-decided name; its metadata rides in the plain sibling keys. */
export const TOOL_KEY = "$katari_tool";
/** The placeholder a private subtree collapses to under the `redact` policy (one-way, not decoded). */
export const REDACTED_KEY = "$katari_redacted";

// The metadata keys carried within a variant. Reserved like the discriminators (in the `$katari_`
// namespace), and read positionally once the variant is known.
export const VALUE_KEY = "$katari_value";
export const SEMANTIC_KIND_KEY = "$katari_semantic_kind";
export const SNAPSHOT_KEY = "$katari_snapshot";
export const GENERICS_KEY = "$katari_generics";
export const SCOPE_KEY = "$katari_scope_id";
export const MODULE_KEY = "$katari_module";
export const DESCRIPTION_KEY = "$katari_description";
export const INPUT_SCHEMA_KEY = "$katari_input_schema";
export const OUTPUT_SCHEMA_KEY = "$katari_output_schema";
export const REACTOR_KEY = "$katari_reactor";
export const CONTEXT_KEY = "$katari_context";

export type WireKind = "data" | "file" | "agent" | "closure" | "tool" | "redacted";

/** Which variant a JSON object denotes, from which reserved discriminator key it carries (checked in a
 *  fixed order; the keys are mutually exclusive in well-formed input). `undefined` means a bare record. */
export function wireKindOf(hasKey: (key: string) => boolean): WireKind | undefined {
  if (hasKey(CONSTRUCTOR_KEY)) return "data";
  if (hasKey(FILE_KEY)) return "file";
  if (hasKey(AGENT_KEY)) return "agent";
  if (hasKey(CLOSURE_KEY)) return "closure";
  if (hasKey(TOOL_KEY)) return "tool";
  if (hasKey(REDACTED_KEY)) return "redacted";
  return undefined;
}

// ─── the FFI delegate vocabulary ──────────────────────────────────────────────────────────────────
//
// The two payload shapes the runtime's `sidecar-protocol` and the FFI port's `protocol` must agree on
// when a handler calls back into the runtime. The full message unions stay per-side (the runtime brands
// its `delegation` correlation as a `DelegationId`; the port sees a plain string), but these two carry
// no branded ids, so they are defined once here — like the reserved keys — instead of kept in lockstep
// by comment.

/** What a handler's inner `delegate` calls, on the wire:
 *   - `named` — a static agent NAME (`context.call`): a qualified name for the `core` reactor, or an
 *     external key for a call reactor (`ffi` / `http`); an absent `reactor` means `core`.
 *   - `value` — a first-class callable VALUE (`KatariAgent.call`): a received agent / closure / tool
 *     reference riding as its own opaque wire `Json`, which the runtime resolves to a delegate target.
 *     No wired-in `call_agent` name — the callable dispatches itself. */
export type DelegateCallee =
  | { kind: "named"; agent: string; reactor?: string }
  | { kind: "value"; callable: Json };

/** The outcome of one inner agent call, echoed back to the sidecar: the callee's `result`, a `throw`
 *  (it raised a typed `prelude.throw` — the payload rides back so the handler catches, or rethrows,
 *  the typed error), an `error` (it panicked / could not be resolved), or `cancelled` (it was
 *  terminated — usually because the parent call itself is being cancelled). */
export type DelegateOutcome =
  | { kind: "result"; value: Json }
  | { kind: "throw"; error: Json }
  | { kind: "error"; message: string }
  | { kind: "cancelled" };
