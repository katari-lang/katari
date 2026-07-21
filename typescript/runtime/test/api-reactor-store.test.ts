// The api reactor MACHINE-ANSWERS an unhandled `prelude.store.*` escalation reaching the run root — the
// store is the run's environment, not an operator question. Driven directly (like `ffi-blob`), with a real
// ResourcePool + project store, an in-memory rows port, and a synchronous command sink: a hand-built
// `escalate` reaches the reactor, and its downward `escalateAck` carries the computed answer. Pins the
// round trip (set → get → found), `absent`, the blob landing (a stored file reowns onto the api root — the
// file library — and an overwrite frees nothing), and the invisibility (a store escalation never becomes an
// open question).

import { describe, expect, test } from "vitest";
import { ApiReactor } from "../src/runtime/actor/api-reactor.js";
import { ResourcePool } from "../src/runtime/actor/resource-pool.js";
import type { StoreRows } from "../src/runtime/actor/store-responder.js";
import { createProjectStore } from "../src/runtime/engine/store.js";
import type { ExternalEvent } from "../src/runtime/event/types.js";
import {
  apiRootIdOf,
  type BlobId,
  type DelegationId,
  type EscalationId,
  newDelegationId,
  newEscalationId,
  type InstanceId,
  type ProjectId,
} from "../src/runtime/ids.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "11111111-1111-4111-8111-111111111111" as ProjectId;
const API_ROOT = apiRootIdOf(PROJECT);
const RUN = "run-store" as InstanceId;

/** An in-memory rows port (the "/"-bounded listing is not exercised here — see `store-responder`). */
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

function harness(rows: StoreRows = memoryRows()) {
  const store = createProjectStore();
  const pool = new ResourcePool(PROJECT, store);
  // A synchronous command sink: the reply thunk runs at once (the substrate's serial turn, collapsed).
  const api = new ApiReactor(
    API_ROOT,
    {
      enqueue: (thunk) => {
        thunk();
        return Promise.resolve();
      },
    },
    pool,
    PROJECT,
    rows,
  );
  return { api, pool, store };
}

const str = (value: string): Value => ({ kind: "string", value });
const view = (prefix: string): Value => ({ kind: "record", fields: { prefix: str(prefix) } });
const record = (fields: Record<string, Value>): Value => ({ kind: "record", fields });
const fileRef = (blobId: string): Value => ({
  kind: "ref",
  semanticKind: "file",
  blobId: blobId as BlobId,
});

/** A `prelude.store.*` escalate reaching the run root (its argument the request's record). */
function storeEscalate(request: string, argument: Value): Extract<ExternalEvent, { kind: "escalate" }> {
  return {
    kind: "escalate",
    delegation: newDelegationId(),
    escalation: newEscalationId(),
    ask: { kind: "request", request: request as never, argument },
    from: "core",
    to: "api",
    run: RUN,
  };
}

/** React to a store escalate and drain the single `escalateAck` the async answer produces. */
async function answer(
  api: ApiReactor,
  request: string,
  argument: Value,
): Promise<Extract<ExternalEvent, { kind: "escalateAck" }>> {
  api.react(storeEscalate(request, argument));
  await new Promise((resolve) => setTimeout(resolve, 0)); // flush the async rows I/O + reply thunk
  const sends = api.drainSends();
  const ack = sends.find((event) => event.kind === "escalateAck");
  if (ack === undefined || ack.kind !== "escalateAck") {
    throw new Error(`no escalateAck was produced (got ${sends.map((event) => event.kind).join(", ")})`);
  }
  return ack;
}

describe("api reactor: machine-answering prelude.store.*", () => {
  test("set → get round trip: the get's escalateAck carries the value set before it", async () => {
    const { api } = harness();
    const setAck = await answer(api, "prelude.store.set", record({ target: view("memos"), key: str("today"), value: str("hi") }));
    expect(setAck.value).toEqual({ kind: "null" });

    const getAck = await answer(api, "prelude.store.get", record({ target: view("memos"), key: str("today") }));
    expect(getAck.value).toMatchObject({ ctor: "prelude.store.found", fields: { value: str("hi") } });
  });

  test("a get on a missing key answers `absent` carrying the full key", async () => {
    const { api } = harness();
    const ack = await answer(api, "prelude.store.get", record({ target: view("memos"), key: str("gone") }));
    expect(ack.value).toMatchObject({ ctor: "prelude.store.absent", fields: { key: str("memos/gone") } });
  });

  test("a stored file's blob reowns onto the api root (the file library), outliving the run", async () => {
    const { api, pool, store } = harness();
    const BLOB = "blob-stored" as BlobId;
    // The file blob arrives IN TRANSIT — the run root released it on the escalate's way up (the value-driven
    // run→api handoff), ready for a receiver to claim it.
    pool.registerBlob(BLOB, { owner: null, hash: "hash", size: 3, semanticKind: "file" });

    const ack = await answer(api, "prelude.store.set", record({ target: view(""), key: str("pic"), value: fileRef(BLOB) }));
    expect(ack.value).toEqual({ kind: "null" });
    // Landed on the api root: a project file, listed on the Files page, outliving the writing run.
    expect(store.blobs[BLOB]?.owner).toBe(API_ROOT);
  });

  test("overwriting a stored file's entry does NOT free the blob", async () => {
    const { api, pool, store } = harness();
    const BLOB = "blob-kept" as BlobId;
    pool.registerBlob(BLOB, { owner: null, hash: "hash", size: 3, semanticKind: "file" });

    await answer(api, "prelude.store.set", record({ target: view(""), key: str("pic"), value: fileRef(BLOB) }));
    expect(store.blobs[BLOB]?.owner).toBe(API_ROOT);
    // Replace the entry with a plain value: the store forgets the reference, but the file stays in the
    // library (there is no reclaim path — it is removed only by an explicit file delete).
    await answer(api, "prelude.store.set", record({ target: view(""), key: str("pic"), value: str("replaced") }));
    expect(store.blobs[BLOB]?.owner).toBe(API_ROOT);
  });

  test("a store escalation never becomes an open question", async () => {
    const { api } = harness();
    await answer(api, "prelude.store.get", record({ target: view(""), key: str("k") }));
    expect(api.listOpenEscalations()).toHaveLength(0);
  });
});
