// Round-trip test for the persistence codec (no DB): serialise a suspended instance + its scopes to
// their row shapes and reconstruct the project snapshot, verifying the engine graph survives intact.

import { describe, expect, test } from "vitest";
import {
  deserializeProject,
  serializeInstance,
} from "../src/runtime/actor/persistence-codec.js";
import type { Instance, Scope } from "../src/runtime/engine/types.js";
import {
  type DelegationId,
  type InstanceId,
  type ProjectId,
  type SnapshotId,
  toCallId,
  toScopeId,
  toThreadId,
} from "../src/runtime/ids.js";

const PROJECT = "project-p" as ProjectId;
const SNAPSHOT = "snapshot-s" as SnapshotId;
const INSTANCE = "instance-i" as InstanceId;
const DELEGATION = "delegation-d" as DelegationId;

describe("persistence codec", () => {
  test("round-trips a suspended instance, its threads, and its owned scopes", () => {
    // An instance whose body delegated to a child and is awaiting its delegateAck (a real suspend point).
    const instance: Instance = {
      id: INSTANCE,
      delegationId: DELEGATION,
      target: { kind: "named", name: "demo.main" as never, snapshot: SNAPSHOT },
      argument: null,
      status: "running",
      rootThreadId: toThreadId(0),
      threads: {
        0: {
          id: toThreadId(0),
          parent: null,
          parentCallId: null,
          scopeId: toScopeId(0),
          blockId: 0,
          status: "running",
          kind: "agent",
          pending: { callId: toCallId(0), output: null },
        },
        1: {
          id: toThreadId(1),
          parent: toThreadId(0),
          parentCallId: toCallId(0),
          scopeId: toScopeId(0),
          blockId: 1,
          status: "running",
          kind: "sequence",
          cursor: 3,
          pending: { callId: toCallId(1), output: 7 },
        },
        2: {
          id: toThreadId(2),
          parent: toThreadId(1),
          parentCallId: toCallId(1),
          scopeId: toScopeId(0),
          blockId: 1,
          status: "running",
          kind: "delegate",
          delegationId: "delegation-child" as DelegationId,
        },
      },
      pendingDelegations: { ["delegation-child" as DelegationId]: toThreadId(2) },
      askRoutes: {},
      escalationContinuations: {},
      cancelExits: {},
      nextThreadId: 3,
      nextCallId: 2,
      nextAskId: 0,
    };
    const scopes: Scope[] = [
      {
        id: toScopeId(0),
        parentId: null,
        owner: INSTANCE,
        values: { 5: { kind: "integer", value: 7 }, 6: { kind: "string", value: "hi" } },
      },
    ];

    const serialized = serializeInstance(PROJECT, instance, scopes);
    expect(serialized.threads).toHaveLength(3);
    expect(serialized.instance.snapshotId).toBe(SNAPSHOT);
    expect(serialized.instance.engineState.nextThreadId).toBe(3);

    const snapshot = deserializeProject(
      [serialized.instance],
      serialized.threads,
      serialized.scopes,
    );

    expect(snapshot.instances[INSTANCE]).toEqual(instance);
    expect(snapshot.scopes[0]).toEqual(scopes[0]);
    expect(snapshot.nextScopeId).toBe(1);
  });
});
