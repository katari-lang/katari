// encryptCheckpoint / decryptCheckpoint round-trip tests. The checkpoint
// is the storage form of the engine 'State'; the only Value-bearing field is
// `threads` (scopes / closures live in the CORE-global store and persist via the
// ScopeStore). The walker must find every secret in a thread's value slots and
// replace each with the storage envelope, then put them back on decrypt.

import { beforeAll, describe, expect, it } from "vitest";
import { randomBytes } from "node:crypto";
import {
  decryptCheckpoint,
  encryptCheckpoint,
  type EngineCheckpoint,
} from "../src/engine/snapshot.js";
import { mkRecord, mkSecret, mkString } from "../src/engine/value.js";
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
    delegations: {},
    pendingDelegateOut: {},
    delegationSenders: {},
    escalationOwners: {},
    lastGcScopeCount: 0,
  };
}

describe("snapshot encryption", () => {
  it("a checkpoint without secrets is unchanged structurally", async () => {
    const base = emptyCheckpoint();
    base.threads = {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      1: { kind: "agent", argument: mkString("x") } as any,
    };
    const enc = await encryptCheckpoint(base);
    expect(enc).toEqual(base);
    expect(await decryptCheckpoint(enc)).toEqual(base);
  });

  it("a secret in a thread value is replaced by $envelope on encrypt", async () => {
    const base = emptyCheckpoint();
    base.threads = {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      1: { kind: "agent", argument: mkSecret("abc") } as any,
    };
    const enc = await encryptCheckpoint(base);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const encryptedSlot = (enc.threads as any)[1].argument;
    expect("$envelope" in encryptedSlot).toBe(true);
    // No plaintext "abc" anywhere in the encrypted JSON.
    expect(JSON.stringify(enc)).not.toContain("abc");
    expect(await decryptCheckpoint(enc)).toEqual(base);
  });

  it("encrypts secrets nested deeply inside a thread's value slots", async () => {
    const base = emptyCheckpoint();
    // A realistic agent thread: the secret lives in the typed `argument`
    // Value (a record), nested under a key. The walker locates Values by
    // their typed positions, then recurses INTO each Value tree — so a
    // secret buried inside a composite argument is still found.
    base.threads = {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      99: {
        kind: "agent",
        argument: mkRecord({
          auth: mkSecret("deep-secret"),
          url: mkString("https://example.com"),
        }),
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any,
    };
    const enc = await encryptCheckpoint(base);
    expect(JSON.stringify(enc)).not.toContain("deep-secret");
    const restored = await decryptCheckpoint(enc);
    expect(restored).toEqual(base);
  });

  it("round-trips a live RecordThread (regression: kind:'record' is not a Value)", async () => {
    // The original crash: a `RecordThread` (`kind: "record"`) suspended across a
    // persist boundary (a `json_object(entries = {...})` literal whose entries
    // delegate) was mistaken for a Value `record` by the old kind-tag walk, which
    // then read its non-existent `.entries`. The typed walker maps a record/tuple
    // thread through its `collected` map instead, and finds secrets inside it.
    const base = emptyCheckpoint();
    base.threads = {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      42: {
        kind: "record",
        blockId: 0,
        nextIndex: 1,
        collected: { 0: mkSecret("collected-secret"), 1: mkString("plain") },
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any,
    };
    const enc = await encryptCheckpoint(base);
    expect(JSON.stringify(enc)).not.toContain("collected-secret");
    expect(await decryptCheckpoint(enc)).toEqual(base);
  });

  it("rejects tampered ciphertext on decrypt", async () => {
    const base = emptyCheckpoint();
    base.threads = {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      1: { kind: "agent", argument: mkSecret("tamper") } as any,
    };
    const enc = await encryptCheckpoint(base);
    // Tamper with the envelope ciphertext (= flip a character in the
    // body half, after the IV separator).
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const env = (enc.threads as any)[1].argument as { $envelope: string };
    const colon = env.$envelope.indexOf(":");
    const original = env.$envelope.slice(colon + 1);
    env.$envelope =
      env.$envelope.slice(0, colon + 1)
      + (original[0] === "A" ? "B" : "A")
      + original.slice(1);
    await expect(decryptCheckpoint(enc)).rejects.toThrow();
  });
});
