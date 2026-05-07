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
  ReqId,
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

function lastDelegateAck(events: MachineEvent[]): Value {
  const ack = [...events].reverse().find((e) => e.kind === "delegateAck");
  if (!ack || ack.kind !== "delegateAck") {
    throw new Error("no delegateAck found in events");
  }
  return ack.value;
}

// ─── tests ──────────────────────────────────────────────────────────────────

describe("handler / request system", () => {
  it("smoke: handler that breaks with a literal value", () => {
    // agent main() -> string {
    //   handle {
    //     <body: call request fetch, return its result>
    //   } where {
    //     req fetch() { break "hello" }
    //   }
    // }
    //
    // IR layout:
    //   block 0: agent main entry (BlockKindAgent)
    //     stmts:
    //       0. call block 1 → var0   (handle expression)
    //       1. exit return var0
    //   block 1: BlockHandle
    //     body: 2, handlers: [{request: 0, handlerBody: 3}]
    //   block 2: handle body (BlockKindInline)
    //     stmts:
    //       0. call block 4 → var1  (request fetch())
    //     trailing: var1
    //   block 3: handler body for fetch (BlockKindInline)
    //     stmts:
    //       0. loadLiteral "hello" → var2
    //       1. exit break var2
    //   block 4: BlockRequest reqId=0
    const blocks: Record<number, Block> = {
      0: {
        kind: "blockUser",
        body: {
          kind: "blockKindAgent",
          parameters: [],
          statements: [
            {
              kind: "statementCall",
              body: {
                target: { kind: "callTargetBlock", block: 1 },
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
      1: {
        kind: "blockHandle",
        body: {
          parallel: false,
          stateInits: [],
          body: 2,
          handlers: [{ request: 0 as ReqId, handlerBody: 3 }],
        },
      },
      2: {
        kind: "blockUser",
        body: {
          kind: "blockKindInline",
          parameters: [],
          statements: [
            {
              kind: "statementCall",
              body: {
                target: { kind: "callTargetBlock", block: 4 },
                arguments: [],
                output: 1 as VarId,
              },
            },
          ],
          trailing: 1 as VarId,
        },
      },
      3: {
        kind: "blockUser",
        body: {
          kind: "blockKindInline",
          parameters: [],
          statements: [
            {
              kind: "statementLoadLiteral",
              body: {
                output: 2 as VarId,
                value: { kind: "literalValueString", string: "hello" },
              },
            },
            {
              kind: "statementExit",
              body: { exitKind: "exitKindBreak", value: 2 as VarId },
            },
          ],
        },
      },
      4: { kind: "blockRequest", body: 0 as ReqId },
    };
    const ir = makeIR(blocks, "main", 0);
    const machine = createMachine(ir);
    const out = applyEvent(machine, delegate("main"));
    const result = lastDelegateAck(out);
    expect(result).toEqual({ kind: "string", value: "hello" });
  });

  it("next + state var: counter handler resumed three times accumulates", () => {
    // agent counter() -> integer {
    //   handle (var n: integer = 0) {
    //     inc(); inc(); inc()  // each request returns the *new* n
    //   } where {
    //     req inc() { next n with { n = n + 1 } }
    //   }
    // }
    //
    // We hand-roll IR to drive the runtime through three asks. After
    // three resumes the body's last call yields 3 (the value of n on
    // the third resume after increment).
    //
    // Block layout (varIds inline; we also use a few helper prim
    // blocks for `+`):
    //   block 0: agent counter
    //     body returns the result of the handle (var0)
    //     stmts:
    //       call block 1 → var0
    //       exit return var0
    //   block 1: BlockHandle
    //     stateInits: [(stateN_handle=10, initN_caller=20)]
    //     body: 2, handlers: [{request:0, handlerBody:3}]
    //   block 2: handle body (inline)
    //     stmts:
    //       loadLiteral 0 → var20  (init for n=0)
    //       call request inc → var30
    //       call request inc → var31
    //       call request inc → var32
    //     trailing: var32
    //
    // Wait — stateInits expects n's init value to be in caller scope.
    // With our recent fix, BlockHandle is callInline so its scope is
    // a child of block 0's (agent's) scope. The agent must compute
    // initN_caller (= 0) BEFORE calling block 1.
    //
    // Revised:
    //   block 0: agent
    //     stmts:
    //       loadLiteral 0 → var20         (initN in agent scope)
    //       call block 1 → var0           (call handle; reads var20 via parent chain)
    //       exit return var0
    //   block 1: BlockHandle stateInits=[(10, 20)]
    //     body: 2, handlers: [{0, 3}]
    //   block 2: handle body (inline)
    //     stmts:
    //       call request inc → var30
    //       call request inc → var31
    //       call request inc → var32
    //     trailing: var32
    //   block 3: req inc handler body (inline)
    //     stmts:
    //       loadLiteral 1 → var40
    //       call prim "add"(left=stateN_handle:10, right=var40) → var41
    //       cont next value=stateN_handle:10 modifiers=[(10, var41)]
    //     // n is reads stateN. We resume with n's CURRENT value, then update.
    //   block 4: BlockRequest inc (reqId=0)
    //   block 5: BlockPrim "add"
    const blocks: Record<number, Block> = {
      0: {
        kind: "blockUser",
        body: {
          kind: "blockKindAgent",
          parameters: [],
          statements: [
            {
              kind: "statementLoadLiteral",
              body: {
                output: 20 as VarId,
                value: { kind: "literalValueInteger", integer: 0 },
              },
            },
            {
              kind: "statementCall",
              body: {
                target: { kind: "callTargetBlock", block: 1 },
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
      1: {
        kind: "blockHandle",
        body: {
          parallel: false,
          stateInits: [[10 as VarId, 20 as VarId]],
          body: 2,
          handlers: [{ request: 0 as ReqId, handlerBody: 3 }],
        },
      },
      2: {
        kind: "blockUser",
        body: {
          kind: "blockKindInline",
          parameters: [],
          statements: [
            {
              kind: "statementCall",
              body: {
                target: { kind: "callTargetBlock", block: 4 },
                arguments: [],
                output: 30 as VarId,
              },
            },
            {
              kind: "statementCall",
              body: {
                target: { kind: "callTargetBlock", block: 4 },
                arguments: [],
                output: 31 as VarId,
              },
            },
            {
              kind: "statementCall",
              body: {
                target: { kind: "callTargetBlock", block: 4 },
                arguments: [],
                output: 32 as VarId,
              },
            },
          ],
          trailing: 32 as VarId,
        },
      },
      3: {
        kind: "blockUser",
        body: {
          kind: "blockKindInline",
          parameters: [],
          statements: [
            {
              kind: "statementLoadLiteral",
              body: {
                output: 40 as VarId,
                value: { kind: "literalValueInteger", integer: 1 },
              },
            },
            {
              kind: "statementCall",
              body: {
                target: { kind: "callTargetBlock", block: 5 },
                arguments: [
                  { label: "left", var: 10 as VarId },
                  { label: "right", var: 40 as VarId },
                ],
                output: 41 as VarId,
              },
            },
            {
              kind: "statementCont",
              body: {
                contKind: "contKindNext",
                value: 10 as VarId,
                modifiers: [[10 as VarId, 41 as VarId]],
              },
            },
          ],
        },
      },
      4: { kind: "blockRequest", body: 0 as ReqId },
      5: { kind: "blockPrim", body: "add" },
    };
    const ir = makeIR(blocks, "counter", 0);
    const machine = createMachine(ir);
    const out = applyEvent(machine, delegate("counter"));
    const result = lastDelegateAck(out);
    // The 3rd inc() returns n = 3 (n was 0→1→2→3 after each resume,
    // with the *new* value being returned). Actually we resume with
    // the CURRENT n then update, so:
    //   call 1: resume with n=0, then n becomes 1 → caller var30=0
    //   call 2: resume with n=1, then n becomes 2 → caller var31=1
    //   call 3: resume with n=2, then n becomes 3 → caller var32=2
    // The body trails on var32 → final value = 2.
    expect(result).toEqual({ kind: "number", value: 2 });
  });
});

