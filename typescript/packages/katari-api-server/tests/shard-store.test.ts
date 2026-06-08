// ShardStore + ProjectIndexStore unit tests (in-memory). The shard payload is
// an opaque EncryptedEngineCheckpoint (the store does not inspect it); the
// project index is a plain-JSON routing table. Also covers facade wiring +
// withTransaction rollback.

import type { EncryptedEngineCheckpoint, ProjectIndex } from "@katari-lang/runtime";
import { describe, expect, it } from "vitest";
import { InMemoryStorage } from "../src/storage/memory-storage.js";
import {
  InMemoryProjectIndexStore,
  InMemoryShardStore,
} from "../src/storage/shard-store-memory.js";

const PROJECT = "proj-1";

// A representative checkpoint payload (treated as opaque by the store).
const checkpoint = (tag: string): EncryptedEngineCheckpoint =>
  ({
    schemaVersion: 1,
    selfEndpoint: "core",
    ffiTargetEndpoint: "ffi",
    envTargetEndpoint: "env",
    threads: { [tag]: { kind: "agent", id: tag } },
    delegations: {},
    pendingDelegateOut: {},
    delegationSenders: {},
    escalationOwners: {},
    lastGcScopeCount: 0,
    // biome-ignore lint/suspicious/noExplicitAny: opaque payload stand-in
  }) as any;

describe("ShardStore", () => {
  it("upsert → get round-trips the checkpoint", async () => {
    const store = new InMemoryShardStore();
    await store.upsert({
      projectId: PROJECT,
      shardId: "s1",
      currentSnapshot: "snap-1",
      status: "active",
      checkpoint: checkpoint("s1"),
    });
    const got = await store.get(PROJECT, "s1");
    expect(got).toEqual({ checkpoint: checkpoint("s1"), currentSnapshot: "snap-1" });
    expect(await store.get(PROJECT, "missing")).toBeNull();
  });

  it("listActive returns only active shards (not completed/terminating)", async () => {
    const store = new InMemoryShardStore();
    await store.upsert({
      projectId: PROJECT,
      shardId: "a",
      currentSnapshot: "snap-1",
      status: "active",
      checkpoint: checkpoint("a"),
    });
    await store.upsert({
      projectId: PROJECT,
      shardId: "b",
      currentSnapshot: "snap-2",
      status: "completed",
      checkpoint: checkpoint("b"),
    });
    const active = await store.listActive(PROJECT);
    expect(active).toEqual([{ shardId: "a", currentSnapshot: "snap-1" }]);
  });

  it("delete removes a shard", async () => {
    const store = new InMemoryShardStore();
    await store.upsert({
      projectId: PROJECT,
      shardId: "s1",
      currentSnapshot: "snap-1",
      status: "active",
      checkpoint: checkpoint("s1"),
    });
    await store.delete(PROJECT, "s1");
    expect(await store.get(PROJECT, "s1")).toBeNull();
  });

  it("scopes shards by project", async () => {
    const store = new InMemoryShardStore();
    await store.upsert({
      projectId: "p-a",
      shardId: "s",
      currentSnapshot: "x",
      status: "active",
      checkpoint: checkpoint("a"),
    });
    expect(await store.get("p-b", "s")).toBeNull();
    expect((await store.listActive("p-b")).length).toBe(0);
  });
});

describe("ProjectIndexStore", () => {
  it("upsert → get round-trips the index", async () => {
    const store = new InMemoryProjectIndexStore();
    const index: ProjectIndex = {
      delegations: { d1: "shard-root" },
      pendingDelegateOut: { d2: "shard-issuer" },
      escalationOwners: { e1: "shard-escalator" },
    };
    await store.upsert(PROJECT, index);
    expect(await store.get(PROJECT)).toEqual(index);
    expect(await store.get("other")).toBeNull();
  });
});

describe("Storage facade + transaction", () => {
  it("exposes shards + projectIndex and rolls them back on tx throw", async () => {
    const storage = new InMemoryStorage();
    await storage.shards.upsert({
      projectId: PROJECT,
      shardId: "committed",
      currentSnapshot: "snap-1",
      status: "active",
      checkpoint: checkpoint("committed"),
    });

    await expect(
      storage.withTransaction(async (tx) => {
        await tx.shards.upsert({
          projectId: PROJECT,
          shardId: "rolled-back",
          currentSnapshot: "snap-1",
          status: "active",
          checkpoint: checkpoint("rolled-back"),
        });
        await tx.projectIndex.upsert(PROJECT, {
          delegations: {},
          pendingDelegateOut: {},
          escalationOwners: {},
        });
        throw new Error("boom");
      }),
    ).rejects.toThrow("boom");

    expect(await storage.shards.get(PROJECT, "committed")).not.toBeNull();
    expect(await storage.shards.get(PROJECT, "rolled-back")).toBeNull();
    expect(await storage.projectIndex.get(PROJECT)).toBeNull();
  });
});
