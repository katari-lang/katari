// Typed Value ↔ EncryptedValue walker tests for 'value-secret-codec'.

import { beforeAll, describe, expect, it } from "vitest";
import { randomBytes } from "node:crypto";
import type { Value } from "../src/engine/value.js";
import { resetKeyCacheForTesting } from "../src/secret-crypto.js";
import {
  decryptValueRecord,
  decryptValueTree,
  encryptValueRecord,
  encryptValueTree,
  redactSecretsInEncrypted,
  type EncryptedValue,
} from "../src/value-secret-codec.js";

beforeAll(() => {
  if (
    process.env.KATARI_SECRET_KEY === undefined
    || process.env.KATARI_SECRET_KEY === ""
  ) {
    process.env.KATARI_SECRET_KEY = randomBytes(32).toString("hex");
  }
  resetKeyCacheForTesting();
});

describe("value-secret-codec", () => {
  it("non-secret Values pass through unchanged", () => {
    const cases: Value[] = [
      { kind: "number", value: 42 },
      { kind: "string", value: "hi" },
      { kind: "boolean", value: true },
      { kind: "null" },
      { kind: "array", elements: [{ kind: "number", value: 1 }] },
      {
        kind: "tagged",
        ctorId: "main.point",
        fields: { x: { kind: "number", value: 3 } },
      },
    ];
    for (const v of cases) {
      const enc = encryptValueTree(v);
      expect(enc).toEqual(v);
      expect(decryptValueTree(enc)).toEqual(v);
    }
  });

  it("a secret leaf becomes a $envelope and round-trips", () => {
    const v: Value = { kind: "secret", value: "sk-live-XXX" };
    const enc = encryptValueTree(v);
    // The encrypted form is the storage envelope, NOT a Value variant.
    expect("$envelope" in enc).toBe(true);
    expect((enc as { $envelope: string }).$envelope).toMatch(/^[^:]+:/);
    expect(decryptValueTree(enc)).toEqual(v);
  });

  it("encrypts secrets nested inside tagged and array containers", () => {
    const v: Value = {
      kind: "tagged",
      ctorId: "main.payload",
      fields: {
        token: { kind: "secret", value: "abc" },
        meta: {
          kind: "array",
          elements: [
            { kind: "string", value: "first" },
            { kind: "secret", value: "def" },
          ],
        },
      },
    };
    const enc = encryptValueTree(v);
    // Walk into the encrypted tree and assert the secrets were replaced.
    expect(enc.kind).toEqual("tagged");
    if (enc.kind !== "tagged") throw new Error("type narrowing");
    expect("$envelope" in enc.fields.token!).toBe(true);
    const innerArr = enc.fields.meta!;
    if (innerArr.kind !== "array") throw new Error("type narrowing");
    expect(innerArr.elements[0]).toEqual({ kind: "string", value: "first" });
    expect("$envelope" in innerArr.elements[1]!).toBe(true);
    // Round-trip restores the original Value tree exactly.
    expect(decryptValueTree(enc)).toEqual(v);
  });

  it("encryptValueRecord / decryptValueRecord round-trip a Record map", () => {
    const args: Record<string, Value> = {
      url: { kind: "string", value: "https://example.com" },
      auth: { kind: "secret", value: "sk-1" },
    };
    const enc = encryptValueRecord(args);
    expect((enc.auth as { $envelope: string }).$envelope).toBeDefined();
    expect(decryptValueRecord(enc)).toEqual(args);
  });

  it("redactSecretsInEncrypted replaces envelopes with deterministic placeholders", () => {
    const enc: EncryptedValue = encryptValueTree({
      kind: "tagged",
      ctorId: "main.creds",
      fields: {
        a: { kind: "secret", value: "alpha" },
        b: { kind: "secret", value: "beta" },
      },
    });
    const redacted = redactSecretsInEncrypted(enc);
    expect(redacted.kind).toEqual("tagged");
    if (redacted.kind !== "tagged") throw new Error("type narrowing");
    const a = redacted.fields.a!;
    const b = redacted.fields.b!;
    if (a.kind !== "secret" || b.kind !== "secret") throw new Error("type narrowing");
    expect(a.value).toMatch(/^<redacted:[0-9a-f]{8}>$/);
    expect(b.value).toMatch(/^<redacted:[0-9a-f]{8}>$/);
    // Distinct ciphertexts should redact to distinct placeholders.
    expect(a.value).not.toEqual(b.value);
  });
});
