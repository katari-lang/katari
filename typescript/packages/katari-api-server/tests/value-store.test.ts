// ValueStore unit tests (in-memory impl). Covers the 3-layer model:
//   - produce (putComplete / open-push-close) + content-addressed dedup
//   - consume (fetch / fetchRange / getState), including module=api files
//   - persistent files (create / get / list / delete) + persistRef promote
//   - single-owner GC (releaseOwner / transferOwnership / dead-owner sweep)
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

  it("blob is freed only when the last referring ref drops", async () => {
    const store = new InMemoryValueStore();
    const a = await store.putComplete({
      projectId: PROJECT,
      owner: "core",
      bytes: enc("shared"),
      semanticKind: "string",
      ownerEntityId: "e-A",
    });
    await store.putComplete({
      projectId: PROJECT,
      owner: "core",
      bytes: enc("shared"),
      semanticKind: "string",
      ownerEntityId: "e-B",
    });
    expect(store.blobs.size).toBe(1);

    // e-A terminates with nothing escaping: its ref drops (entity CASCADE), one
    // referrer remains (e-B), blob stays.
    store.deleteRefsOwnedBy(PROJECT, "e-A");
    expect(store.blobs.size).toBe(1);
    expect(await store.fetch(PROJECT, "core", a.id)).toBeNull();

    // e-B terminates: last referrer gone, blob freed.
    store.deleteRefsOwnedBy(PROJECT, "e-B");
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
      ownerEntityId: "e-1",
    });
    const file = await store.persistRef({
      projectId: PROJECT,
      module: "ffi",
      id: ref.id,
      ownerEntityId: "proj-root",
      displayName: "kept.bin",
    });
    expect(file).not.toBeNull();
    expect(file!.hash).toBe(ref.hash);
    expect(file!.contentType).toBe("application/octet-stream");
    // One blob, two referrers (the ephemeral ref + the new file).
    expect(store.blobs.size).toBe(1);
    expect([...store.blobs.values()][0]?.refCount).toBe(2);

    // e-1 terminates (its ephemeral ref drops); the api file (owned by the
    // project root) still holds the blob, so it survives.
    store.deleteRefsOwnedBy(PROJECT, "e-1");
    expect(store.blobs.size).toBe(1);
    expect(dec((await store.fetch(PROJECT, "api", file!.id))!)).toBe("promote me");
  });

  it("persistRef returns null for an unknown / errored ref", async () => {
    const store = new InMemoryValueStore();
    expect(
      await store.persistRef({ projectId: PROJECT, module: "core", id: "ghost", ownerEntityId: "r" }),
    ).toBeNull();
  });
});

describe("ValueStore: value-driven ascent (entity model)", () => {
  const put = (store: InMemoryValueStore, text: string, owner: string, refsTo?: { module: "core"; id: string }[]) =>
    store.putComplete({
      projectId: PROJECT,
      owner: "core",
      bytes: enc(text),
      semanticKind: "string",
      ownerEntityId: owner,
      refsTo,
    });

  it("detach (owner→null) keeps escaping refs; entity delete drops the rest; claim re-owns to parent", async () => {
    const store = new InMemoryValueStore();
    const keep = await put(store, "escapes", "child");
    const drop = await put(store, "local", "child");

    // child terminal: detach the escaping ref (owner→null), then self-delete its
    // entity (the rest cascade away).
    await store.reownRefs(PROJECT, "child", null, [{ module: "core", id: keep.id }]);
    store.deleteRefsOwnedBy(PROJECT, "child");
    expect(await store.fetch(PROJECT, "core", keep.id)).not.toBeNull(); // detached, survives
    expect(await store.fetch(PROJECT, "core", drop.id)).toBeNull(); // cascaded away
    expect(store.blobs.size).toBe(1);

    // parent claims the result value's refs by id (null → parent).
    await store.reownRefs(PROJECT, null, "parent", [{ module: "core", id: keep.id }]);
    // a later teardown of `child` drops nothing (keep is owned by parent now).
    store.deleteRefsOwnedBy(PROJECT, "child");
    expect(await store.fetch(PROJECT, "core", keep.id)).not.toBeNull();
  });

  it("detach/claim drag a closure's captures along (refs_to)", async () => {
    const store = new InMemoryValueStore();
    const capture = await put(store, "captured", "child");
    const closure = await put(store, "closure-env", "child", [{ module: "core", id: capture.id }]);

    // Only the closure is in the returned value; its capture comes along.
    await store.reownRefs(PROJECT, "child", null, [{ module: "core", id: closure.id }]);
    store.deleteRefsOwnedBy(PROJECT, "child");
    await store.reownRefs(PROJECT, null, "parent", [{ module: "core", id: closure.id }]);
    store.deleteRefsOwnedBy(PROJECT, "child");
    expect(await store.fetch(PROJECT, "core", closure.id)).not.toBeNull();
    expect(await store.fetch(PROJECT, "core", capture.id)).not.toBeNull();
  });

  it("reownRefs (escalation persist) moves owned refs up without touching the rest", async () => {
    const store = new InMemoryValueStore();
    const escalated = await put(store, "for-run", "raiser");
    const local = await put(store, "still-local", "raiser");

    await store.reownRefs(PROJECT, "raiser", "run-root", [{ module: "core", id: escalated.id }]);
    // `local` is untouched (raiser keeps running); tearing down the raiser drops it.
    store.deleteRefsOwnedBy(PROJECT, "raiser");
    expect(await store.fetch(PROJECT, "core", local.id)).toBeNull();
    // `escalated` is owned by `run-root` and survives.
    expect(await store.fetch(PROJECT, "core", escalated.id)).not.toBeNull();
  });

  it("sweepDetachedRefs drops in-transit (owner=null) refs, keeps entity-owned", async () => {
    const store = new InMemoryValueStore();
    const owned = await put(store, "owned", "e-live");
    // An in-transit ref a crash left detached (no owner entity).
    const detached = await store.putComplete({
      projectId: PROJECT,
      owner: "core",
      bytes: enc("in-transit"),
      semanticKind: "string",
    });

    const freed = await store.sweepDetachedRefs(PROJECT);
    expect(freed).toBe(1); // `detached`'s blob
    expect(await store.fetch(PROJECT, "core", owned.id)).not.toBeNull();
    expect(await store.fetch(PROJECT, "core", detached.id)).toBeNull();
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
