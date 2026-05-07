import { describe, expect, it } from "vitest";
import {
  applyEvent,
  createMachine,
  type MachineEvent,
  type Value,
} from "../src/index.js";
import type {
  Block,
  IRMetadata,
  IRModule,
  VarId,
} from "../src/ir/types.js";
import type { DelegationId } from "../src/machine/id.js";

function metadata(): IRMetadata {
  return { schemaVersion: 1 };
}
function makeIR(blocks: Record<number, Block>, entryName: string, entryBlockId: number): IRModule {
  return {
    metadata: metadata(),
    name: "test",
    blocks: Object.fromEntries(Object.entries(blocks).map(([k, v]) => [k, v])),
    entries: { [entryName]: entryBlockId },
    nameTable: { varNames: {}, blockNames: {} },
  };
}
function delegate(qualifiedName: string): MachineEvent {
  return {
    from: "API",
    to: "CORE",
    kind: "delegate",
    qualifiedName,
    args: {},
    delegationId: ("d-" + Math.random().toString(36).slice(2)) as DelegationId,
  };
}
function lastDelegateAck(events: MachineEvent[]): Value {
  const ack = [...events].reverse().find((e) => e.kind === "delegateAck");
  if (!ack || ack.kind !== "delegateAck") throw new Error("no ack");
  return ack.value;
}

/** Inline block that loads `n` and trails it. */
function literalBlock(n: number, varId = 999): Block {
  return {
    kind: "blockUser",
    body: {
      kind: "blockKindInline",
      parameters: [],
      statements: [
        {
          kind: "statementLoadLiteral",
          contents: {
            output: varId as VarId,
            value: { kind: "literalValueInteger", integer: n },
          },
        },
      ],
      trailing: varId as VarId,
    },
  };
}

/** Build a top-level "agent main returns a structural value" IR. */
function agentReturningStructural(structuralBlockId: number, blocks: Record<number, Block>): IRModule {
  blocks[0] = {
    kind: "blockUser",
    body: {
      kind: "blockKindAgent",
      parameters: [],
      statements: [
        {
          kind: "statementCall",
          contents: {
            target: { kind: "callTargetBlock", block: structuralBlockId },
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
  };
  return makeIR(blocks, "main", 0);
}

describe("ArrayThread", () => {
  it("empty array → []", () => {
    const blocks: Record<number, Block> = {
      1: { kind: "blockArray", arrayBlock: { parallel: false, elements: [] } },
    };
    const machine = createMachine(agentReturningStructural(1, blocks));
    expect(lastDelegateAck(applyEvent(machine, delegate("main")))).toEqual({
      kind: "array",
      elements: [],
    });
  });

  it("sequential array preserves element order", () => {
    const blocks: Record<number, Block> = {
      1: { kind: "blockArray", arrayBlock: { parallel: false, elements: [10, 11, 12] } },
      10: literalBlock(5, 1000),
      11: literalBlock(6, 1001),
      12: literalBlock(7, 1002),
    };
    const machine = createMachine(agentReturningStructural(1, blocks));
    expect(lastDelegateAck(applyEvent(machine, delegate("main")))).toEqual({
      kind: "array",
      elements: [
        { kind: "number", value: 5 },
        { kind: "number", value: 6 },
        { kind: "number", value: 7 },
      ],
    });
  });

  it("parallel array preserves index-based order despite concurrent dispatch", () => {
    const blocks: Record<number, Block> = {
      1: { kind: "blockArray", arrayBlock: { parallel: true, elements: [10, 11, 12] } },
      10: literalBlock(100, 1000),
      11: literalBlock(200, 1001),
      12: literalBlock(300, 1002),
    };
    const machine = createMachine(agentReturningStructural(1, blocks));
    expect(lastDelegateAck(applyEvent(machine, delegate("main")))).toEqual({
      kind: "array",
      elements: [
        { kind: "number", value: 100 },
        { kind: "number", value: 200 },
        { kind: "number", value: 300 },
      ],
    });
  });

  it("nested array (array of array)", () => {
    const blocks: Record<number, Block> = {
      // outer = [inner_a, inner_b]
      1: { kind: "blockArray", arrayBlock: { parallel: false, elements: [2, 3] } },
      // inner_a = [1, 2]
      2: { kind: "blockArray", arrayBlock: { parallel: false, elements: [10, 11] } },
      // inner_b = [3]
      3: { kind: "blockArray", arrayBlock: { parallel: false, elements: [12] } },
      10: literalBlock(1, 1000),
      11: literalBlock(2, 1001),
      12: literalBlock(3, 1002),
    };
    const machine = createMachine(agentReturningStructural(1, blocks));
    expect(lastDelegateAck(applyEvent(machine, delegate("main")))).toEqual({
      kind: "array",
      elements: [
        {
          kind: "array",
          elements: [
            { kind: "number", value: 1 },
            { kind: "number", value: 2 },
          ],
        },
        {
          kind: "array",
          elements: [{ kind: "number", value: 3 }],
        },
      ],
    });
  });
});

describe("TupleThread", () => {
  it("empty tuple → ()", () => {
    const blocks: Record<number, Block> = {
      1: { kind: "blockTuple", tupleBlock: { parallel: false, elements: [] } },
    };
    const machine = createMachine(agentReturningStructural(1, blocks));
    expect(lastDelegateAck(applyEvent(machine, delegate("main")))).toEqual({
      kind: "tuple",
      elements: [],
    });
  });

  it("sequential tuple preserves element order", () => {
    const blocks: Record<number, Block> = {
      1: { kind: "blockTuple", tupleBlock: { parallel: false, elements: [10, 11] } },
      10: literalBlock(11, 1000),
      11: literalBlock(22, 1001),
    };
    const machine = createMachine(agentReturningStructural(1, blocks));
    expect(lastDelegateAck(applyEvent(machine, delegate("main")))).toEqual({
      kind: "tuple",
      elements: [
        { kind: "number", value: 11 },
        { kind: "number", value: 22 },
      ],
    });
  });

  it("parallel tuple preserves index order", () => {
    const blocks: Record<number, Block> = {
      1: { kind: "blockTuple", tupleBlock: { parallel: true, elements: [10, 11, 12] } },
      10: literalBlock(7, 1000),
      11: literalBlock(8, 1001),
      12: literalBlock(9, 1002),
    };
    const machine = createMachine(agentReturningStructural(1, blocks));
    expect(lastDelegateAck(applyEvent(machine, delegate("main")))).toEqual({
      kind: "tuple",
      elements: [
        { kind: "number", value: 7 },
        { kind: "number", value: 8 },
        { kind: "number", value: 9 },
      ],
    });
  });
});
