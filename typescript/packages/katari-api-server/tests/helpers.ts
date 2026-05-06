// Shared fixtures for api-server tests. Builds a minimal but useful IR
// module + matching schema bundle.

import type { IRModule, SchemaBundle } from "katari-runtime";
import type { Block, VarId } from "katari-runtime/dist/ir/types.js";

// A trivial agent: agent main() -> string { return "hi" }
export function literalReturnIR(literal: string, irName = "test"): IRModule {
  const blocks: Record<number, Block> = {
    0: {
      kind: "blockUser",
      body: {
        kind: "blockKindAgent",
        parameters: [],
        statements: [
          {
            kind: "statementLoadLiteral",
            contents: {
              output: 0 as VarId,
              value: { kind: "literalValueString", string: literal },
            },
          },
          {
            kind: "statementExit",
            contents: { exitKind: "exitKindReturn", value: 0 as VarId },
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
      kind: "blockUser",
      body: {
        kind: "blockKindAgent",
        parameters: [],
        statements: [
          {
            kind: "statementCall",
            contents: {
              target: { kind: "callTargetBlock", block: 1 },
              arguments: [],
              output: 0 as VarId,
            },
          },
          {
            kind: "statementExit",
            contents: { exitKind: "exitKindReturn", value: 0 as VarId },
          },
        ],
      },
    },
    1: {
      kind: "blockExternal",
      externalName: { module_: irName, name: "ext_call" },
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
