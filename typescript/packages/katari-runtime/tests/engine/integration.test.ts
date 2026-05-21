// Integration tests for the new engine.
//
// We feed an external `delegate API→CORE` event into the engine to spawn
// a root AgentThread. translateExternal registers the delegation, the
// AgentThread spawns its body UserThread, the runner drives it to
// completion, and `emitAgentRootCompletion` fires a `delegateAck
// CORE→API` outbound. The test asserts on that outbound event.

import { describe, expect, it } from "vitest";
import {
  applyEvent,
  CORE_ENDPOINT,
  createDelegationId,
  createState,
  endpoint,
  type Event,
} from "../../src/engine/index.js";
import { encodeCoreAgentDefId } from "../../src/agent-def-id.js";
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
    blocks: Object.fromEntries(
      Object.entries(blocks).map(([k, v]) => [k, v]),
    ) as IRModule["blocks"],
    entries: entries as Record<string, number>,
    nameTable: { varNames: {}, blockNames: {} },
  };
}

function userBlock(
  args: Pick<UserBlock, "parameters" | "statements" | "trailing">,
): Block {
  return { kind: "blockUser", body: args };
}

function agentBlock(qualifiedName: string, entryBody: number): Block {
  return {
    kind: "blockAgent",
    body: {
      qualifiedName,
      parameters: [],
      entryBody,
      name: qualifiedName,
      description: undefined,
      inputSchema: "{}",
      outputSchema: "{}",
    },
  };
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
          block: 100,
          arguments: [
            { label: "lhs", var: v0 },
            { label: "rhs", var: v1 },
          ],
          output: out,
        },
      },
    ];
    const userBlk = userBlock({
      parameters: [],
      statements: stmts,
      trailing: out,
    });

    const module = ir({
      // Entry block: BlockAgent wrapping the body BlockUser at id 2.
      1: agentBlock("main", 2),
      2: userBlk,
      100: primBlock("add"),
    }, { main: 1 });

    const state = createState(module);
    const delegationId = createDelegationId();

    const event: Event = {
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: {
        kind: "delegate",
        agentDefId: encodeCoreAgentDefId({
          kind: "qname",
          value: "main",
        }),
        args: {},
        delegationId,
      },
    };

    const result = applyEvent(state, event);
    const ack = result.outbound.find(
      (e) => e.payload.kind === "delegateAck" && e.payload.delegationId === delegationId,
    );
    expect(ack).toBeDefined();
    if (ack && ack.payload.kind === "delegateAck") {
      expect(ack.payload.value).toEqual({ kind: "number", value: 5 });
    }
    // Delegation entry cleared after the agent finished.
    expect(Object.keys(result.state.delegations).length).toBe(0);
    expect(Object.keys(result.state.delegationSenders).length).toBe(0);
  });

  it("missing entry emits a prim.throw escalate back to the sender", () => {
    const state = createState(ir({}, {}));
    const delegationId = createDelegationId();
    const result = applyEvent(state, {
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: {
        kind: "delegate",
        agentDefId: encodeCoreAgentDefId({
          kind: "qname",
          value: "missing",
        }),
        args: {},
        delegationId,
      },
    });
    // The runner converts EntryNotFoundError into an outbound throw escalate
    // directed at the delegation sender so the API Module can mark the agent
    // as errored.
    const escalate = result.outbound.find(
      (e) => e.payload.kind === "escalate" && e.payload.delegationId === delegationId,
    );
    expect(escalate).toBeDefined();
    if (escalate && escalate.payload.kind === "escalate") {
      expect(escalate.to).toBe(API_ENDPOINT);
    }
  });

  it("core→core: top-level agent calling another top-level agent resolves through the bus", async () => {
    const out0 = 0 as VarId;
    const helperLit = 1 as VarId;
    const out1 = 2 as VarId;

    // helper(): returns 7 directly.
    const helperBody = userBlock({
      parameters: [],
      statements: [
        {
          kind: "statementLoadLiteral",
          body: { output: out0, value: { kind: "literalValueInteger", integer: 7 } },
        },
      ],
      trailing: out0,
    });

    // main(): loads an agent literal for `helper`, then dispatches via
    // a per-call-site BlockDelegate{TargetValue helperLit}.
    const mainBody = userBlock({
      parameters: [],
      statements: [
        {
          kind: "statementLoadLiteral",
          body: {
            output: helperLit,
            value: {
              kind: "literalValueAgent",
              qualifiedName: "helper",
            },
          },
        },
        {
          kind: "statementCall",
          body: {
            block: 5,
            arguments: [],
            output: out1,
          },
        },
      ],
      trailing: out1,
    });

    const helperDelegate: Block = {
      kind: "blockDelegate",
      body: {
        target: { kind: "delegateTargetValue", body: helperLit },
      },
    };

    const module = ir(
      {
        1: agentBlock("main", 2),
        2: mainBody,
        3: agentBlock("helper", 4),
        4: helperBody,
        5: helperDelegate,
      },
      { main: 1, helper: 3 },
    );

    const delegationId = createDelegationId();
    const apiOutbound: Event[] = [];

    // Test wires: a CoreModule (= the engine) registered with a bus, plus
    // a tiny stub API module that just collects outbound delegateAck events.
    const { CoreModule } = await import("../../src/modules/core.js");
    const { ExternalEventBus } = await import("../../src/bus.js");
    const { noopLogger } = await import("../../src/engine/logger.js");

    const core = new CoreModule({
      endpoint: CORE_ENDPOINT,
      snapshotId: "test-snap",
      irModule: module,
      logger: noopLogger,
    });

    const apiStub = {
      endpoint: API_ENDPOINT,
      async feed(event: Event) {
        apiOutbound.push(event);
        return { outbound: [] };
      },
      async persist() {},
      async load() {},
    };

    const bus = new ExternalEventBus(noopLogger);
    bus.registerAll([
      { name: "core", module: core },
      { name: "api", module: apiStub },
    ]);

    bus.push({
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: {
        kind: "delegate",
        agentDefId: encodeCoreAgentDefId({
          kind: "qname",
          value: "main",
        }),
        args: {},
        delegationId,
      },
    });
    await bus.drain();

    const apiAck = apiOutbound.find(
      (e) =>
        e.payload.kind === "delegateAck" &&
        e.payload.delegationId === delegationId,
    );
    expect(apiAck).toBeDefined();
    if (apiAck && apiAck.payload.kind === "delegateAck") {
      expect(apiAck.payload.value).toEqual({ kind: "number", value: 7 });
    }
    // CORE state cleaned up: no leftover delegations or threads.
    const coreState = core.currentState;
    expect(Object.keys(coreState.delegations).length).toBe(0);
    expect(Object.keys(coreState.pendingDelegateOut).length).toBe(0);
    expect(Object.keys(coreState.delegationSenders).length).toBe(0);
    expect(Object.keys(coreState.threads).length).toBe(0);
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
          block: 200,
          arguments: [],
          output: v0,
        },
      },
    ];
    const userBlk = userBlock({
      parameters: [],
      statements: stmts,
      trailing: v0,
    });

    const module = ir({
      1: agentBlock("main", 2),
      2: userBlk,
      200: {
        kind: "blockDelegate",
        body: { target: { kind: "delegateTargetExternal", body: "test.wait" } },
      },
    }, { main: 1 });

    const state = createState(module);
    const delegationId = createDelegationId();

    // Start the agent — it pauses on the external delegate.
    const startResult = applyEvent(state, {
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: {
        kind: "delegate",
        agentDefId: encodeCoreAgentDefId({
          kind: "qname",
          value: "main",
        }),
        args: {},
        delegationId,
      },
    });
    // Outbound should include a CORE→FFI delegate.
    const ffiDelegate = startResult.outbound.find((e) => e.payload.kind === "delegate");
    expect(ffiDelegate).toBeDefined();

    // Now terminate.
    const cancelResult = applyEvent(startResult.state, {
      from: API_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: { kind: "terminate", delegationId },
    });

    // We expect outbound to contain a CORE→FFI terminate.
    const ffiTerminate = cancelResult.outbound.find(
      (e) => e.payload.kind === "terminate",
    );
    expect(ffiTerminate).toBeDefined();
  });
});
