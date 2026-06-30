// The api root as the built-in http port: a `fetch` request that bubbles unhandled to the run root is
// performed by the api root itself (not surfaced to the user), and its response answers the escalation. Also
// checks the boundary rules — a secret header is REVEALED to the request, and the response is PUBLIC.

import { createAgentName } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { ApiReactor, type CommandSink } from "../src/runtime/actor/api-reactor.js";
import { ResourcePool } from "../src/runtime/actor/resource-pool.js";
import { HTTP_FETCH_REQUEST } from "../src/runtime/engine/common.js";
import { createProjectStore } from "../src/runtime/engine/store.js";
import type { ExternalEvent } from "../src/runtime/event/types.js";
import type { HttpCall, HttpTransport } from "../src/runtime/external/http-transport.js";
import {
  apiRootIdOf,
  type DelegationId,
  type EscalationId,
  type ProjectId,
  type SnapshotId,
} from "../src/runtime/ids.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-api-fetch" as ProjectId;
const SNAPSHOT = "snapshot-1" as SnapshotId;
const ESCALATION = "escalation-1" as EscalationId;

/** A transport that records what it was asked to do (so a test can inspect the revealed request). */
class CapturingHttpTransport implements HttpTransport {
  readonly dispatched: HttpCall[] = [];
  readonly aborted: string[] = [];
  onComplete(): void {}
  dispatch(call: HttpCall): void {
    this.dispatched.push(call);
  }
  abort(id: string): void {
    this.aborted.push(id);
  }
}

/** A command sink that runs its thunk synchronously, so a test can `startRun` and observe the result now. */
const SYNC_COMMANDS: CommandSink = {
  enqueue: (thunk) => {
    void thunk();
    return Promise.resolve();
  },
};

/** A `fetch` request argument with a secret auth header (private) plus public url / method / body. */
function fetchArgument(): Value {
  return {
    kind: "record",
    fields: {
      url: { kind: "string", value: "https://api.example.com/v1" },
      method: { kind: "string", value: "POST" },
      headers: {
        kind: "record",
        fields: { Authorization: { kind: "string", value: "Bearer sk-secret", private: true } },
      },
      body: { kind: "string", value: "{}" },
    },
  };
}

/** Build an api reactor and start a run on it, returning the reactor and the (live) run delegation a fetch
 *  raised inside that run escalates under. */
function startedRun(transport: HttpTransport): { api: ApiReactor; run: DelegationId } {
  const pool = new ResourcePool(PROJECT, createProjectStore());
  const api = new ApiReactor(apiRootIdOf(PROJECT), SYNC_COMMANDS, transport, pool);
  const { run } = api.startRun(createAgentName("main"), SNAPSHOT, null, "main");
  api.drainSends(); // discard the run's launch `delegate`
  return { api, run };
}

function fetchEscalate(run: DelegationId): ExternalEvent {
  return {
    kind: "escalate",
    delegation: run,
    escalation: ESCALATION,
    ask: { kind: "request", request: HTTP_FETCH_REQUEST, argument: fetchArgument() },
    from: "core",
    to: "api",
  };
}

describe("api root as the http port", () => {
  test("performs a fetch reaching the root and answers it with the public { status, body }", () => {
    const transport = new CapturingHttpTransport();
    const { api, run } = startedRun(transport);

    api.react(fetchEscalate(run));
    // A fetch is not a user-answerable escalation — it is auto-performed, so it never enters the open list.
    expect(api.listOpenEscalations()).toHaveLength(0);
    // It is dispatched only post-commit, with the secret header REVEALED to the transport.
    expect(api.drainSends()).toHaveLength(0);
    api.afterCommit(fetchEscalate(run));
    expect(transport.dispatched).toHaveLength(1);
    expect(transport.dispatched[0]?.argument).toMatchObject({
      headers: { Authorization: "Bearer sk-secret" },
    });

    api.completeFetch({
      id: ESCALATION,
      outcome: { kind: "result", value: { status: 404, body: "not found" } },
    });
    const sends = api.drainSends();
    expect(sends).toHaveLength(1);
    const ack = sends[0];
    expect(ack?.kind).toBe("escalateAck");
    if (ack?.kind !== "escalateAck") throw new Error("expected an escalateAck");
    // A non-2xx is data, not an error; the answer is the value, and it is PUBLIC (no private marker) even
    // though the request carried a secret header.
    expect(ack.value).toEqual({
      kind: "record",
      fields: {
        status: { kind: "integer", value: 404 },
        body: { kind: "string", value: "not found" },
      },
    });
    expect(ack.value.private).toBeUndefined();
  });

  test("a no-response error fails the run (terminates its root)", () => {
    const { api, run } = startedRun(new CapturingHttpTransport());
    api.react(fetchEscalate(run));
    api.afterCommit(fetchEscalate(run));

    api.completeFetch({
      id: ESCALATION,
      outcome: { kind: "error", message: "getaddrinfo ENOTFOUND" },
    });
    const sends = api.drainSends();
    expect(sends).toHaveLength(1);
    expect(sends[0]?.kind).toBe("terminate");
    expect(sends[0]?.delegation).toBe(run);
  });
});
