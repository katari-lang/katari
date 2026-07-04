// The typed error channel across the FFI boundary, end to end through the ProjectActor: a handler raises
// `FfiThrow` (the in-process analogue of the port's `katari.throw`) and the call fails as a `prelude.throw`
// a katari-side handler catches — while a plain JS error stays a panic that the throw handler must NOT
// catch. Inward, a katari callee's throw reaches the handler's `context.call` as a typed `FfiThrow`
// rejection (payload intact, not a flattened message), and an uncaught one rethrows: the payload rides the
// full circle katari → sidecar → katari unchanged.

import {
  createAgentName,
  type IRModule,
  type Operation,
  type QualifiedName,
  type SchemaInfo,
} from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { InMemoryPersistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import {
  type FfiHandler,
  FfiThrow,
  InProcessFfiTransport,
} from "../src/runtime/external/runner.js";
import type { ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-ffi-throw" as ProjectId;
const SNAPSHOT = "snapshot-ffi-throw" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };
const THROW = createAgentName("prelude.throw");

/** `{ error: { message } }` raise operations: build the payload record and delegate to `prelude.throw`. */
function raiseOperations(message: string, base: number, output: number): Operation[] {
  return [
    { kind: "loadLiteral", output: base, value: { kind: "string", value: message } },
    { kind: "makeRecord", entries: [["message", base]], output: base + 1 },
    { kind: "makeRecord", entries: [["error", base + 1]], output: base + 2 },
    { kind: "delegate", target: { kind: "name", name: THROW }, argument: base + 2, output },
  ];
}

/** The shared program.
 *    agent main() { handle { compute({}) } with throw(e) => break -1 }   — the catching entry
 *    agent plain() { return compute({}) }                                — the uncaught entry
 *    agent thrower() { throw({ message: "inner boom" }) }                — a katari callee that throws
 *  with `compute` the external (FFI) agent under test. */
function ir(): IRModule {
  return {
    metadata: { schemaVersion: 1 },
    blocks: {
      // main: handle-wrapped external call, with a `prelude.throw` handler breaking -1.
      0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      1: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "call", target: 2, output: 10 },
            { kind: "exit", target: 0, value: 10 },
          ],
        },
        parameters: { parameter: 99 },
      },
      2: {
        block: {
          kind: "handle",
          parallel: false,
          initialStates: [],
          body: 3,
          handlers: [{ request: THROW, body: 4 }],
          thenClause: null,
        },
        parameters: {},
      },
      3: {
        block: {
          kind: "sequence",
          result: 33,
          operations: [
            { kind: "makeRecord", entries: [], output: 31 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("compute") },
              argument: 31,
              output: 33,
            },
          ],
        },
        parameters: {},
      },
      4: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "loadLiteral", output: 40, value: { kind: "integer", value: -1 } },
            { kind: "exit", target: 2, value: 40 },
          ],
        },
        parameters: { parameter: 41 },
      },
      // compute: the external agent under test.
      6: { block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      7: {
        block: { kind: "external", key: "compute", input: 8, reactor: "ffi" },
        parameters: { parameter: 8 },
      },
      // plain: the same external call with no handler around it.
      10: {
        block: { kind: "agent", body: 11, schema: EMPTY_SCHEMA, defaults: {} },
        parameters: {},
      },
      11: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "makeRecord", entries: [], output: 50 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("compute") },
              argument: 50,
              output: 51,
            },
            { kind: "exit", target: 10, value: 51 },
          ],
        },
        parameters: { parameter: 52 },
      },
      // thrower: a katari callee whose body raises `prelude.throw` (for the handler to call back into).
      15: {
        block: { kind: "agent", body: 16, schema: EMPTY_SCHEMA, defaults: {} },
        parameters: {},
      },
      16: {
        block: {
          kind: "sequence",
          result: 63,
          operations: [...raiseOperations("inner boom", 60, 63)],
        },
        parameters: { parameter: 66 },
      },
      // The `prelude.throw` wrapper pair a raise delegates to.
      20: {
        block: { kind: "agent", body: 21, schema: EMPTY_SCHEMA, defaults: {} },
        parameters: {},
      },
      21: {
        block: { kind: "request", name: THROW, input: 70 },
        parameters: { parameter: 70 },
      },
    },
    entries: {
      [createAgentName("main")]: 0,
      [createAgentName("plain")]: 10,
      [createAgentName("compute")]: 6,
      [createAgentName("thrower")]: 15,
      [THROW]: 20,
    },
    names: {},
  };
}

function run(entry: string, handlers: Record<string, FfiHandler>): Promise<Value> {
  const registry = new SnapshotRegistry();
  const module = ir();
  for (const name of Object.keys(module.entries)) {
    registry.set(SNAPSHOT, moduleOfName(name as QualifiedName), module);
  }
  const actor = new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims: new PrimRegistry(),
    blobs: new InMemoryBlobStore(),
    external: new InProcessFfiTransport(handlers),
    http: new StubHttpTransport(),
    persistence: new InMemoryPersistence(),
  });
  return actor.startRun(createAgentName(entry), SNAPSHOT, null).result;
}

describe("typed throw across the FFI boundary", () => {
  test("a handler's FfiThrow is caught by a katari-side `prelude.throw` handler", async () => {
    const result = run("main", {
      compute: () => {
        throw new FfiThrow({ $constructor: "main.my_error", value: { message: "ffi boom" } });
      },
    });
    await expect(result).resolves.toEqual({ kind: "integer", value: -1 });
  });

  test("an uncaught FfiThrow fails the run with the serialized payload (not a panic)", async () => {
    const failure = run("plain", {
      compute: () => {
        throw new FfiThrow({ $constructor: "main.my_error", value: { message: "ffi boom" } });
      },
    });
    await expect(failure).rejects.toThrow(/throw: .*ffi boom/);
    await expect(failure).rejects.not.toThrow(/panic/);
  });

  test("a plain JS error stays a panic — the katari throw handler does not catch it", async () => {
    const failure = run("main", {
      compute: () => {
        throw new Error("infrastructure kaboom");
      },
    });
    await expect(failure).rejects.toThrow(/panic: .*infrastructure kaboom/);
  });

  test("a katari callee's throw reaches the handler as a typed FfiThrow rejection", async () => {
    const result = run("plain", {
      compute: async (_argument, context) => {
        try {
          await context.call("thrower");
          return "unreachable";
        } catch (error) {
          if (!(error instanceof FfiThrow)) throw error;
          const payload = error.error;
          const message =
            typeof payload === "object" && payload !== null && !Array.isArray(payload)
              ? payload.message
              : null;
          return `caught: ${String(message)}`;
        }
      },
    });
    await expect(result).resolves.toEqual({ kind: "string", value: "caught: inner boom" });
  });

  test("an uncaught inner throw rethrows: the payload rides katari → sidecar → katari unchanged", async () => {
    // The handler does not catch, so the callee's typed error becomes the handler's own typed throw —
    // which main's katari-side handler catches, closing the full circle.
    const result = run("main", {
      compute: (_argument, context) => context.call("thrower"),
    });
    await expect(result).resolves.toEqual({ kind: "integer", value: -1 });
  });
});
