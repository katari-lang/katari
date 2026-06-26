// The sidecar dispatch logic: dispatch → result / error, an unknown key → error, and the abort handshake
// (signal the in-flight handler, confirm `cancelled` once it settles). Plus `katari.agent` composing the
// `<package>.<name>` registration key from the bundler's ambient `globalThis.__katariModule`.

import type { Json } from "@katari-lang/types";
import { afterEach, describe, expect, test } from "vitest";
import { defaultSidecar, katari, Sidecar } from "../src/index.js";
import type { SidecarReply, SidecarRequest } from "../src/protocol.js";

/** Collect the replies a Sidecar emits for the requests driven through it. */
function collector() {
  const replies: SidecarReply[] = [];
  return { replies, send: (reply: SidecarReply) => replies.push(reply) };
}

const dispatch = (delegation: string, key: string, argument: Json | null = null): SidecarRequest => ({
  kind: "dispatch",
  delegation,
  key,
  argument,
  redispatch: false,
});

describe("Sidecar dispatch", () => {
  test("runs a handler and replies with its result (plain Json in, plain Json out)", async () => {
    const sidecar = new Sidecar();
    sidecar.register("ext.greet", (argument) => {
      const name =
        typeof argument === "object" && argument !== null && !Array.isArray(argument)
          ? argument.name
          : "stranger";
      return `Hello, ${String(name)}`;
    });
    const { replies, send } = collector();
    sidecar.handle(dispatch("d1", "ext.greet", { name: "world" }), send);
    await tick();
    expect(replies).toEqual([{ kind: "result", delegation: "d1", value: "Hello, world" }]);
  });

  test("replies with an error when the handler throws", async () => {
    const sidecar = new Sidecar();
    sidecar.register("ext.boom", () => {
      throw new Error("kaboom");
    });
    const { replies, send } = collector();
    sidecar.handle(dispatch("d1", "ext.boom"), send);
    await tick();
    expect(replies).toEqual([{ kind: "error", delegation: "d1", message: "kaboom" }]);
  });

  test("replies with an error for an unregistered key", () => {
    const sidecar = new Sidecar();
    const { replies, send } = collector();
    sidecar.handle(dispatch("d1", "ext.missing"), send);
    expect(replies).toEqual([
      { kind: "error", delegation: "d1", message: 'no FFI handler registered for "ext.missing"' },
    ]);
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
    const { replies, send } = collector();
    sidecar.handle(dispatch("d1", "ext.slow"), send);
    await tick();
    expect(replies).toEqual([]); // still running

    sidecar.handle({ kind: "abort", delegation: "d1" }, send);
    await tick();
    expect(observedAbort).toBe(true);
    // The handler resolved a value, but because it was aborted the reply is `cancelled`, not `result`.
    expect(replies).toEqual([{ kind: "cancelled", delegation: "d1" }]);
  });

  test("an abort for an unknown / finished call is a no-op (no reply)", () => {
    const sidecar = new Sidecar();
    const { replies, send } = collector();
    sidecar.handle({ kind: "abort", delegation: "ghost" }, send);
    expect(replies).toEqual([]);
  });

  test("a handler returning undefined replies with an explicit null value, not a dropped field", async () => {
    const sidecar = new Sidecar();
    // A handler that returns nothing is out of the `Json` contract, but the runtime must still receive a
    // well-formed reply (a missing `value` decodes to `undefined`, which crashes the value codec).
    sidecar.register("ext.void", () => undefined as unknown as Json);
    const { replies, send } = collector();
    sidecar.handle(dispatch("d1", "ext.void"), send);
    await tick();
    expect(replies).toEqual([{ kind: "result", delegation: "d1", value: null }]);
  });

  test("a handler returning a non-serialisable value fails only that call (no process crash)", async () => {
    const sidecar = new Sidecar();
    // A BigInt makes JSON.stringify throw; without the guard that throw escapes the unawaited promise chain
    // and crashes the whole sidecar. It must instead become an `error` reply for this one delegation.
    sidecar.register("ext.bigint", () => 10n as unknown as Json);
    const { replies, send } = collector();
    sidecar.handle(dispatch("d1", "ext.bigint"), send);
    await tick();
    expect(replies.length).toBe(1);
    expect(replies[0]).toMatchObject({ kind: "error", delegation: "d1" });
  });

  test("a duplicate dispatch for an in-flight delegation is ignored (no map corruption)", async () => {
    const sidecar = new Sidecar();
    let resolveFirst: (value: string) => void = () => {};
    sidecar.register("ext.slow", () => new Promise<string>((resolve) => (resolveFirst = resolve)));
    sidecar.register("ext.other", () => "second");
    const { replies, send } = collector();
    sidecar.handle(dispatch("d1", "ext.slow"), send);
    await tick();
    // Same delegation id, different handler: must not overwrite the in-flight controller nor reply.
    sidecar.handle(dispatch("d1", "ext.other"), send);
    await tick();
    expect(replies).toEqual([]);
    // The original is still tracked and settles correctly under its own id.
    resolveFirst("first");
    await tick();
    expect(replies).toEqual([{ kind: "result", delegation: "d1", value: "first" }]);
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
    const { replies, send } = collector();
    sidecar.handle(dispatch("d1", "ext.failcancel"), send);
    await tick();
    sidecar.handle({ kind: "abort", delegation: "d1" }, send);
    await tick();
    expect(replies).toEqual([{ kind: "cancelled", delegation: "d1" }]);
  });
});

describe("katari.agent", () => {
  afterEach(() => {
    globalThis.__katariModule = undefined;
  });

  test("registers under <package>.<name> from the ambient module", async () => {
    globalThis.__katariModule = "ext_agent";
    katari.agent("ping", () => "pong");
    const { replies, send } = collector();
    defaultSidecar.handle(dispatch("d1", "ext_agent.ping"), send);
    await tick();
    expect(replies).toEqual([{ kind: "result", delegation: "d1", value: "pong" }]);
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
