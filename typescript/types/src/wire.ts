// The value-wire conventions: how the engine's tagged value model is rendered to / read from bare `Json` at
// the HTTP + FFI boundary. Defined ONCE here and shared by both sides that must agree byte-for-byte — the
// runtime codec (`runtime/value/codec.ts`) and the FFI port (`@katari-lang/port`'s `values.ts`) — so the two
// can never drift (the previous hand-mirrored copies had to be kept in lockstep by comment).
//
// A JSON object is exactly one variant, chosen by which reserved single-`$` discriminator key it carries:
//
//   data value      { "$constructor": name, "value": { …fields } }
//   file handle     { "$ref": blobId, "semanticKind": … }   (identity only; metadata lives runtime-side)
//   agent reference { "$agent": name, "snapshot": …, "generics"? }
//   closure         { "$closure": blockId, "scopeId": …, "snapshot": …, "module": …, "generics"? }
//   tool            { "$tool": name, "reactor": …, "context": <value>, "snapshot": …,
//                     "description": …, "inputSchema": …, "outputSchema"? }
//   bare record     { …escaped keys }              (no reserved key present)
//
// A data value's fields nest under `VALUE_KEY`, so no field name can collide with a discriminator. A bare
// record's own keys that begin with `$` are escaped (leading `$` doubled), so a record can never emit a
// single-`$` key — the discriminator namespace is exclusive. Only the discriminator key is `$`-prefixed;
// every metadata key (`value`, `semanticKind`, `snapshot`, …) is plain and read positionally within its
// variant. `$redacted` is the one exception: it marks a subtree the `redact` policy withheld — a one-way
// sink, not part of the bijection.
//
// The FFI delegate vocabulary (`DelegateCallee` / `DelegateOutcome`, at the bottom) lives here for the
// same reason: both ends of the sidecar wire import the one definition instead of mirroring it by hand.

import type { Json } from "./json";

/** A `data` value's constructor name; its fields ride under `VALUE_KEY`. */
export const CONSTRUCTOR_KEY = "$constructor";
/** A `file` value's blob id; its metadata rides in the plain sibling keys. */
export const FILE_KEY = "$ref";
/** A top-level agent reference's qualified name. */
export const AGENT_KEY = "$agent";
/** A closure reference's block id. */
export const CLOSURE_KEY = "$closure";
/** A runtime-minted tool agent's runtime-decided name; its metadata rides in the plain sibling keys. */
export const TOOL_KEY = "$tool";
/** The placeholder a private subtree collapses to under the `redact` policy (one-way, not decoded). */
export const REDACTED_KEY = "$redacted";

// Plain metadata keys (no `$`), read positionally within a variant.
export const VALUE_KEY = "value";
export const SEMANTIC_KIND_KEY = "semanticKind";
// The pre-slim file handle carried its blob metadata inline; no variant reads these three keys any
// more (metadata lives on the blob's runtime row). They survive only because the admin web UI still
// names them — rendering old persisted handles and labelling its uploads — and can be deleted once it
// reads the files API instead.
export const SIZE_KEY = "size";
export const HASH_KEY = "hash";
export const CONTENT_TYPE_KEY = "contentType";
export const SNAPSHOT_KEY = "snapshot";
export const GENERICS_KEY = "generics";
export const SCOPE_KEY = "scopeId";
export const MODULE_KEY = "module";
export const DESCRIPTION_KEY = "description";
export const INPUT_SCHEMA_KEY = "inputSchema";
export const OUTPUT_SCHEMA_KEY = "outputSchema";
export const REACTOR_KEY = "reactor";
export const CONTEXT_KEY = "context";

/** Escape a bare-record key for the wire: a key starting with `$` gets its leading `$` doubled, so a
 *  record can never emit a single-`$` key (that namespace is the reserved discriminators'). */
export function escapeRecordKey(key: string): string {
  return key.startsWith("$") ? `$${key}` : key;
}

/** Reverse `escapeRecordKey`: strip one leading `$` from a `$$…` key (our escaped output). A single-`$`
 *  key was never produced by our encoder, so if one reaches a record position it is an external
 *  producer's literal key — preserve it unchanged. */
export function unescapeRecordKey(key: string): string {
  return key.startsWith("$$") ? key.slice(1) : key;
}

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
 *   - `value` — a first-class callable VALUE (`KatariAgent.call`): a received `$agent` / `$closure` /
 *     `$tool` riding as its own opaque wire `Json`, which the runtime resolves to a delegate target.
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
