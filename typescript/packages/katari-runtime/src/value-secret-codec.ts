// Typed encrypt / decrypt walkers for the runtime `Value` tree at the
// storage boundary.
//
// Each Module's persistence layer calls 'encryptValueTree' before handing a
// Value to storage and 'decryptValueTree' after reading one back. Storage
// only ever sees the 'EncryptedValue' shape, which carries '$envelope'
// (= AES-GCM ciphertext) in place of the plaintext 'secret' variant.
//
// Byte-sequence values carry a `rep` (inline text / ref). Only `secret`
// holds a credential that needs encryption; `string` / `file` reps contain
// no secrets (a ref is just module/id/hash/size, inline string is plain
// text), so they pass through unchanged. v0.1.0 secrets are inline-only.

import type { ClosureId } from "./engine/id.js";
import { type BytesRep, mkSecret, type RefRep, type Value } from "./engine/value.js";
import type { QualifiedName } from "./ir/types.js";
import { decryptSecret, encryptSecret } from "./secret-crypto.js";

/** Storage-form replacement for the 'secret' Value variant (AES-GCM ciphertext). */
export type EncryptedSecret = { readonly $envelope: string };

/** Mirror of 'Value' where every 'secret' has been replaced by 'EncryptedSecret'. */
export type EncryptedValue =
  | { kind: "number"; value: number }
  | { kind: "boolean"; value: boolean }
  | { kind: "null" }
  | { kind: "string"; rep: BytesRep }
  | { kind: "file"; rep: RefRep }
  | { kind: "array"; elements: EncryptedValue[] }
  | { kind: "record"; entries: Record<string, EncryptedValue>; ctor?: QualifiedName }
  | { kind: "closure"; closureId: ClosureId; generics?: Record<string, import("./json.js").Json> }
  | { kind: "agentLiteral"; qualifiedName: QualifiedName; snapshot?: string }
  | EncryptedSecret;

/**
 * Walk a 'Value' tree and encrypt every 'secret' leaf into the storage
 * envelope form. Containers recurse. Pure.
 */
export function encryptValueTree(value: Value): EncryptedValue {
  switch (value.kind) {
    case "number":
    case "boolean":
    case "null":
    case "string":
    case "file":
    case "closure":
    case "agentLiteral":
      return value;
    case "array":
      return { kind: "array", elements: value.elements.map(encryptValueTree) };
    case "record": {
      const entries: Record<string, EncryptedValue> = {};
      for (const [k, v] of Object.entries(value.entries)) entries[k] = encryptValueTree(v);
      return value.ctor !== undefined
        ? { kind: "record", entries, ctor: value.ctor }
        : { kind: "record", entries };
    }
    case "secret":
      if (value.rep.kind !== "inline") {
        throw new Error("encryptValueTree: secret ref not supported in v0.1.0");
      }
      return { $envelope: encryptSecret(value.rep.text) };
  }
}

/**
 * Inverse of 'encryptValueTree'. Throws via 'secret-crypto' if any envelope
 * fails AES-GCM authentication.
 */
export function decryptValueTree(encrypted: EncryptedValue): Value {
  if ("$envelope" in encrypted) {
    return mkSecret(decryptSecret(encrypted.$envelope));
  }
  switch (encrypted.kind) {
    case "number":
    case "boolean":
    case "null":
    case "string":
    case "file":
    case "closure":
    case "agentLiteral":
      return encrypted;
    case "array":
      return { kind: "array", elements: encrypted.elements.map(decryptValueTree) };
    case "record": {
      const entries: Record<string, Value> = {};
      for (const [k, v] of Object.entries(encrypted.entries)) entries[k] = decryptValueTree(v);
      return encrypted.ctor !== undefined
        ? { kind: "record", entries, ctor: encrypted.ctor }
        : { kind: "record", entries };
    }
  }
}

/**
 * Replace every encrypted-secret envelope with a `<redacted:HHHHHHHH>`
 * placeholder. Used at HTTP wire boundaries that surface stored rows to
 * operators / clients (must never return cleartext secrets).
 */
export function redactSecretsInEncrypted(value: EncryptedValue): Value {
  if ("$envelope" in value) {
    return mkSecret(redactPlaceholder(value.$envelope));
  }
  switch (value.kind) {
    case "number":
    case "boolean":
    case "null":
    case "string":
    case "file":
    case "closure":
    case "agentLiteral":
      return value;
    case "array":
      return { kind: "array", elements: value.elements.map(redactSecretsInEncrypted) };
    case "record": {
      const entries: Record<string, Value> = {};
      for (const [k, v] of Object.entries(value.entries)) entries[k] = redactSecretsInEncrypted(v);
      return value.ctor !== undefined
        ? { kind: "record", entries, ctor: value.ctor }
        : { kind: "record", entries };
    }
  }
}

function redactPlaceholder(source: string): string {
  let h = 0;
  for (let i = 0; i < source.length; i++) {
    h = (h * 31 + source.charCodeAt(i)) | 0;
  }
  return `<redacted:${(h >>> 0).toString(16).padStart(8, "0").slice(0, 8)}>`;
}

/** Convenience: encrypt every Value in a `Record<string, Value>` map. */
export function encryptValueRecord(args: Record<string, Value>): Record<string, EncryptedValue> {
  const out: Record<string, EncryptedValue> = {};
  for (const [k, v] of Object.entries(args)) out[k] = encryptValueTree(v);
  return out;
}

/** Convenience: decrypt every EncryptedValue in a record map. */
export function decryptValueRecord(args: Record<string, EncryptedValue>): Record<string, Value> {
  const out: Record<string, Value> = {};
  for (const [k, v] of Object.entries(args)) out[k] = decryptValueTree(v);
  return out;
}
