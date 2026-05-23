// encryptCheckpoint / decryptCheckpoint round-trip tests. The checkpoint
// is the deeply-nested storage form of the engine 'State'; secrets can
// live in scopes, threads, delegations, etc. The walker must find them
// all and replace each with the storage envelope, then put them back
// on decrypt.

import { beforeAll, describe, expect, it } from "vitest";
import { randomBytes } from "node:crypto";
import {
  decryptCheckpoint,
  encryptCheckpoint,
  type EngineCheckpoint,
} from "../src/engine/snapshot.js";
import { resetKeyCacheForTesting } from "../src/secret-crypto.js";

beforeAll(() => {
  if (
    process.env.KATARI_SECRET_KEY === undefined
    || process.env.KATARI_SECRET_KEY === ""
  ) {
    process.env.KATARI_SECRET_KEY = randomBytes(32).toString("hex");
  }
  resetKeyCacheForTesting();
});

function emptyCheckpoint(): EngineCheckpoint {
  return {
    schemaVersion: 1,
    selfEndpoint: "core://main" as EngineCheckpoint["selfEndpoint"],
    ffiTargetEndpoint: "ext://ffi" as EngineCheckpoint["ffiTargetEndpoint"],
    envTargetEndpoint: "ext://env" as EngineCheckpoint["envTargetEndpoint"],
    threads: {},
    scopes: {},
    closures: {},
    nextClosureId: 0,
    delegations: {},
    pendingDelegateOut: {},
    delegationSenders: {},
    escalationOwners: {},
    lastGcScopeCount: 0,
  };
}

describe("snapshot encryption", () => {
  it("a checkpoint without secrets is unchanged structurally", () => {
    const base = emptyCheckpoint();
    base.scopes = {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      1: { parentId: null, values: { 7: { kind: "string", value: "x" } } } as any,
    };
    const enc = encryptCheckpoint(base);
    expect(enc).toEqual(base);
    expect(decryptCheckpoint(enc)).toEqual(base);
  });

  it("a secret in a scope value is replaced by $envelope on encrypt", () => {
    const base = emptyCheckpoint();
    base.scopes = {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      1: { parentId: null, values: { 7: { kind: "secret", value: "abc" } } } as any,
    };
    const enc = encryptCheckpoint(base);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const encryptedSlot = (enc.scopes as any)[1].values[7];
    expect("$envelope" in encryptedSlot).toBe(true);
    // No plaintext "abc" anywhere in the encrypted JSON.
    expect(JSON.stringify(enc)).not.toContain("abc");
    expect(decryptCheckpoint(enc)).toEqual(base);
  });

  it("encrypts secrets nested deeply inside thread / delegation rows", () => {
    const base = emptyCheckpoint();
    // Synthetic shape — the walker is structural and doesn't care
    // about the exact thread variant, just that the JSON tree contains
    // `kind: "secret"` nodes.
    base.threads = {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      99: {
        kind: "agent",
        args: {
          auth: { kind: "secret", value: "deep-secret" },
          url: { kind: "string", value: "https://example.com" },
        },
      } as any,
    };
    const enc = encryptCheckpoint(base);
    expect(JSON.stringify(enc)).not.toContain("deep-secret");
    const restored = decryptCheckpoint(enc);
    expect(restored).toEqual(base);
  });

  it("rejects tampered ciphertext on decrypt", () => {
    const base = emptyCheckpoint();
    base.scopes = {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      1: { parentId: null, values: { 7: { kind: "secret", value: "tamper" } } } as any,
    };
    const enc = encryptCheckpoint(base);
    // Tamper with the envelope ciphertext (= flip a character in the
    // body half, after the IV separator).
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const env = (enc.scopes as any)[1].values[7] as { $envelope: string };
    const colon = env.$envelope.indexOf(":");
    const original = env.$envelope.slice(colon + 1);
    env.$envelope =
      env.$envelope.slice(0, colon + 1)
      + (original[0] === "A" ? "B" : "A")
      + original.slice(1);
    expect(() => decryptCheckpoint(enc)).toThrow();
  });
});
