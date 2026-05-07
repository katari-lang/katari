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

/** Agent that just calls one external block and returns its result. */
function pausesOnExternalIR(): IRModule {
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
      kind: "blockExternal",
      body: { module_: "test", name: "ext_call" },
    },
  };
  return makeIR(blocks, "main", 0);
}

// ─── Tests ──────────────────────────────────────────────────────────────────

describe("ExternalThread FFI ack idempotency", () => {
  it("delegateAck for an unknown delegationId is silently absorbed", () => {
    // Construct a machine with no live external delegations and feed it an
    // FFI delegateAck. Used to throw → version poisoned. Now a no-op.
    const machine = createMachine(pausesOnExternalIR());
    const out = applyEvent(machine, {
      from: "FFI",
      to: "CORE",
      kind: "delegateAck",
      delegationId: "not-a-real-id" as DelegationId,
      value: { kind: "string", value: "ignored" },
    });
    // No outbound events, no throw.
    expect(out).toEqual([]);
  });

  it("duplicate delegateAck on the same delegationId: first completes, second is a no-op", () => {
    const machine = createMachine(pausesOnExternalIR());

    // Phase A: kick off the agent → outbound CORE→FFI delegate.
    const startOut = applyEvent(machine, delegate("main"));
    const ffi = startOut.find(
      (e) => e.kind === "delegate" && e.from === "CORE" && e.to === "FFI",
    );
    if (ffi === undefined || ffi.kind !== "delegate") {
      throw new Error("expected outbound FFI delegate");
    }
    const ffiDelegationId = ffi.delegationId;

    // Phase B: first delegateAck — agent completes, CORE→API delegateAck emitted.
    const finishOut = applyEvent(machine, {
      from: "FFI",
      to: "CORE",
      kind: "delegateAck",
      delegationId: ffiDelegationId,
      value: { kind: "string", value: "ok" },
    });
    const ack = [...finishOut].reverse().find(
      (e) => e.kind === "delegateAck" && e.from === "CORE" && e.to === "API",
    );
    expect(ack && ack.kind === "delegateAck" && ack.value).toEqual({
      kind: "string",
      value: "ok",
    });

    // Phase C: a duplicate / late delegateAck for the same id — no throw.
    const replayOut = applyEvent(machine, {
      from: "FFI",
      to: "CORE",
      kind: "delegateAck",
      delegationId: ffiDelegationId,
      value: { kind: "string", value: "duplicate" },
    });
    expect(replayOut).toEqual([]);
  });

  it("late terminateAck after delegateAck is also a no-op (existing behavior, regression check)", () => {
    const machine = createMachine(pausesOnExternalIR());
    const startOut = applyEvent(machine, delegate("main"));
    const ffi = startOut.find(
      (e) => e.kind === "delegate" && e.from === "CORE" && e.to === "FFI",
    );
    if (ffi === undefined || ffi.kind !== "delegate") {
      throw new Error("expected outbound FFI delegate");
    }
    const ffiDelegationId = ffi.delegationId;

    applyEvent(machine, {
      from: "FFI",
      to: "CORE",
      kind: "delegateAck",
      delegationId: ffiDelegationId,
      value: { kind: "string", value: "first" },
    });

    const lateTerminateOut = applyEvent(machine, {
      from: "FFI",
      to: "CORE",
      kind: "terminateAck",
      delegationId: ffiDelegationId,
    });
    expect(lateTerminateOut).toEqual([]);
  });
});
