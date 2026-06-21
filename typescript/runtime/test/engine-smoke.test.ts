// End-to-end smoke test for the in-memory core: hand-built IR driven through the ProjectActor, with no
// compiler and no DB. Exercises the uniform delegate model (every primitive is a child instance), the
// internal turn loop, structural nodes (for / match), control flow (return), and the value model.

import { createAgentName, type IRModule, type SchemaInfo } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { InMemoryPersistence } from "../src/runtime/actor/persistence.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import type { ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-smoke" as ProjectId;
const SNAPSHOT = "snapshot-smoke" as SnapshotId;
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

function run(ir: IRModule, entry: string, argument: Value | null): Promise<Value> {
  const registry = new SnapshotRegistry();
  registry.set(SNAPSHOT, ir);
  const actor = new ProjectActor({
    projectId: PROJECT,
    registry,
    prims: new PrimRegistry(),
    blobs: new InMemoryBlobStore(),
    persistence: new InMemoryPersistence(),
  });
  return actor.startRun(createAgentName(entry), SNAPSHOT, argument);
}

describe("in-memory core", () => {
  test("returns an arithmetic result through the uniform delegate model", async () => {
    // agent main() { return 1 + 2 }   (every `+` is a delegate to a `primitive.add` child instance)
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 2, value: { kind: "integer", value: 1 } },
              { kind: "loadLiteral", output: 3, value: { kind: "integer", value: 2 } },
              {
                kind: "makeRecord",
                entries: [
                  ["left", 2],
                  ["right", 3],
                ],
                output: 4,
              },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("primitive.add") },
                argument: 4,
                output: 5,
              },
              { kind: "exit", target: 0, value: 5 },
            ],
          },
          parameters: { parameter: 1 },
        },
        ...primitiveWrapper(6, 7, 8, "primitive.add"),
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("primitive.add")]: 6,
      },
      names: {},
    };

    await expect(run(ir, "main", null)).resolves.toEqual({ kind: "integer", value: 3 });
  });

  test("maps a sequential for loop over an array argument", async () => {
    // agent triple(xs) { for (x in xs) { x * 3 } }
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        // triple agent + body
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
        // for node
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
        // for body: x * 3  (falls through with the product => mapped value)
        3: {
          block: {
            kind: "sequence",
            result: 22,
            operations: [
              { kind: "loadLiteral", output: 21, value: { kind: "integer", value: 3 } },
              {
                kind: "makeRecord",
                entries: [
                  ["left", 20],
                  ["right", 21],
                ],
                output: 23,
              },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("primitive.multiply") },
                argument: 23,
                output: 22,
              },
            ],
          },
          parameters: { iterator: 20 },
        },
        ...primitiveWrapper(6, 7, 8, "primitive.multiply"),
      },
      entries: {
        [createAgentName("triple")]: 0,
        [createAgentName("primitive.multiply")]: 6,
      },
      names: {},
    };

    const argument: Value = {
      kind: "record",
      fields: {
        xs: {
          kind: "array",
          elements: [
            { kind: "integer", value: 1 },
            { kind: "integer", value: 2 },
            { kind: "integer", value: 4 },
          ],
        },
      },
    };
    await expect(run(ir, "triple", argument)).resolves.toEqual({
      kind: "array",
      elements: [
        { kind: "integer", value: 3 },
        { kind: "integer", value: 6 },
        { kind: "integer", value: 12 },
      ],
    });
  });

  test("selects a match arm and binds its pattern variable", async () => {
    // agent classify(n) { match n { 0 => "zero"; m => "other" } }   (over the record field `n`)
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "getField", source: 10, field: "n", output: 11 },
              { kind: "call", target: 2, output: 12 },
              { kind: "exit", target: 0, value: 12 },
            ],
          },
          parameters: { parameter: 10 },
        },
        2: {
          block: {
            kind: "match",
            subject: 11,
            arms: [
              { pattern: { kind: "literal", value: { kind: "integer", value: 0 } }, body: 3 },
              { pattern: { kind: "variable", variable: 30 }, body: 4 },
            ],
            fallback: null,
          },
          parameters: {},
        },
        3: {
          block: {
            kind: "sequence",
            result: 31,
            operations: [
              { kind: "loadLiteral", output: 31, value: { kind: "string", value: "zero" } },
            ],
          },
          parameters: {},
        },
        4: {
          block: {
            kind: "sequence",
            result: 41,
            operations: [
              { kind: "loadLiteral", output: 41, value: { kind: "string", value: "other" } },
            ],
          },
          parameters: {},
        },
      },
      entries: { [createAgentName("classify")]: 0 },
      names: {},
    };

    await expect(
      run(ir, "classify", { kind: "record", fields: { n: { kind: "integer", value: 0 } } }),
    ).resolves.toEqual({ kind: "string", value: "zero" });
    await expect(
      run(ir, "classify", { kind: "record", fields: { n: { kind: "integer", value: 7 } } }),
    ).resolves.toEqual({ kind: "string", value: "other" });
  });
});
