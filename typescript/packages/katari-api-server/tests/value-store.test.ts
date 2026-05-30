// ValueStore unit tests (in-memory impl). Covers the 3-layer model:
//   - produce (putComplete / open-push-close) + content-addressed dedup
//   - consume (fetch / fetchRange / getState), including module=api files
//   - persistent files (create / get / list / delete) + persistRef promote
//   - GC primitives (sweepInstance / sweepUnreachable) + blob refcount sweep
//   - facade wiring + withTransaction rollback

import { hashText } from "@katari-lang/runtime";
import { describe, expect, it } from "vitest";
import { InMemoryStorage } from "../src/storage/memory-storage.js";
import { InMemoryValueStore } from "../src/storage/value-store-memory.js";

const PROJECT = "proj-1";
const enc = (text: string): Uint8Array => new TextEncoder().encode(text);
const dec = (bytes: Uint8Array): string => new TextDecoder().decode(bytes);

describe("ValueStore: produce / consume", () => {
  it("putComplete → fetch round-trips and content-addresses", async () => {
    const store = new InMemoryValueStore();
    const result = await store.putComplete({
      projectId: PROJECT,
      owner: "core",
      bytes: enc("hello world"),
      semanticKind: "string",
    });
    expect(result.size).toBe(11);
    expect(result.hash).toBe(hashText("hello world"));

    const bytes = await store.fetch(PROJECT, "core", result.id);
    expect(bytes).not.toBeNull();
    expect(dec(bytes!)).toBe("hello world");

    const state = await store.getState(PROJECT, "core", result.id);
    expect(state).toMatchObject({
      state: "complete",
      semanticKind: "string",
      hash: result.hash,
      size: 11,
    });
  });

  it("open → pushChunk* → close concatenates and hashes the whole payload", async () => {
    const store = new InMemoryValueStore();
    const handle = await store.open({ projectId: PROJECT, owner: "ffi", semanticKind: "file" });
    await handle.pushChunk(enc("foo"));
    await handle.pushChunk(enc("bar"));
    await handle.pushChunk(enc("baz"));
    const result = await handle.close();
    expect(result.size).toBe(9);
    expect(result.hash).toBe(hashText("foobarbaz"));

    const bytes = await store.fetch(PROJECT, "ffi", result.id);
    expect(dec(bytes!)).toBe("foobarbaz");
  });

  it("abort marks the ref errored; fetch yields null", async () => {
    const store = new InMemoryValueStore();
    const handle = await store.open({ projectId: PROJECT, owner: "ffi", semanticKind: "string" });
    await handle.pushChunk(enc("partial"));
    await handle.abort("sidecar crashed");
    const state = await store.getState(PROJECT, "ffi", handle.id);
    expect(state).toMatchObject({ state: "errored", errorMessage: "sidecar crashed" });
    expect(await store.fetch(PROJECT, "ffi", handle.id)).toBeNull();
  });

  it("fetchRange returns the requested slice", async () => {
    const store = new InMemoryValueStore();
    const { id } = await store.putComplete({
      projectId: PROJECT,
      owner: "core",
      bytes: enc("0123456789"),
      semanticKind: "string",
    });
    expect(dec((await store.fetchRange(PROJECT, "core", id, 2, 5))!)).toBe("23456");
    expect(dec((await store.fetchRange(PROJECT, "core", id, 8, 100))!)).toBe("89");
  });

  it("unknown ref yields null state / bytes", async () => {
    const store = new InMemoryValueStore();
    expect(await store.getState(PROJECT, "core", "nope")).toBeNull();
    expect(await store.fetch(PROJECT, "core", "nope")).toBeNull();
  });
});

describe("ValueStore: dedup + refcount", () => {
  it("identical bytes share one blob with refcount 2", async () => {
    const store = new InMemoryValueStore();
    const a = await store.putComplete({
      projectId: PROJECT,
      owner: "core",
      bytes: enc("dup"),
      semanticKind: "string",
    });
    const b = await store.putComplete({
      projectId: PROJECT,
      owner: "ffi",
      bytes: enc("dup"),
      semanticKind: "string",
    });
    expect(a.hash).toBe(b.hash);
    expect(store.blobs.size).toBe(1);
    expect([...store.blobs.values()][0]?.refCount).toBe(2);

    // Both still independently fetchable.
    expect(dec((await store.fetch(PROJECT, "core", a.id))!)).toBe("dup");
    expect(dec((await store.fetch(PROJECT, "ffi", b.id))!)).toBe("dup");
  });

  it("blob is swept only when the last referrer goes", async () => {
    const store = new InMemoryValueStore();
    const a = await store.putComplete({
      projectId: PROJECT,
      owner: "core",
      bytes: enc("shared"),
      semanticKind: "string",
      ownerInstanceId: "shard-A",
    });
    await store.putComplete({
      projectId: PROJECT,
      owner: "core",
      bytes: enc("shared"),
      semanticKind: "string",
      ownerInstanceId: "shard-B",
    });
    expect(store.blobs.size).toBe(1);

    // Sweep shard-A: one referrer remains, blob stays.
    expect(await store.sweepInstance(PROJECT, "shard-A")).toBe(1);
    expect(store.blobs.size).toBe(1);
    expect(await store.fetch(PROJECT, "core", a.id)).toBeNull();

    // Sweep shard-B: last referrer gone, blob swept.
    expect(await store.sweepInstance(PROJECT, "shard-B")).toBe(1);
    expect(store.blobs.size).toBe(0);
  });
});

describe("ValueStore: persistent files", () => {
  it("create / get / list / delete with blob sweep", async () => {
    const store = new InMemoryValueStore();
    const file = await store.createFile({
      projectId: PROJECT,
      bytes: enc("file-bytes"),
      contentType: "text/plain",
      displayName: "notes.txt",
    });
    expect(file.size).toBe(10);
    expect(file.displayName).toBe("notes.txt");

    // Files are consumed via module = "api".
    expect(dec((await store.fetch(PROJECT, "api", file.id))!)).toBe("file-bytes");
    expect(await store.getState(PROJECT, "api", file.id)).toMatchObject({
      semanticKind: "file",
      contentType: "text/plain",
    });

    expect((await store.listFiles(PROJECT)).map((f) => f.id)).toContain(file.id);

    expect(await store.deleteFile(PROJECT, file.id)).toBe(true);
    expect(await store.getFile(PROJECT, file.id)).toBeNull();
    expect(store.blobs.size).toBe(0);
    expect(await store.deleteFile(PROJECT, file.id)).toBe(false);
  });

  it("persistRef promotes an ephemeral ref to a file sharing the blob", async () => {
    const store = new InMemoryValueStore();
    const ref = await store.putComplete({
      projectId: PROJECT,
      owner: "ffi",
      bytes: enc("promote me"),
      semanticKind: "file",
      contentType: "application/octet-stream",
    });
    const file = await store.persistRef({
      projectId: PROJECT,
      module: "ffi",
      id: ref.id,
      displayName: "kept.bin",
    });
    expect(file).not.toBeNull();
    expect(file!.hash).toBe(ref.hash);
    expect(file!.contentType).toBe("application/octet-stream");
    // One blob, two referrers (the ephemeral ref + the new file).
    expect(store.blobs.size).toBe(1);
    expect([...store.blobs.values()][0]?.refCount).toBe(2);

    // Sweeping the ephemeral ref leaves the file (and blob) intact.
    await store.sweepUnreachable(PROJECT, []);
    expect(store.blobs.size).toBe(1);
    expect(dec((await store.fetch(PROJECT, "api", file!.id))!)).toBe("promote me");
  });

  it("persistRef returns null for an unknown / errored ref", async () => {
    const store = new InMemoryValueStore();
    expect(await store.persistRef({ projectId: PROJECT, module: "core", id: "ghost" })).toBeNull();
  });
});

describe("ValueStore: reachability sweep", () => {
  it("keeps reachable refs and removes the rest", async () => {
    const store = new InMemoryValueStore();
    const keep = await store.putComplete({
      projectId: PROJECT,
      owner: "core",
      bytes: enc("keep"),
      semanticKind: "string",
    });
    const drop = await store.putComplete({
      projectId: PROJECT,
      owner: "core",
      bytes: enc("drop"),
      semanticKind: "string",
    });
    const removed = await store.sweepUnreachable(PROJECT, [{ owner: "core", id: keep.id }]);
    expect(removed).toBe(1);
    expect(await store.fetch(PROJECT, "core", keep.id)).not.toBeNull();
    expect(await store.fetch(PROJECT, "core", drop.id)).toBeNull();
    expect(store.blobs.size).toBe(1);
  });
});

describe("ValueStore: facade + transaction", () => {
  it("is reachable via Storage.values and rolls back on tx throw", async () => {
    const storage = new InMemoryStorage();
    const committed = await storage.values.putComplete({
      projectId: PROJECT,
      owner: "core",
      bytes: enc("committed"),
      semanticKind: "string",
    });

    await expect(
      storage.withTransaction(async (tx) => {
        await tx.values.putComplete({
          projectId: PROJECT,
          owner: "core",
          bytes: enc("rolled-back"),
          semanticKind: "string",
        });
        throw new Error("boom");
      }),
    ).rejects.toThrow("boom");

    // The committed ref survives; the rolled-back produce left no blob.
    expect(await storage.values.fetch(PROJECT, "core", committed.id)).not.toBeNull();
    expect(storage.values.blobs.size).toBe(1);
  });
});
