// Round-trip test for the persistence codec (no DB): serialise a suspended instance + its scopes to
// their row shapes and reconstruct the project snapshot, verifying the engine graph survives intact.

import { describe, expect, test } from "vitest";
import {
  deserializeProject,
  type PersistedInstance,
  serializeBlob,
  serializeCoreInstance,
  serializeScope,
} from "../src/runtime/actor/persistence-codec.js";
import type { BlobEntry, CoreInstance, Scope } from "../src/runtime/engine/types.js";
import {
  type BlobId,
  type DelegationId,
  type EscalationId,
  type InstanceId,
  type ProjectId,
  type SnapshotId,
  toAskId,
  toCallId,
  toScopeId,
  toThreadId,
} from "../src/runtime/ids.js";

const PROJECT = "project-p" as ProjectId;
const SNAPSHOT = "snapshot-s" as SnapshotId;
const INSTANCE = "instance-i" as InstanceId;
const DELEGATION = "delegation-d" as DelegationId;
const BLOB = "blob-b" as BlobId;

describe("persistence codec", () => {
  test("round-trips a suspended instance, its threads, and its owned scopes", () => {
    // An instance whose body delegated to a child and is awaiting its delegateAck (a real suspend point).
    const instance: CoreInstance = {
      kind: "core",
      id: INSTANCE,
      delegationId: DELEGATION,
      callerReactor: "core",
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
          // The root's forward route for an in-flight escape, plus the escalation→askId bridge that
          // converts its returning escalateAck — both ride in the root thread payload now (was the
          // instance's engine_state) and must survive the round-trip.
          forwardRoutes: { [toAskId(2)]: { thread: toThreadId(1), askId: toAskId(0) } },
          kind: "agent",
          pending: { callId: toCallId(0), output: null },
          escalations: { ["escalation-r" as EscalationId]: toAskId(2) },
        },
        1: {
          id: toThreadId(1),
          parent: toThreadId(0),
          parentCallId: toCallId(0),
          scopeId: toScopeId(0),
          blockId: 1,
          status: "running",
          forwardRoutes: {},
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
          forwardRoutes: {},
          kind: "delegate",
          delegationId: "delegation-child" as DelegationId,
          // A delegate proxy relaying an inbound escalate holds the escalation here — it must survive the
          // round-trip (routes now ride per-thread, not in the instance's engine_state).
          relays: { [toAskId(4)]: "escalation-e" as EscalationId },
        },
      },
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

    const serialized = serializeCoreInstance(PROJECT, instance);
    expect(serialized.threads).toHaveLength(3);
    expect(serialized.instance.snapshotId).toBe(SNAPSHOT);
    expect(serialized.instance.engineState.nextThreadId).toBe(3);

    // Scopes and blobs persist independently of the instance Layer 2 (the ResourcePool's units), so the
    // codec serialises each one at a time.
    const serializedScopes = scopes.map((scope) => serializeScope(PROJECT, scope));
    const blob: BlobEntry = {
      owner: INSTANCE,
      hash: "abc123",
      size: 4096,
      contentType: "text/plain",
      semanticKind: "file",
    };
    // Reconstruct the joined core row (envelope ⋈ core_instances) that a reactivation reads back.
    const joined: PersistedInstance = {
      id: instance.id,
      delegationId: instance.delegationId,
      target: serialized.instance.target,
      snapshotId: serialized.instance.snapshotId,
      status: instance.status,
      ambientGenerics: serialized.instance.ambientGenerics,
      engineState: serialized.instance.engineState,
    };
    const snapshot = deserializeProject([joined], serialized.threads, serializedScopes, [
      serializeBlob(PROJECT, BLOB, blob),
    ]);

    expect(snapshot.instances[INSTANCE]).toEqual(instance);
    expect(snapshot.scopes[0]).toEqual(scopes[0]);
    expect(snapshot.blobs[BLOB]).toEqual(blob);
    expect(snapshot.nextScopeId).toBe(1);
  });
});
