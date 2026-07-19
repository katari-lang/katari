// Encrypt-at-rest for secrets: the AES-256-GCM primitive and the structural seal / unseal applied at the
// persistence boundary. The test key comes from `vitest.config.ts` (`KATARI_SECRET_KEY`).

import { describe, expect, test } from "vitest";
import { decryptSecret, encryptSecret } from "../src/lib/crypto.js";
import { sealForStorage, unsealFromStorage } from "../src/runtime/actor/seal.js";
import type { Value } from "../src/runtime/value/types.js";

describe("crypto", () => {
  test("round-trips a string through encrypt / decrypt", () => {
    const plaintext = "sk-secret-api-key";
    const encrypted = encryptSecret(plaintext);
    expect(encrypted).not.toContain(plaintext);
    expect(decryptSecret(encrypted)).toBe(plaintext);
  });

  test("a fresh IV makes two encryptions of the same plaintext differ", () => {
    expect(encryptSecret("same")).not.toBe(encryptSecret("same"));
  });

  test("decrypting a tampered ciphertext throws (the GCM auth tag fails)", () => {
    const encrypted = encryptSecret("payload");
    const bytes = Buffer.from(encrypted, "base64");
    const last = bytes.length - 1;
    bytes[last] = (bytes[last] ?? 0) ^ 0xff; // flip a ciphertext bit
    expect(() => decryptSecret(bytes.toString("base64"))).toThrow();
  });
});

const secret: Value = { kind: "string", value: "sk-123", private: true };
const publicValue: Value = { kind: "string", value: "hello" };

describe("sealForStorage / unsealFromStorage", () => {
  test("leaves a wholly public payload structurally unchanged", () => {
    const record: Value = { kind: "record", fields: { a: publicValue } };
    expect(sealForStorage(record)).toEqual(record);
  });

  test("seals a private value (no plaintext at rest) and round-trips it back", () => {
    const sealed = sealForStorage(secret);
    expect(JSON.stringify(sealed)).not.toContain("sk-123");
    expect(JSON.stringify(sealed)).toContain("$katari_sealed");
    expect(unsealFromStorage(sealed)).toEqual(secret);
  });

  test("is structural: a private field seals, public siblings stay plain", () => {
    const record: Value = { kind: "record", fields: { name: publicValue, apiKey: secret } };
    const sealed = sealForStorage(record);
    // The public field is still readable plain JSON; the private one is ciphertext.
    expect(sealed).toMatchObject({ kind: "record", fields: { name: { value: "hello" } } });
    expect(JSON.stringify(sealed)).not.toContain("sk-123");
    expect(unsealFromStorage(sealed)).toEqual(record);
  });

  test("covers nested private values inside a private subtree (sealed as one unit)", () => {
    const value: Value = {
      kind: "record",
      private: true,
      fields: { inner: { kind: "string", value: "nested", private: true } },
    };
    const sealed = sealForStorage(value);
    expect(JSON.stringify(sealed)).not.toContain("nested");
    expect(unsealFromStorage(sealed)).toEqual(value);
  });

  test("round-trips a scope's values map (the engine's at-rest variable store)", () => {
    const values: Record<number, Value> = {
      1: publicValue,
      2: secret,
      3: { kind: "array", elements: [publicValue, secret] },
    };
    const sealed = sealForStorage(values);
    expect(JSON.stringify(sealed)).not.toContain("sk-123");
    expect(unsealFromStorage(sealed)).toEqual(values);
  });

  test("a null payload passes through", () => {
    expect(sealForStorage(null)).toBeNull();
    expect(unsealFromStorage(null)).toBeNull();
  });
});
