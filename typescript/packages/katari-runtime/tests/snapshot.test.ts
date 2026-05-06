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
  VarId,
} from "../src/ir/types.js";
import type { DelegationId } from "../src/machine/id.js";

// ─── helpers (small subset borrowed from handle.test.ts) ───────────────────

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

function delegateEvent(qualifiedName: string): MachineEvent {
  return {
    from: "API",
    to: "CORE",
    kind: "delegate",
    qualifiedName,
    args: {},
    delegationId: ("d-" + Math.random().toString(36).slice(2)) as DelegationId,
  };
}

function findOutgoingFFIDelegate(events: MachineEvent[]): {
  delegationId: DelegationId;
} {
  const e = events.find(
    (ev) => ev.kind === "delegate" && ev.from === "CORE" && ev.to === "FFI",
  );
  if (e === undefined || e.kind !== "delegate") {
    throw new Error("no outbound FFI delegate found");
  }
  return { delegationId: e.delegationId };
}

function lastDelegateAckToAPI(events: MachineEvent[]): Value {
  const ack = [...events].reverse().find(
    (ev) =>
      ev.kind === "delegateAck" && ev.from === "CORE" && ev.to === "API",
  );
  if (!ack || ack.kind !== "delegateAck") {
    throw new Error("no API delegateAck found");
  }
  return ack.value;
}

// ─── snapshot round-trip with a paused FFI agent ───────────────────────────

describe("MachineSnapshot round-trip", () => {
  it("freeze a machine waiting on FFI, restore, then deliver delegateAck", () => {
    // agent main() -> string {
    //   ext_call()        // external block — suspends machine on outbound delegate
    // }
    //
    // IR layout:
    //   block 0: agent main entry (blockKindAgent)
    //     stmts:
    //       call block 1 → var0
    //       exit return var0
    //   block 1: blockExternal (qualified: "test.ext_call")
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
    const ir = makeIR(blocks, "main", 0);

    // Phase 1: original machine — kick off an agent, capture FFI delegation id.
    const original = createMachine(ir);
    const startEvent = delegateEvent("main");
    const startOut = applyEvent(original, startEvent);
    const { delegationId: ffiDelegationId } = findOutgoingFFIDelegate(startOut);

    // Snapshot must be valid JSON (no Map / Set / functions leaking).
    const snap = serializeMachine(original);
    const json = JSON.stringify(snap);
    expect(json).toContain('"schemaVersion":1');
    expect(json).toContain('"kind":"api"');
    expect(json).toContain('"kind":"user"');
    expect(json).toContain('"kind":"external"');

    // Phase 2: brand new machine restored from snapshot.
    const restored = deserializeMachine(ir, JSON.parse(json));

    // Sanity: the API delegation entry survived the round-trip.
    expect(restored.apiDelegations.has(startEvent.delegationId)).toBe(true);
    expect(restored.delegations.has(ffiDelegationId)).toBe(true);

    // Phase 3: deliver FFI delegateAck on the restored machine, expect
    // an outbound delegateAck CORE→API with our value.
    const finishOut = applyEvent(restored, {
      from: "FFI",
      to: "CORE",
      kind: "delegateAck",
      delegationId: ffiDelegationId,
      value: { kind: "string", value: "ok" },
    });

    expect(lastDelegateAckToAPI(finishOut)).toEqual({
      kind: "string",
      value: "ok",
    });

    // Restored machine ran to completion: APIThread should be gone.
    expect(restored.apiDelegations.size).toBe(0);
    expect(restored.delegations.size).toBe(0);
  });

  it("snapshot of a fresh machine round-trips to a usable empty state", () => {
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
                value: { kind: "literalValueString", string: "fresh" },
              },
            },
            {
              kind: "statementExit",
              contents: { exitKind: "exitKindReturn", value: 0 as VarId },
            },
          ],
        },
      },
    };
    const ir = makeIR(blocks, "main", 0);

    const empty = createMachine(ir);
    const snap = serializeMachine(empty);
    expect(snap.threads).toEqual([]);
    expect(snap.scopes).toEqual([]);

    const restored = deserializeMachine(ir, snap);
    const out = applyEvent(restored, delegateEvent("main"));
    expect(lastDelegateAckToAPI(out)).toEqual({
      kind: "string",
      value: "fresh",
    });
  });
});
