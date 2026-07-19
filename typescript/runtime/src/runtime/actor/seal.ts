// Encrypt-at-rest for secret values, applied at the persistence boundary. A persisted payload (a delegation
// argument, a scope's variables, a whole thread, an outbox event) is JSON whose leaves may be `Value` nodes;
// a private one carries `private: true`. Before a payload is written, every private node — anywhere in the
// tree — is replaced by an encrypted `{ $sealed }` sentinel; on read it is decrypted back. Public structure
// stays plain JSON, so the column keeps its readable shape and only the secrets are ciphertext.
//
// Sealing a private node encrypts the whole subtree at once (nested private values ride along), and a sealed
// sentinel is not re-walked on read — it is already plaintext once decrypted. The marker rides only on
// `Value` nodes, so `private === true` unambiguously identifies what to seal.

import { decryptSecret, encryptSecret } from "../../lib/crypto.js";

/** The reserved key an encrypted private subtree collapses to at rest (a `$`-prefixed sentinel, like the
 *  codec's `$katari_ref` / `$katari_agent`, so it never collides with engine payload structure). */
const SEALED_KEY = "$sealed";

function isObject(node: unknown): node is Record<string, unknown> {
  return typeof node === "object" && node !== null && !Array.isArray(node);
}

/** Map a JSON tree with `transform`, returning the *same reference* for any subtree it left unchanged. On the
 *  hot persist path the common case is a payload with no secrets, so this avoids copying it at all. */
function rewrite(
  node: unknown,
  transform: (node: Record<string, unknown>) => unknown | null,
): unknown {
  if (Array.isArray(node)) {
    let changed = false;
    const out = node.map((child) => {
      const next = rewrite(child, transform);
      if (next !== child) changed = true;
      return next;
    });
    return changed ? out : node;
  }
  if (!isObject(node)) return node;
  // A non-null transform result replaces this node whole (and its subtree is not walked); null means recurse.
  const replacement = transform(node);
  if (replacement !== null) return replacement;
  let changed = false;
  const out: Record<string, unknown> = {};
  for (const [key, child] of Object.entries(node)) {
    const next = rewrite(child, transform);
    if (next !== child) changed = true;
    out[key] = next;
  }
  return changed ? out : node;
}

function sealNode(node: unknown): unknown {
  // A private Value node: encrypt the entire subtree into one sealed sentinel (nested privates ride along).
  return rewrite(node, (object) =>
    object.private === true ? { [SEALED_KEY]: encryptSecret(JSON.stringify(object)) } : null,
  );
}

function unsealNode(node: unknown): unknown {
  // A sealed sentinel decrypts back to its private Value subtree (already plaintext, so it is not re-walked).
  return rewrite(node, (object) => {
    const sealed = object[SEALED_KEY];
    return typeof sealed === "string" ? JSON.parse(decryptSecret(sealed)) : null;
  });
}

/** Seal a payload for storage: every private Value node within becomes an encrypted `{ $sealed }` sentinel,
 *  the rest stays plain JSON. A structural no-op when nothing is private. The shape is otherwise preserved, so
 *  the cast back to the column's declared type describes exactly what `unsealFromStorage` reconstructs. */
export function sealForStorage<T>(value: T): T {
  return sealNode(value) as T;
}

/** The inverse of `sealForStorage`: decrypt every `{ $sealed }` sentinel back into its private Value subtree. */
export function unsealFromStorage<T>(value: T): T {
  return unsealNode(value) as T;
}
