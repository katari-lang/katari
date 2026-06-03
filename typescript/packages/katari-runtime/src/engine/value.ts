// Runtime Value type.
//
// Design (v0.1.0 value-model rewrite — see docs/2026-05-30-value-and-streaming.md):
//   - Byte-sequence kinds (`string` / `file` / `secret`) carry a `rep`
//     (`BytesRep`) instead of an inline `value`. `BytesRep` is either an
//     inline UTF-8 text or a content-addressed `ref` to a blob.
//   - v0.1.0 only ever produces the `inline` rep (no storage / promotion
//     yet). `file` always uses a ref by design, so file values do not
//     exist until the value store lands (Phase B). `secret` is inline-only
//     in v0.1.0.
//   - `ref` carries the owner module + id + content hash/size. `project`
//     is NOT on the ref (ambient context). v0.1.0 refs are always
//     `complete` (building/streaming is v0.2).
//
// closure values are machine-local id references into `state.closures`;
// agentLiteral carries the qualified name PLUS the snapshot it resolves
// against (the external form). The snapshot is supplied where the value is
// created — `literalToValue` reads it from the shard's `state.snapshot`.

import type { LiteralValue, QualifiedName } from "../ir/types.js";
import { hashText } from "../storage/hash.js";

/** Owner module of a value reference. `project` is ambient (not carried). */
export type RefModule = "core" | "ffi" | "api";

/**
 * Content-addressed reference to a blob. v0.1.0 refs are always complete
 * (hash/size known). The bytes live in the value store; this is just the
 * handle. See docs/2026-05-30-value-and-streaming.md §3.
 */
export type RefRep = {
  kind: "ref";
  module: RefModule;
  id: string;
  /** Content hash (complete). Used for dedup + equality. */
  hash: string;
  size: number;
  contentType?: string;
};

/**
 * Storage state of a byte sequence: inline UTF-8 text, or a ref to a blob.
 * file is always a ref (no inline); string/secret are inline in v0.1.0.
 */
export type BytesRep = { kind: "inline"; text: string } | RefRep;

export type Value =
  | { kind: "number"; value: number }
  | { kind: "boolean"; value: boolean }
  | { kind: "null" }
  // Byte sequences. `string` is UTF-8 text; `file` is opaque bytes (always
  // a ref); `secret` is an opaque credential (inline-only in v0.1.0).
  | { kind: "string"; rep: BytesRep }
  | { kind: "file"; rep: RefRep }
  | { kind: "secret"; rep: BytesRep }
  // Tuples and arrays share one runtime variant — both ordered sequences
  // of 'Value's. The static type system enforces arity / homogeneity at
  // compile time. A JSON array decodes to this variant directly.
  | { kind: "array"; elements: Value[] }
  // Map layer — object / data / record share one string-keyed Value, mirroring
  // the seq layer's single `array`. `entries` is the field/key→value map; an
  // optional `ctor` carries the data constructor's qualified name. A bare
  // object / record value has no `ctor`; a `data` value carries it. The static
  // type system enforces which keys / ctor are required (`data <: object <:
  // record`). A JSON object decodes here ( `$constructor` ⇒ `ctor`).
  | { kind: "record"; entries: Record<string, Value>; ctor?: QualifiedName }
  // A closure is ALWAYS a content-addressed ref (Phase E / #5 — content-
  // addressed closures). Its body block + snapshot + captured environment are
  // serialized to a value-store blob at the closure literal (make-closure); the
  // ref is the handle that flows everywhere. Invoking it materializes the blob
  // into the receiving shard (grafting the captured env). Content-addressing
  // keeps the graph acyclic, so the eventual GC is reference-counting (no
  // cross-shard mark-sweep). There is no machine-local closure VALUE form — the
  // shard-local dispatch record (`state.closures`) is keyed by the engine's
  // `closure:N` agent def id, never by a Value.
  | { kind: "closure"; ref: RefRep }
  // Top-level callable reference (agent / prim / ctor / external). An agent
  // value is the EXTERNAL form: it carries the snapshot it resolves against
  // (`qualifiedName@snapshot` on the wire), set when the value is born — from
  // the shard's `state.snapshot` at a source literal, or the `@snapshot` stamp
  // on a received wire value. The bare `qualifiedName` is the INTERNAL id used
  // for IR-entries / dispatch lookup. `snapshot` is absent only for an
  // internal-form value that leaked to the boundary (delegating it then fails
  // with an un-stamped-target error — the same "not found" outcome).
  | { kind: "agentLiteral"; qualifiedName: QualifiedName; snapshot?: string };

/** A closure carried by content-addressed ref (its serialized body+env blob). */
export type ClosureValue = Extract<Value, { kind: "closure" }>;

/** A value-reference handle (owner module + id) — the unit the GC ownership
 *  layer tracks (a ref's identity, independent of its content hash). */
export type RefHandle = { module: RefModule; id: string };

/**
 * Collect every content-ref handle reachable in `value` (a `string`/`file`
 * carried as a ref, or a `closure`), recursing through array / tagged / record.
 * Inline byte sequences and scalars carry no ref. Used by the GC ownership
 * layer to find the refs a crossing value (delegateAck / escalate) carries, and
 * the refs a closure blob captures. Duplicates are not de-duped (callers use a
 * Set if needed).
 */
export function collectRefs(value: Value): RefHandle[] {
  const out: RefHandle[] = [];
  const walk = (v: Value): void => {
    switch (v.kind) {
      case "string":
      case "secret":
        if (v.rep.kind === "ref") out.push({ module: v.rep.module, id: v.rep.id });
        return;
      case "file":
        out.push({ module: v.rep.module, id: v.rep.id });
        return;
      case "closure":
        out.push({ module: v.ref.module, id: v.ref.id });
        return;
      case "array":
        for (const e of v.elements) walk(e);
        return;
      case "record":
        for (const e of Object.values(v.entries)) walk(e);
        return;
      default:
        return;
    }
  };
  walk(value);
  return out;
}

// ─── Byte-sequence helpers ──────────────────────────────────────────────────
//
// v0.1.0 byte sequences are inline-only at construction. These helpers keep
// the (many) call sites terse and centralise the rep handling so the Phase D
// materialize path (ref → fetch) has one place to grow.

/** Construct an inline `string` value. */
export function mkString(text: string): Value {
  return { kind: "string", rep: { kind: "inline", text } };
}

/** Construct an inline `secret` value. */
export function mkSecret(text: string): Value {
  return { kind: "secret", rep: { kind: "inline", text } };
}

/** True for `string` / `secret` / `file` (the byte-sequence kinds). */
export function isBytesValue(
  v: Value,
): v is Extract<Value, { kind: "string" | "secret" | "file" }> {
  return v.kind === "string" || v.kind === "secret" || v.kind === "file";
}

/**
 * Read the inline UTF-8 text of a `string` / `secret` value.
 *
 * v0.1.0: byte-sequence values are always inline, so this is total for
 * string/secret. Once refs exist (Phase B/D) callers that may see a ref
 * must use the async materialize path instead; this helper throws on a
 * ref so the gap surfaces loudly rather than silently mis-reading.
 */
export function inlineText(v: Value): string {
  if (v.kind !== "string" && v.kind !== "secret") {
    throw new Error(`inlineText: expected string/secret, got ${v.kind}`);
  }
  if (v.rep.kind !== "inline") {
    throw new Error("inlineText: value is a ref (not yet materializable — Phase D)");
  }
  return v.rep.text;
}

/** Like 'inlineText' but returns null for non-string / non-inline values. */
export function tryInlineString(v: Value): string | null {
  if (v.kind === "string" && v.rep.kind === "inline") return v.rep.text;
  return null;
}

// ─── Content addressing (metadata-only, no fetch) ───────────────────────────
//
// `string` / `secret` equality and `match` against string literals compare
// CONTENT, but never need the bytes: an inline rep hashes its own UTF-8 text
// and a ref carries its precomputed hash, so a hash comparison settles it
// without touching the value store. (Combining ops — concat / format — DO need
// the bytes; those await `materializeBytes` once the async quantum lands.)

/** Content hash of a byte-sequence rep. Inline → hash its text; ref → its hash. */
export function bytesHash(rep: BytesRep): string {
  return rep.kind === "inline" ? hashText(rep.text) : rep.hash;
}

/**
 * Content equality of two byte-sequence reps. Both inline is a direct text
 * compare; any ref involved falls back to hash equality. No fetch.
 */
export function bytesContentEqual(a: BytesRep, b: BytesRep): boolean {
  if (a.kind === "inline" && b.kind === "inline") return a.text === b.text;
  return bytesHash(a) === bytesHash(b);
}

/** Whether a byte-sequence rep equals a known inline text (match literals). No fetch. */
export function bytesEqualsText(rep: BytesRep, text: string): boolean {
  return rep.kind === "inline" ? rep.text === text : rep.hash === hashText(text);
}

/** Convert an IR LiteralValue to a runtime Value. `snapshot` is the shard's
 *  current snapshot, stamped onto an agent literal so the value carries its
 *  external form (`qname@snapshot`); ignored for every other literal kind. */
export function literalToValue(literal: LiteralValue, snapshot?: string): Value {
  switch (literal.kind) {
    case "literalValueInteger":
      return { kind: "number", value: literal.integer };
    case "literalValueNumber":
      return { kind: "number", value: literal.number };
    case "literalValueString":
      return mkString(literal.string);
    case "literalValueBoolean":
      return { kind: "boolean", value: literal.boolean };
    case "literalValueNull":
      return { kind: "null" };
    case "literalValueAgent":
      return { kind: "agentLiteral", qualifiedName: literal.qualifiedName, snapshot };
  }
}

/**
 * Singleton null value. Frozen so accidental mutation by any consumer
 * cannot corrupt every other null reference in the system.
 */
export const NULL_VALUE: Value = Object.freeze({ kind: "null" }) as Value;
