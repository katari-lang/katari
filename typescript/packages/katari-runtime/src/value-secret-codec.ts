// Typed encrypt / decrypt walkers for the runtime `Value` tree at the
// storage boundary.
//
// Each Module's persistence layer calls 'encryptValueTree' before
// handing a Value (or a Value-bearing container) to the storage layer
// and 'decryptValueTree' after reading one back. Storage itself stays
// completely unaware of secrets — it only sees the 'EncryptedValue'
// shape, which carries '$envelope' (= AES-GCM ciphertext) in place of
// the plaintext 'secret' variant.
//
// The two types are kept distinct on purpose: a stray 'EncryptedValue'
// leaking into runtime code (where `Value` is expected) fails the
// 'Value' discriminant check ('$envelope' is not a 'kind: "secret"'),
// so the type system catches "forgot to decrypt" at compile time.

import type { ClosureId } from "./engine/id.js";
import type { Value } from "./engine/value.js";
import type { QualifiedName } from "./ir/types.js";
import { decryptSecret, encryptSecret } from "./secret-crypto.js";

/** Storage-form replacement for the 'secret' Value variant. Carries
 * the AES-GCM-encrypted wire form produced by 'secret-crypto'. */
export type EncryptedSecret = { readonly $envelope: string };

/** Mirror of 'Value' where every 'secret' variant has been replaced
 * by 'EncryptedSecret'. Container variants ('array' / 'tagged')
 * recurse into 'EncryptedValue' so nested secrets transform too. */
export type EncryptedValue =
  | { kind: "number"; value: number }
  | { kind: "string"; value: string }
  | { kind: "boolean"; value: boolean }
  | { kind: "null" }
  | { kind: "array"; elements: EncryptedValue[] }
  | {
      kind: "tagged";
      ctorId: QualifiedName;
      fields: Record<string, EncryptedValue>;
    }
  | { kind: "record"; entries: Record<string, EncryptedValue> }
  | { kind: "closure"; closureId: ClosureId }
  | { kind: "agentLiteral"; qualifiedName: QualifiedName }
  | EncryptedSecret;

/**
 * Walk a 'Value' tree and encrypt every 'secret' leaf into the
 * storage envelope form. Container variants ('array' / 'tagged')
 * recurse into their children. Pure: returns a fresh tree without
 * mutating the input. Idempotent on subtrees that contain no
 * secrets (= encrypt of a non-secret Value just returns the same
 * structure, retyped).
 */
export function encryptValueTree(value: Value): EncryptedValue {
  switch (value.kind) {
    case "number":
    case "string":
    case "boolean":
    case "null":
    case "closure":
    case "agentLiteral":
      return value;
    case "array":
      return { kind: "array", elements: value.elements.map(encryptValueTree) };
    case "tagged": {
      const fields: Record<string, EncryptedValue> = {};
      for (const [k, v] of Object.entries(value.fields)) {
        fields[k] = encryptValueTree(v);
      }
      return { kind: "tagged", ctorId: value.ctorId, fields };
    }
    case "record": {
      const entries: Record<string, EncryptedValue> = {};
      for (const [k, v] of Object.entries(value.entries)) {
        entries[k] = encryptValueTree(v);
      }
      return { kind: "record", entries };
    }
    case "secret":
      return { $envelope: encryptSecret(value.value) };
  }
}

/**
 * Inverse of 'encryptValueTree'. Throws via 'secret-crypto' if any
 * envelope fails AES-GCM authentication (= tampering or wrong key).
 */
export function decryptValueTree(encrypted: EncryptedValue): Value {
  if ("$envelope" in encrypted) {
    return { kind: "secret", value: decryptSecret(encrypted.$envelope) };
  }
  switch (encrypted.kind) {
    case "number":
    case "string":
    case "boolean":
    case "null":
    case "closure":
    case "agentLiteral":
      return encrypted;
    case "array":
      return {
        kind: "array",
        elements: encrypted.elements.map(decryptValueTree),
      };
    case "tagged": {
      const fields: Record<string, Value> = {};
      for (const [k, v] of Object.entries(encrypted.fields)) {
        fields[k] = decryptValueTree(v);
      }
      return { kind: "tagged", ctorId: encrypted.ctorId, fields };
    }
    case "record": {
      const entries: Record<string, Value> = {};
      for (const [k, v] of Object.entries(encrypted.entries)) {
        entries[k] = decryptValueTree(v);
      }
      return { kind: "record", entries };
    }
  }
}

/**
 * Replace every encrypted-secret envelope (and every plaintext secret,
 * defensively) in an EncryptedValue tree with a placeholder string of
 * the form `<redacted:HHHHHHHH>`. The 8-hex-digit suffix is derived
 * from the ciphertext bytes so two distinct secrets in the same tree
 * render distinctly to a human reader; the function is not a
 * cryptographic hash.
 *
 * Used at HTTP wire boundaries that surface stored rows back to
 * operators / clients: the API must never return cleartext secrets,
 * and exposing raw ciphertext would just leak metadata without
 * helping the caller.
 */
export function redactSecretsInEncrypted(value: EncryptedValue): Value {
  if ("$envelope" in value) {
    return { kind: "secret", value: redactPlaceholder(value.$envelope) };
  }
  switch (value.kind) {
    case "number":
    case "string":
    case "boolean":
    case "null":
    case "closure":
    case "agentLiteral":
      return value;
    case "array":
      return {
        kind: "array",
        elements: value.elements.map(redactSecretsInEncrypted),
      };
    case "tagged": {
      const fields: Record<string, Value> = {};
      for (const [k, v] of Object.entries(value.fields)) {
        fields[k] = redactSecretsInEncrypted(v);
      }
      return { kind: "tagged", ctorId: value.ctorId, fields };
    }
    case "record": {
      const entries: Record<string, Value> = {};
      for (const [k, v] of Object.entries(value.entries)) {
        entries[k] = redactSecretsInEncrypted(v);
      }
      return { kind: "record", entries };
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
  for (const [k, v] of Object.entries(args)) {
    out[k] = encryptValueTree(v);
  }
  return out;
}

/** Convenience: decrypt every EncryptedValue in a record map. */
export function decryptValueRecord(args: Record<string, EncryptedValue>): Record<string, Value> {
  const out: Record<string, Value> = {};
  for (const [k, v] of Object.entries(args)) {
    out[k] = decryptValueTree(v);
  }
  return out;
}
