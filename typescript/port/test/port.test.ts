// The sidecar dispatch logic: dispatch → result / error, an unknown key → error, the abort handshake
// (signal the in-flight handler, unwind its pending inner calls, confirm `cancelled` once it settles), and
// the inner agent-call channel (`context.call` → a `delegate` message → its `delegateResult` settles the
// awaited promise). Plus `katari.agent` composing the `<module>.<name>` registration key from the bundler's
// ambient `globalThis.__katariModule`.

import type { Json } from "@katari-lang/types";
import { afterEach, describe, expect, test } from "vitest";
import {
  defaultSidecar,
  type HandlerContext,
  katari,
  KatariCallError,
  KatariCancelledError,
  Sidecar,
} from "../src/index.js";
import type { RuntimeMessage, SidecarMessage } from "../src/protocol.js";

/** Collect the messages a Sidecar emits for the messages driven through it. */
function collector() {
  const messages: SidecarMessage[] = [];
  return { messages, send: (message: SidecarMessage) => messages.push(message) };
}

const dispatch = (
  delegation: string,
  key: string,
  argument: Json | null = null,
): RuntimeMessage => ({
  kind: "dispatch",
  delegation,
  key,
  argument,
});

describe("Sidecar dispatch", () => {
  test("runs a handler against its decoded, type-assumed argument and replies with its result", async () => {
    const sidecar = new Sidecar();
    sidecar.register<{ name: string }>("ext.greet", ({ name }) => `Hello, ${name}`);
    const { messages, send } = collector();
    sidecar.handle(dispatch("d1", "ext.greet", { name: "world" }), send);
    await tick();
    expect(messages).toEqual([{ kind: "result", delegation: "d1", value: "Hello, world" }]);
  });

  test("replies with an error when the handler throws", async () => {
    const sidecar = new Sidecar();
    sidecar.register("ext.boom", () => {
      throw new Error("kaboom");
    });
    const { messages, send } = collector();
    sidecar.handle(dispatch("d1", "ext.boom"), send);
    await tick();
    expect(messages).toEqual([{ kind: "error", delegation: "d1", message: "kaboom" }]);
  });

  test("replies with an error for an unregistered key", () => {
    const sidecar = new Sidecar();
    const { messages, send } = collector();
    sidecar.handle(dispatch("d1", "ext.missing"), send);
    expect(messages).toEqual([
      { kind: "error", delegation: "d1", message: 'no FFI handler registered for "ext.missing"' },
    ]);
  });

  test("unescapes wire record keys on the way in and re-escapes them on the way out", async () => {
    const sidecar = new Sidecar();
    sidecar.register<{ $weird: string }>("ext.echo", (argument) => ({ $weird: argument.$weird }));
    const { messages, send } = collector();
    sidecar.handle(dispatch("d1", "ext.echo", { $$weird: "kept" }), send);
    await tick();
    expect(messages).toEqual([{ kind: "result", delegation: "d1", value: { $$weird: "kept" } }]);
  });

  test("aborts an in-flight handler and confirms cancelled once it settles", async () => {
    const sidecar = new Sidecar();
    let observedAbort = false;
    // A handler that resolves only when its signal aborts (a stand-in for a cancellable side effect).
    sidecar.register(
      "ext.slow",
      (_argument, { signal }) =>
        new Promise<string>((resolve) => {
          signal.addEventListener("abort", () => {
            observedAbort = true;
            resolve("late");
          });
        }),
    );
    const { messages, send } = collector();
    sidecar.handle(dispatch("d1", "ext.slow"), send);
    await tick();
    expect(messages).toEqual([]); // still running

    sidecar.handle({ kind: "abort", delegation: "d1" }, send);
    await tick();
    expect(observedAbort).toBe(true);
    // The handler resolved a value, but because it was aborted the reply is `cancelled`, not `result`.
    expect(messages).toEqual([{ kind: "cancelled", delegation: "d1" }]);
  });

  test("an abort for an unknown / finished call is a no-op (no reply)", () => {
    const sidecar = new Sidecar();
    const { messages, send } = collector();
    sidecar.handle({ kind: "abort", delegation: "ghost" }, send);
    expect(messages).toEqual([]);
  });

  test("a handler returning undefined replies with an explicit null value, not a dropped field", async () => {
    const sidecar = new Sidecar();
    // A handler that returns nothing must still produce a well-formed reply (a missing `value` decodes to
    // `undefined`, which crashes the value codec on the runtime side).
    sidecar.register("ext.void", () => undefined);
    const { messages, send } = collector();
    sidecar.handle(dispatch("d1", "ext.void"), send);
    await tick();
    expect(messages).toEqual([{ kind: "result", delegation: "d1", value: null }]);
  });

  test("a handler returning a non-encodable value fails only that call (no process crash)", async () => {
    const sidecar = new Sidecar();
    // A BigInt has no wire form; without the guard the throw escapes the unawaited promise chain and
    // crashes the whole sidecar. It must instead become an `error` reply for this one delegation.
    sidecar.register("ext.bigint", () => 10n);
    const { messages, send } = collector();
    sidecar.handle(dispatch("d1", "ext.bigint"), send);
    await tick();
    expect(messages.length).toBe(1);
    expect(messages[0]).toMatchObject({ kind: "error", delegation: "d1" });
  });

  test("a duplicate dispatch for an in-flight delegation is ignored (no map corruption)", async () => {
    const sidecar = new Sidecar();
    let resolveFirst: (value: string) => void = () => {};
    sidecar.register("ext.slow", () => new Promise<string>((resolve) => (resolveFirst = resolve)));
    sidecar.register("ext.other", () => "second");
    const { messages, send } = collector();
    sidecar.handle(dispatch("d1", "ext.slow"), send);
    await tick();
    // Same delegation id, different handler: must not overwrite the in-flight controller nor reply.
    sidecar.handle(dispatch("d1", "ext.other"), send);
    await tick();
    expect(messages).toEqual([]);
    // The original is still tracked and settles correctly under its own id.
    resolveFirst("first");
    await tick();
    expect(messages).toEqual([{ kind: "result", delegation: "d1", value: "first" }]);
  });

  test("a handler that throws after being aborted still confirms cancelled", async () => {
    const sidecar = new Sidecar();
    sidecar.register(
      "ext.failcancel",
      (_argument, { signal }) =>
        new Promise<string>((_resolve, reject) => {
          signal.addEventListener("abort", () => reject(new Error("cleanup failed")));
        }),
    );
    const { messages, send } = collector();
    sidecar.handle(dispatch("d1", "ext.failcancel"), send);
    await tick();
    sidecar.handle({ kind: "abort", delegation: "d1" }, send);
    await tick();
    expect(messages).toEqual([{ kind: "cancelled", delegation: "d1" }]);
  });
});

describe("context.call (the inner agent-call channel)", () => {
  test("emits a delegate message and resolves with the decoded delegateResult", async () => {
    const sidecar = new Sidecar();
    sidecar.register("ext.caller", async (_argument, context) => {
      const sum = await context.call<number>("main.add", { a: 1, b: 2 });
      return sum + 10;
    });
    const { messages, send } = collector();
    sidecar.handle(dispatch("d1", "ext.caller"), send);
    await tick();
    // The inner call went out; the handler is suspended on it.
    expect(messages).toMatchObject([
      { kind: "delegate", delegation: "d1", agent: "main.add", argument: { a: 1, b: 2 } },
    ]);
    const delegate = messages[0];
    if (delegate?.kind !== "delegate") throw new Error("expected a delegate message");
    sidecar.handle(
      {
        kind: "delegateResult",
        delegation: "d1",
        call: delegate.call,
        outcome: { kind: "result", value: 3 },
      },
      send,
    );
    await tick();
    expect(messages[1]).toEqual({ kind: "result", delegation: "d1", value: 13 });
  });

  test("carries an explicit reactor and defaults to none (core) otherwise", async () => {
    const sidecar = new Sidecar();
    sidecar.register("ext.caller", (_argument, context) => {
      void context.call("main.sibling", null, { reactor: "ffi" }).catch(() => {});
      void context.call("main.plain").catch(() => {});
      return "done";
    });
    const { messages, send } = collector();
    sidecar.handle(dispatch("d1", "ext.caller"), send);
    await tick();
    const delegates = messages.filter((message) => message.kind === "delegate");
    expect(delegates[0]).toMatchObject({ agent: "main.sibling", reactor: "ffi" });
    expect(delegates[1]).toMatchObject({ agent: "main.plain" });
    expect(delegates[1]).not.toHaveProperty("reactor");
  });

  test("rejects the awaiting handler with KatariCallError on an error outcome", async () => {
    const sidecar = new Sidecar();
    sidecar.register("ext.caller", async (_argument, context) => {
      try {
        await context.call("main.missing");
        return "unreachable";
      } catch (error) {
        return error instanceof KatariCallError ? `caught: ${error.message}` : "wrong error";
      }
    });
    const { messages, send } = collector();
    sidecar.handle(dispatch("d1", "ext.caller"), send);
    await tick();
    const delegate = messages[0];
    if (delegate?.kind !== "delegate") throw new Error("expected a delegate message");
    sidecar.handle(
      {
        kind: "delegateResult",
        delegation: "d1",
        call: delegate.call,
        outcome: { kind: "error", message: "no such agent" },
      },
      send,
    );
    await tick();
    expect(messages[1]).toEqual({ kind: "result", delegation: "d1", value: "caught: no such agent" });
  });

  test("an abort rejects pending inner calls with KatariCancelledError, so the handler unwinds", async () => {
    const sidecar = new Sidecar();
    let observed: unknown;
    sidecar.register("ext.caller", async (_argument, context) => {
      try {
        await context.call("main.slow");
      } catch (error) {
        observed = error;
        throw error;
      }
      return "unreachable";
    });
    const { messages, send } = collector();
    sidecar.handle(dispatch("d1", "ext.caller"), send);
    await tick();
    sidecar.handle({ kind: "abort", delegation: "d1" }, send);
    await tick();
    expect(observed).toBeInstanceOf(KatariCancelledError);
    // The unwound (aborted) handler confirms the cancel, not an error.
    expect(messages.filter((message) => message.kind !== "delegate")).toEqual([
      { kind: "cancelled", delegation: "d1" },
    ]);
  });

  test("a call issued after the abort rejects immediately", async () => {
    const sidecar = new Sidecar();
    let lateCall: Promise<unknown> | undefined;
    let capturedContext: HandlerContext | undefined;
    sidecar.register(
      "ext.caller",
      (_argument, context) =>
        new Promise<string>((resolve) => {
          capturedContext = context;
          context.signal.addEventListener("abort", () => {
            // Settle into the observed error immediately — the rejection is synchronous with the abort, and
            // an unobserved rejection would trip the test runner before the assertion below runs.
            lateCall = context.call("main.late").then(
              () => "resolved",
              (error: unknown) => error,
            );
            resolve("done");
          });
        }),
    );
    const { messages, send } = collector();
    sidecar.handle(dispatch("d1", "ext.caller"), send);
    await tick();
    sidecar.handle({ kind: "abort", delegation: "d1" }, send);
    await tick();
    expect(capturedContext?.signal.aborted).toBe(true);
    await expect(lateCall).resolves.toBeInstanceOf(KatariCancelledError);
    expect(messages.filter((message) => message.kind === "delegate")).toEqual([]);
  });

  test("a delegateResult landing after the handler settled is ignored (fire-and-forget call)", async () => {
    const sidecar = new Sidecar();
    sidecar.register("ext.caller", (_argument, context) => {
      // Fired but never awaited: the handler returns while the inner call is pending. The runtime holds the
      // outer result until the child is cancelled; this side just drops the late outcome.
      void context.call("main.forgotten").catch(() => {});
      return "done";
    });
    const { messages, send } = collector();
    sidecar.handle(dispatch("d1", "ext.caller"), send);
    await tick();
    const delegate = messages.find((message) => message.kind === "delegate");
    if (delegate?.kind !== "delegate") throw new Error("expected a delegate message");
    expect(messages.at(-1)).toEqual({ kind: "result", delegation: "d1", value: "done" });
    // The late (post-settle) outcome must not throw nor emit anything.
    sidecar.handle(
      {
        kind: "delegateResult",
        delegation: "d1",
        call: delegate.call,
        outcome: { kind: "cancelled" },
      },
      send,
    );
    await tick();
    expect(messages.filter((message) => message.kind !== "delegate")).toEqual([
      { kind: "result", delegation: "d1", value: "done" },
    ]);
  });
});

describe("katari.agent", () => {
  afterEach(() => {
    globalThis.__katariModule = undefined;
  });

  test("registers under <module>.<name> from the ambient module, with the argument type assumed", async () => {
    globalThis.__katariModule = "ext_agent";
    katari.agent<{ who: string }>("ping", ({ who }) => `pong ${who}`);
    const { messages, send } = collector();
    defaultSidecar.handle(dispatch("d1", "ext_agent.ping", { who: "you" }), send);
    await tick();
    expect(messages).toEqual([{ kind: "result", delegation: "d1", value: "pong you" }]);
  });

  test("throws when called outside a bundle (no ambient module)", () => {
    globalThis.__katariModule = undefined;
    expect(() => katari.agent("x", () => null)).toThrow(/__katariModule is unset/);
  });

  test("rejects a dotted name", () => {
    globalThis.__katariModule = "ext_agent";
    expect(() => katari.agent("a.b", () => null)).toThrow(/bare identifier/);
  });
});

/** Let queued microtasks (the handler's promise chain) run. */
function tick(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}
