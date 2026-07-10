// Engine-level tests for the `finally` statement (the runtime side of the `defer` operation). Hand-built IR
// driven through the ProjectActor, exactly like engine-smoke / recovery — no compiler, no DB. A `defer` op
// arms (block, the executing thread's scope) onto the instance's finalizer stack; at the instance's terminal
// the stack drains in reverse before the ack. These cover: reverse-order execution before a normal ack,
// finalizers running on a cancel, the cancel-during-finalization atomicity rule, panic skipping finalizers
// (both instance-level and finalizer-level), mid-finalization recovery, and the io-only escalation backstop.

import { createAgentName, type IRModule, type QualifiedName, type SchemaInfo } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { InMemoryPersistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor, RunCancelledError } from "../src/runtime/actor/project-actor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import {
  type FfiCall,
  type FfiCompletion,
  type FfiTransport,
  InProcessFfiTransport,
} from "../src/runtime/external/runner.js";
import type { DelegationId, ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";

const PROJECT = "project-finally" as ProjectId;
const SNAPSHOT = "snapshot-finally" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

/** An agent whose body is an ffi external leaf: `entries[name] -> agent -> external{key}`. Two block ids —
 *  the finalizer's observable side effect is a `delegate` to one of these. */
function externalFfiAgent(agentId: number, leafId: number, inputVar: number, key: string) {
  return {
    [agentId]: {
      block: { kind: "agent", body: leafId, schema: EMPTY_SCHEMA, defaults: {} },
      parameters: {},
    },
    [leafId]: {
      block: { kind: "external", key, input: inputVar, reactor: "ffi" },
      parameters: { parameter: inputVar },
    },
  } as const;
}

/** An agent whose body is a request leaf (an unhandled request that escalates): `entries[name] -> agent ->
 *  request{name}`. Used both as an unhandled body suspend point and as a finalizer's forbidden escalation. */
function requestAgent(agentId: number, leafId: number, inputVar: number, name: string) {
  return {
    [agentId]: {
      block: { kind: "agent", body: leafId, schema: EMPTY_SCHEMA, defaults: {} },
      parameters: {},
    },
    [leafId]: {
      block: { kind: "request", name: createAgentName(name), input: inputVar },
      parameters: { parameter: inputVar },
    },
  } as const;
}

/** A leaf primitive wrapped in its agent (`entries[name] -> agent -> primitive`), for `prelude.add`. */
function primitiveWrapper(agentId: number, leafId: number, inputVar: number, name: string) {
  return {
    [agentId]: {
      block: { kind: "agent", body: leafId, schema: EMPTY_SCHEMA, defaults: {} },
      parameters: {},
    },
    [leafId]: {
      block: { kind: "primitive", name, input: inputVar },
      parameters: { parameter: inputVar },
    },
  } as const;
}

/** A finalizer body: build a `{ tag }` record from an enclosing binding (`tagVar`, resolved up the scope
 *  chain — proving the finalizer reads the scope it was armed in) and delegate it to the named callee. */
function finalizerBody(
  blockId: number,
  tagVar: number,
  argVar: number,
  outVar: number,
  callee: string,
) {
  return {
    [blockId]: {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "makeRecord", entries: [["tag", tagVar]], output: argVar },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName(callee) },
            argument: argVar,
            output: outVar,
          },
        ],
      },
      parameters: {},
    },
  } as const;
}

/** A finalizer body that panics: `add({ left: 1, right: "x" })` — the add prim panics (a string is not a
 *  number), so the panic escapes the finalizer and fails the instance. */
function panicFinalizerBody(blockId: number, leftVar: number, rightVar: number, recVar: number, outVar: number) {
  return {
    [blockId]: {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "loadLiteral", output: leftVar, value: { kind: "integer", value: 1 } },
          { kind: "loadLiteral", output: rightVar, value: { kind: "string", value: "x" } },
          {
            kind: "makeRecord",
            entries: [
              ["left", leftVar],
              ["right", rightVar],
            ],
            output: recVar,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.add") },
            argument: recVar,
            output: outVar,
          },
        ],
      },
      parameters: {},
    },
  } as const;
}

function registerModules(registry: SnapshotRegistry, ir: IRModule): void {
  for (const name of Object.keys(ir.entries)) {
    registry.set(SNAPSHOT, moduleOfName(name as QualifiedName), ir);
  }
}

function makeActor(ir: IRModule, external: FfiTransport, persistence = new InMemoryPersistence()): ProjectActor {
  const registry = new SnapshotRegistry();
  registerModules(registry, ir);
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims: new PrimRegistry(),
    blobs: new InMemoryBlobStore(),
    external,
    http: new StubHttpTransport(),
    persistence,
  });
}

async function waitUntil<T>(predicate: () => T | undefined): Promise<T> {
  for (let attempt = 0; attempt < 1000; attempt++) {
    const value = predicate();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error("waitUntil: predicate never held");
}

/** Yield the event loop repeatedly so the serial mailbox drains any queued turns (e.g. a terminate produced
 *  by a just-committed cancel command reaches core before the test drives the next external completion). */
async function drainMailbox(): Promise<void> {
  for (let tick = 0; tick < 20; tick++) await new Promise((resolve) => setTimeout(resolve, 0));
}

/** A recording FFI transport: logs each dispatched `{ key, argument }` in order and each abort. Keys listed in
 *  `hold` stay in flight until `release`d (modelling a slow, multi-turn external call); the rest complete
 *  immediately. `recover` leaves a held call alone (the warm-reset / process-survived model). */
function recordingFfi(hold: Set<string> = new Set()): {
  transport: FfiTransport;
  dispatched: Array<{ key: string; argument: FfiCall["argument"] }>;
  aborted: DelegationId[];
  release(key: string): void;
} {
  const dispatched: Array<{ key: string; argument: FfiCall["argument"] }> = [];
  const aborted: DelegationId[] = [];
  const held = new Map<string, DelegationId>();
  let sink: ((completion: FfiCompletion) => void) | null = null;
  const complete = (delegation: DelegationId, key: string): void => {
    sink?.({ delegation, outcome: { kind: "result", value: `${key}-done` } });
  };
  const transport: FfiTransport = {
    onComplete(register) {
      sink = register;
    },
    onDelegate() {},
    dispatch(call) {
      dispatched.push({ key: call.key, argument: call.argument });
      if (hold.has(call.key)) {
        held.set(call.key, call.delegation);
        return;
      }
      complete(call.delegation, call.key);
    },
    recover() {
      // Warm reset: a held handler's process survived, so recovery leaves it in flight (no completion here).
    },
    abort(delegation) {
      aborted.push(delegation);
      sink?.({ delegation, outcome: { kind: "cancelled" } });
    },
    deliverDelegateResult() {},
    close() {},
  };
  const release = (key: string): void => {
    const delegation = held.get(key);
    if (delegation !== undefined) {
      held.delete(key);
      complete(delegation, key);
    }
  };
  return { transport, dispatched, aborted, release };
}

describe("finally (defer)", () => {
  test("runs finalizers in reverse arming order before a normal completion's ack, keeping the original result", async () => {
    // agent main() { let tag = "from-main"; defer finalize_a(tag); defer finalize_b(tag); return 42 }
    // finalize_a is armed first, finalize_b second — so finalize_b runs first (reverse). Each finalizer reads
    // the enclosing `tag` binding through the scope it was armed in and records it via a distinct ffi key.
    const ir: IRModule = {
      metadata: { schemaVersion: 3 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 500, value: { kind: "string", value: "from-main" } },
              { kind: "defer", block: 2 }, // finalize_a — armed first, runs LAST
              { kind: "defer", block: 3 }, // finalize_b — armed second, runs FIRST
              { kind: "loadLiteral", output: 101, value: { kind: "integer", value: 42 } },
              { kind: "exit", target: 0, value: 101 },
            ],
          },
          parameters: { parameter: 100 },
        },
        ...finalizerBody(2, 500, 200, 201, "finalize_a"),
        ...finalizerBody(3, 500, 300, 301, "finalize_b"),
        ...externalFfiAgent(4, 5, 400, "finalize_a"),
        ...externalFfiAgent(6, 7, 600, "finalize_b"),
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("finalize_a")]: 4,
        [createAgentName("finalize_b")]: 6,
      },
      names: {},
    };

    const ffi = recordingFfi();
    const { result } = makeActor(ir, ffi.transport).startRun(createAgentName("main"), SNAPSHOT, null);
    await expect(result).resolves.toEqual({ kind: "integer", value: 42 });
    // Reverse arming order, and each finalizer read the enclosing `tag` binding through its armed scope.
    expect(ffi.dispatched.map((entry) => entry.key)).toEqual(["finalize_b", "finalize_a"]);
    expect(ffi.dispatched.map((entry) => entry.argument)).toEqual([
      { tag: "from-main" },
      { tag: "from-main" },
    ]);
  });

  test("runs finalizers on a cancel, then acks the cancel after the drain", async () => {
    // agent main() { defer finalize_a("x"); ask_value({}) }  — the request is unhandled, so it escalates to the
    // run root and the body suspends on an open escalation. Cancelling the run tears the body down, then the
    // finalizer runs, and only after it drains does the run settle as cancelled.
    const ir: IRModule = {
      metadata: { schemaVersion: 3 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 500, value: { kind: "string", value: "x" } },
              { kind: "defer", block: 2 },
              { kind: "makeRecord", entries: [], output: 110 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("ask_value") },
                argument: 110,
                output: 111,
              },
              { kind: "exit", target: 0, value: 111 },
            ],
          },
          parameters: { parameter: 100 },
        },
        ...finalizerBody(2, 500, 200, 201, "finalize_a"),
        ...externalFfiAgent(4, 5, 400, "finalize_a"),
        ...requestAgent(6, 7, 600, "ask_value"),
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("finalize_a")]: 4,
        [createAgentName("ask_value")]: 6,
      },
      names: {},
    };

    const ffi = recordingFfi();
    const actor = makeActor(ir, ffi.transport);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    await waitUntil(() => (actor.listOpenEscalations().length > 0 ? true : undefined));

    await actor.cancelRun(run, "user requested");
    await expect(result).rejects.toBeInstanceOf(RunCancelledError);
    // The finalizer ran during the cancel teardown (before the cancelAck), and it was NOT aborted.
    expect(ffi.dispatched.map((entry) => entry.key)).toEqual(["finalize_a"]);
    expect(ffi.aborted).toHaveLength(0);
  });

  test("a cancel arriving mid-finalization does not cancel the finalizer; it acks cancelled and discards the result", async () => {
    // agent main() { defer finalize_slow("x"); return 5 }  — main completes normally, so the finalizer starts;
    // its ffi is slow (held). A cancel now arrives mid-drain: it must NOT abort the finalizer, and when the
    // finalizer finishes the terminal acks cancelled (the completed result 5 is discarded).
    const ir: IRModule = {
      metadata: { schemaVersion: 3 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 500, value: { kind: "string", value: "x" } },
              { kind: "defer", block: 2 },
              { kind: "loadLiteral", output: 101, value: { kind: "integer", value: 5 } },
              { kind: "exit", target: 0, value: 101 },
            ],
          },
          parameters: { parameter: 100 },
        },
        ...finalizerBody(2, 500, 200, 201, "finalize_slow"),
        ...externalFfiAgent(4, 5, 400, "finalize_slow"),
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("finalize_slow")]: 4,
      },
      names: {},
    };

    const ffi = recordingFfi(new Set(["finalize_slow"]));
    const actor = makeActor(ir, ffi.transport);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    // The finalizer is in flight (its slow ffi dispatched); the run is held open awaiting the drain.
    await waitUntil(() => (ffi.dispatched.length > 0 ? true : undefined));

    // Cancel while the finalizer runs, then let the terminate reach core before releasing the held ffi.
    await actor.cancelRun(run, "user requested");
    await drainMailbox();
    ffi.release("finalize_slow");

    await expect(result).rejects.toBeInstanceOf(RunCancelledError);
    // The finalizer was never aborted — it completed normally, only the terminal flipped to cancelled.
    expect(ffi.aborted).toHaveLength(0);
    expect(ffi.dispatched.map((entry) => entry.key)).toEqual(["finalize_slow"]);
  });

  test("a panic of the instance skips its finalizers", async () => {
    // agent main() { defer finalize_a("x"); add({ left: 1, right: "x" }) }  — the body panics (string is not a
    // number); the panicked instance's state is untrusted, so its finalizer is skipped and the run fails.
    const ir: IRModule = {
      metadata: { schemaVersion: 3 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 500, value: { kind: "string", value: "x" } },
              { kind: "defer", block: 2 },
              { kind: "loadLiteral", output: 101, value: { kind: "integer", value: 1 } },
              { kind: "loadLiteral", output: 102, value: { kind: "string", value: "x" } },
              {
                kind: "makeRecord",
                entries: [
                  ["left", 101],
                  ["right", 102],
                ],
                output: 103,
              },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("prelude.add") },
                argument: 103,
                output: 104,
              },
              { kind: "exit", target: 0, value: 104 },
            ],
          },
          parameters: { parameter: 100 },
        },
        ...finalizerBody(2, 500, 200, 201, "finalize_a"),
        ...externalFfiAgent(4, 5, 400, "finalize_a"),
        ...primitiveWrapper(6, 7, 600, "prelude.add"),
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("finalize_a")]: 4,
        [createAgentName("prelude.add")]: 6,
      },
      names: {},
    };

    const ffi = recordingFfi();
    const { result } = makeActor(ir, ffi.transport).startRun(createAgentName("main"), SNAPSHOT, null);
    await expect(result).rejects.toThrow(/panic.*number/);
    expect(ffi.dispatched).toHaveLength(0); // the finalizer never ran
  });

  test("a panic inside a finalizer fails the instance and skips the remaining finalizers", async () => {
    // agent main() { defer finalize_a("x"); defer panic_finalizer(); return 5 }
    // panic_finalizer is armed second, so it runs first; it panics. The instance then fails and the still-armed
    // finalize_a is skipped.
    const ir: IRModule = {
      metadata: { schemaVersion: 3 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 500, value: { kind: "string", value: "x" } },
              { kind: "defer", block: 2 }, // finalize_a — armed first, would run LAST
              { kind: "defer", block: 8 }, // panic_finalizer — armed second, runs FIRST (and panics)
              { kind: "loadLiteral", output: 101, value: { kind: "integer", value: 5 } },
              { kind: "exit", target: 0, value: 101 },
            ],
          },
          parameters: { parameter: 100 },
        },
        ...finalizerBody(2, 500, 200, 201, "finalize_a"),
        ...panicFinalizerBody(8, 800, 801, 802, 803),
        ...externalFfiAgent(4, 5, 400, "finalize_a"),
        ...primitiveWrapper(6, 7, 600, "prelude.add"),
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("finalize_a")]: 4,
        [createAgentName("prelude.add")]: 6,
      },
      names: {},
    };

    const ffi = recordingFfi();
    const { result } = makeActor(ir, ffi.transport).startRun(createAgentName("main"), SNAPSHOT, null);
    await expect(result).rejects.toThrow(/panic.*number/);
    expect(ffi.dispatched).toHaveLength(0); // the surviving finalizer was skipped after the panic
  });

  test("resumes a drain suspended mid-finalization after a reload and acks the original result", async () => {
    // agent main() { defer finalize_slow("x"); return 5 }  — main completes, the finalizer's slow ffi is in
    // flight and the whole finalizing state persists. A fresh actor over the same store + surviving transport
    // reloads it; releasing the ffi resumes the drain, which acks the ORIGINAL result 5.
    const ir: IRModule = {
      metadata: { schemaVersion: 3 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 500, value: { kind: "string", value: "x" } },
              { kind: "defer", block: 2 },
              { kind: "loadLiteral", output: 101, value: { kind: "integer", value: 5 } },
              { kind: "exit", target: 0, value: 101 },
            ],
          },
          parameters: { parameter: 100 },
        },
        ...finalizerBody(2, 500, 200, 201, "finalize_slow"),
        ...externalFfiAgent(4, 5, 400, "finalize_slow"),
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("finalize_slow")]: 4,
      },
      names: {},
    };

    const persistence = new StoringPersistence();
    // One shared transport across both actors = the finalizer handler's process survived the reset. Its slow
    // handler suspends until released.
    let releaseSlow: (value: string) => void = () => {};
    let slowRan = false;
    const transport = new InProcessFfiTransport({
      finalize_slow: () => {
        slowRan = true;
        return new Promise<string>((resolve) => (releaseSlow = resolve));
      },
    });

    const actorOne = makeActor(ir, transport, persistence);
    const { run } = actorOne.startRun(createAgentName("main"), SNAPSHOT, null);
    // The finalizer's ffi was dispatched (post-commit), so the finalizing state is durable.
    await waitUntil(() => (slowRan ? true : undefined));

    // Reload in a fresh actor over the same store + transport. The drain has not yet acked.
    const actorTwo = makeActor(ir, transport, persistence);
    await actorTwo.activate();
    expect(persistence.peekRun(run)?.state).not.toBe("done");

    // The surviving finalizer settles: its completion reaches the NEW actor, the drain finishes, and the
    // deferred delegateAck carries the ORIGINAL result 5.
    releaseSlow("finalize_slow-done");
    const done = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "done" ? record : undefined;
    });
    expect(done.result).toEqual({ kind: "integer", value: 5 });
  });

  test("panics with the finally restriction when a finalizer performs a parent-proxying escalation", async () => {
    // agent main() { defer bad_finalizer(); return 5 }  where bad_finalizer performs ask_value({}) — a
    // user-facing request that would proxy through the parent. The compiler forbids this statically; the
    // runtime backstop panics naming the finally restriction, and the run fails with that message.
    const ir: IRModule = {
      metadata: { schemaVersion: 3 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "defer", block: 2 },
              { kind: "loadLiteral", output: 101, value: { kind: "integer", value: 5 } },
              { kind: "exit", target: 0, value: 101 },
            ],
          },
          parameters: { parameter: 100 },
        },
        // bad_finalizer body: ask_value({}) — an escalation that would proxy through the parent.
        2: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "makeRecord", entries: [], output: 200 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("ask_value") },
                argument: 200,
                output: 201,
              },
            ],
          },
          parameters: {},
        },
        ...requestAgent(6, 7, 600, "ask_value"),
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("ask_value")]: 6,
      },
      names: {},
    };

    const ffi = recordingFfi();
    const { result } = makeActor(ir, ffi.transport).startRun(createAgentName("main"), SNAPSHOT, null);
    await expect(result).rejects.toThrow(/finally/i);
  });
});
