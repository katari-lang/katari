// Shared fixtures for api-server tests. Builds a minimal but useful IR
// module + matching schema bundle.
//
// All entries are wrapped in a `blockAgent` (the externally-callable
// boundary in the new runtime). The inner `blockUser` body holds the
// actual statements (the agent boundary semantics live on the wrapper,
// not the inner block).

import type { IRModule, SchemaBundle } from "katari-runtime";
import type { Block, VarId } from "katari-runtime/dist/ir/types.js";

// A trivial agent: agent main() -> string { return "hi" }
export function literalReturnIR(literal: string, irName = "test"): IRModule {
  const blocks: Record<number, Block> = {
    0: {
      kind: "blockAgent",
      body: {
        qualifiedName: { module_: irName, name: "main" },
        parameters: [],
        entryBody: 1,
      },
    },
    1: {
      kind: "blockUser",
      body: {
        parameters: [],
        statements: [
          {
            kind: "statementLoadLiteral",
            body: {
              output: 0 as VarId,
              value: { kind: "literalValueString", string: literal },
            },
          },
          {
            kind: "statementExit",
            body: { exitKind: "exitKindReturn", value: 0 as VarId },
          },
        ],
      },
    },
  };
  return {
    metadata: { schemaVersion: 1 },
    name: irName,
    blocks: Object.fromEntries(
      Object.entries(blocks).map(([k, v]) => [k, v]),
    ),
    entries: { main: 0 },
    nameTable: { varNames: {}, blockNames: {} },
  };
}

// Calls an external block, so machine pauses on outbound delegate.
export function pausesOnExternalIR(irName = "test"): IRModule {
  const blocks: Record<number, Block> = {
    0: {
      kind: "blockAgent",
      body: {
        qualifiedName: { module_: irName, name: "main" },
        parameters: [],
        entryBody: 1,
      },
    },
    1: {
      kind: "blockUser",
      body: {
        parameters: [],
        statements: [
          {
            kind: "statementCall",
            body: {
              target: { kind: "callTargetBlock", block: 2 },
              arguments: [],
              output: 0 as VarId,
            },
          },
          {
            kind: "statementExit",
            body: { exitKind: "exitKindReturn", value: 0 as VarId },
          },
        ],
      },
    },
    2: {
      kind: "blockExternal",
      body: { module_: irName, name: "ext_call" },
    },
  };
  return {
    metadata: { schemaVersion: 1 },
    name: irName,
    blocks: Object.fromEntries(
      Object.entries(blocks).map(([k, v]) => [k, v]),
    ),
    entries: { main: 0 },
    nameTable: { varNames: {}, blockNames: {} },
  };
}

export function trivialSchemaBundle(): SchemaBundle {
  return {
    schemaVersion: 1,
    agents: [
      {
        qualifiedName: { module_: "test", name: "main" },
        parameters: { type: "object", properties: {} },
        returns: { type: "string" },
        description: "Returns a greeting",
      },
    ],
  };
}
