// End-to-end test for the built-in `http` reactor, driven through the whole ProjectActor (no real network).
// A hand-built program reads a secret from the env, puts it in a request header, and calls `http.fetch`; the
// reactor receives that as a `delegate` (an external leaf marked `reactor: "http"`), reveals the secret at the
// boundary, dispatches through a controllable transport, and lifts the response back to a public
// `{ status, body }`. The three tests cover the happy path (with the secret declassified into a public
// response), the unhandled-error path (→ a run-failing panic), and the at-most-once recovery contract (an
// interrupted request is never re-sent — it fails on restart).

import { createAgentName, type IRModule, type QualifiedName, type SchemaInfo } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { InMemoryPersistence, type Persistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { type EnvReader, registerHostPrims } from "../src/runtime/engine/host-prims.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import {
  type HttpCall,
  type HttpCompletion,
  type HttpTransport,
} from "../src/runtime/external/http-transport.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import type { DelegationId, ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";

const PROJECT = "project-http" as ProjectId;
const SNAPSHOT = "snapshot-http" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

// agent main() {
//   let key = prelude.env.get_secret({ key: "API_KEY" })     // a private string
//   return prelude.http.fetch({
//     url: "https://example.test/ping", method: "GET",
//     headers: { authorization: key }, body: "",
//   })
// }
// `get_secret` is a host primitive (its leaf runs on the prim registry); `fetch` is an external agent whose
// body is an external leaf marked `reactor: "http"`, so its call routes to the http reactor.
const FETCH_IR: IRModule = {
  metadata: { schemaVersion: 1 },
  blocks: {
    0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
    1: {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "loadLiteral", output: 20, value: { kind: "string", value: "API_KEY" } },
          { kind: "makeRecord", entries: [["key", 20]], output: 21 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.env.get_secret") },
            argument: 21,
            output: 22,
          },
          { kind: "makeRecord", entries: [["authorization", 22]], output: 23 },
          {
            kind: "loadLiteral",
            output: 24,
            value: { kind: "string", value: "https://example.test/ping" },
          },
          { kind: "loadLiteral", output: 25, value: { kind: "string", value: "GET" } },
          { kind: "loadLiteral", output: 26, value: { kind: "string", value: "" } },
          {
            kind: "makeRecord",
            entries: [
              ["url", 24],
              ["method", 25],
              ["headers", 23],
              ["body", 26],
            ],
            output: 27,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.http.fetch") },
            argument: 27,
            output: 28,
          },
          { kind: "exit", target: 0, value: 28 },
        ],
      },
      parameters: { parameter: 1 },
    },
    // get_secret host-primitive agent + its leaf.
    6: { block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
    7: {
      block: { kind: "primitive", name: "prelude.env.get_secret", input: 70 },
      parameters: { parameter: 70 },
    },
    // fetch external agent + its external leaf, routed to the http reactor.
    8: { block: { kind: "agent", body: 9, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
    9: {
      block: { kind: "external", key: "fetch", input: 90, reactor: "http" },
      parameters: { parameter: 90 },
    },
  },
  entries: {
    [createAgentName("main")]: 0,
    [createAgentName("prelude.env.get_secret")]: 6,
    [createAgentName("prelude.http.fetch")]: 8,
  },
  names: {},
};

// agent main() { par [ fetch({url,method,headers,body}), return 7 ] }
// The `return 7` cancels the par, terminating the in-flight fetch. The cancel is graceful: the reactor
// `terminate`s the http call, the transport confirms with a `cancelled`, and the run resolves to 7 only after
// that terminateAck — so the terminateAck follows the terminate (never a recovery error).
const CANCELLING_FETCH_IR: IRModule = {
  metadata: { schemaVersion: 1 },
  blocks: {
    0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
    1: {
      block: { kind: "sequence", result: null, operations: [{ kind: "call", target: 2, output: 10 }] },
      parameters: { parameter: 11 },
    },
    2: { block: { kind: "parallel", elements: [3, 4] }, parameters: {} },
    // element 0: fetch(...) — an http call that never completes (the test never feeds it a result).
    3: {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "makeRecord", entries: [], output: 30 },
          { kind: "loadLiteral", output: 31, value: { kind: "string", value: "https://example.test/x" } },
          { kind: "loadLiteral", output: 32, value: { kind: "string", value: "GET" } },
          { kind: "loadLiteral", output: 33, value: { kind: "string", value: "" } },
          {
            kind: "makeRecord",
            entries: [
              ["url", 31],
              ["method", 32],
              ["headers", 30],
              ["body", 33],
            ],
            output: 34,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.http.fetch") },
            argument: 34,
            output: 35,
          },
        ],
      },
      parameters: {},
    },
    // element 1: return 7 (cancels the par, and with it the in-flight fetch).
    4: {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "loadLiteral", output: 40, value: { kind: "integer", value: 7 } },
          { kind: "exit", target: 0, value: 40 },
        ],
      },
      parameters: {},
    },
    8: { block: { kind: "agent", body: 9, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
    9: {
      block: { kind: "external", key: "fetch", input: 90, reactor: "http" },
      parameters: { parameter: 90 },
    },
  },
  entries: {
    [createAgentName("main")]: 0,
    [createAgentName("prelude.http.fetch")]: 8,
  },
  names: {},
};

/** A fixed env exposing one secret, so `get_secret("API_KEY")` yields a private `"sk-123"`. */
const ENV: EnvReader = {
  async readSecret(_projectId, key) {
    return key === "API_KEY" ? "sk-123" : null;
  },
  async readPublic() {
    return {};
  },
};

/** A transport the test drives by hand: it records each dispatched call and lets the test feed completions.
 *  A recovery is auto-answered with an error, mirroring the real transport's at-most-once contract for work
 *  it no longer holds (an interrupted request is never re-sent). */
class ControlledHttpTransport implements HttpTransport {
  readonly dispatched: HttpCall[] = [];
  readonly recovered: DelegationId[] = [];
  readonly aborted: DelegationId[] = [];
  private sink: ((completion: HttpCompletion) => void) | null = null;

  onComplete(sink: (completion: HttpCompletion) => void): void {
    this.sink = sink;
  }

  dispatch(call: HttpCall): void {
    this.dispatched.push(call);
  }

  recover(delegation: DelegationId): void {
    this.recovered.push(delegation);
    // A fresh test transport holds no live requests, so a recovery always refuses (at-most-once).
    this.feed({
      delegation,
      outcome: { kind: "error", message: "http request interrupted by a runtime restart" },
    });
  }

  abort(delegation: DelegationId): void {
    this.aborted.push(delegation);
    if (this.confirmsAbort) {
      // Mirror the real transport: with no separate live request to interrupt (completions are test-driven),
      // an abort confirms the teardown straight away with a `cancelled`.
      this.feed({ delegation, outcome: { kind: "cancelled" } });
    }
  }

  /** Feed a completion back to the reactor (the test's hook for a finished initial dispatch). */
  feed(completion: HttpCompletion): void {
    if (this.sink === null) throw new Error("ControlledHttpTransport: no sink registered");
    this.sink(completion);
  }

  /** When false, an abort is recorded but never confirmed — modelling a crash before the `cancelled` lands. */
  constructor(private readonly confirmsAbort: boolean = true) {}
}

function makeActor(
  http: HttpTransport,
  persistence: Persistence = new InMemoryPersistence(),
  ir: IRModule = FETCH_IR,
): ProjectActor {
  const registry = new SnapshotRegistry();
  for (const name of Object.keys(ir.entries)) {
    registry.set(SNAPSHOT, moduleOfName(name as QualifiedName), ir);
  }
  const prims = new PrimRegistry();
  registerHostPrims(prims, { env: ENV });
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims,
    blobs: new InMemoryBlobStore(),
    external: new StubFfiTransport(),
    http,
    persistence,
  });
}

async function waitUntil<T>(predicate: () => T | undefined): Promise<T> {
  for (let attempt = 0; attempt < 1000; attempt++) {
    const value = predicate();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error("waitUntil: predicate never held");
}

describe("http reactor", () => {
  test("performs an http.fetch with a secret header revealed at the boundary, returning a public response", async () => {
    const transport = new ControlledHttpTransport();
    const actor = makeActor(transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The reactor dispatches once the delegate turn commits; the argument is plain Json with the secret
    // header revealed (http is an allowed sink — unlike the user-facing API, which would redact it).
    const call = await waitUntil(() => transport.dispatched[0]);
    expect(call.argument).toEqual({
      url: "https://example.test/ping",
      method: "GET",
      headers: { authorization: "sk-123" },
      body: "",
    });

    transport.feed({
      delegation: call.delegation,
      outcome: { kind: "result", value: { status: 204, body: "pong" } },
    });

    const value = await result;
    expect(value).toEqual({
      kind: "record",
      fields: {
        status: { kind: "integer", value: 204 },
        body: { kind: "string", value: "pong" },
      },
    });
    // Declassified: the response is public even though the request carried a secret header.
    expect(value.private).toBeUndefined();
    expect(value.kind).toBe("record");
    if (value.kind === "record") {
      expect(value.fields.status?.private).toBeUndefined();
      expect(value.fields.body?.private).toBeUndefined();
    }
  });

  test("fails the run with a panic when the request errors with no handler", async () => {
    const transport = new ControlledHttpTransport();
    const actor = makeActor(transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await waitUntil(() => transport.dispatched[0]);
    transport.feed({
      delegation: call.delegation,
      outcome: { kind: "error", message: "connection refused" },
    });

    // A request that produced no response escalates a panic; unhandled, it fails the run.
    await expect(result).rejects.toThrow(/connection refused/);
  });

  test("never re-sends an interrupted request on recovery — it fails at-most-once", async () => {
    const persistence = new StoringPersistence();

    // First actor: the request dispatches but never completes, so the project persists suspended on it.
    const firstTransport = new ControlledHttpTransport();
    const actorOne = makeActor(firstTransport, persistence);
    const { run } = actorOne.startRun(createAgentName("main"), SNAPSHOT, null);
    await waitUntil(() => firstTransport.dispatched[0]);
    // The run root and the http call's instance are both persisted at the suspend point.
    await waitUntil(() => (persistence.instanceCount() >= 2 ? true : undefined));

    // Process "crash": a fresh actor recovers from the same state. Its transport refuses to re-send the
    // in-flight request (recover → error), so the call fails with a panic that, unhandled, fails the run.
    const secondTransport = new ControlledHttpTransport();
    const actorTwo = makeActor(secondTransport, persistence);
    await actorTwo.activate();

    await waitUntil(() => secondTransport.recovered[0]);
    // Recovery never turned into a fresh send.
    expect(secondTransport.dispatched).toHaveLength(0);

    const failed = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "error" ? record : undefined;
    });
    expect(failed.errorMessage).toMatch(/interrupted by a runtime restart/);
  });

  test("cancels an in-flight fetch via abort and resolves once the transport confirms (terminateAck)", async () => {
    // The `return 7` cancels the par → the reactor `terminate`s the fetch → the transport confirms the abort
    // with a `cancelled` → terminateAck. The run resolves to 7 ONLY after that confirmation (it would hang if
    // the abort path were not wired), so this proves the terminateAck follows the terminate — no re-send.
    const transport = new ControlledHttpTransport();
    const actor = makeActor(transport, new InMemoryPersistence(), CANCELLING_FETCH_IR);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    await waitUntil(() => transport.dispatched[0]);
    const value = await result;
    expect(value).toEqual({ kind: "integer", value: 7 });
    // The reactor aborted the in-flight call rather than re-dispatching it.
    expect(transport.aborted).toHaveLength(1);
  });

  test("recovers a cancelling fetch: abort confirms at-most-once (no re-send) and the run completes", async () => {
    const persistence = new StoringPersistence();

    // First actor: dispatch the fetch, then `return 7` cancels it → the call is `cancelling`. Its transport
    // never confirms the abort (a crash before the `cancelled` lands), so the project persists at cancelling.
    const firstTransport = new ControlledHttpTransport(false);
    const actorOne = makeActor(firstTransport, persistence, CANCELLING_FETCH_IR);
    const { run } = actorOne.startRun(createAgentName("main"), SNAPSHOT, null);
    await waitUntil(() => (firstTransport.aborted.length > 0 ? true : undefined));

    // Recover in a fresh actor: the base's uniform recovery aborts the cancelling call (it does NOT
    // re-dispatch), and this transport confirms the abort with a `cancelled` → terminateAck → the run resolves.
    const secondTransport = new ControlledHttpTransport();
    const actorTwo = makeActor(secondTransport, persistence, CANCELLING_FETCH_IR);
    await actorTwo.activate();

    const done = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "done" ? record : undefined;
    });
    expect(done.result).toEqual({ kind: "integer", value: 7 });
    // Recovery aborted the cancelling call; it never re-dispatched (no request re-sent).
    expect(secondTransport.aborted).toHaveLength(1);
    expect(secondTransport.dispatched).toHaveLength(0);
  });
});
