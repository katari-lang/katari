// The `prelude.store` prims over a stubbed rows port + effects: full-key resolution through the
// view's prefix, the found/absent sum, FS-style listing with the "/" boundary, and the write path's
// blob-ownership calls (adopt on set, reclaim only when no other entry still references the blob).

import { describe, expect, test } from "vitest";
import type { PrimContext, StoreEffects } from "../src/runtime/engine/context.js";
import {
  type EnvReader,
  registerHostPrims,
  type StoreRows,
} from "../src/runtime/engine/host-prims.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import type { BlobId, ProjectId } from "../src/runtime/ids.js";
import { SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-store" as ProjectId;

const ENV: EnvReader = {
  readSecret: async () => null,
  readPublic: async () => ({}),
};

/** An in-memory rows port faithful on the two queries the prims lean on: the "/"-bounded prefix
 *  listing and the other-entry blob-reference probe. */
function memoryRows(): StoreRows & { table: Map<string, Value> } {
  const table = new Map<string, Value>();
  return {
    table,
    read: async (_project, key) => table.get(key),
    upsert: async (_project, key, value) => {
      table.set(key, value);
    },
    remove: async (_project, key) => {
      table.delete(key);
    },
    listKeys: async (_project, prefix) =>
      [...table.keys()].filter((key) => prefix === "" || key.startsWith(`${prefix}/`)).sort(),
    isBlobReferenced: async (_project, blobId, exceptKey) =>
      [...table.entries()].some(
        ([key, value]) => key !== exceptKey && JSON.stringify(value).includes(blobId),
      ),
  };
}

function harness() {
  const rows = memoryRows();
  const adopted: Value[] = [];
  const freed: BlobId[][] = [];
  const effects: StoreEffects = {
    adoptForStore: (value) => adopted.push(value),
    freeStoreBlobs: (blobIds) => freed.push([...blobIds]),
  };
  const prims = new PrimRegistry();
  registerHostPrims(prims, { env: ENV, store: rows });
  const context: PrimContext = {
    projectId: PROJECT,
    ir: new SnapshotRegistry(),
    blobs: new InMemoryBlobStore(),
    blobEntryOf: () => undefined,
    storeEffects: effects,
  };
  const run = (name: string, fields: Record<string, Value>): Promise<Value> =>
    prims.run(name, { kind: "record", fields }, context);
  return { rows, adopted, freed, run };
}

const str = (value: string): Value => ({ kind: "string", value });
const view = (prefix: string): Value => ({
  kind: "record",
  ctor: "prelude.store.store" as never,
  fields: { prefix: str(prefix) },
});
const fileRef = (blobId: string): Value => ({
  kind: "ref",
  semanticKind: "file",
  blobId: blobId as BlobId,
});

describe("prelude.store prims", () => {
  test("set writes under the view's prefix and get reads it back as `found`", async () => {
    const { rows, run } = harness();
    await run("prelude.store.set", { target: view("memos"), key: str("today"), value: str("hi") });
    expect(rows.table.has("memos/today")).toBe(true);
    const result = await run("prelude.store.get", { target: view("memos"), key: str("today") });
    expect(result).toMatchObject({ ctor: "prelude.store.found", fields: { value: str("hi") } });
  });

  test("get on a missing key is `absent` carrying the full key", async () => {
    const { run } = harness();
    const result = await run("prelude.store.get", { target: view("memos"), key: str("gone") });
    expect(result).toMatchObject({
      ctor: "prelude.store.absent",
      fields: { key: str("memos/gone") },
    });
  });

  test("list is FS-shaped: leaves and deduplicated branches directly under the prefix, /-bounded", async () => {
    const { run } = harness();
    for (const key of ["a", "dir/x", "dir/y", "dirx", "dir/deep/z"]) {
      await run("prelude.store.set", { target: view(""), key: str(key), value: str(key) });
    }
    const root = await run("prelude.store.list", { target: view("") });
    expect(root).toMatchObject({
      kind: "array",
      elements: [
        { ctor: "prelude.store.leaf", fields: { key: str("a") } },
        { ctor: "prelude.store.branch", fields: { name: str("dir") } },
        { ctor: "prelude.store.leaf", fields: { key: str("dirx") } },
      ],
    });
    const under = await run("prelude.store.list", { target: view("dir") });
    expect(under).toMatchObject({
      kind: "array",
      elements: [
        { ctor: "prelude.store.branch", fields: { name: str("deep") } },
        { ctor: "prelude.store.leaf", fields: { key: str("x") } },
        { ctor: "prelude.store.leaf", fields: { key: str("y") } },
      ],
    });
  });

  test("set adopts the value's blobs; replacing the last reference frees them", async () => {
    const { adopted, freed, run } = harness();
    await run("prelude.store.set", { target: view(""), key: str("pic"), value: fileRef("blob-1") });
    expect(adopted).toHaveLength(1);
    await run("prelude.store.set", { target: view(""), key: str("pic"), value: str("replaced") });
    expect(freed).toEqual([["blob-1"]]);
  });

  test("a blob another entry still references is NOT freed", async () => {
    const { freed, run } = harness();
    await run("prelude.store.set", { target: view(""), key: str("a"), value: fileRef("blob-2") });
    await run("prelude.store.set", { target: view(""), key: str("b"), value: fileRef("blob-2") });
    await run("prelude.store.delete", { target: view(""), key: str("a") });
    expect(freed).toEqual([]);
    await run("prelude.store.delete", { target: view(""), key: str("b") });
    expect(freed).toEqual([["blob-2"]]);
  });

  test("delete removes the entry; a later get is `absent`", async () => {
    const { run } = harness();
    await run("prelude.store.set", { target: view(""), key: str("k"), value: str("v") });
    await run("prelude.store.delete", { target: view(""), key: str("k") });
    const result = await run("prelude.store.get", { target: view(""), key: str("k") });
    expect(result).toMatchObject({ ctor: "prelude.store.absent" });
  });
});
