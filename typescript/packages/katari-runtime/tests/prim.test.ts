import { describe, expect, it } from "vitest";
import {
  applyEvent,
  createMachine,
  type MachineEvent,
} from "../src/index.js";
import type {
  Block,
  IRMetadata,
  IRModule,
  VarId,
} from "../src/ir/types.js";
import type { DelegationId } from "../src/machine/id.js";

// ─── helpers ────────────────────────────────────────────────────────────────

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

/**
 * Build an agent that does `op(left, right)` and returns the result.
 * Used to drive a prim through the full UserThread machinery so we get
 * the same throw path the engine actually takes at runtime (rather than
 * calling the prim function directly, which is not exported).
 */
function agentApplyingPrim(
  primName: string,
  leftLit: number,
  rightLit: number,
): IRModule {
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
              value: { kind: "literalValueInteger", integer: leftLit },
            },
          },
          {
            kind: "statementLoadLiteral",
            contents: {
              output: 2 as VarId,
              value: { kind: "literalValueInteger", integer: rightLit },
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
    1: { kind: "blockPrim", name: primName },
  };
  return makeIR(blocks, "main", 0);
}

// ─── Tests ──────────────────────────────────────────────────────────────────

describe("prim div / mod", () => {
  it("div by non-zero returns the quotient", () => {
    const machine = createMachine(agentApplyingPrim("div", 10, 4));
    const out = applyEvent(machine, delegate("main"));
    const ack = [...out].reverse().find((e) => e.kind === "delegateAck");
    expect(ack && ack.kind === "delegateAck" && ack.value).toEqual({
      kind: "number",
      value: 2.5,
    });
  });

  it("div by zero throws (no NaN / Infinity propagation)", () => {
    const machine = createMachine(agentApplyingPrim("div", 1, 0));
    expect(() => applyEvent(machine, delegate("main"))).toThrowError(
      /prim div: division by zero/,
    );
  });

  it("mod by non-zero returns the remainder", () => {
    const machine = createMachine(agentApplyingPrim("mod", 10, 3));
    const out = applyEvent(machine, delegate("main"));
    const ack = [...out].reverse().find((e) => e.kind === "delegateAck");
    expect(ack && ack.kind === "delegateAck" && ack.value).toEqual({
      kind: "number",
      value: 1,
    });
  });

  it("mod by zero throws", () => {
    const machine = createMachine(agentApplyingPrim("mod", 5, 0));
    expect(() => applyEvent(machine, delegate("main"))).toThrowError(
      /prim mod: modulo by zero/,
    );
  });
});
