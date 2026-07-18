// End-to-end test for the built-in `http` reactor, driven through the whole ProjectActor (no real network).
// A hand-built program reads a secret from the env, puts it in a request header, and calls `http.fetch`; the
// reactor receives that as a `delegate` (an external leaf marked `reactor: "http"`), reveals the secret at the
// boundary, dispatches through a controllable transport, and lifts the response back to a public
// `{ status, body }`. The three tests cover the happy path (with the secret declassified into a public
// response), the unhandled-error path (→ a run-failing `throw[http.fetch_error]`), and the at-most-once
// recovery contract (an interrupted request is never re-sent — it fails on restart).

import { createServer } from "node:http";
import { createAgentName, type IRModule, type QualifiedName, type SchemaInfo } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { InMemoryPersistence, type Persistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { type EnvReader, registerHostPrims } from "../src/runtime/engine/host-prims.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import {
  FetchHttpTransport,
  type HttpCall,
  type HttpCompletion,
  type HttpTransport,
} from "../src/runtime/external/http-transport.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import type { BlobId, DelegationId, ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { type BlobStore, InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import type { Value } from "../src/runtime/value/types.js";

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
    [createAgentName("main")]: { block: 0, private: false },
    [createAgentName("prelude.env.get_secret")]: { block: 6, private: false },
    [createAgentName("prelude.http.fetch")]: { block: 8, private: false },
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
    [createAgentName("main")]: { block: 0, private: false },
    [createAgentName("prelude.http.fetch")]: { block: 8, private: false },
  },
  names: {},
};

/** The public body text the public-body loopback test submits (a plain, non-secret string). */
const PUBLIC_BODY_TEXT = "public-body-text";

// agent main() {
//   let key = prelude.env.get_secret({ key: "API_KEY" })     // a private string
//   return prelude.http.fetch({
//     url, method: "POST",
//     headers: { authorization: key },   // secret in a header (a private submission surface)
//     body: key,                         // AND the same secret in the body (the new private surface)
//   })
// }
// Both surfaces carry the secret so one test proves the whole rule: the reveal at the reactor boundary
// puts BOTH on the wire, and the response the server returns is untainted.
function postSecretBodyIr(url: string): IRModule {
  return {
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
            { kind: "loadLiteral", output: 24, value: { kind: "string", value: url } },
            { kind: "loadLiteral", output: 25, value: { kind: "string", value: "POST" } },
            // The body slot reuses register 22 — the same private secret the header carries.
            {
              kind: "makeRecord",
              entries: [
                ["url", 24],
                ["method", 25],
                ["headers", 23],
                ["body", 22],
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
      6: { block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      7: {
        block: { kind: "primitive", name: "prelude.env.get_secret", input: 70 },
        parameters: { parameter: 70 },
      },
      8: { block: { kind: "agent", body: 9, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      9: {
        block: { kind: "external", key: "fetch", input: 90, reactor: "http" },
        parameters: { parameter: 90 },
      },
    },
    entries: {
      [createAgentName("main")]: { block: 0, private: false },
      [createAgentName("prelude.env.get_secret")]: { block: 6, private: false },
      [createAgentName("prelude.http.fetch")]: { block: 8, private: false },
    },
    names: {},
  };
}

// agent main() { return prelude.http.fetch({ url, method: "POST", headers: {}, body: PUBLIC_BODY_TEXT }) }
// A plain public body: it must reach the wire exactly like before (a public value fits the now
// private-capable `body` sink unchanged — public <: private).
function postPublicBodyIr(url: string): IRModule {
  return {
    metadata: { schemaVersion: 1 },
    blocks: {
      0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      1: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "makeRecord", entries: [], output: 23 },
            { kind: "loadLiteral", output: 24, value: { kind: "string", value: url } },
            { kind: "loadLiteral", output: 25, value: { kind: "string", value: "POST" } },
            { kind: "loadLiteral", output: 26, value: { kind: "string", value: PUBLIC_BODY_TEXT } },
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
      8: { block: { kind: "agent", body: 9, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      9: {
        block: { kind: "external", key: "fetch", input: 90, reactor: "http" },
        parameters: { parameter: 90 },
      },
    },
    entries: {
      [createAgentName("main")]: { block: 0, private: false },
      [createAgentName("prelude.http.fetch")]: { block: 8, private: false },
    },
    names: {},
  };
}

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

  // This double records the handle-carrying argument and never materialises a body, so it needs no resolver.
  useBlobResolver(): void {}

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

  close(): void {
    this.sink = null;
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
  blobs: BlobStore = new InMemoryBlobStore(),
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
    blobs,
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

  test("fails the run with a typed `throw[http.fetch_error]` when the request errors with no handler", async () => {
    const transport = new ControlledHttpTransport();
    const actor = makeActor(transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await waitUntil(() => transport.dispatched[0]);
    transport.feed({
      delegation: call.delegation,
      outcome: { kind: "error", message: "connection refused" },
    });

    // A request that produced no response escalates `throw[http.fetch_error]` (program-anticipatable, a
    // handler could catch it to retry); unhandled, it fails the run with the serialized payload.
    await expect(result).rejects.toThrow(
      /throw: .*prelude\.http\.fetch_error.*connection refused/,
    );
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

// The reveal boundary end-to-end: drive the whole ProjectActor through the REAL `FetchHttpTransport`
// against a loopback http server, so what the server actually receives on the wire is the assertion. This
// proves the stdlib rule change — a `string of private` body reaches the destination server (revealed at
// the single transport boundary, exactly like a secret header) — and that the server's response is never
// tainted by the private request.
describe("http reactor — private body sink (real transport over loopback)", () => {
  interface Loopback {
    url: string;
    /** The last request the server received, filled in on its `end` — read after the run resolves. */
    received: { body: string; authorization: string | null };
    close: () => Promise<void>;
  }

  /** Start a loopback server that records the request body + `authorization` header it receives and replies
   *  200 "ok". Bound to 127.0.0.1 on an ephemeral port so tests never touch a real network. */
  async function startLoopback(): Promise<Loopback> {
    const received: Loopback["received"] = { body: "", authorization: null };
    const server = createServer((request, response) => {
      const chunks: Buffer[] = [];
      request.on("data", (chunk: Buffer) => chunks.push(chunk));
      request.on("end", () => {
        received.body = Buffer.concat(chunks).toString("utf8");
        received.authorization = request.headers.authorization ?? null;
        response.writeHead(200, { "content-type": "text/plain" });
        response.end("ok");
      });
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
    const address = server.address();
    if (address === null || typeof address === "string") {
      throw new Error("loopback server did not bind a port");
    }
    return {
      url: `http://127.0.0.1:${address.port}/submit`,
      received,
      close: () =>
        new Promise<void>((resolve, reject) =>
          server.close((error) => (error ? reject(error) : resolve())),
        ),
    };
  }

  test("reveals a private body to the wire and leaves the response untainted", async () => {
    const loopback = await startLoopback();
    try {
      const actor = makeActor(
        new FetchHttpTransport(),
        new InMemoryPersistence(),
        postSecretBodyIr(loopback.url),
      );
      const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
      const value = await result;

      // The secret reached the actual wire in BOTH private submission surfaces (header AND body), revealed
      // at the reactor boundary — the whole point of making the body a private-capable sink.
      expect(loopback.received.body).toBe("sk-123");
      expect(loopback.received.authorization).toBe("sk-123");

      // Declassified: the response is public even though the request carried a secret body (the reactor
      // mints the response with `jsonToValue`, which never marks a value private — no new taint rule).
      expect(value.private).toBeUndefined();
      expect(value.kind).toBe("record");
      if (value.kind === "record") {
        expect(value.fields.status).toEqual({ kind: "integer", value: 200 });
        expect(value.fields.body).toEqual({ kind: "string", value: "ok" });
        expect(value.fields.status?.private).toBeUndefined();
        expect(value.fields.body?.private).toBeUndefined();
      }
    } finally {
      await loopback.close();
    }
  });

  test("a plain public body still reaches the wire unchanged", async () => {
    const loopback = await startLoopback();
    try {
      const actor = makeActor(
        new FetchHttpTransport(),
        new InMemoryPersistence(),
        postPublicBodyIr(loopback.url),
      );
      const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
      const value = await result;

      // A public value fits the now private-capable `body` sink (public <: private) with no change on the
      // wire — the regression guard that widening the sink did not break the ordinary case.
      expect(loopback.received.body).toBe(PUBLIC_BODY_TEXT);
      expect(value.kind).toBe("record");
      if (value.kind === "record") {
        expect(value.fields.status).toEqual({ kind: "integer", value: 200 });
      }
    } finally {
      await loopback.close();
    }
  });
});

// The file body slots end-to-end: a `file` in a request body rides to the reactor as its HANDLE, and the
// transport reads the bytes from the blob store only at the send boundary. These tests drive the whole
// ProjectActor with a program that forwards its request argument to `http.fetch`, so the request body — a
// real body-sum value built here with a file ref — is exactly what reaches the wire (a loopback server that
// records the raw bytes it received). The last test proves the other half: the external-call envelope the
// reactor hands the transport carries only the handle, never the base64.
describe("http reactor — file request bodies (real transport over loopback)", () => {
  const FILE_BLOB = "blob-http-body" as BlobId;
  // Arbitrary non-UTF-8 bytes (a 0xff), so a base64 / raw comparison is meaningful and text framing is exact.
  const FILE_BYTES = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0xff]);
  const FILE_CONTENT_TYPE = "image/png";
  const FILE_BASE64 = Buffer.from(FILE_BYTES).toString("base64");

  // agent main(request) { return http.fetch(request) } — forwards the whole request, so the test controls
  // the body sum precisely (built as a runtime value and passed as the run argument).
  const FORWARD_FETCH_IR: IRModule = {
    metadata: { schemaVersion: 1 },
    blocks: {
      0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      1: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("prelude.http.fetch") },
              argument: 1,
              output: 2,
            },
            { kind: "exit", target: 0, value: 2 },
          ],
        },
        parameters: { parameter: 1 },
      },
      8: { block: { kind: "agent", body: 9, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      9: {
        block: { kind: "external", key: "fetch", input: 90, reactor: "http" },
        parameters: { parameter: 90 },
      },
    },
    entries: {
      [createAgentName("main")]: { block: 0, private: false },
      [createAgentName("prelude.http.fetch")]: { block: 8, private: false },
    },
    names: {},
  };

  const fileRef: Value = { kind: "ref", semanticKind: "file", blobId: FILE_BLOB };
  const string = (value: string): Value => ({ kind: "string", value });
  const dataValue = (ctor: string, fields: Record<string, Value>): Value => ({
    kind: "record",
    ctor: createAgentName(ctor),
    fields,
  });

  /** The `{ url, method: POST, headers: {}, body }` request value the forwarding program sends. */
  function request(url: string, body: Value): Value {
    return {
      kind: "record",
      fields: {
        url: string(url),
        method: string("POST"),
        headers: { kind: "record", fields: {} },
        body,
      },
    };
  }

  interface RawLoopback {
    url: string;
    /** The raw request bytes + Content-Type the server received, read after the run resolves. */
    received: { body: Buffer; contentType: string | null };
    close: () => Promise<void>;
  }

  /** A loopback server that records the RAW request bytes (not decoded to text) + the Content-Type, so a
   *  binary / multipart body's exact bytes are the assertion. Bound to 127.0.0.1 on an ephemeral port. */
  async function startRawLoopback(): Promise<RawLoopback> {
    const received: RawLoopback["received"] = { body: Buffer.alloc(0), contentType: null };
    const server = createServer((incoming, response) => {
      const chunks: Buffer[] = [];
      incoming.on("data", (chunk: Buffer) => chunks.push(chunk));
      incoming.on("end", () => {
        received.body = Buffer.concat(chunks);
        received.contentType = incoming.headers["content-type"] ?? null;
        response.writeHead(200, { "content-type": "text/plain" });
        response.end("ok");
      });
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
    const address = server.address();
    if (address === null || typeof address === "string") {
      throw new Error("loopback server did not bind a port");
    }
    return {
      url: `http://127.0.0.1:${address.port}/upload`,
      received,
      close: () =>
        new Promise<void>((resolve, reject) =>
          server.close((error) => (error ? reject(error) : resolve())),
        ),
    };
  }

  /** An actor with the file already uploaded (bytes in the store, its row in the warm catalog), driving the
   *  forwarding program through the real `FetchHttpTransport`. */
  async function actorWithFile(http: HttpTransport): Promise<ProjectActor> {
    const blobs = new InMemoryBlobStore();
    await blobs.put(PROJECT, FILE_BLOB, FILE_BYTES);
    const actor = makeActor(http, new InMemoryPersistence(), FORWARD_FETCH_IR, blobs);
    await actor.uploadBlob(FILE_BLOB, {
      hash: "hash-http-body",
      size: FILE_BYTES.byteLength,
      contentType: FILE_CONTENT_TYPE,
      semanticKind: "file",
    });
    return actor;
  }

  test("json body: a file leaf becomes base64 in place, the rest of the tree unchanged", async () => {
    const loopback = await startRawLoopback();
    try {
      const actor = await actorWithFile(new FetchHttpTransport());
      // { name: "avatar", data: <file> } — only `data` should become base64 on the wire.
      const tree: Value = { kind: "record", fields: { name: string("avatar"), data: fileRef } };
      const body = dataValue("prelude.http.json", { value: tree });
      const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, request(loopback.url, body));
      await result;

      expect(loopback.received.contentType).toBe("application/json");
      const document: unknown = JSON.parse(loopback.received.body.toString("utf8"));
      expect(document).toEqual({ name: "avatar", data: FILE_BASE64 });
    } finally {
      await loopback.close();
    }
  });

  test("binary body: the file's raw bytes, its content type the Content-Type", async () => {
    const loopback = await startRawLoopback();
    try {
      const actor = await actorWithFile(new FetchHttpTransport());
      const body = dataValue("prelude.http.binary", { content: fileRef });
      const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, request(loopback.url, body));
      await result;

      expect(new Uint8Array(loopback.received.body)).toEqual(FILE_BYTES);
      expect(loopback.received.contentType).toBe(FILE_CONTENT_TYPE);
    } finally {
      await loopback.close();
    }
  });

  test("multipart body: RFC 7578 parts, the file part carrying the raw bytes", async () => {
    const loopback = await startRawLoopback();
    try {
      const actor = await actorWithFile(new FetchHttpTransport());
      const parts: Value = {
        kind: "array",
        elements: [
          dataValue("prelude.http.multipart_text", { name: string("caption"), content: string("hello") }),
          dataValue("prelude.http.multipart_file", {
            name: string("upload"),
            filename: string("logo.png"),
            content: fileRef,
          }),
        ],
      };
      const body = dataValue("prelude.http.multipart", { parts });
      const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, request(loopback.url, body));
      await result;

      expect(loopback.received.contentType).toMatch(/^multipart\/form-data; boundary=----katari[0-9a-f]+$/);
      // Read the framing as latin1 so raw file bytes survive the round-trip for the structural assertions.
      const framed = loopback.received.body.toString("latin1");
      expect(framed).toContain('Content-Disposition: form-data; name="caption"');
      expect(framed).toContain("hello");
      expect(framed).toContain('Content-Disposition: form-data; name="upload"; filename="logo.png"');
      expect(framed).toContain(`Content-Type: ${FILE_CONTENT_TYPE}`);
      // The file part carries the exact raw bytes (not base64, not decoded).
      expect(loopback.received.body.includes(Buffer.from(FILE_BYTES))).toBe(true);
    } finally {
      await loopback.close();
    }
  });

  test("the envelope handed to the transport carries the file HANDLE, never the base64 bytes", async () => {
    const transport = new ControlledHttpTransport();
    const actor = await actorWithFile(transport);
    const tree: Value = { kind: "record", fields: { data: fileRef } };
    const body = dataValue("prelude.http.json", { value: tree });
    actor.startRun(createAgentName("main"), SNAPSHOT, request("https://example.test/x", body));

    const call = await waitUntil(() => transport.dispatched[0]);
    // The body rides as the slim `$ref` handle, exactly as the value plane / DB / trace hold it.
    expect(call.argument).toMatchObject({
      body: {
        $constructor: "prelude.http.json",
        value: { value: { data: { $ref: FILE_BLOB, semanticKind: "file" } } },
      },
    });
    // The base64 of the bytes is nowhere in the envelope — it is born only inside the transport's send.
    expect(JSON.stringify(call.argument)).not.toContain(FILE_BASE64);
  });
});
