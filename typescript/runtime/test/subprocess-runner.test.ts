// The FFI subprocess transport: the protocol logic (dispatch → reply routing, cancel, crash recovery) is
// unit-tested against a fake channel, and the real `subprocessSidecar` channel is integration-tested against
// a genuine `node` sidecar that speaks the wire protocol — proving the stdio framing end to end.

import { describe, expect, test } from "vitest";
import type { FfiResult } from "../src/runtime/external/runner.js";
import type {
  SidecarHandlers,
  SidecarSpawner,
} from "../src/runtime/external/subprocess-runner.js";
import {
  SubprocessExternalRunner,
  subprocessSidecar,
} from "../src/runtime/external/subprocess-runner.js";
import type { SidecarReply, SidecarRequest } from "../src/runtime/external/sidecar-protocol.js";
import { type InstanceId, type ProjectId, type ThreadId, toThreadId } from "../src/runtime/ids.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-ffi" as ProjectId;
const INSTANCE = "instance-ffi" as InstanceId;

/** A fake channel: records what the runner sends, lets the test drive replies / a crash on the latest spawn,
 *  and counts spawns (so respawn-after-crash is observable). */
function fakeChannel() {
  const sent: SidecarRequest[] = [];
  let current: SidecarHandlers | null = null;
  let spawnCount = 0;
  let killed = 0;
  const spawner: SidecarSpawner = (handlers) => {
    spawnCount += 1;
    current = handlers;
    return {
      send: (request) => sent.push(request),
      kill: () => {
        killed += 1;
      },
    };
  };
  return {
    spawner,
    sent,
    reply: (reply: SidecarReply) => current?.onReply(reply),
    crash: (reason: string) => current?.onClose(reason),
    get spawnCount() {
      return spawnCount;
    },
    get killed() {
      return killed;
    },
  };
}

function collectResults(runner: SubprocessExternalRunner): FfiResult[] {
  const results: FfiResult[] = [];
  runner.onResult((result) => results.push(result));
  return results;
}

describe("SubprocessExternalRunner (protocol logic)", () => {
  const thread = toThreadId(1);
  const call = (key: string, argument: Value | null = null) => ({
    projectId: PROJECT,
    instance: INSTANCE,
    thread,
    key,
    argument,
  });

  test("spawns lazily on the first dispatch and routes the reply to the sink", () => {
    const channel = fakeChannel();
    const runner = new SubprocessExternalRunner(channel.spawner);
    const results = collectResults(runner);
    expect(channel.spawnCount).toBe(0); // nothing spawned until there is work

    runner.dispatch(call("echo", { kind: "integer", value: 7 }));
    expect(channel.spawnCount).toBe(1);
    expect(channel.sent).toEqual([
      {
        kind: "dispatch",
        instance: INSTANCE,
        thread,
        key: "echo",
        argument: { kind: "integer", value: 7 },
        redispatch: false,
      },
    ]);

    channel.reply({ kind: "result", instance: INSTANCE, thread, value: { kind: "integer", value: 7 } });
    expect(results).toEqual([
      { kind: "ffiResult", instance: INSTANCE, thread, value: { kind: "integer", value: 7 } },
    ]);
  });

  test("maps an error reply to a panic and a cancelled reply to the abort confirmation", () => {
    const channel = fakeChannel();
    const runner = new SubprocessExternalRunner(channel.spawner);
    const results = collectResults(runner);

    runner.dispatch(call("boom"));
    channel.reply({ kind: "error", instance: INSTANCE, thread, message: "boom!" });
    runner.dispatch(call("slow"));
    runner.cancel(INSTANCE, thread);
    expect(channel.sent.at(-1)).toEqual({ kind: "abort", instance: INSTANCE, thread });
    channel.reply({ kind: "cancelled", instance: INSTANCE, thread });

    expect(results).toEqual([
      { kind: "ffiError", instance: INSTANCE, thread, message: "boom!" },
      { kind: "ffiCancelled", instance: INSTANCE, thread },
    ]);
  });

  test("a sidecar crash fails every in-flight call as a panic, and the next dispatch respawns", () => {
    const channel = fakeChannel();
    const runner = new SubprocessExternalRunner(channel.spawner);
    const results = collectResults(runner);

    runner.dispatch(call("a"));
    runner.dispatch({ ...call("b"), thread: toThreadId(2) });
    channel.crash("FFI sidecar exited (code 1)");

    expect(results).toEqual([
      { kind: "ffiError", instance: INSTANCE, thread, message: "FFI sidecar exited (code 1)" },
      {
        kind: "ffiError",
        instance: INSTANCE,
        thread: toThreadId(2),
        message: "FFI sidecar exited (code 1)",
      },
    ]);

    // A new dispatch respawns; the crashed call is not re-failed (it was cleared).
    runner.dispatch(call("c"));
    expect(channel.spawnCount).toBe(2);
    channel.reply({ kind: "result", instance: INSTANCE, thread, value: { kind: "string", value: "ok" } });
    expect(results.at(-1)).toEqual({
      kind: "ffiResult",
      instance: INSTANCE,
      thread,
      value: { kind: "string", value: "ok" },
    });
  });
});

// A genuine sidecar (CommonJS, run via `node -e`): reads dispatch / abort lines on stdin and replies on
// stdout — echoing the argument as the result, erroring on key "boom", leaving key "hang" in flight (no
// reply) until an abort confirms it cancelled, exiting on "crash". Proves the real stdio framing, not just
// the in-memory protocol.
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
    const head = { instance: message.instance, thread: message.thread };
    if (message.kind === "abort") { reply({ kind: "cancelled", ...head }); continue; }
    if (message.key === "crash") { process.exit(1); }
    if (message.key === "boom") { reply({ kind: "error", ...head, message: "boom!" }); continue; }
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
    const runner = new SubprocessExternalRunner(subprocessSidecar("node", ["-e", SIDECAR]));
    const results = collectResults(runner);
    const base = { projectId: PROJECT, instance: INSTANCE };
    try {
      runner.dispatch({ ...base, thread: toThreadId(1), key: "echo", argument: { kind: "integer", value: 42 } });
      runner.dispatch({ ...base, thread: toThreadId(2), key: "boom", argument: null });
      runner.dispatch({ ...base, thread: toThreadId(3), key: "hang", argument: null });
      runner.cancel(INSTANCE, toThreadId(3));

      const echo = await waitUntil(() => results.find((r) => r.thread === toThreadId(1)));
      expect(echo).toEqual({
        kind: "ffiResult",
        instance: INSTANCE,
        thread: toThreadId(1),
        value: { kind: "integer", value: 42 },
      });
      const boom = await waitUntil(() => results.find((r) => r.thread === toThreadId(2)));
      expect(boom).toEqual({ kind: "ffiError", instance: INSTANCE, thread: toThreadId(2), message: "boom!" });
      const cancelled = await waitUntil(() => results.find((r) => r.thread === toThreadId(3)));
      expect(cancelled).toEqual({ kind: "ffiCancelled", instance: INSTANCE, thread: toThreadId(3) });

      // A crashing dispatch fails its call as a panic (the process exits while it is in flight).
      runner.dispatch({ ...base, thread: toThreadId(4), key: "crash", argument: null });
      const crashed = await waitUntil(() =>
        results.find((r) => r.thread === toThreadId(4) && r.kind === "ffiError"),
      );
      expect(crashed?.kind).toBe("ffiError");
    } finally {
      runner.close();
    }
  });
});
