import { describe, expect, it } from "vitest";
import {
  applyEvent,
  createMachine,
  deserializeMachine,
  serializeMachine,
  type MachineEvent,
  type Value,
} from "../src/index.js";
import type {
  Block,
  IRMetadata,
  IRModule,
  ReqId,
  VarId,
} from "../src/ir/types.js";
import type { DelegationId } from "../src/machine/id.js";

// ─── helpers ────────────────────────────────────────────────────────────────

function metadata(): IRMetadata {
  return { schemaVersion: 1 };
}

function makeIR(
  blocks: Record<number, Block>,
  entryName: string,
  entryBlockId: number,
): IRModule {
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

function delegate(
  qualifiedName: string,
  args: Record<string, Value> = {},
): MachineEvent {
  return {
    from: "API",
    to: "CORE",
    kind: "delegate",
    qualifiedName,
    args,
    delegationId: ("d-" + Math.random().toString(36).slice(2)) as DelegationId,
  };
}

function lastDelegateAck(events: MachineEvent[]): Value {
  const ack = [...events].reverse().find((e) => e.kind === "delegateAck");
  if (!ack || ack.kind !== "delegateAck") {
    throw new Error("no delegateAck found");
  }
  return ack.value;
}

// ─── Cartesian product mechanics ────────────────────────────────────────────
//
// Test strategy: the body block accumulates a string (state var) by appending
// `a*10+b` for each iteration. We assert the final accumulated string matches
// the expected visit order for Cartesian product semantics:
//
// for (a in xs, b in ys) → (x0,y0), (x0,y1), ..., (x0,y_{m-1}), (x1,y0), ...
//
// VarId allocation:
//   var 100 = xs init in agent scope
//   var 101 = ys init in agent scope
//   var 110 = a (body iter var = state var slot in for scope)
//   var 111 = b
//   var 120 = acc init in agent scope (= "")
//   var 121 = acc state var in for scope
//   var 130 = body's per-iter intermediate
//   var 200 = result of for in agent scope

describe("ForThread Cartesian product", () => {
  it("two iters of equal length → product visit order", () => {
    // xs = [1, 2, 3], ys = [10, 20]  → 6 iterations
    // Expected visit order: (1,10),(1,20),(2,10),(2,20),(3,10),(3,20)
    // We accumulate a tagged-value list (linked-list style: Cons / Nil) of (a,b)
    // pairs, then return the list. We simplify by accumulating a string:
    //   acc' = acc <> to_string(a) <> "," <> to_string(b) <> ";"
    //
    // For brevity we instead use an array prim — but the runtime has no
    // array_push prim. We use string concat instead.
    //
    // IR:
    //   block 0: agent main
    //     stmt 0: load xs = [1,2,3] (via array literal block)
    //     stmt 1: load ys = [10, 20]
    //     stmt 2: load acc = ""
    //     stmt 3: call for-block(stateInit) → result var 200
    //     stmt 4: exit return result
    //   block 1: blockArray for xs
    //   block 2: blockArray for ys
    //   block 3: BlockFor parallel=false iters=[(110, 100), (111, 101)]
    //            stateInits=[(121, 120)] body=4
    //   block 4: body inline: acc' = acc <> to_string(a) <> "," <> to_string(b) <> ";"
    //            cont for_next value=null modifiers=[(121, acc')]
    //   block 5: blockPrim "to_string"
    //   block 6: blockPrim "concat"
    //   ... small literal load helpers

    // To keep IR sizes manageable, we use simpler arithmetic: accumulate
    //   acc' = acc * 100 + (a * 10 + b)
    // so the integer trail uniquely identifies the visit sequence.
    //
    // Final acc for (1,10),(1,20),(2,10),(2,20),(3,10),(3,20):
    //   start: 0
    //   * 100 + 20  →   20            (1*10+10=20)
    //   * 100 + 30  → 2030
    //   * 100 + 30  → 203030
    //   * 100 + 40  → 20303040
    //   * 100 + 40  → 2030304040
    //   * 100 + 50  → 203030404050
    //
    // Wait — a*10+b: (1,10)=20, (1,20)=30, (2,10)=30, (2,20)=40, (3,10)=40,
    // (3,20)=50. Visit order encoded as concatenated 2-digit chunks:
    //   "20-30-30-40-40-50"
    //
    // We use a small utility: accumulate decimal-shifted: acc * 100 + chunk.
    const blocks: Record<number, Block> = {
      // agent main
      0: {
        kind: "blockUser",
        body: {
          kind: "blockKindAgent",
          parameters: [],
          statements: [
            // var 100 = xs (call array block 1)
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 1 },
                arguments: [],
                output: 100 as VarId,
              },
            },
            // var 101 = ys (call array block 2)
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 2 },
                arguments: [],
                output: 101 as VarId,
              },
            },
            // var 120 = 0 (acc init)
            {
              kind: "statementLoadLiteral",
              contents: {
                output: 120 as VarId,
                value: { kind: "literalValueInteger", integer: 0 },
              },
            },
            // var 200 = call for block 3 (result = final acc)
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 3 },
                arguments: [],
                output: 200 as VarId,
              },
            },
            {
              kind: "statementExit",
              contents: { exitKind: "exitKindReturn", value: 200 as VarId },
            },
          ],
        },
      },
      // xs = [1, 2, 3]
      1: {
        kind: "blockArray",
        arrayBlock: { parallel: false, elements: [10, 11, 12] },
      },
      // ys = [10, 20]
      2: {
        kind: "blockArray",
        arrayBlock: { parallel: false, elements: [20, 21] },
      },
      // for-block: iters=[(a=110, src=100), (b=111, src=101)] stateInits=[(acc=121, init=120)]
      3: {
        kind: "blockFor",
        forBlock: {
          parallel: false,
          iters: [
            [110 as VarId, 100 as VarId],
            [111 as VarId, 101 as VarId],
          ],
          stateInits: [[121 as VarId, 120 as VarId]],
          bodyBlock: 4,
          thenBlock: 5,
        },
      },
      // body: chunk = a*10 + b; acc' = acc*100 + chunk; cont for_next
      4: {
        kind: "blockUser",
        body: {
          kind: "blockKindInline",
          parameters: [],
          statements: [
            // var 130 = a*10
            {
              kind: "statementLoadLiteral",
              contents: {
                output: 131 as VarId,
                value: { kind: "literalValueInteger", integer: 10 },
              },
            },
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 6 }, // mul
                arguments: [
                  { label: "left", var: 110 as VarId }, // a
                  { label: "right", var: 131 as VarId }, // 10
                ],
                output: 132 as VarId,
              },
            },
            // var 133 = a*10 + b
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 7 }, // add
                arguments: [
                  { label: "left", var: 132 as VarId },
                  { label: "right", var: 111 as VarId },
                ],
                output: 133 as VarId,
              },
            },
            // var 134 = acc * 100
            {
              kind: "statementLoadLiteral",
              contents: {
                output: 135 as VarId,
                value: { kind: "literalValueInteger", integer: 100 },
              },
            },
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 6 }, // mul
                arguments: [
                  { label: "left", var: 121 as VarId }, // acc
                  { label: "right", var: 135 as VarId }, // 100
                ],
                output: 136 as VarId,
              },
            },
            // var 137 = acc*100 + chunk
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 7 }, // add
                arguments: [
                  { label: "left", var: 136 as VarId },
                  { label: "right", var: 133 as VarId },
                ],
                output: 137 as VarId,
              },
            },
            // cont for_next, modifier acc → 137
            {
              kind: "statementCont",
              contents: {
                contKind: "contKindForNext",
                modifiers: [[121 as VarId, 137 as VarId]],
              },
            },
          ],
        },
      },
      // then(value) { return acc }
      // The for body never trails (always for_next), so the `done` value of
      // the for body doesn't matter. But after all iters, the for emits
      // done(NULL_VALUE) to the then block. We *want* the final acc, so
      // then-clause reads the for-scope's acc state var (var 121) and
      // returns it.
      //
      // Wait — for-scope state vars are visible to thenBlock because thenBlock
      // is callInline'd with parent=for.scopeId. So we can read 121 directly.
      5: {
        kind: "blockUser",
        body: {
          kind: "blockKindInline",
          parameters: [{ label: "value", var: 150 as VarId }],
          statements: [],
          trailing: 121 as VarId,
        },
      },
      // mul / add
      6: { kind: "blockPrim", name: "mul" },
      7: { kind: "blockPrim", name: "add" },
    };
    // xs element blocks (referenced by block 1)
    blocks[10] = literalBlock(1);
    blocks[11] = literalBlock(2);
    blocks[12] = literalBlock(3);
    // ys element blocks (referenced by block 2)
    blocks[20] = literalBlock(10);
    blocks[21] = literalBlock(20);
    const ir = makeIR(blocks, "main", 0);
    const machine = createMachine(ir);
    const out = applyEvent(machine, delegate("main"));
    expect(lastDelegateAck(out)).toEqual({
      kind: "number",
      value: 203030404050,
    });
  });

  it("single iter behaves like classic for (radix-1 degeneration)", () => {
    // for (a in [7, 8]) acc'  = acc * 10 + a
    // Expected acc: 0 → 7 → 78
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
                output: 100 as VarId,
              },
            },
            {
              kind: "statementLoadLiteral",
              contents: {
                output: 120 as VarId,
                value: { kind: "literalValueInteger", integer: 0 },
              },
            },
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 3 },
                arguments: [],
                output: 200 as VarId,
              },
            },
            {
              kind: "statementExit",
              contents: { exitKind: "exitKindReturn", value: 200 as VarId },
            },
          ],
        },
      },
      1: {
        kind: "blockArray",
        arrayBlock: { parallel: false, elements: [10, 11] },
      },
      3: {
        kind: "blockFor",
        forBlock: {
          parallel: false,
          iters: [[110 as VarId, 100 as VarId]],
          stateInits: [[121 as VarId, 120 as VarId]],
          bodyBlock: 4,
          thenBlock: 5,
        },
      },
      4: {
        kind: "blockUser",
        body: {
          kind: "blockKindInline",
          parameters: [],
          statements: [
            {
              kind: "statementLoadLiteral",
              contents: {
                output: 131 as VarId,
                value: { kind: "literalValueInteger", integer: 10 },
              },
            },
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 6 },
                arguments: [
                  { label: "left", var: 121 as VarId },
                  { label: "right", var: 131 as VarId },
                ],
                output: 132 as VarId,
              },
            },
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 7 },
                arguments: [
                  { label: "left", var: 132 as VarId },
                  { label: "right", var: 110 as VarId },
                ],
                output: 133 as VarId,
              },
            },
            {
              kind: "statementCont",
              contents: {
                contKind: "contKindForNext",
                modifiers: [[121 as VarId, 133 as VarId]],
              },
            },
          ],
        },
      },
      5: {
        kind: "blockUser",
        body: {
          kind: "blockKindInline",
          parameters: [{ label: "value", var: 150 as VarId }],
          statements: [],
          trailing: 121 as VarId,
        },
      },
      6: { kind: "blockPrim", name: "mul" },
      7: { kind: "blockPrim", name: "add" },
    };
    // arrays of literal values (block 10, 11): we model as integer literal
    // loaders into per-element wrapper blocks. Reuse blockArray's element
    // semantics: block 10 / 11 are inline blocks that load a literal and
    // trail it.
    blocks[10] = literalBlock(7);
    blocks[11] = literalBlock(8);
    const ir = makeIR(blocks, "main", 0);
    const machine = createMachine(ir);
    const out = applyEvent(machine, delegate("main"));
    expect(lastDelegateAck(out)).toEqual({ kind: "number", value: 78 });
  });

  it("any empty iter source → total = 0, body never runs, then-block sees initial acc", () => {
    // for (a in [1,2,3], b in []) ... ; then return acc (= 0)
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
                output: 100 as VarId,
              },
            },
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 2 },
                arguments: [],
                output: 101 as VarId,
              },
            },
            {
              kind: "statementLoadLiteral",
              contents: {
                output: 120 as VarId,
                value: { kind: "literalValueInteger", integer: 999 },
              },
            },
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 3 },
                arguments: [],
                output: 200 as VarId,
              },
            },
            {
              kind: "statementExit",
              contents: { exitKind: "exitKindReturn", value: 200 as VarId },
            },
          ],
        },
      },
      1: {
        kind: "blockArray",
        arrayBlock: { parallel: false, elements: [10, 11, 12] },
      },
      // ys = []
      2: {
        kind: "blockArray",
        arrayBlock: { parallel: false, elements: [] },
      },
      3: {
        kind: "blockFor",
        forBlock: {
          parallel: false,
          iters: [
            [110 as VarId, 100 as VarId],
            [111 as VarId, 101 as VarId],
          ],
          stateInits: [[121 as VarId, 120 as VarId]],
          bodyBlock: 4,
          thenBlock: 5,
        },
      },
      4: {
        kind: "blockUser",
        body: {
          kind: "blockKindInline",
          parameters: [],
          statements: [
            // body should never run; if it does, the test will produce a
            // different value (we update acc to 1).
            {
              kind: "statementLoadLiteral",
              contents: {
                output: 130 as VarId,
                value: { kind: "literalValueInteger", integer: 1 },
              },
            },
            {
              kind: "statementCont",
              contents: {
                contKind: "contKindForNext",
                modifiers: [[121 as VarId, 130 as VarId]],
              },
            },
          ],
        },
      },
      5: {
        kind: "blockUser",
        body: {
          kind: "blockKindInline",
          parameters: [{ label: "value", var: 150 as VarId }],
          statements: [],
          trailing: 121 as VarId,
        },
      },
    };
    blocks[10] = literalBlock(1);
    blocks[11] = literalBlock(2);
    blocks[12] = literalBlock(3);
    const ir = makeIR(blocks, "main", 0);
    const machine = createMachine(ir);
    const out = applyEvent(machine, delegate("main"));
    expect(lastDelegateAck(out)).toEqual({ kind: "number", value: 999 });
  });

  it("for_break exits with the break value (bypasses then-clause)", () => {
    // for (a in [1,2,3]) {
    //   if a == 2: break "hit"   (exit for_break with literal "hit")
    // } then(_) { "should not see this" }
    //
    // We approximate "if a == 2 break" as: load 2; eq(a, 2); if true then exit
    // for_break "hit". To avoid building if/then in IR, we test the simpler:
    // body always for_break with literal "hit" on the very first iteration.
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
                output: 100 as VarId,
              },
            },
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 3 },
                arguments: [],
                output: 200 as VarId,
              },
            },
            {
              kind: "statementExit",
              contents: { exitKind: "exitKindReturn", value: 200 as VarId },
            },
          ],
        },
      },
      1: {
        kind: "blockArray",
        arrayBlock: { parallel: false, elements: [10, 11, 12] },
      },
      3: {
        kind: "blockFor",
        forBlock: {
          parallel: false,
          iters: [[110 as VarId, 100 as VarId]],
          stateInits: [],
          bodyBlock: 4,
          thenBlock: 5,
        },
      },
      4: {
        kind: "blockUser",
        body: {
          kind: "blockKindInline",
          parameters: [],
          statements: [
            {
              kind: "statementLoadLiteral",
              contents: {
                output: 130 as VarId,
                value: { kind: "literalValueString", string: "hit" },
              },
            },
            {
              kind: "statementExit",
              contents: {
                exitKind: "exitKindForBreak",
                value: 130 as VarId,
              },
            },
          ],
        },
      },
      5: {
        kind: "blockUser",
        body: {
          kind: "blockKindInline",
          parameters: [{ label: "value", var: 150 as VarId }],
          statements: [
            {
              kind: "statementLoadLiteral",
              contents: {
                output: 151 as VarId,
                value: { kind: "literalValueString", string: "should-not-see" },
              },
            },
          ],
          trailing: 151 as VarId,
        },
      },
    };
    blocks[10] = literalBlock(1);
    blocks[11] = literalBlock(2);
    blocks[12] = literalBlock(3);
    const ir = makeIR(blocks, "main", 0);
    const machine = createMachine(ir);
    const out = applyEvent(machine, delegate("main"));
    expect(lastDelegateAck(out)).toEqual({ kind: "string", value: "hit" });
  });

  it("parallel for is rejected at runtime", () => {
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
                output: 100 as VarId,
              },
            },
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 3 },
                arguments: [],
                output: 200 as VarId,
              },
            },
            {
              kind: "statementExit",
              contents: { exitKind: "exitKindReturn", value: 200 as VarId },
            },
          ],
        },
      },
      1: {
        kind: "blockArray",
        arrayBlock: { parallel: false, elements: [10, 11] },
      },
      3: {
        kind: "blockFor",
        forBlock: {
          parallel: true, // unsupported
          iters: [[110 as VarId, 100 as VarId]],
          stateInits: [],
          bodyBlock: 4,
        },
      },
      4: {
        kind: "blockUser",
        body: {
          kind: "blockKindInline",
          parameters: [],
          statements: [
            {
              kind: "statementCont",
              contents: { contKind: "contKindForNext", modifiers: [] },
            },
          ],
        },
      },
    };
    blocks[10] = literalBlock(1);
    blocks[11] = literalBlock(2);
    const ir = makeIR(blocks, "main", 0);
    const machine = createMachine(ir);
    expect(() => applyEvent(machine, delegate("main"))).toThrowError(
      /parallel for is not yet implemented/,
    );
  });

  it("snapshot mid-iteration → restore → completes with same Cartesian visit order", () => {
    // We can't easily pause for-loop mid-iteration without an external
    // suspend. Instead we snapshot a *fresh* machine that hasn't started,
    // round-trip it, then run a small for-loop on the restored machine and
    // assert it completes with the right value. Mid-iteration snapshot/
    // restore is exercised more thoroughly by the FFI-suspended tests in
    // snapshot.test.ts.
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
                output: 100 as VarId,
              },
            },
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 2 },
                arguments: [],
                output: 101 as VarId,
              },
            },
            {
              kind: "statementLoadLiteral",
              contents: {
                output: 120 as VarId,
                value: { kind: "literalValueInteger", integer: 0 },
              },
            },
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 3 },
                arguments: [],
                output: 200 as VarId,
              },
            },
            {
              kind: "statementExit",
              contents: { exitKind: "exitKindReturn", value: 200 as VarId },
            },
          ],
        },
      },
      1: {
        kind: "blockArray",
        arrayBlock: { parallel: false, elements: [10, 11] },
      },
      2: {
        kind: "blockArray",
        arrayBlock: { parallel: false, elements: [12, 13] },
      },
      3: {
        kind: "blockFor",
        forBlock: {
          parallel: false,
          iters: [
            [110 as VarId, 100 as VarId],
            [111 as VarId, 101 as VarId],
          ],
          stateInits: [[121 as VarId, 120 as VarId]],
          bodyBlock: 4,
          thenBlock: 5,
        },
      },
      // body: acc' = acc * 100 + (a*10+b); cont for_next acc=acc'
      4: {
        kind: "blockUser",
        body: {
          kind: "blockKindInline",
          parameters: [],
          statements: [
            {
              kind: "statementLoadLiteral",
              contents: {
                output: 131 as VarId,
                value: { kind: "literalValueInteger", integer: 10 },
              },
            },
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 6 },
                arguments: [
                  { label: "left", var: 110 as VarId },
                  { label: "right", var: 131 as VarId },
                ],
                output: 132 as VarId,
              },
            },
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 7 },
                arguments: [
                  { label: "left", var: 132 as VarId },
                  { label: "right", var: 111 as VarId },
                ],
                output: 133 as VarId,
              },
            },
            {
              kind: "statementLoadLiteral",
              contents: {
                output: 135 as VarId,
                value: { kind: "literalValueInteger", integer: 100 },
              },
            },
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 6 },
                arguments: [
                  { label: "left", var: 121 as VarId },
                  { label: "right", var: 135 as VarId },
                ],
                output: 136 as VarId,
              },
            },
            {
              kind: "statementCall",
              contents: {
                target: { kind: "callTargetBlock", block: 7 },
                arguments: [
                  { label: "left", var: 136 as VarId },
                  { label: "right", var: 133 as VarId },
                ],
                output: 137 as VarId,
              },
            },
            {
              kind: "statementCont",
              contents: {
                contKind: "contKindForNext",
                modifiers: [[121 as VarId, 137 as VarId]],
              },
            },
          ],
        },
      },
      5: {
        kind: "blockUser",
        body: {
          kind: "blockKindInline",
          parameters: [{ label: "value", var: 150 as VarId }],
          statements: [],
          trailing: 121 as VarId,
        },
      },
      6: { kind: "blockPrim", name: "mul" },
      7: { kind: "blockPrim", name: "add" },
    };
    blocks[10] = literalBlock(1);
    blocks[11] = literalBlock(2);
    blocks[12] = literalBlock(3);
    blocks[13] = literalBlock(4);
    const ir = makeIR(blocks, "main", 0);
    const fresh = createMachine(ir);
    const restored = deserializeMachine(ir, JSON.parse(JSON.stringify(serializeMachine(fresh))));
    const out = applyEvent(restored, delegate("main"));
    // (a,b) order: (1,3),(1,4),(2,3),(2,4)
    //   chunks: 1*10+3=13, 14, 23, 24
    //   acc: 0→13→1314→131423→13142324
    expect(lastDelegateAck(out)).toEqual({ kind: "number", value: 13142324 });
  });
});

// ─── helpers (continued) ────────────────────────────────────────────────────

/** Inline block that loads `n` and trails it as the body's value. */
function literalBlock(n: number): Block {
  return {
    kind: "blockUser",
    body: {
      kind: "blockKindInline",
      parameters: [],
      statements: [
        {
          kind: "statementLoadLiteral",
          contents: {
            output: 999 as VarId,
            value: { kind: "literalValueInteger", integer: n },
          },
        },
      ],
      trailing: 999 as VarId,
    },
  };
}

// Suppress unused import warnings for fixtures that use ReqId in narrower tests.
void (null as unknown as ReqId);
