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
      ownerDelegationId: "d-A",
    });
    await store.putComplete({
      projectId: PROJECT,
      owner: "core",
      bytes: enc("shared"),
      semanticKind: "string",
      ownerDelegationId: "d-B",
    });
    expect(store.blobs.size).toBe(1);

    // d-A terminates with nothing escaping: its ref drops, one referrer
    // remains (d-B), blob stays. 0 blobs freed.
    expect(await store.releaseOwner(PROJECT, "d-A", "parent", [])).toBe(0);
    expect(store.blobs.size).toBe(1);
    expect(await store.fetch(PROJECT, "core", a.id)).toBeNull();

    // d-B terminates: last referrer gone, blob freed.
    expect(await store.releaseOwner(PROJECT, "d-B", "parent", [])).toBe(1);
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
      ownerDelegationId: "d-1",
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

    // d-1 terminates (its ephemeral ref drops); the api_file still holds the
    // blob, so it survives. 0 blobs freed.
    expect(await store.releaseOwner(PROJECT, "d-1", "parent", [])).toBe(0);
    expect(store.blobs.size).toBe(1);
    expect(dec((await store.fetch(PROJECT, "api", file!.id))!)).toBe("promote me");
  });

  it("persistRef returns null for an unknown / errored ref", async () => {
    const store = new InMemoryValueStore();
    expect(await store.persistRef({ projectId: PROJECT, module: "core", id: "ghost" })).toBeNull();
  });
});

describe("ValueStore: single-owner GC", () => {
  const put = (store: InMemoryValueStore, text: string, owner: string, refsTo?: { module: "core"; id: string }[]) =>
    store.putComplete({
      projectId: PROJECT,
      owner: "core",
      bytes: enc(text),
      semanticKind: "string",
      ownerDelegationId: owner,
      refsTo,
    });

  it("releaseOwner re-owns the escaping ref to the parent and drops the rest", async () => {
    const store = new InMemoryValueStore();
    const keep = await put(store, "escapes", "child");
    const drop = await put(store, "local", "child");

    // child terminates; only `keep` is in the returned value → re-owned by
    // parent, `drop` is collected.
    const freed = await store.releaseOwner(PROJECT, "child", "parent", [
      { module: "core", id: keep.id },
    ]);
    expect(freed).toBe(1); // `drop`'s blob
    expect(await store.fetch(PROJECT, "core", keep.id)).not.toBeNull();
    expect(await store.fetch(PROJECT, "core", drop.id)).toBeNull();
    // `keep` is now owned by `parent` — surviving a later release of `child`.
    expect(await store.releaseOwner(PROJECT, "child", "x", [])).toBe(0);
    expect(await store.fetch(PROJECT, "core", keep.id)).not.toBeNull();
  });

  it("releaseOwner drags a closure's captures up with it (refs_to)", async () => {
    const store = new InMemoryValueStore();
    const capture = await put(store, "captured", "child");
    // A closure-shaped ref that internally references `capture`.
    const closure = await put(store, "closure-env", "child", [{ module: "core", id: capture.id }]);

    // Only the closure is in the returned value; its capture must come along.
    await store.releaseOwner(PROJECT, "child", "parent", [{ module: "core", id: closure.id }]);
    // Both survive a later release of `child` (both now owned by `parent`).
    expect(await store.releaseOwner(PROJECT, "child", "x", [])).toBe(0);
    expect(await store.fetch(PROJECT, "core", closure.id)).not.toBeNull();
    expect(await store.fetch(PROJECT, "core", capture.id)).not.toBeNull();
  });

  it("transferOwnership (escalate) moves refs up without dropping the rest", async () => {
    const store = new InMemoryValueStore();
    const escalated = await put(store, "for-parent", "child");
    const local = await put(store, "still-local", "child");

    await store.transferOwnership(PROJECT, "child", "receiver", [
      { module: "core", id: escalated.id },
    ]);
    // `local` is untouched (child keeps running); releasing child drops only it.
    expect(await store.releaseOwner(PROJECT, "child", "x", [])).toBe(1);
    expect(await store.fetch(PROJECT, "core", local.id)).toBeNull();
    // `escalated` is owned by `receiver` and survives.
    expect(await store.fetch(PROJECT, "core", escalated.id)).not.toBeNull();
  });

  it("sweepRefsWithDeadOwners drops refs of dead owners, keeps live + unowned", async () => {
    const store = new InMemoryValueStore();
    const live = await put(store, "live-owner", "d-live");
    const dead = await put(store, "dead-owner", "d-dead");
    const unowned = await store.putComplete({
      projectId: PROJECT,
      owner: "core",
      bytes: enc("unowned"),
      semanticKind: "string",
    });

    const freed = await store.sweepRefsWithDeadOwners(PROJECT, new Set(["d-live"]));
    expect(freed).toBe(1); // `dead`'s blob
    expect(await store.fetch(PROJECT, "core", live.id)).not.toBeNull();
    expect(await store.fetch(PROJECT, "core", dead.id)).toBeNull();
    expect(await store.fetch(PROJECT, "core", unowned.id)).not.toBeNull(); // null-owner left alone
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
