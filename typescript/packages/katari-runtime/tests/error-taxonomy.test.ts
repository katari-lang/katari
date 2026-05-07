import { describe, expect, it } from "vitest";
import {
  applyEvent,
  createMachine,
  EntryNotFoundError,
  RecoverableEngineError,
  type MachineEvent,
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
    blocks: Object.fromEntries(
      Object.entries(blocks).map(([k, v]) => [k, v]),
    ),
    entries: { [entryName]: entryBlockId },
    nameTable: { varNames: {}, blockNames: {} },
  };
}

function delegate(qualifiedName: string, delegationId?: DelegationId): MachineEvent {
  return {
    from: "API",
    to: "CORE",
    kind: "delegate",
    qualifiedName,
    args: {},
    delegationId: delegationId ?? (("d-" + Math.random().toString(36).slice(2)) as DelegationId),
  };
}

describe("Engine error taxonomy", () => {
  it("typo'd qualifiedName → EntryNotFoundError (recoverable)", () => {
    // Even an empty IR — a missing qualifiedName should never poison.
    const ir = makeIR({}, "main", 0);
    const machine = createMachine(ir);
    const myDelegation = "d-test-delegation" as DelegationId;
    let caught: unknown;
    try {
      applyEvent(machine, delegate("typo", myDelegation));
    } catch (err) {
      caught = err;
    }
    expect(caught).toBeInstanceOf(EntryNotFoundError);
    expect(caught).toBeInstanceOf(RecoverableEngineError);
    if (caught instanceof EntryNotFoundError) {
      expect(caught.qualifiedName).toBe("typo");
      expect(caught.delegationId).toBe(myDelegation);
    }
  });

  it("prim with mismatched arg kind → RecoverableEngineError", () => {
    // agent main() -> ? { add(left=string("hi"), right=number(1)) }
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
                output: 1 as VarId,
                value: { kind: "literalValueString", string: "hi" },
              },
            },
            {
              kind: "statementLoadLiteral",
              contents: {
                output: 2 as VarId,
                value: { kind: "literalValueInteger", integer: 1 },
              },
            },
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 1 },
                arguments: [
                  { label: "left", var: 1 as VarId },
                  { label: "right", var: 2 as VarId },
                ],
                output: 3 as VarId,
              },
            },
            {
              kind: "statementExit",
              contents: { exitKind: "exitKindReturn", value: 3 as VarId },
            },
          ],
        },
      },
      1: { kind: "blockPrim", name: "add" },
    };
    const ir = makeIR(blocks, "main", 0);
    const machine = createMachine(ir);
    expect(() => applyEvent(machine, delegate("main"))).toThrowError(RecoverableEngineError);
  });

  it("match with no arms and no default → RecoverableEngineError", () => {
    // agent main() -> ? { match (var0 = "x") {} }
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
                value: { kind: "literalValueString", string: "x" },
              },
            },
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 1 },
                arguments: [],
                output: 1 as VarId,
              },
            },
            {
              kind: "statementExit",
              contents: { exitKind: "exitKindReturn", value: 1 as VarId },
            },
          ],
        },
      },
      1: {
        kind: "blockMatch",
        matchBlock: { subject: 0 as VarId, arms: [] },
      },
    };
    const ir = makeIR(blocks, "main", 0);
    const machine = createMachine(ir);
    expect(() => applyEvent(machine, delegate("main"))).toThrowError(RecoverableEngineError);
  });

  it("RecoverableEngineError instances are also Errors (so generic Error catch still catches them)", () => {
    const ir = makeIR({}, "main", 0);
    const machine = createMachine(ir);
    let caught: unknown;
    try {
      applyEvent(machine, delegate("typo"));
    } catch (err) {
      caught = err;
    }
    expect(caught).toBeInstanceOf(Error);
  });
});
