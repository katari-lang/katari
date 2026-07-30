// Authenticated symmetric encryption for secrets at rest (AES-256-GCM). Two conceptually distinct callers
// share this one primitive: sealing private (`secret`) values in the engine's persisted payloads, and
// encrypting `env` secret entries. The keys are the runtime's `KATARI_SECRET_KEY` (required at boot) plus
// any `KATARI_SECRET_KEY_PREVIOUS` entries.
//
// The wire form is base64 of `version (1 byte) || iv (12 bytes) || authTag (16 bytes) || ciphertext`. A fresh
// random IV per call keeps GCM safe under one key, and the auth tag makes a tampered or wrong-key ciphertext
// fail loudly on decrypt rather than returning garbage.
//
// The version byte is what makes the format changeable later — a future envelope (a different cipher, a
// wrapped data key) can be introduced without having to guess how to read what is already stored. It costs
// one byte and it is the difference between "we can migrate" and "we cannot". Envelopes written before the
// byte existed carry no version, so `decryptSecret` also accepts that legacy layout: GCM authenticates the
// whole thing, so trying both interpretations is unambiguous rather than a guess.
//
// Key ROTATION is deliberately not recorded in the envelope: the runtime simply tries each configured key in
// turn. That keeps the ciphertext from advertising which key opens it, and with one or two keys the cost is
// nil. To rotate, put the new key in KATARI_SECRET_KEY and move the old one to KATARI_SECRET_KEY_PREVIOUS;
// everything written from then on uses the new key while old values keep opening.

import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
import { config } from "../config/index.js";

const ALGORITHM = "aes-256-gcm";
const IV_BYTES = 12;
const TAG_BYTES = 16;
/** The current envelope layout. Bump when the framing (not the key) changes. */
const ENVELOPE_VERSION = 1;

/** Encrypt a UTF-8 string into the base64 `version || iv || tag || ciphertext` envelope, under the newest
 *  configured key. */
export function encryptSecret(plaintext: string): string {
  const [key] = config.secretKeys;
  if (key === undefined) throw new Error("no secret key is configured");
  const iv = randomBytes(IV_BYTES);
  const cipher = createCipheriv(ALGORITHM, key, iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  return Buffer.concat([Buffer.of(ENVELOPE_VERSION), iv, cipher.getAuthTag(), ciphertext]).toString(
    "base64",
  );
}

/** One way of reading an envelope's bytes — the parts at a given framing offset. */
interface EnvelopeParts {
  iv: Buffer;
  tag: Buffer;
  ciphertext: Buffer;
}

/** Split an envelope at `offset` (0 for the legacy layout, 1 to skip the version byte), or `null` when there
 *  are not enough bytes for the framing to be that shape. */
function partsAt(envelope: Buffer, offset: number): EnvelopeParts | null {
  if (envelope.length < offset + IV_BYTES + TAG_BYTES) return null;
  return {
    iv: envelope.subarray(offset, offset + IV_BYTES),
    tag: envelope.subarray(offset + IV_BYTES, offset + IV_BYTES + TAG_BYTES),
    ciphertext: envelope.subarray(offset + IV_BYTES + TAG_BYTES),
  };
}

/** Attempt one (framing, key) pair. Returns `null` rather than throwing, since a failure here only means
 *  "not this combination" — the caller decides when every combination is exhausted. */
function tryOpen(parts: EnvelopeParts, key: Buffer): string | null {
  try {
    const decipher = createDecipheriv(ALGORITHM, key, parts.iv);
    decipher.setAuthTag(parts.tag);
    return Buffer.concat([decipher.update(parts.ciphertext), decipher.final()]).toString("utf8");
  } catch {
    return null;
  }
}

/** Decrypt a base64 envelope back to its UTF-8 string, trying the current framing then the legacy one, and
 *  each configured key in turn. Throws if none of them opens it — the ciphertext was tampered with, or no
 *  configured key seals it (the usual cause being a KATARI_SECRET_KEY that was regenerated rather than
 *  carried over). */
export function decryptSecret(encoded: string): string {
  const envelope = Buffer.from(encoded, "base64");
  const framings = [
    ...(envelope[0] === ENVELOPE_VERSION ? [partsAt(envelope, 1)] : []),
    partsAt(envelope, 0),
  ];
  for (const parts of framings) {
    if (parts === null) continue;
    for (const key of config.secretKeys) {
      const plaintext = tryOpen(parts, key);
      if (plaintext !== null) return plaintext;
    }
  }
  throw new Error(
    "could not decrypt a stored secret: it was sealed under a key this runtime does not have, or the " +
      "ciphertext was altered. If KATARI_SECRET_KEY was changed, restore the previous value or list it in " +
      "KATARI_SECRET_KEY_PREVIOUS.",
  );
}
