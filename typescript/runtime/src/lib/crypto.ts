// Authenticated symmetric encryption for secrets at rest (AES-256-GCM). Two conceptually distinct callers
// share this one primitive: sealing private (`secret`) values in the engine's persisted payloads, and
// encrypting `env` secret entries. The key is the runtime's `KATARI_SECRET_KEY` (required at boot).
//
// The wire form is base64 of `iv (12 bytes) || authTag (16 bytes) || ciphertext`. A fresh random IV per call
// keeps GCM safe under the single key, and the auth tag makes a tampered or wrong-key ciphertext fail loudly
// on decrypt rather than returning garbage.

import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
import { config } from "../config/index.js";

const ALGORITHM = "aes-256-gcm";
const IV_BYTES = 12;
const TAG_BYTES = 16;

/** Encrypt a UTF-8 string into the base64 `iv || tag || ciphertext` envelope. */
export function encryptSecret(plaintext: string): string {
  const iv = randomBytes(IV_BYTES);
  const cipher = createCipheriv(ALGORITHM, config.secretKey, iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), ciphertext]).toString("base64");
}

/** Decrypt a base64 `iv || tag || ciphertext` envelope back to its UTF-8 string. Throws if the ciphertext
 *  was tampered with or the key is wrong (the GCM auth tag fails to verify). */
export function decryptSecret(encoded: string): string {
  const envelope = Buffer.from(encoded, "base64");
  const iv = envelope.subarray(0, IV_BYTES);
  const tag = envelope.subarray(IV_BYTES, IV_BYTES + TAG_BYTES);
  const ciphertext = envelope.subarray(IV_BYTES + TAG_BYTES);
  const decipher = createDecipheriv(ALGORITHM, config.secretKey, iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf8");
}
