// The FFI subprocess transport: the protocol logic (dispatch → reply routing, abort, crash recovery) is
// unit-tested against a fake channel, and the real `subprocessSidecar` channel is integration-tested against
// a genuine `node` sidecar that speaks the wire protocol — proving the stdio framing end to end. Every call
// is correlated by its `delegation` id (the id the ffi reactor's pending-call and core's proxy share).

import { describe, expect, test } from "vitest";
import type { FfiCompletion, FfiInnerDelegate } from "../src/runtime/external/runner.js";
import type {
  SidecarHandlers,
  SidecarSpawner,
} from "../src/runtime/external/subprocess-runner.js";
import {
  SubprocessFfiTransport,
  subprocessSidecar,
} from "../src/runtime/external/subprocess-runner.js";
import type { Json } from "@katari-lang/types";
import type { RuntimeMessage, SidecarMessage } from "../src/runtime/external/sidecar-protocol.js";
import {
  type DelegationId,
  type ProjectId,
  type SnapshotId,
  toDelegationId,
} from "../src/runtime/ids.js";

const PROJECT = "project-ffi" as ProjectId;
const SNAPSHOT = "snapshot-ffi" as SnapshotId;

/** A fake channel: records what the transport sends, lets the test drive replies / a crash on the latest
 *  spawn, and counts spawns (so respawn-after-crash is observable). */
function fakeChannel() {
  const sent: RuntimeMessage[] = [];
  let current: SidecarHandlers | null = null;
  let spawnCount = 0;
  let killed = 0;
  const spawner: SidecarSpawner = (handlers) => {
    spawnCount += 1;
    current = handlers;
    return {
      send: (message) => sent.push(message),
      kill: () => {
        killed += 1;
      },
    };
  };
  return {
    spawner,
    sent,
    reply: (message: SidecarMessage) => current?.onMessage(message),
    crash: (reason: string) => current?.onClose(reason),
    get spawnCount() {
      return spawnCount;
    },
    get killed() {
      return killed;
    },
  };
}

function collectCompletions(transport: SubprocessFfiTransport): FfiCompletion[] {
  const completions: FfiCompletion[] = [];
  transport.onComplete((completion) => completions.push(completion));
  return completions;
}

describe("SubprocessFfiTransport (protocol logic)", () => {
  const delegation = toDelegationId("delegation-1");
  const call = (key: string, argument: Json | null = null) => ({
    projectId: PROJECT,
    delegation,
    snapshot: SNAPSHOT,
    key,
    argument,
  });

  test("spawns lazily on the first dispatch and routes the reply to the sink", () => {
    const channel = fakeChannel();
    const transport = new SubprocessFfiTransport(channel.spawner);
    const completions = collectCompletions(transport);
    expect(channel.spawnCount).toBe(0); // nothing spawned until there is work

    transport.dispatch(call("echo", { kind: "integer", value: 7 }));
    expect(channel.spawnCount).toBe(1);
    expect(channel.sent).toEqual([
      {
        kind: "dispatch",
        delegation,
        key: "echo",
        argument: { kind: "integer", value: 7 },
      },
    ]);

    channel.reply({ kind: "result", delegation, value: { kind: "integer", value: 7 } });
    expect(completions).toEqual([
      { delegation, outcome: { kind: "result", value: { kind: "integer", value: 7 } } },
    ]);
  });

  test("maps an error reply to a panic and a cancelled reply to the abort confirmation", () => {
    const channel = fakeChannel();
    const transport = new SubprocessFfiTransport(channel.spawner);
    const completions = collectCompletions(transport);

    transport.dispatch(call("boom"));
    channel.reply({ kind: "error", delegation, message: "boom!" });
    transport.dispatch(call("slow"));
    transport.abort(delegation);
    expect(channel.sent.at(-1)).toEqual({ kind: "abort", delegation });
    channel.reply({ kind: "cancelled", delegation });

    expect(completions).toEqual([
      { delegation, outcome: { kind: "error", message: "boom!" } },
      { delegation, outcome: { kind: "cancelled" } },
    ]);
  });

  test("maps a throw reply to a typed throw completion (the payload rides, not a message)", () => {
    const channel = fakeChannel();
    const transport = new SubprocessFfiTransport(channel.spawner);
    const completions = collectCompletions(transport);

    transport.dispatch(call("thrower"));
    channel.reply({
      kind: "throw",
      delegation,
      error: { $katari_constructor: "main.my_error", $katari_value: { message: "typed!" } },
    });

    expect(completions).toEqual([
      {
        delegation,
        outcome: {
          kind: "throw",
          error: { $katari_constructor: "main.my_error", $katari_value: { message: "typed!" } },
        },
      },
    ]);
  });

  test("routes a sidecar delegate message to the delegate sink and sends its result back", () => {
    const channel = fakeChannel();
    const transport = new SubprocessFfiTransport(channel.spawner);
    collectCompletions(transport);
    const delegates: FfiInnerDelegate[] = [];
    transport.onDelegate((request) => delegates.push(request));

    transport.dispatch(call("caller"));
    channel.reply({
      kind: "delegate",
      delegation,
      call: "token-1",
      callee: { kind: "named", agent: "main.helper" },
      argument: { n: 1 },
    });
    expect(delegates).toEqual([
      {
        kind: "delegate",
        delegation,
        call: "token-1",
        callee: { kind: "named", agent: "main.helper" },
        argument: { n: 1 },
      },
    ]);

    transport.deliverDelegateResult({
      delegation,
      call: "token-1",
      outcome: { kind: "result", value: 2 },
    });
    expect(channel.sent.at(-1)).toEqual({
      kind: "delegateResult",
      delegation,
      call: "token-1",
      outcome: { kind: "result", value: 2 },
    });
  });

  test("recover leaves an in-flight handler alone and refuses a call it no longer holds (at-most-once)", () => {
    const channel = fakeChannel();
    const transport = new SubprocessFfiTransport(channel.spawner);
    const completions = collectCompletions(transport);

    // In flight: recovery must neither error it nor send anything (its reply will come by itself).
    transport.dispatch(call("slow"));
    const sentBefore = channel.sent.length;
    transport.recover(delegation);
    expect(channel.sent).toHaveLength(sentBefore);
    expect(completions).toEqual([]);

    // Unknown (a fresh transport = a fresh process): refused with an error, never re-run.
    const gone = toDelegationId("delegation-gone");
    transport.recover(gone);
    expect(completions).toEqual([
      { delegation: gone, outcome: { kind: "error", message: expect.stringMatching(/at-most-once/) } },
    ]);
    expect(channel.sent).toHaveLength(sentBefore);
  });

  test("a sidecar crash fails every in-flight call as a panic, and the next dispatch respawns", () => {
    const channel = fakeChannel();
    const transport = new SubprocessFfiTransport(channel.spawner);
    const completions = collectCompletions(transport);
    const second = toDelegationId("delegation-2");

    transport.dispatch(call("a"));
    transport.dispatch({ projectId: PROJECT, delegation: second, snapshot: SNAPSHOT, key: "b", argument: null });
    channel.crash("FFI sidecar exited (code 1)");

    expect(completions).toEqual([
      { delegation, outcome: { kind: "error", message: "FFI sidecar exited (code 1)" } },
      { delegation: second, outcome: { kind: "error", message: "FFI sidecar exited (code 1)" } },
    ]);

    // A new dispatch respawns; the crashed call is not re-failed (it was cleared).
    transport.dispatch(call("c"));
    expect(channel.spawnCount).toBe(2);
    channel.reply({ kind: "result", delegation, value: { kind: "string", value: "ok" } });
    expect(completions.at(-1)).toEqual({
      delegation,
      outcome: { kind: "result", value: { kind: "string", value: "ok" } },
    });
  });
});

// A genuine sidecar (CommonJS, run via `node -e`): reads dispatch / abort lines on stdin and replies on
// stdout — echoing the argument as the result, erroring on key "boom", leaving key "hang" in flight (no
// reply) until an abort confirms it cancelled, exiting on "crash". Proves the real stdio framing, not just
// the in-memory protocol. Each reply echoes the `delegation` it answers.
const SIDECAR = `
let buffer = "";
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let index;
  while ((index = buffer.indexOf("\\n")) >= 0) {
    const line = buffer.slice(0, index);
    buffer = buffer.slice(index + 1);
    if (!line) continue;
    const message = JSON.parse(line);
    const reply = (object) => process.stdout.write(JSON.stringify(object) + "\\n");
    const head = { delegation: message.delegation };
    if (message.kind === "abort") { reply({ kind: "cancelled", ...head }); continue; }
    if (message.key === "crash") { process.exit(1); }
    if (message.key === "boom") { reply({ kind: "error", ...head, message: "boom!" }); continue; }
    if (message.key === "thrower") { reply({ kind: "throw", ...head, error: { message: "typed!" } }); continue; }
    if (message.key === "hang") { continue; }
    reply({ kind: "result", ...head, value: message.argument });
  }
});
`;

async function waitUntil<T>(predicate: () => T | undefined): Promise<T> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const value = predicate();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error("waitUntil: predicate never held");
}

describe("subprocessSidecar (real process)", () => {
  test("dispatches to a real node sidecar and routes result / error / cancelled / crash back", async () => {
    const transport = new SubprocessFfiTransport(subprocessSidecar("node", ["-e", SIDECAR]));
    const completions = collectCompletions(transport);
    const found = (delegation: DelegationId) =>
      completions.find((completion) => completion.delegation === delegation);
    const echo = toDelegationId("d-echo");
    const boom = toDelegationId("d-boom");
    const thrower = toDelegationId("d-thrower");
    const hang = toDelegationId("d-hang");
    const crash = toDelegationId("d-crash");
    try {
      transport.dispatch({ projectId: PROJECT, delegation: echo, snapshot: SNAPSHOT, key: "echo", argument: { kind: "integer", value: 42 } });
      transport.dispatch({ projectId: PROJECT, delegation: boom, snapshot: SNAPSHOT, key: "boom", argument: null });
      transport.dispatch({ projectId: PROJECT, delegation: thrower, snapshot: SNAPSHOT, key: "thrower", argument: null });
      transport.dispatch({ projectId: PROJECT, delegation: hang, snapshot: SNAPSHOT, key: "hang", argument: null });
      transport.abort(hang);

      expect(await waitUntil(() => found(echo))).toEqual({
        delegation: echo,
        outcome: { kind: "result", value: { kind: "integer", value: 42 } },
      });
      expect(await waitUntil(() => found(boom))).toEqual({
        delegation: boom,
        outcome: { kind: "error", message: "boom!" },
      });
      expect(await waitUntil(() => found(thrower))).toEqual({
        delegation: thrower,
        outcome: { kind: "throw", error: { message: "typed!" } },
      });
      expect(await waitUntil(() => found(hang))).toEqual({
        delegation: hang,
        outcome: { kind: "cancelled" },
      });

      // A crashing dispatch fails its call as a panic (the process exits while it is in flight).
      transport.dispatch({ projectId: PROJECT, delegation: crash, snapshot: SNAPSHOT, key: "crash", argument: null });
      const crashed = await waitUntil(() =>
        found(crash)?.outcome.kind === "error" ? found(crash) : undefined,
      );
      expect(crashed?.outcome.kind).toBe("error");
    } finally {
      transport.close();
    }
  });
});
