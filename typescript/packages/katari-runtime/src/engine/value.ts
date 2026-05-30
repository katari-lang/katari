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
// agentLiteral carries only the qualified name (the snapshot axis is
// added in the per-project-module phase, Phase E).

import type { LiteralValue, QualifiedName } from "../ir/types.js";
import { hashText } from "../storage/hash.js";
import type { ClosureId } from "./id.js";

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
  | { kind: "tagged"; ctorId: QualifiedName; fields: Record<string, Value> }
  // Homogeneous map from string keys to values (surface `record[K, V]`).
  | { kind: "record"; entries: Record<string, Value> }
  // A closure has two forms (Phase E / #5 — content-addressed closures):
  //   - `closureId`: machine-local, an index into the current shard's
  //     `state.closures`. The form within a shard.
  //   - `ref`:       content-addressed. The closure's body block + snapshot +
  //     captured environment are serialized to a value-store blob; the ref is
  //     the handle. This is the form a closure takes when it crosses a shard
  //     boundary (an arg / return that escapes its home shard). The receiver
  //     materializes it back into a local closure (grafting the captured env
  //     into its own scopes). Content-addressing keeps the graph acyclic, so
  //     the eventual GC is reference-counting (no cross-shard mark-sweep).
  | { kind: "closure"; closureId: ClosureId }
  | { kind: "closure"; ref: RefRep }
  // Top-level callable reference (agent / prim / ctor / external).
  | { kind: "agentLiteral"; qualifiedName: QualifiedName };

/** A closure carried by content-addressed ref (its serialized body+env blob). */
export type ClosureValue = Extract<Value, { kind: "closure" }>;

/** Narrow a closure Value to its local form (asserts it is not a content ref). */
export function isLocalClosure(
  value: ClosureValue,
): value is { kind: "closure"; closureId: ClosureId } {
  return "closureId" in value;
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

/** Convert an IR LiteralValue to a runtime Value. */
export function literalToValue(literal: LiteralValue): Value {
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
      return { kind: "agentLiteral", qualifiedName: literal.qualifiedName };
  }
}

/**
 * Singleton null value. Frozen so accidental mutation by any consumer
 * cannot corrupt every other null reference in the system.
 */
export const NULL_VALUE: Value = Object.freeze({ kind: "null" }) as Value;
