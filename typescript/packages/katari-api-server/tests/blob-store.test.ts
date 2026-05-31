// Contract tests for BlobStore. The S3 backend needs a live endpoint
// (exercised against s3mock / SeaweedFS at the integration layer), so the
// unit contract runs against InMemoryBlobStore — the same put/get/range/
// delete + idempotency semantics PgValueStore relies on.

import { describe, expect, it } from "vitest";
import { type BlobStore, InMemoryBlobStore } from "../src/storage/blob-store.js";

const PROJECT = "11111111-1111-1111-1111-111111111111";
const enc = (s: string) => new TextEncoder().encode(s);
const dec = (b: Uint8Array) => new TextDecoder().decode(b);

const backends: Array<[string, BlobStore]> = [["InMemoryBlobStore", new InMemoryBlobStore()]];

describe.each(backends)("BlobStore contract: %s", (_name, store) => {
  it("put then get round-trips the bytes", async () => {
    const hash = "hash-roundtrip";
    await store.put(PROJECT, hash, enc("hello world"));
    const got = await store.get(PROJECT, hash);
    expect(got).not.toBeNull();
    expect(dec(got!)).toBe("hello world");
  });

  it("get on a missing blob returns null", async () => {
    expect(await store.get(PROJECT, "nope")).toBeNull();
    expect(await store.getRange(PROJECT, "nope", 0, 4)).toBeNull();
  });

  it("getRange returns the requested slice and clamps past EOF", async () => {
    const hash = "hash-range";
    await store.put(PROJECT, hash, enc("0123456789"));
    expect(dec((await store.getRange(PROJECT, hash, 2, 4))!)).toBe("2345");
    // Range running past EOF returns the available tail, not an error.
    expect(dec((await store.getRange(PROJECT, hash, 8, 100))!)).toBe("89");
    // Zero-length range is an empty buffer, not null.
    expect((await store.getRange(PROJECT, hash, 0, 0))!.length).toBe(0);
  });

  it("put is idempotent (content-addressed) — repeat put keeps the bytes", async () => {
    const hash = "hash-idem";
    await store.put(PROJECT, hash, enc("once"));
    await store.put(PROJECT, hash, enc("once"));
    expect(dec((await store.get(PROJECT, hash))!)).toBe("once");
  });

  it("delete removes the bytes; second delete is a no-op", async () => {
    const hash = "hash-del";
    await store.put(PROJECT, hash, enc("bye"));
    await store.delete(PROJECT, hash);
    expect(await store.get(PROJECT, hash)).toBeNull();
    await store.delete(PROJECT, hash); // no throw
  });

  it("blobs are isolated per project", async () => {
    const other = "22222222-2222-2222-2222-222222222222";
    await store.put(PROJECT, "shared", enc("a"));
    expect(await store.get(other, "shared")).toBeNull();
  });
});
