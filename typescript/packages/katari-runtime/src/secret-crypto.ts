// AES-256-GCM encrypt / decrypt for secret values at the storage
// boundary. The key is loaded once at first use from the
// `KATARI_SECRET_KEY` environment variable (32 bytes, hex-encoded);
// rotation is out of scope for v0.1.0 — restart the runtime with a
// new key to rotate, accepting that snapshots encrypted under the
// old key become unreadable.
//
// IV: 12 random bytes per encrypt call (GCM-recommended length).
// Output wire shape: `<base64(iv)>:<base64(ciphertext + auth-tag)>`.
// The leading IV is unique per encrypt so identical plaintexts
// produce distinct ciphertexts (= no inadvertent grouping).
//
// Threat model: protects against database snapshot leaks. Does NOT
// protect against in-process memory dumps (plaintext lives in the
// `secret` Value variant by design) or against a compromised
// sidecar (trust assumption: same-host, same operator).

import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

const KEY_ENV = "KATARI_SECRET_KEY";
const ALGORITHM = "aes-256-gcm";
const IV_LENGTH = 12;
const TAG_LENGTH = 16;

let cachedKey: Buffer | null = null;

function loadKey(): Buffer {
  const hex = process.env[KEY_ENV];
  if (hex === undefined || hex.length === 0) {
    throw new SecretCryptoError(
      `${KEY_ENV} must be set to a hex-encoded 32-byte key (64 hex chars). ` +
        `Generate one with: openssl rand -hex 32`,
    );
  }
  let key: Buffer;
  try {
    key = Buffer.from(hex, "hex");
  } catch {
    throw new SecretCryptoError(`${KEY_ENV} is not valid hex`);
  }
  if (key.length !== 32) {
    throw new SecretCryptoError(`${KEY_ENV} must decode to 32 bytes (256 bits), got ${key.length}`);
  }
  return key;
}

function getKey(): Buffer {
  if (cachedKey === null) cachedKey = loadKey();
  return cachedKey;
}

/**
 * Reset the cached key. Tests use this to swap the env var between
 * cases; production code should never call it (rotation requires a
 * process restart by design).
 */
export function resetKeyCacheForTesting(): void {
  cachedKey = null;
}

/** Encrypt a plaintext string. Output is the IV-prefixed wire form. */
export function encryptSecret(plaintext: string): string {
  const iv = randomBytes(IV_LENGTH);
  const cipher = createCipheriv(ALGORITHM, getKey(), iv);
  const encrypted = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return `${iv.toString("base64")}:${Buffer.concat([encrypted, tag]).toString("base64")}`;
}

/** Decrypt the IV-prefixed wire form. Throws on tampering / wrong key. */
export function decryptSecret(wire: string): string {
  const colon = wire.indexOf(":");
  if (colon === -1) {
    throw new SecretCryptoError("decryptSecret: missing IV separator");
  }
  const iv = Buffer.from(wire.slice(0, colon), "base64");
  if (iv.length !== IV_LENGTH) {
    throw new SecretCryptoError(`decryptSecret: IV must be ${IV_LENGTH} bytes, got ${iv.length}`);
  }
  const body = Buffer.from(wire.slice(colon + 1), "base64");
  if (body.length < TAG_LENGTH) {
    throw new SecretCryptoError(`decryptSecret: ciphertext shorter than auth tag`);
  }
  const tag = body.subarray(body.length - TAG_LENGTH);
  const encrypted = body.subarray(0, body.length - TAG_LENGTH);
  const decipher = createDecipheriv(ALGORITHM, getKey(), iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(encrypted), decipher.final()]).toString("utf8");
}

export class SecretCryptoError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SecretCryptoError";
  }
}
