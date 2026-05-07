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

const apiDelegationId = "api-delegation-id" as DelegationId;

function delegate(qualifiedName: string): MachineEvent {
  return {
    from: "API",
    to: "CORE",
    kind: "delegate",
    qualifiedName,
    args: {},
    delegationId: apiDelegationId,
  };
}

// IR: agent main pauses on an external call — the only way the agent can
// be "in flight" between applyEvent invocations.
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
      externalName: { module_: "test", name: "ext_call" },
    },
  };
  return makeIR(blocks, "main", 0);
}

// ─── Tests ──────────────────────────────────────────────────────────────────

describe("return / cancel race", () => {
  it("cancel arriving while agent is suspended on FFI: terminateAck wins, no delegateAck emitted", () => {
    // Scenario (1) of the docstring: API sends terminate while the engine is
    // still waiting on the FFI delegateAck. The agent emits terminateAck and
    // never produces a delegateAck.
    const machine = createMachine(pausesOnExternalIR());

    // Phase A: kick off → outbound CORE→FFI delegate; agent is now parked.
    const startOut = applyEvent(machine, delegate("main"));
    const ffi = startOut.find(
      (e) => e.kind === "delegate" && e.from === "CORE" && e.to === "FFI",
    );
    if (ffi === undefined || ffi.kind !== "delegate") {
      throw new Error("expected outbound FFI delegate");
    }
    const ffiDelegationId = ffi.delegationId;

    // Phase B: API requests termination *before* the FFI ack arrives. We
    // expect: outbound CORE→FFI terminate (forwarding the request to the
    // sidecar), but no terminateAck-to-API yet (we still have a live
    // ExternalThread to clean up).
    const terminateOut = applyEvent(machine, {
      from: "API",
      to: "CORE",
      kind: "terminate",
      delegationId: apiDelegationId,
    });
    const ffiTerminate = terminateOut.find(
      (e) => e.kind === "terminate" && e.from === "CORE" && e.to === "FFI",
    );
    expect(ffiTerminate).toBeDefined();
    const apiTerminateAckEarly = terminateOut.find(
      (e) => e.kind === "terminateAck" && e.from === "CORE" && e.to === "API",
    );
    expect(apiTerminateAckEarly).toBeUndefined();

    // Phase C: FFI acknowledges the terminate. We now expect the
    // CORE→API terminateAck to fire and the machine state to be empty.
    const finishOut = applyEvent(machine, {
      from: "FFI",
      to: "CORE",
      kind: "terminateAck",
      delegationId: ffiDelegationId,
    });
    const apiTerminateAck = finishOut.find(
      (e) => e.kind === "terminateAck" && e.from === "CORE" && e.to === "API",
    );
    expect(apiTerminateAck).toBeDefined();
    if (apiTerminateAck && apiTerminateAck.kind === "terminateAck") {
      expect(apiTerminateAck.delegationId).toBe(apiDelegationId);
    }
    // No delegateAck — the result was discarded.
    const apiDelegateAck = finishOut.find(
      (e) => e.kind === "delegateAck" && e.from === "CORE" && e.to === "API",
    );
    expect(apiDelegateAck).toBeUndefined();

    // No threads / scopes left.
    expect(machine.threads.size).toBe(0);
  });

  it("FFI delegateAck arriving after CORE has already issued terminate: external thread is idempotent, terminate completes cleanly", () => {
    // Scenario covered by the idempotent ack work (Stage A5) but worth
    // re-verifying alongside the cancel race: a sidecar may answer with a
    // result *after* it has been told to terminate. The runtime treats that
    // delegateAck as a cancelAck (statusValue === "cancelling" branch in
    // ExternalThread.handleDelegateAckFromFFI).
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
      from: "API",
      to: "CORE",
      kind: "terminate",
      delegationId: apiDelegationId,
    });

    // Sidecar answers with a delegateAck rather than a terminateAck.
    const finishOut = applyEvent(machine, {
      from: "FFI",
      to: "CORE",
      kind: "delegateAck",
      delegationId: ffiDelegationId,
      value: { kind: "string", value: "late-result" },
    });

    const apiTerminateAck = finishOut.find(
      (e) => e.kind === "terminateAck" && e.from === "CORE" && e.to === "API",
    );
    expect(apiTerminateAck).toBeDefined();
    const apiDelegateAck = finishOut.find(
      (e) => e.kind === "delegateAck" && e.from === "CORE" && e.to === "API",
    );
    expect(apiDelegateAck).toBeUndefined();
    expect(machine.threads.size).toBe(0);
  });
});
