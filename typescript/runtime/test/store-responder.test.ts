// The store responder — the pure answer construction the runtime machine-answers a `prelude.store.*`
// request with, over a stubbed rows port: full-key resolution through the view's prefix, the found/absent
// sum, and the FS-shaped listing with its "/" boundary. (The escalation wiring — recognise the request,
// reply on the downward path, land a stored file in the library — is exercised in `api-reactor-store`.)

import { describe, expect, test } from "vitest";
import { answerStoreRequest, type StoreRows } from "../src/runtime/actor/store-responder.js";
import type { ProjectId } from "../src/runtime/ids.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-store-responder" as ProjectId;
const GET = "prelude.store.get" as never;
const SET = "prelude.store.set" as never;
const DELETE = "prelude.store.delete" as never;
const LIST = "prelude.store.list" as never;

/** An in-memory rows port faithful on the "/"-bounded prefix listing the responder leans on. */
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
  };
}

const str = (value: string): Value => ({ kind: "string", value });
/** The `store` view — a record with a `prefix` field (the responder reads the field, not the ctor). */
const view = (prefix: string): Value => ({ kind: "record", fields: { prefix: str(prefix) } });
const record = (fields: Record<string, Value>): Value => ({ kind: "record", fields });

describe("store responder", () => {
  test("set writes under the view's prefix and get reads it back as `found`", async () => {
    const rows = memoryRows();
    const setAnswer = await answerStoreRequest(
      rows,
      PROJECT,
      SET,
      record({ target: view("memos"), key: str("today"), value: str("hi") }),
    );
    expect(setAnswer).toEqual({ kind: "null" });
    expect(rows.table.has("memos/today")).toBe(true);

    const getAnswer = await answerStoreRequest(
      rows,
      PROJECT,
      GET,
      record({ target: view("memos"), key: str("today") }),
    );
    expect(getAnswer).toMatchObject({
      ctor: "prelude.store.found",
      fields: { value: str("hi") },
    });
  });

  test("get on a missing key is `absent` carrying the full key", async () => {
    const rows = memoryRows();
    const answer = await answerStoreRequest(
      rows,
      PROJECT,
      GET,
      record({ target: view("memos"), key: str("gone") }),
    );
    expect(answer).toMatchObject({
      ctor: "prelude.store.absent",
      fields: { key: str("memos/gone") },
    });
  });

  test("delete removes the entry; a later get is `absent`", async () => {
    const rows = memoryRows();
    await answerStoreRequest(rows, PROJECT, SET, record({ target: view(""), key: str("k"), value: str("v") }));
    const del = await answerStoreRequest(rows, PROJECT, DELETE, record({ target: view(""), key: str("k") }));
    expect(del).toEqual({ kind: "null" });
    const answer = await answerStoreRequest(rows, PROJECT, GET, record({ target: view(""), key: str("k") }));
    expect(answer).toMatchObject({ ctor: "prelude.store.absent" });
  });

  test("list is FS-shaped: leaves and deduplicated branches directly under the prefix, /-bounded", async () => {
    const rows = memoryRows();
    for (const key of ["a", "dir/x", "dir/y", "dirx", "dir/deep/z"]) {
      await answerStoreRequest(rows, PROJECT, SET, record({ target: view(""), key: str(key), value: str(key) }));
    }
    const root = await answerStoreRequest(rows, PROJECT, LIST, record({ target: view("") }));
    expect(root).toMatchObject({
      kind: "array",
      elements: [
        { ctor: "prelude.store.leaf", fields: { key: str("a") } },
        { ctor: "prelude.store.branch", fields: { name: str("dir") } },
        { ctor: "prelude.store.leaf", fields: { key: str("dirx") } },
      ],
    });
    const under = await answerStoreRequest(rows, PROJECT, LIST, record({ target: view("dir") }));
    expect(under).toMatchObject({
      kind: "array",
      elements: [
        { ctor: "prelude.store.branch", fields: { name: str("deep") } },
        { ctor: "prelude.store.leaf", fields: { key: str("x") } },
        { ctor: "prelude.store.leaf", fields: { key: str("y") } },
      ],
    });
  });
});
