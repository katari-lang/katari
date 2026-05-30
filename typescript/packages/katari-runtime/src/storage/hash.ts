// Content hashing for byte-sequence values.
//
// All byte sequences (`string` / `file` / `secret`) are content-addressed by
// a Blake3 hash. The hash is the dedup key in the value store (`value_blobs`),
// the equality witness for `string == string` (Phase D), and the `hash` field
// on a `$ref` wire envelope. It MUST be computed identically everywhere, so
// every site routes through these helpers.
//
// Blake3 (not the openssl-backed `crypto.createHash`, which lacks it) via the
// pure-TS `@noble/hashes` — no native binding / postinstall, so it stays
// portable across the runtime, the api-server impl, and the sidecar.

import { blake3 } from "@noble/hashes/blake3";
import { bytesToHex } from "@noble/hashes/utils";

/** Blake3 content hash of raw bytes, as lowercase hex. */
export function hashBytes(bytes: Uint8Array): string {
  return bytesToHex(blake3(bytes));
}

/**
 * Content hash of a UTF-8 string. `string` values hash their UTF-8 encoding
 * so an inline string and a ref produced from the same text collide (= they
 * are equal). Keep this consistent with how the value store encodes string
 * bytes (always UTF-8).
 */
export function hashText(text: string): string {
  return hashBytes(new TextEncoder().encode(text));
}
