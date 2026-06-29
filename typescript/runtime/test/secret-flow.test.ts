// End-to-end secret information flow through the in-memory core: a private value enters (a `secret` source
// primitive, or a private run argument) and the engine keeps the `private` marker faithful as it flows
// through a pure primitive, a field read, a `let` destructure, and a `for` map. The marker is what the
// user-facing API redacts and persistence encrypts, so these are the propagation rules those boundaries rely
// on. `register` on the prim registry is the documented seam a real `env` / `secret` source plugs into.

import { createAgentName, type IRModule, type QualifiedName, type SchemaInfo } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { InMemoryPersistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import type { ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { valueToJson } from "../src/runtime/value/codec.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-secret" as ProjectId;
const SNAPSHOT = "snapshot-secret" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

/** A leaf primitive wrapped in its agent: `entries[name] -> agent -> BlockPrimitive`. Two block ids. */
function primitiveWrapper(agentId: number, leafId: number, inputVar: number, name: string) {
  return {
    [agentId]: {
      block: { kind: "agent", body: leafId, schema: EMPTY_SCHEMA, defaults: {} },
      parameters: {},
    },
    [leafId]: {
      block: { kind: "primitive", name, input: inputVar },
      parameters: { parameter: inputVar },
    },
  } as const;
}

/** A prim registry with a `primitive.secret` source that returns a fixed private string (mirrors how a real
 *  env / secret source would be registered by the host). */
function secretPrims(): PrimRegistry {
  const prims = new PrimRegistry();
  prims.register("primitive.secret", () => ({ kind: "string", value: "sk-123", private: true }));
  return prims;
}

function run(ir: IRModule, entry: string, argument: Value | null): Promise<Value> {
  const registry = new SnapshotRegistry();
  for (const name of Object.keys(ir.entries)) {
    registry.set(SNAPSHOT, moduleOfName(name as QualifiedName), ir);
  }
  const actor = new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims: secretPrims(),
    blobs: new InMemoryBlobStore(),
    external: new StubFfiTransport(),
    persistence: new InMemoryPersistence(),
  });
  return actor.startRun(createAgentName(entry), SNAPSHOT, argument).result;
}

describe("secret information flow", () => {
  test("a pure primitive taints its result from a secret input (concat of a secret is secret)", async () => {
    // agent main() { return concat(secret(), " world") }
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "makeRecord", entries: [], output: 2 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("primitive.secret") },
                argument: 2,
                output: 3,
              },
              { kind: "loadLiteral", output: 4, value: { kind: "string", value: " world" } },
              {
                kind: "makeRecord",
                entries: [
                  ["left", 3],
                  ["right", 4],
                ],
                output: 5,
              },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("primitive.concat") },
                argument: 5,
                output: 6,
              },
              { kind: "exit", target: 0, value: 6 },
            ],
          },
          parameters: { parameter: 1 },
        },
        ...primitiveWrapper(10, 11, 12, "primitive.secret"),
        ...primitiveWrapper(20, 21, 22, "primitive.concat"),
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("primitive.secret")]: 10,
        [createAgentName("primitive.concat")]: 20,
      },
      names: {},
    };

    const result = await run(ir, "main", null);
    expect(result).toEqual({ kind: "string", value: "sk-123 world", private: true });
    // The user-facing API would redact it; the FFI sidecar would see the real value.
    expect(valueToJson(result, "redact")).toEqual({ $redacted: true });
    expect(valueToJson(result, "reveal")).toBe("sk-123 world");
  });

  test("a field read inherits the container's privacy", async () => {
    // agent main(p) { return p.token }   with p a private record { token: "t" }
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "getField", source: 10, field: "token", output: 11 },
              { kind: "exit", target: 0, value: 11 },
            ],
          },
          parameters: { parameter: 10 },
        },
      },
      entries: { [createAgentName("main")]: 0 },
      names: {},
    };

    const argument: Value = {
      kind: "record",
      private: true,
      fields: { token: { kind: "string", value: "t" } },
    };
    expect(await run(ir, "main", argument)).toEqual({ kind: "string", value: "t", private: true });
  });

  test("a let destructure inherits the container's privacy (the field value itself is public)", async () => {
    // agent main(p) { let { token: t } = p; return t }   with p a private record { token: "x" }
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              {
                kind: "bindPattern",
                pattern: { kind: "record", fields: [["token", { kind: "variable", variable: 40 }]] },
                source: 10,
              },
              { kind: "exit", target: 0, value: 40 },
            ],
          },
          parameters: { parameter: 10 },
        },
      },
      entries: { [createAgentName("main")]: 0 },
      names: {},
    };

    const argument: Value = {
      kind: "record",
      private: true,
      fields: { token: { kind: "string", value: "x" } },
    };
    expect(await run(ir, "main", argument)).toEqual({ kind: "string", value: "x", private: true });
  });

  test("iterating a private array binds each element as private", async () => {
    // agent main(rec) { for (x in rec.xs) { x } }   with rec.xs a private array (rec itself public)
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "getField", source: 10, field: "xs", output: 11 },
              { kind: "call", target: 2, output: 12 },
              { kind: "exit", target: 0, value: 12 },
            ],
          },
          parameters: { parameter: 10 },
        },
        2: {
          block: {
            kind: "for",
            parallel: false,
            source: 11,
            initialStates: [],
            body: 3,
            thenClause: null,
          },
          parameters: {},
        },
        // identity body: the iteration's value is the element itself (an implicit next on fall-through)
        3: { block: { kind: "sequence", result: 20, operations: [] }, parameters: { iterator: 20 } },
      },
      entries: { [createAgentName("main")]: 0 },
      names: {},
    };

    const argument: Value = {
      kind: "record",
      fields: {
        xs: {
          kind: "array",
          private: true,
          elements: [
            { kind: "integer", value: 1 },
            { kind: "integer", value: 2 },
          ],
        },
      },
    };
    expect(await run(ir, "main", argument)).toEqual({
      kind: "array",
      elements: [
        { kind: "integer", value: 1, private: true },
        { kind: "integer", value: 2, private: true },
      ],
    });
  });

  test("a panic carrying a secret redacts the run error message (no plaintext at the wire / at rest)", async () => {
    // agent main() { panic({ msg: secret() }) }  — unhandled, the panic fails the run. Its message becomes
    // the run's errorMessage, which is neither redacted at the wire nor sealed at rest, so the secret must be
    // redacted at the source. `primitive.panic` is a request (an agent wrapping a request leaf), not a prim.
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "makeRecord", entries: [], output: 2 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("primitive.secret") },
                argument: 2,
                output: 3,
              },
              { kind: "makeRecord", entries: [["msg", 3]], output: 4 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("primitive.panic") },
                argument: 4,
                output: 5,
              },
              { kind: "exit", target: 0, value: 5 },
            ],
          },
          parameters: { parameter: 1 },
        },
        ...primitiveWrapper(10, 11, 12, "primitive.secret"),
        20: { block: { kind: "agent", body: 21, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        21: {
          block: { kind: "request", name: createAgentName("primitive.panic"), input: 22 },
          parameters: { parameter: 22 },
        },
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("primitive.secret")]: 10,
        [createAgentName("primitive.panic")]: 20,
      },
      names: {},
    };

    // The run rejects with the redacted placeholder; the secret value "sk-123" never appears in the message.
    await expect(run(ir, "main", null)).rejects.toThrow("panic: [redacted]");
  });
});
