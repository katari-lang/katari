// AES-256-GCM primitive tests for 'secret-crypto'. The key cache is
// reset between cases so each test exercises the env-var load path.

import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { randomBytes } from "node:crypto";
import {
  decryptSecret,
  encryptSecret,
  resetKeyCacheForTesting,
  SecretCryptoError,
} from "../src/secret-crypto.js";

beforeAll(() => {
  process.env.KATARI_SECRET_KEY = randomBytes(32).toString("hex");
  resetKeyCacheForTesting();
});

afterEach(() => {
  // Each case may swap the env var. Reset cache so the next test
  // re-reads from process.env.
  resetKeyCacheForTesting();
});

describe("secret-crypto", () => {
  it("round-trips an ASCII string", () => {
    const ct = encryptSecret("hello world");
    expect(ct).not.toEqual("hello world");
    expect(decryptSecret(ct)).toEqual("hello world");
  });

  it("round-trips an empty string", () => {
    const ct = encryptSecret("");
    expect(decryptSecret(ct)).toEqual("");
  });

  it("round-trips multi-byte UTF-8", () => {
    const plain = "🔐 säkrä — トークン";
    const ct = encryptSecret(plain);
    expect(decryptSecret(ct)).toEqual(plain);
  });

  it("produces distinct ciphertexts for the same plaintext (random IV)", () => {
    const a = encryptSecret("repeated");
    const b = encryptSecret("repeated");
    expect(a).not.toEqual(b);
    expect(decryptSecret(a)).toEqual("repeated");
    expect(decryptSecret(b)).toEqual("repeated");
  });

  it("refuses ciphertext that fails AES-GCM authentication", () => {
    const ct = encryptSecret("tamper-me");
    // Flip a bit in the body half (after the IV separator). The auth
    // tag binds the iv + body, so any flip aborts the decrypt.
    const colon = ct.indexOf(":");
    const tampered = ct.slice(0, colon + 1) + flipFirstChar(ct.slice(colon + 1));
    expect(() => decryptSecret(tampered)).toThrow();
  });

  it("refuses ciphertext encrypted under a different key", () => {
    const original = encryptSecret("cross-key-test");
    process.env.KATARI_SECRET_KEY = randomBytes(32).toString("hex");
    resetKeyCacheForTesting();
    expect(() => decryptSecret(original)).toThrow();
  });

  it("refuses to encrypt when KATARI_SECRET_KEY is unset", () => {
    delete process.env.KATARI_SECRET_KEY;
    resetKeyCacheForTesting();
    expect(() => encryptSecret("anything")).toThrow(SecretCryptoError);
  });

  it("refuses to encrypt when the key is not 32 bytes", () => {
    process.env.KATARI_SECRET_KEY = "deadbeef";
    resetKeyCacheForTesting();
    expect(() => encryptSecret("anything")).toThrow(SecretCryptoError);
  });

  it("refuses a malformed wire string", () => {
    expect(() => decryptSecret("no-colon-here")).toThrow(SecretCryptoError);
    expect(() => decryptSecret(":missing-iv")).toThrow();
    expect(() => decryptSecret("aaaa:")).toThrow();
  });
});

function flipFirstChar(s: string): string {
  if (s.length === 0) return "A";
  const first = s.charCodeAt(0);
  // Flip a low bit so the result is still a valid base64 character.
  const replacement = String.fromCharCode(first ^ 1);
  return replacement + s.slice(1);
}
