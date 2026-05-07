import { describe, expect, it } from "vitest";
import {
  applyEvent,
  createMachine,
  deserializeMachine,
  RequestThread,
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
    throw new Error("no delegateAck found");
  }
  return ack.value;
}

// IR shared by the tests below: a handle whose body issues a single request.
// We use the FFI-suspend trick from snapshot.test.ts to pause the machine,
// snapshot it, and then resume on a fresh machine.
//
// Here we drive the request by way of an external block so the handler body
// itself triggers a CORE→FFI delegate that suspends. We then snapshot and
// restore.
//
// IR layout:
//   block 0: agent main
//     stmts:
//       call block 1 → var0       (handle expression)
//       exit return var0
//   block 1: BlockHandle parallel=false body=2 handlers=[{0, 3}]
//   block 2: handle body (inline)
//     stmts:
//       call block 4 → var1        (request fetch())
//     trailing: var1
//   block 3: handler body (inline) — break with the literal "fetched"
//     stmts:
//       loadLiteral "fetched" → var2
//       exit break var2
//   block 4: BlockRequest reqId=0
function buildHandleRequestIR(): IRModule {
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
      kind: "blockHandle",
      handleBlock: {
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
            contents: {
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
            contents: {
              output: 2 as VarId,
              value: { kind: "literalValueString", string: "fetched" },
            },
          },
          {
            kind: "statementExit",
            contents: { exitKind: "exitKindBreak", value: 2 as VarId },
          },
        ],
      },
    },
    4: { kind: "blockRequest", reqId: 0 as ReqId },
  };
  return makeIR(blocks, "main", 0);
}

// ─── Tests ──────────────────────────────────────────────────────────────────

describe("RequestThread snapshot pass-3 re-trigger", () => {
  it("standard live flow still works (sanity)", () => {
    const ir = buildHandleRequestIR();
    const machine = createMachine(ir);
    const out = applyEvent(machine, delegate("main"));
    expect(lastDelegateAck(out)).toEqual({ kind: "string", value: "fetched" });
  });

  it("snapshot of a freshly-created machine round-trips and runs to completion", () => {
    // The most common case: a brand-new (unprovisioned) machine snapshotted
    // produces an empty snapshot, restoring to an empty machine. This already
    // works; we mainly want to ensure pass 3 doesn't break it.
    const ir = buildHandleRequestIR();
    const fresh = createMachine(ir);
    const restored = deserializeMachine(
      ir,
      JSON.parse(JSON.stringify(serializeMachine(fresh))),
    );
    const out = applyEvent(restored, delegate("main"));
    expect(lastDelegateAck(out)).toEqual({ kind: "string", value: "fetched" });
  });

  it("hasIssuedAsk reflects pendingAskId correctly", () => {
    // Constructing a real RequestThread requires the full ChildThreadInit
    // setup with a live parent + handler boundary, which is heavy. We use
    // Object.create + manual field assignment — the same shape that
    // restoreSkeleton uses — to verify the getter contract directly.
    //
    // This is the smallest unit of behaviour the deserializer's pass 3
    // depends on: `if (!thread.hasIssuedAsk) thread.onCall(state)`.
    type Mutable = {
      pendingAskId: number | undefined;
    };
    const proto = RequestThread.prototype;
    const fresh = Object.create(proto) as RequestThread;
    (fresh as unknown as Mutable).pendingAskId = undefined;
    expect(fresh.hasIssuedAsk).toBe(false);

    const asked = Object.create(proto) as RequestThread;
    (asked as unknown as Mutable).pendingAskId = 0;
    expect(asked.hasIssuedAsk).toBe(true);
  });

  it("onAskComplete throws a clear error when pendingAskId is undefined", () => {
    // If something ever bypasses pass 3 and feeds askComplete to a
    // not-yet-asked RequestThread, the message must call out the snapshot
    // inconsistency so the bug is debuggable rather than mistaken for a
    // mismatch.
    type Mutable = {
      pendingAskId: number | undefined;
    };
    const proto = RequestThread.prototype;
    const thread = Object.create(proto) as RequestThread;
    (thread as unknown as Mutable).pendingAskId = undefined;
    // Stub the parent / parentCallId fields the success path would touch.
    Object.assign(thread as unknown as Record<string, unknown>, {
      parent: { id: "stub" },
      parentCallId: 0,
    });
    expect(() =>
      thread.onAskComplete(
        // The throw fires *before* it touches `machine`; null is fine.
        null as never,
        0 as never,
        { kind: "null" } as Value,
      ),
    ).toThrowError(/pendingAskId is undefined/);
  });
});
