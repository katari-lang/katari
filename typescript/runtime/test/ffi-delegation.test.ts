// FFI inner delegation, end to end through the ProjectActor: a running FFI handler calls back into the
// runtime (`context.call` on the in-process transport — the same channel the real port speaks over stdio).
// Covers the core default target, ffi→ffi calls, the uniform proxy-up of a callee's failure (a callee panic
// is NOT catchable by the handler's JS try/catch — it proxies up past the ffi call, and the cancel cascade
// tears the dead callee's siblings down), the escalation proxy chain (a callee's user-facing request surfaces
// at the run root and its answer descends back), the held completion (a handler returning with a
// fire-and-forget child still running), and the cancel cascade distributing a terminate through the children.

import {
  createAgentName,
  type IRModule,
  type QualifiedName,
  type SchemaInfo,
} from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { InMemoryPersistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor, RunCancelledError } from "../src/runtime/actor/project-actor.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import { type FfiHandler, InProcessFfiTransport } from "../src/runtime/external/runner.js";
import type { ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-ffi-delegation" as ProjectId;
const SNAPSHOT = "snapshot-ffi-delegation" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

/** The shared program: `agent main() { return compute({}) }` with `compute` an external (FFI) agent, plus
 *  the callees a handler may reach back into — `prelude.add` (a core primitive agent) and `ask_value` (a
 *  core agent whose body is a bare request, so calling it escalates a user-facing ask to the run root). */
function ir(): IRModule {
  return {
    metadata: { schemaVersion: 1 },
    blocks: {
      0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      1: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "makeRecord", entries: [], output: 2 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("compute") },
              argument: 2,
              output: 3,
            },
            { kind: "exit", target: 0, value: 3 },
          ],
        },
        parameters: { parameter: 1 },
      },
      // compute: the external agent under test (its body delegates to the ffi reactor).
      6: { block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      7: {
        block: { kind: "external", key: "compute", input: 8, reactor: "ffi" },
        parameters: { parameter: 8 },
      },
      // prelude.add: a primitive wrapped in its agent (a core callee for the handler to reach).
      10: { block: { kind: "agent", body: 11, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      11: {
        block: { kind: "primitive", name: "prelude.add", input: 12 },
        parameters: { parameter: 12 },
      },
      // ask_value: a core agent whose whole body is a request — calling it raises a user-facing ask.
      15: { block: { kind: "agent", body: 16, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      16: {
        block: { kind: "request", name: createAgentName("ask_value"), input: 17 },
        parameters: { parameter: 17 },
      },
      // typed_compute: an external agent that declares `-> string`, so its result is conformed at the FFI
      // boundary; typed_main calls it. A handler returning a non-string exercises the output-schema check.
      20: {
        block: {
          kind: "agent",
          body: 21,
          schema: { input: {}, output: { type: "string" }, requests: [], genericBindings: {} },
          defaults: {},
        },
        parameters: {},
      },
      21: {
        block: { kind: "external", key: "typed_compute", input: 22, reactor: "ffi" },
        parameters: { parameter: 22 },
      },
      25: { block: { kind: "agent", body: 26, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      26: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "makeRecord", entries: [], output: 2 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("typed_compute") },
              argument: 2,
              output: 3,
            },
            { kind: "exit", target: 25, value: 3 },
          ],
        },
        parameters: { parameter: 1 },
      },
      // strict: a core agent with a CONSTRAINED input schema (`value: integer`) — a handler passing a bad
      // argument to it exercises the dynamic-dispatch input pre-check on the FFI inner-call channel.
      30: {
        block: {
          kind: "agent",
          body: 31,
          schema: {
            input: {
              type: "object",
              properties: { value: { type: "integer" } },
              required: ["value"],
              additionalProperties: true,
            },
            output: {},
            requests: [],
            genericBindings: {},
          },
          defaults: {},
        },
        parameters: {},
      },
      31: {
        block: {
          kind: "sequence",
          result: 41,
          operations: [{ kind: "getField", source: 40, field: "value", output: 41 }],
        },
        parameters: { parameter: 40 },
      },
    },
    entries: {
      [createAgentName("main")]: 0,
      [createAgentName("compute")]: 6,
      [createAgentName("prelude.add")]: 10,
      [createAgentName("ask_value")]: 15,
      [createAgentName("typed_compute")]: 20,
      [createAgentName("typed_main")]: 25,
      [createAgentName("strict")]: 30,
    },
    names: {},
  };
}

function makeActor(handlers: Record<string, FfiHandler>): ProjectActor {
  const registry = new SnapshotRegistry();
  const module = ir();
  for (const name of Object.keys(module.entries)) {
    registry.set(SNAPSHOT, moduleOfName(name as QualifiedName), module);
  }
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims: new PrimRegistry(),
    blobs: new InMemoryBlobStore(),
    external: new InProcessFfiTransport(handlers),
    http: new StubHttpTransport(),
    persistence: new InMemoryPersistence(),
  });
}

function run(handlers: Record<string, FfiHandler>): Promise<Value> {
  return makeActor(handlers).startRun(createAgentName("main"), SNAPSHOT, null).result;
}

/** Spin the event loop until `predicate` holds (the actor pumps its mailbox asynchronously). */
async function waitUntil<T>(predicate: () => T | undefined): Promise<T> {
  for (let attempt = 0; attempt < 1000; attempt++) {
    const value = predicate();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error("waitUntil: predicate never held");
}

describe("FFI inner delegation", () => {
  test("a handler calls a core agent (the default reactor) and resumes with its result", async () => {
    const result = run({
      compute: async (_argument, context) => {
        const sum = await context.call("prelude.add", { left: 20, right: 22 });
        return sum;
      },
    });
    await expect(result).resolves.toEqual({ kind: "integer", value: 42 });
  });

  test("a handler dispatches a received callable VALUE (an agent reference) directly on core", async () => {
    const result = run({
      // `context.callValue` is the in-process analogue of the port's `KatariAgent.call`: the handler holds
      // a callable value (here an `$agent` reference — the port would have decoded it from an argument) and
      // dispatches it. The runtime resolves the value to its target itself; no `call_agent` name is used.
      compute: async (_argument, context) => {
        const sum = await context.callValue(
          { $agent: "prelude.add", snapshot: SNAPSHOT },
          { left: 1, right: 2 },
        );
        return sum;
      },
    });
    await expect(result).resolves.toEqual({ kind: "integer", value: 3 });
  });

  test("dispatching a non-callable VALUE fails the inner call as an error the handler can catch", async () => {
    // A malformed callable crossing the FFI boundary is a bug, so — unlike the katari `call_agent`
    // primitive, which raises a catchable `reflection.call_error` — it is a plain error (a panic): it
    // reaches the handler as a rejected promise (uncaught, it would fail the handler and the run).
    let caught = "";
    const result = run({
      compute: async (_argument, context) => {
        try {
          await context.callValue(42, {});
          return "unreachable";
        } catch (error) {
          caught = error instanceof Error ? error.message : String(error);
          return "fallback";
        }
      },
    });
    await expect(result).resolves.toEqual({ kind: "string", value: "fallback" });
    expect(caught).toMatch(/not a callable value/);
  });

  test("a bad-arg context.call to an agent target fails the inner call as a catchable error", async () => {
    // `context.call` is DYNAMIC dispatch, like the AI's `call_agent`: a bad ARGUMENT is the caller's dispatch
    // error, pre-validated against the callee's declared input schema and delivered back as a catchable inner
    // error — never the acceptance surface's uncatchable panic. (Only a callee's EXECUTION failure proxies up.)
    // This matches the tool-typed callee's behaviour, removing the tool-vs-agent asymmetry.
    let caught = "";
    const result = run({
      compute: async (_argument, context) => {
        try {
          await context.call("strict", { value: "not-an-integer" });
          return "unreachable";
        } catch (error) {
          caught = error instanceof Error ? error.message : String(error);
          return "fallback";
        }
      },
    });
    await expect(result).resolves.toEqual({ kind: "string", value: "fallback" });
    expect(caught).toMatch(/strict.*input schema/);
  });

  test("a callee's panic is not catchable by the JS handler — it proxies up and fails the run", async () => {
    // The handler's try/catch cannot turn a callee's panic into a fallback: `context.call` no longer rejects
    // on a callee failure, so the `await` neither resolves nor rejects with the panic — the panic proxies UP
    // past the ffi call to the run root, failing the run. (The cancel cascade later unwinds the handler's
    // await, but its result is discarded — the run has already failed.)
    const result = run({
      compute: async (_argument, context) => {
        try {
          await context.call("no.such.agent");
          return "unreachable";
        } catch {
          return "fallback";
        }
      },
    });
    await expect(result).rejects.toThrow();
  });

  test("a callee failure with no katari handler proxies up and fails the run", async () => {
    // No try/catch — and the mechanism is the same either way now: the callee's panic proxies UP under the
    // ffi call and, uncaught, fails the run (the outcome the old inner-call rejection produced, reached by
    // proxy instead of by settling the inner call as an error).
    const result = run({
      compute: (_argument, context) => context.call("no.such.agent"),
    });
    await expect(result).rejects.toThrow();
  });

  test("a callee panic that proxies up tears down the handler's sibling inner call via the cascade", async () => {
    // The dead callee's cleanup rides the cancel cascade, not a special-cased terminate: when the panic
    // proxies up and fails the run, the ffi handler is terminated and `terminateChildren` unwinds its OTHER
    // in-flight inner call too — so a sibling child does not leak.
    let siblingUnwound = false;
    const result = run({
      compute: async (_argument, context) => {
        context.call("slow", null, { reactor: "ffi" }).catch(() => {
          siblingUnwound = true;
        });
        await context.call("no.such.agent"); // proxies up (uncatchable) → fails the run
        return "unreachable";
      },
      slow: () => new Promise((resolve) => setTimeout(() => resolve("late"), 100)),
    });
    await expect(result).rejects.toThrow();
    await waitUntil(() => (siblingUnwound ? true : undefined));
  });

  test("an ffi→ffi inner call runs a sibling handler through the same transport", async () => {
    const result = run({
      compute: async (_argument, context) => {
        const inner = await context.call("greet", { name: "world" }, { reactor: "ffi" });
        return `compute: ${String(inner)}`;
      },
      greet: (argument) => {
        const name =
          typeof argument === "object" && argument !== null && !Array.isArray(argument)
            ? String(argument.name)
            : "?";
        return `Hello, ${name}`;
      },
    });
    await expect(result).resolves.toEqual({ kind: "string", value: "compute: Hello, world" });
  });

  test("a callee's user-facing request is proxied to the run root and its answer descends back", async () => {
    const actor = makeActor({
      compute: async (_argument, context) => {
        const answer = await context.call("ask_value", {});
        return answer;
      },
    });
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The request escalated out of the callee, through the ffi call's proxy, past main, to the run root.
    const open = await waitUntil(() => {
      const list = actor.listOpenEscalations();
      return list.length > 0 ? list : undefined;
    });
    expect(open[0]?.request).toBe(createAgentName("ask_value"));

    const escalation = open[0]?.escalation;
    if (escalation === undefined) throw new Error("no open escalation");
    await actor.answerEscalation(escalation, { kind: "integer", value: 7 });
    // The answer descended the same proxy chain and resumed the callee, whose result reached the handler.
    await expect(result).resolves.toEqual({ kind: "integer", value: 7 });
    expect(actor.listOpenEscalations()).toHaveLength(0);
  });

  test("a completion with a fire-and-forget child still running is held until the child is cancelled", async () => {
    let childSettled = false;
    const result = run({
      compute: (_argument, context) => {
        // Fired but never awaited: the handler returns while this inner call is in flight. The runtime must
        // cancel the child and only then deliver the handler's result.
        void context.call("slow", null, { reactor: "ffi" }).catch(() => {});
        return "done";
      },
      slow: () =>
        new Promise((resolve) =>
          setTimeout(() => {
            childSettled = true;
            resolve("late");
          }, 30),
        ),
    });
    await expect(result).resolves.toEqual({ kind: "string", value: "done" });
    // The held completion waited for the child's teardown — the child settled before the run did.
    expect(childSettled).toBe(true);
  });

  test("an external result conforming to the declared output schema flows through", async () => {
    const actor = makeActor({ typed_compute: () => "hello" });
    const { result } = actor.startRun(createAgentName("typed_main"), SNAPSHOT, null);
    await expect(result).resolves.toEqual({ kind: "string", value: "hello" });
  });

  test("an external result that violates the declared output schema fails the run at the boundary", async () => {
    // `typed_compute` declares `-> string`, but the untyped handler returns an integer. The assumed-typing
    // contract is only a promise across the FFI boundary, so the runtime conforms the result and fails the
    // run with a panic naming the boundary — rather than letting a wrong-typed value corrupt a match later.
    const actor = makeActor({ typed_compute: () => 42 });
    const { result } = actor.startRun(createAgentName("typed_main"), SNAPSHOT, null);
    await expect(result).rejects.toThrow(/output schema/);
  });

  test("cancelling the run distributes the terminate through the call's inner delegations", async () => {
    let handlerUnwound = false;
    const actor = makeActor({
      compute: async (_argument, context) => {
        try {
          return await context.call("slow", null, { reactor: "ffi" });
        } catch (error) {
          handlerUnwound = true;
          throw error;
        }
      },
      slow: () => new Promise((resolve) => setTimeout(() => resolve("late"), 30)),
    });
    const { run: runDelegation, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    // Let the dispatch fan out to the inner call before cancelling.
    await new Promise((resolve) => setTimeout(resolve, 5));
    await actor.cancelRun(runDelegation, "user requested");

    await expect(result).rejects.toBeInstanceOf(RunCancelledError);
    await waitUntil(() => (handlerUnwound ? true : undefined));
  });
});
