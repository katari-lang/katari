// Integration tests for the new engine.
//
// We feed an external `delegate API→CORE` event into the engine to spawn
// a root user thread. The engine's translateExternal builds the root
// thread, the runner drives it to completion, and emitRootCompletion
// fires a `delegateAck CORE→API` outbound. The test asserts on that
// outbound event.

import { describe, expect, it } from "vitest";
import {
  applyEvent,
  CORE_ENDPOINT,
  createDelegationId,
  createState,
  endpoint,
  type Event,
} from "../../src/engine/index.js";
import type {
  IRModule,
  Block,
  Statement,
  UserBlock,
  VarId,
} from "../../src/ir/types.js";

function ir(blocks: Record<number, Block>, entries: Record<string, number> = {}): IRModule {
  return {
    metadata: { schemaVersion: 1 },
    name: "test",
    blocks: Object.fromEntries(
      Object.entries(blocks).map(([k, v]) => [k, v]),
    ) as IRModule["blocks"],
    entries: entries as Record<string, number>,
    nameTable: { varNames: {}, blockNames: {} },
  };
}

function userBlock(
  args: Pick<UserBlock, "kind" | "parameters" | "statements" | "trailing">,
): Block {
  return { kind: "blockUser", body: args };
}

function primBlock(name: string): Block {
  return { kind: "blockPrim", body: name };
}

const API_ENDPOINT = endpoint("api://test");

describe("engine integration: end-to-end via external delegate", () => {
  it("user thread calls add(2,3); engine emits delegateAck with 5", () => {
    const v0 = 0 as VarId;
    const v1 = 1 as VarId;
    const out = 2 as VarId;

    const stmts: Statement[] = [
      { kind: "statementLoadLiteral", body: { output: v0, value: { kind: "literalValueInteger", integer: 2 } } },
      { kind: "statementLoadLiteral", body: { output: v1, value: { kind: "literalValueInteger", integer: 3 } } },
      {
        kind: "statementCall",
        body: {
          target: { kind: "callTargetBlock", block: 100 },
          arguments: [
            { label: "left", var: v0 },
            { label: "right", var: v1 },
          ],
          output: out,
        },
      },
    ];
    const userBlk = userBlock({
      kind: "blockKindAgent",
      parameters: [],
      statements: stmts,
      trailing: out,
    });

    const module = ir({
      1: userBlk,
      100: primBlock("add"),
    }, { main: 1 });

    const state = createState(module);
    const delegationId = createDelegationId();

    const event: Event = {
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: {
        kind: "delegate",
        targetBlock: { module_: "", name: "main" },
        args: {},
        delegationId,
      },
    };

    const result = applyEvent(state, event);
    expect(result.errors).toEqual([]);
    const ack = result.outbound.find(
      (e) => e.payload.kind === "delegateAck" && e.payload.delegationId === delegationId,
    );
    expect(ack).toBeDefined();
    if (ack && ack.payload.kind === "delegateAck") {
      expect(ack.payload.value).toEqual({ kind: "number", value: 5 });
    }
    // Apidelegation cleared.
    expect(Object.keys(result.state.apiDelegations).length).toBe(0);
  });

  it("missing entry returns Recoverable error and no outbound", () => {
    const state = createState(ir({}, {}));
    const result = applyEvent(state, {
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: {
        kind: "delegate",
        targetBlock: { module_: "", name: "missing" },
        args: {},
        delegationId: createDelegationId(),
      },
    });
    expect(result.errors.length).toBe(1);
    expect(result.errors[0]?.name).toBe("EntryNotFoundError");
    expect(result.outbound).toEqual([]);
  });

  it("terminate before completion: cancel cascade + terminateAck outbound", () => {
    // Set up an agent that pauses on an external — call ext "wait", then
    // return its value. Because the engine's external translation
    // translates the inbound delegateAck before the agent finishes, we
    // can issue a `terminate` while it's paused.
    const v0 = 0 as VarId;
    const stmts: Statement[] = [
      {
        kind: "statementCall",
        body: {
          target: { kind: "callTargetBlock", block: 200 },
          arguments: [],
          output: v0,
        },
      },
    ];
    const userBlk = userBlock({
      kind: "blockKindAgent",
      parameters: [],
      statements: stmts,
      trailing: v0,
    });

    const module = ir({
      1: userBlk,
      200: { kind: "blockExternal", body: { module_: "test", name: "wait" } },
    }, { main: 1 });

    const state = createState(module);
    const delegationId = createDelegationId();

    // Start the agent — it pauses on the external delegate.
    const startResult = applyEvent(state, {
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: {
        kind: "delegate",
        targetBlock: { module_: "", name: "main" },
        args: {},
        delegationId,
      },
    });
    expect(startResult.errors).toEqual([]);
    // Outbound should include a CORE→FFI delegate.
    const ffiDelegate = startResult.outbound.find((e) => e.payload.kind === "delegate");
    expect(ffiDelegate).toBeDefined();

    // Now terminate.
    const cancelResult = applyEvent(startResult.state, {
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: { kind: "terminate", delegationId },
    });
    expect(cancelResult.errors).toEqual([]);

    // We expect outbound to contain a CORE→FFI terminate.
    const ffiTerminate = cancelResult.outbound.find(
      (e) => e.payload.kind === "terminate",
    );
    expect(ffiTerminate).toBeDefined();
  });
});
