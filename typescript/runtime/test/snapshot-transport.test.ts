// SnapshotFfiTransport routing: each snapshot gets its own sidecar process, a call is routed to its
// snapshot's process, an abort follows the delegation to the right process, and a snapshot with no bundle
// fails the call as an error. Driven against fake channels (no real `node`).

import { describe, expect, test } from "vitest";
import type { FfiCompletion } from "../src/runtime/external/runner.js";
import {
  type BundleSource,
  type Materialize,
  SnapshotFfiTransport,
} from "../src/runtime/external/snapshot-transport.js";
import type { SidecarReply, SidecarRequest } from "../src/runtime/external/sidecar-protocol.js";
import type { SidecarHandlers, SidecarSpawner } from "../src/runtime/external/subprocess-runner.js";
import type { DelegationId, ProjectId, SnapshotId } from "../src/runtime/ids.js";

const PROJECT = "project-ffi" as ProjectId;

/** A fake sidecar channel: records what was sent and lets the test drive replies on it. */
function fakeChannel() {
  const sent: SidecarRequest[] = [];
  let handlers: SidecarHandlers | null = null;
  const spawner: SidecarSpawner = (h) => {
    handlers = h;
    return { send: (request) => sent.push(request), kill: () => {} };
  };
  return { spawner, sent, reply: (reply: SidecarReply) => handlers?.onReply(reply) };
}

/** A transport over fake channels: one channel per snapshot (recorded), and a bundle for every snapshot
 *  except `"s-empty"` (which has none). */
function harness() {
  const channels = new Map<string, ReturnType<typeof fakeChannel>>();
  const bundleSource: BundleSource = async (_projectId, snapshot) =>
    snapshot === ("s-empty" as SnapshotId) ? null : { entry: "/* bundle */", runtime: "node" };
  const materialize: Materialize = async (_bundle, snapshot) => {
    const channel = fakeChannel();
    channels.set(snapshot, channel);
    return channel.spawner;
  };
  const transport = new SnapshotFfiTransport(bundleSource, materialize);
  const completions: FfiCompletion[] = [];
  transport.onComplete((completion) => completions.push(completion));
  return { transport, channels, completions };
}

const tick = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0));

const call = (delegation: string, snapshot: string, key = "handler"): Parameters<
  SnapshotFfiTransport["dispatch"]
>[0] => ({
  projectId: PROJECT,
  delegation: delegation as DelegationId,
  snapshot: snapshot as SnapshotId,
  key,
  argument: null,
});

describe("SnapshotFfiTransport", () => {
  test("spawns one process per snapshot and routes each call to its snapshot", async () => {
    const { transport, channels } = harness();
    transport.dispatch(call("d1", "s1"));
    transport.dispatch(call("d2", "s2"));
    await tick();

    expect([...channels.keys()].sort()).toEqual(["s1", "s2"]);
    expect(channels.get("s1")?.sent).toEqual([
      { kind: "dispatch", delegation: "d1", key: "handler", argument: null, redispatch: false },
    ]);
    expect(channels.get("s2")?.sent).toEqual([
      { kind: "dispatch", delegation: "d2", key: "handler", argument: null, redispatch: false },
    ]);
  });

  test("reuses one process for several calls to the same snapshot", async () => {
    const { transport, channels } = harness();
    transport.dispatch(call("d1", "s1"));
    await tick();
    transport.dispatch(call("d2", "s1"));
    await tick();
    expect(channels.size).toBe(1);
    expect(channels.get("s1")?.sent.map((request) => request.delegation)).toEqual(["d1", "d2"]);
  });

  test("delivers a reply to the shared completion sink", async () => {
    const { transport, channels, completions } = harness();
    transport.dispatch(call("d1", "s1"));
    await tick();
    channels.get("s1")?.reply({ kind: "result", delegation: "d1" as DelegationId, value: 42 });
    expect(completions).toEqual([{ delegation: "d1", outcome: { kind: "result", value: 42 } }]);
  });

  test("routes an abort to the delegation's snapshot process", async () => {
    const { transport, channels } = harness();
    transport.dispatch(call("d1", "s1"));
    await tick();
    transport.abort("d1" as DelegationId);
    await tick(); // the abort routes to the process on a microtask
    expect(channels.get("s1")?.sent.at(-1)).toEqual({ kind: "abort", delegation: "d1" });
  });

  test("fails a call as an error when its snapshot has no bundle", async () => {
    const { transport, completions } = harness();
    transport.dispatch(call("d1", "s-empty"));
    await tick();
    expect(completions).toHaveLength(1);
    expect(completions[0]?.outcome.kind).toBe("error");
  });
});
