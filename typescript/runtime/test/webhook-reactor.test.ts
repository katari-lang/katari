// End-to-end tests for the `webhook` reactor, driven through the whole ProjectActor (no real HTTP server —
// deliveries enter through `actor.deliverWebhook`, exactly what the public route calls). A hand-built
// program calls `webhook.inbound(callback, subscriber)`; the reactor mints a token, dispatches the
// subscriber once with the URL, converts each delivery into a `call_agent` delegation of the callback
// (schema-validated at the acceptance surface), and settles the whole call with the subscriber's result.
//
// Covered: the delivery happy path; a schema-violating delivery (a typed `reflection.call_error`, the
// callback never runs); an unknown token; the endpoint deactivating when the subscriber settles; and the
// restart contract — the endpoint SURVIVES a restart (token + callback reload from `webhook_instances`,
// the subscriber resumes as durable core work), the piece that separates webhook from ffi / http.

import { createAgentName, type IRModule, type SchemaInfo } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { InMemoryPersistence, type Persistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import {
  type FfiHandler,
  InProcessFfiTransport,
  StubFfiTransport,
} from "../src/runtime/external/runner.js";
import type { ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-webhook" as ProjectId;
const SNAPSHOT = "snapshot-webhook" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

/** The callback's compiled signature — what a delivery's body is validated against. */
const ECHO_SCHEMA: SchemaInfo = {
  input: {
    type: "object",
    properties: { message: { type: "string" } },
    required: ["message"],
    additionalProperties: false,
  },
  output: { type: "string" },
  requests: [],
  genericBindings: {},
};

/**
 * agent echo(message: string) -> string { message }
 * agent main() { webhook.inbound(callback = echo, subscriber = <subscriber>) }
 * The subscriber variant is the test's knob:
 *   - "ffi":     agent subscriber(url) { subscribe(url = url) }   (an in-process FFI external the test
 *                holds open — the discord-watch shape);
 *   - "request": agent subscriber(url) { wait(url = url) }        (an unhandled user-facing request — an
 *                open escalation that survives a restart, the manual-registration shape).
 */
function webhookIr(subscriber: "ffi" | "request"): IRModule {
  return {
    metadata: { schemaVersion: 1 },
    blocks: {
      0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, description: "", defaults: {} }, parameters: {} },
      1: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "loadAgent", output: 11, name: createAgentName("echo") },
            { kind: "loadAgent", output: 12, name: createAgentName("subscriber") },
            {
              kind: "makeRecord",
              entries: [
                ["callback", 11],
                ["subscriber", 12],
              ],
              output: 13,
            },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("prelude.webhook.inbound") },
              argument: 13,
              output: 14,
            },
            { kind: "exit", target: 0, value: 14 },
          ],
        },
        parameters: { parameter: 10 },
      },
      // echo: the callback — returns its validated `message`.
      2: { block: { kind: "agent", body: 3, schema: ECHO_SCHEMA, description: "", defaults: {} }, parameters: {} },
      3: {
        block: {
          kind: "sequence",
          result: 21,
          operations: [{ kind: "getField", source: 20, field: "message", output: 21 }],
        },
        parameters: { parameter: 20 },
      },
      // webhook.inbound: the external leaf routed to the webhook reactor.
      4: { block: { kind: "agent", body: 5, schema: EMPTY_SCHEMA, description: "", defaults: {} }, parameters: {} },
      5: {
        block: { kind: "external", key: "inbound", input: 50, reactor: "webhook" },
        parameters: { parameter: 50 },
      },
      // subscriber: forwards the minted url to its blocking leg and returns that leg's result.
      6: { block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, description: "", defaults: {} }, parameters: {} },
      7: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "getField", source: 60, field: "url", output: 61 },
            { kind: "makeRecord", entries: [["url", 61]], output: 62 },
            {
              kind: "delegate",
              target: {
                kind: "name",
                name: createAgentName(subscriber === "ffi" ? "subscribe" : "wait"),
              },
              argument: 62,
              output: 63,
            },
            { kind: "exit", target: 6, value: 63 },
          ],
        },
        parameters: { parameter: 60 },
      },
      // subscribe: an FFI external the in-process transport serves (held open by the test).
      8: { block: { kind: "agent", body: 9, schema: EMPTY_SCHEMA, description: "", defaults: {} }, parameters: {} },
      9: {
        block: { kind: "external", key: "subscribe", input: 90, reactor: "ffi" },
        parameters: { parameter: 90 },
      },
      // wait: an unhandled request — escalates to the run root as an open (durable) question.
      10: { block: { kind: "agent", body: 11, schema: EMPTY_SCHEMA, description: "", defaults: {} }, parameters: {} },
      11: {
        block: { kind: "request", name: createAgentName("wait"), input: 110 },
        parameters: { parameter: 110 },
      },
    },
    entries: {
      [createAgentName("main")]: 0,
      [createAgentName("echo")]: 2,
      [createAgentName("prelude.webhook.inbound")]: 4,
      [createAgentName("subscriber")]: 6,
      [createAgentName("subscribe")]: 8,
      [createAgentName("wait")]: 10,
    },
    names: {},
  };
}

function actorFor(options: {
  subscriber: "ffi" | "request";
  handlers?: Record<string, FfiHandler>;
  persistence?: Persistence;
}): ProjectActor {
  const registry = new SnapshotRegistry();
  const module = webhookIr(options.subscriber);
  for (const name of Object.keys(module.entries)) {
    registry.set(SNAPSHOT, moduleOfName(createAgentName(name)), module);
  }
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims: new PrimRegistry(),
    blobs: new InMemoryBlobStore(),
    external:
      options.handlers !== undefined
        ? new InProcessFfiTransport(options.handlers)
        : new StubFfiTransport(),
    http: new StubHttpTransport(),
    persistence: options.persistence ?? new InMemoryPersistence(),
  });
}

/** Poll until `read` yields a value (the reactor turns are asynchronous, so the test observes, not steps). */
async function eventually<T>(read: () => T | undefined): Promise<T> {
  for (let attempt = 0; attempt < 400; attempt += 1) {
    const value = read();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error("condition not reached in time");
}

function bodyOf(fields: Record<string, Value>): Value {
  return { kind: "record", fields };
}

const HELLO = bodyOf({ message: { kind: "string", value: "hello" } });

describe("the webhook reactor (an ffi-held subscriber)", () => {
  test("mints a URL, serves deliveries against the callback's schema, and settles with the subscriber", async () => {
    let capturedUrl: string | undefined;
    let releaseSubscriber: (() => void) | undefined;
    const actor = actorFor({
      subscriber: "ffi",
      handlers: {
        subscribe: (argument) => {
          const url = argument !== null && typeof argument === "object" ? argument : {};
          capturedUrl = String((url as { url?: unknown }).url);
          return new Promise((resolve) => {
            releaseSubscriber = () => resolve("served");
          });
        },
      },
    });
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The subscriber received the minted URL: the endpoint is live.
    const url = await eventually(() => capturedUrl);
    expect(url).toMatch(/\/inbound\/[A-Za-z0-9_-]+$/);
    const token = url.split("/inbound/")[1] ?? "";

    // A conforming delivery invokes the callback; its result is the response.
    await expect(actor.deliverWebhook(token, HELLO)).resolves.toEqual({
      kind: "result",
      value: { kind: "string", value: "hello" },
    });

    // A violating delivery fails at the dynamic-dispatch boundary — a typed `reflection.call_error`,
    // the callback never runs, the endpoint stays live.
    const violation = await actor.deliverWebhook(
      token,
      bodyOf({ wrong: { kind: "integer", value: 1 } }),
    );
    expect(violation.kind).toBe("throw");
    if (violation.kind === "throw") {
      expect(violation.value.kind).toBe("record");
      if (violation.value.kind === "record") {
        expect(String(violation.value.ctor)).toBe("prelude.reflection.call_error");
      }
    }

    // A token nobody minted resolves `unknown`.
    await expect(actor.deliverWebhook("no-such-token", HELLO)).resolves.toEqual({
      kind: "unknown",
    });

    // The subscriber settles -> `inbound` returns its result and the endpoint deactivates.
    const release = await eventually(() => releaseSubscriber);
    release();
    await expect(result).resolves.toEqual({ kind: "string", value: "served" });
    await expect(actor.deliverWebhook(token, HELLO)).resolves.toEqual({ kind: "unknown" });
  });
});

describe("the webhook reactor (restart survival)", () => {
  test("the endpoint outlives a restart: the token reloads and the subscriber's open question persists", async () => {
    const persistence = new StoringPersistence();
    const first = actorFor({ subscriber: "request", persistence });
    const { run } = first.startRun(createAgentName("main"), SNAPSHOT, null);

    // The subscriber suspended on its unhandled `wait(url)` — the open escalation carries the URL.
    const escalation = await eventually(() => first.listOpenEscalations()[0]);
    const argument = escalation.argument;
    if (argument === null || argument.kind !== "record" || argument.fields.url?.kind !== "string") {
      throw new Error("the wait escalation does not carry the minted url");
    }
    const token = argument.fields.url.value.split("/inbound/")[1] ?? "";

    // Deliveries work while the subscriber waits.
    await expect(first.deliverWebhook(token, HELLO)).resolves.toEqual({
      kind: "result",
      value: { kind: "string", value: "hello" },
    });

    // Restart: a fresh actor over the same durable rows. The endpoint must still serve — the token and
    // callback reload from `webhook_instances`; nothing is re-dispatched.
    const second = actorFor({ subscriber: "request", persistence });
    await second.activate();
    await expect(second.deliverWebhook(token, HELLO)).resolves.toEqual({
      kind: "result",
      value: { kind: "string", value: "hello" },
    });

    // Answering the subscriber's question ends the subscription; the run completes with the answer and
    // the endpoint deactivates — durably (no webhook instance survives).
    const reloaded = await eventually(() => second.listOpenEscalations()[0]);
    await second.answerEscalation(reloaded.escalation, { kind: "string", value: "unsubscribed" });
    await eventually(() => (persistence.peekRun(run)?.state === "done" ? true : undefined));
    expect(persistence.peekRun(run)?.result).toEqual({ kind: "string", value: "unsubscribed" });
    await expect(second.deliverWebhook(token, HELLO)).resolves.toEqual({ kind: "unknown" });
    expect(persistence.envelopeCount("webhook")).toBe(0);
  });
});
