// The mcp reactor's authorize park/retry loop, driven through the whole ProjectActor with a controlled
// store-gated transport (no real MCP server): an oauth operation whose transport reports
// `authorizationRequired` does not settle — the reactor raises a genuine `prelude.mcp.authorize`
// escalation from the call's own instance (a DURABLE row, relayed to the api root like any user request)
// and parks. Answering the escalation (the value is ignored) re-runs the parked operation from scratch;
// the transport re-reads the credential store, so a deposit-then-ack succeeds while an ack over an
// still-empty store simply parks again with a fresh escalation — the one unbounded loop that covers
// first authorization, refresh death, empty answers, and every race. Recovery: the open escalation row
// plus (for a transport call) the extension's `parked` dispatch variant ARE the park state — a reload
// reconstructs the parked call whole (never refusing it through the at-most-once transport
// reconciliation, which stays the fate of a genuinely IN-FLIGHT interrupted call), and a post-reload ack
// re-runs identically to a warm one: a provide re-lists from its ext row, a tool call re-dispatches the
// same tool and arguments. Re-running is safe because the parked attempt was REJECTED with a 401 — the
// server provably never executed it.

import {
  createAgentName,
  type IRModule,
  type QualifiedName,
  type SchemaInfo,
} from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import {
  type PersistedOpenEscalation,
  type Persistence,
} from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import type {
  McpCredentialStore,
  McpOAuthCredential,
} from "../src/runtime/external/mcp-oauth.js";
import type {
  McpCall,
  McpCompletion,
  McpTransport,
} from "../src/runtime/external/mcp-transport.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import type { DelegationId, ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";

const PROJECT = "project-mcp-authorize" as ProjectId;
const SNAPSHOT = "snapshot-mcp-authorize" as SnapshotId;
const SERVER_URL = "https://mcp.example.test/mcp";
const CREDENTIAL_NAME = "github";
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

const CREDENTIAL: McpOAuthCredential = {
  tokens: { access_token: "token-123", token_type: "Bearer" },
  clientInformation: { client_id: "client-123" },
  resourceUrl: SERVER_URL,
};

// agent main() {
//   mcp.provide(url = "https://mcp.example.test/mcp", auth = mcp.oauth(name = "github"),
//               continuation = continuation)
// }
// agent continuation(value) {   // dispatched with { value: toolbox } once the listing lands
//   return reflection.call_agent(target = value.value.add, args = { x: 19, y: 23 })
// }
const OAUTH_PROVIDE_IR: IRModule = {
  metadata: { schemaVersion: 1 },
  blocks: {
    0: {
      block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    1: {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "loadLiteral", output: 11, value: { kind: "string", value: SERVER_URL } },
          { kind: "loadLiteral", output: 12, value: { kind: "string", value: CREDENTIAL_NAME } },
          { kind: "makeRecord", entries: [["name", 12]], output: 13 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.mcp.oauth") },
            argument: 13,
            output: 14,
          },
          { kind: "loadAgent", output: 15, name: createAgentName("continuation") },
          {
            kind: "makeRecord",
            entries: [
              ["url", 11],
              ["auth", 14],
              ["continuation", 15],
            ],
            output: 16,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.mcp.provide") },
            argument: 16,
            output: 17,
          },
          { kind: "exit", target: 0, value: 17 },
        ],
      },
      parameters: { parameter: 10 },
    },
    2: {
      block: { kind: "agent", body: 3, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    3: {
      block: { kind: "external", key: "prelude.mcp.provide", input: 30, reactor: "mcp" },
      parameters: { parameter: 30 },
    },
    4: {
      block: { kind: "agent", body: 5, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    5: {
      block: { kind: "construct", name: createAgentName("prelude.mcp.oauth"), input: 50 },
      parameters: { parameter: 50 },
    },
    // continuation: receives { value: toolbox } and calls the minted `add` through call_agent.
    6: {
      block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    7: {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "getField", source: 60, field: "value", output: 61 },
          { kind: "getField", source: 61, field: "add", output: 62 },
          { kind: "loadLiteral", output: 63, value: { kind: "integer", value: 19 } },
          { kind: "loadLiteral", output: 64, value: { kind: "integer", value: 23 } },
          {
            kind: "makeRecord",
            entries: [
              ["x", 63],
              ["y", 64],
            ],
            output: 65,
          },
          {
            kind: "makeRecord",
            entries: [
              ["target", 62],
              ["args", 65],
            ],
            output: 66,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.reflection.call_agent") },
            argument: 66,
            output: 67,
          },
          { kind: "exit", target: 6, value: 67 },
        ],
      },
      parameters: { parameter: 60 },
    },
  },
  entries: {
    [createAgentName("main")]: 0,
    [createAgentName("prelude.mcp.provide")]: 2,
    [createAgentName("prelude.mcp.oauth")]: 4,
    [createAgentName("continuation")]: 6,
  },
  names: {},
};

/** The listing completion the transport feeds once the store holds a credential. */
const ADD_LISTING: McpCompletion["outcome"] = {
  kind: "result",
  value: {
    tools: [
      {
        name: "add",
        description: "Adds two integers.",
        inputSchema: {
          type: "object",
          properties: { x: { type: "number" }, y: { type: "number" } },
          required: ["x", "y"],
        },
        outputSchema: { type: "string" },
      },
    ],
  },
};

/** A one-credential in-memory store the gated transport reads through — `seed` plays the runtime-hosted
 *  authorization flow's deposit, `clear` a deletion. `save` is unused here (the reactor never writes;
 *  refresh write-back is the provider's business, tested in mcp-oauth.test.ts). */
function credentialStore(): McpCredentialStore & { seed: () => void; clear: () => void } {
  let entry: { credential: McpOAuthCredential; generation: number } | null = null;
  return {
    async load(name) {
      return name === CREDENTIAL_NAME ? entry : null;
    },
    async save() {
      return false;
    },
    seed() {
      entry = { credential: CREDENTIAL, generation: 1 };
    },
    clear() {
      entry = null;
    },
  };
}

/** The url a dispatched call's descriptor names — what the real transport stamps the park signal with. */
function descriptorUrlOf(call: McpCall): string {
  const descriptor = call.descriptor;
  if (descriptor !== null && typeof descriptor === "object" && !Array.isArray(descriptor)) {
    const url = descriptor.url;
    if (typeof url === "string") return url;
  }
  throw new Error("test transport: the dispatched call carries no { url } descriptor");
}

/** A hand-driven transport that mimics the real one's oauth classification: a GATED operation checks the
 *  credential store and completes as the `authorizationRequired` park signal while the credential is
 *  absent; present (or ungated), it succeeds — a listing with the `add` listing, a tool call with "42".
 *  Which operations are gated selects the park site under test (the provide's listing, or a minted
 *  tool's call). Recovery refuses with the typed restart throw, exactly like the real transport. */
class AuthGatedMcpTransport implements McpTransport {
  readonly dispatched: McpCall[] = [];
  readonly recovered: DelegationId[] = [];
  private sink: ((completion: McpCompletion) => void) | null = null;

  constructor(
    private readonly store: McpCredentialStore,
    private readonly gated: { listing: boolean; tools: boolean },
  ) {}

  onComplete(sink: (completion: McpCompletion) => void): void {
    this.sink = sink;
  }

  dispatch(call: McpCall): void {
    this.dispatched.push(call);
    void this.performGated(call);
  }

  private async performGated(call: McpCall): Promise<void> {
    const gated = call.kind === "listTools" ? this.gated.listing : this.gated.tools;
    if (gated && (await this.store.load(CREDENTIAL_NAME)) === null) {
      this.feed({
        delegation: call.delegation,
        outcome: {
          kind: "authorizationRequired",
          url: descriptorUrlOf(call),
          name: CREDENTIAL_NAME,
        },
      });
      return;
    }
    this.feed({
      delegation: call.delegation,
      outcome: call.kind === "listTools" ? ADD_LISTING : { kind: "result", value: "42" },
    });
  }

  recover(delegation: DelegationId): void {
    this.recovered.push(delegation);
    this.feed({
      delegation,
      outcome: {
        kind: "throw",
        error: {
          $constructor: "prelude.mcp.server_error",
          value: { message: "mcp call interrupted by a runtime restart" },
        },
      },
    });
  }

  abort(delegation: DelegationId): void {
    this.feed({ delegation, outcome: { kind: "cancelled" } });
  }

  evict(): void {}

  close(): void {
    this.sink = null;
  }

  private feed(completion: McpCompletion): void {
    if (this.sink === null) throw new Error("AuthGatedMcpTransport: no sink registered");
    this.sink(completion);
  }
}

function makeActor(
  mcp: McpTransport,
  persistence: Persistence = new StoringPersistence(),
  ir: IRModule = OAUTH_PROVIDE_IR,
): ProjectActor {
  const registry = new SnapshotRegistry();
  for (const name of Object.keys(ir.entries)) {
    registry.set(SNAPSHOT, moduleOfName(name as QualifiedName), ir);
  }
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims: new PrimRegistry(),
    blobs: new InMemoryBlobStore(),
    external: new StubFfiTransport(),
    http: new StubHttpTransport(),
    mcp,
    persistence,
  });
}

/** `OAUTH_PROVIDE_IR` with the continuation TYPED: output `{ done: boolean }` (closed), returning
 *  `{ done: true }` AFTER the mid-body tool call. The companion of the mid-body conform regression test
 *  (mcp-reactor.test.ts): the park/ack retry must behave identically under a constraining caller
 *  schema — the retried tool's intermediate result is not the caller's result. */
function typedContinuationIr(): IRModule {
  const clone: IRModule = structuredClone(OAUTH_PROVIDE_IR);
  const continuationAgent = clone.blocks[6]?.block;
  if (continuationAgent?.kind !== "agent") {
    throw new Error("block 6 must be the continuation agent");
  }
  continuationAgent.schema = {
    input: {},
    output: {
      type: "object",
      properties: { done: { type: "boolean" } },
      required: ["done"],
      additionalProperties: false,
    },
    requests: [],
    genericBindings: {},
  };
  const body = clone.blocks[7]?.block;
  if (body?.kind !== "sequence") throw new Error("block 7 must be the continuation sequence");
  const exit = body.operations.pop();
  if (exit?.kind !== "exit") throw new Error("the continuation must end with an exit");
  body.operations.push(
    { kind: "loadLiteral", output: 68, value: { kind: "boolean", value: true } },
    { kind: "makeRecord", entries: [["done", 68]], output: 69 },
    { kind: "exit", target: 6, value: 69 },
  );
  return clone;
}

async function waitUntil<T>(predicate: () => T | undefined): Promise<T> {
  for (let attempt = 0; attempt < 1000; attempt++) {
    const value = predicate();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error("waitUntil: predicate never held");
}

async function waitUntilAsync<T>(predicate: () => Promise<T | undefined>): Promise<T> {
  for (let attempt = 0; attempt < 1000; attempt++) {
    const value = await predicate();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error("waitUntilAsync: predicate never held");
}

/** The DURABLE authorize rows the mcp reactor holds open (raiser-owned `escalations`, `from = mcp`) —
 *  the park state's source of truth, read back through the loader exactly as a reactivation would. */
async function durableMcpEscalations(
  persistence: StoringPersistence,
): Promise<PersistedOpenEscalation[]> {
  let rows: PersistedOpenEscalation[] = [];
  await persistence.load(PROJECT, async (loader) => {
    rows = await loader.base.raisedEscalations("mcp");
  });
  return rows;
}

/** The expected `{ url, name }` argument Value an authorize escalation carries. */
const AUTHORIZE_ARGUMENT = {
  kind: "record",
  fields: {
    url: { kind: "string", value: SERVER_URL },
    name: { kind: "string", value: CREDENTIAL_NAME },
  },
};

describe("mcp authorize escalation: the park/retry loop", () => {
  test("a listing that cannot authenticate parks: the authorize escalation opens durably, and the answered ack re-reads the store and succeeds", async () => {
    const store = credentialStore();
    const persistence = new StoringPersistence();
    const transport = new AuthGatedMcpTransport(store, { listing: true, tools: false });
    const actor = makeActor(transport, persistence);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The provide's listing dispatches, cannot authenticate (empty store), and parks: a user-facing
    // escalation opens at the api root, carrying the request name and the `{ url, name }` argument.
    const listing = await waitUntil(() => transport.dispatched[0]);
    expect(listing.kind).toBe("listTools");
    const open = await waitUntil(() => actor.listOpenEscalations()[0]);
    expect(open.request).toBe("prelude.mcp.authorize");
    expect(open.argument).toEqual(AUTHORIZE_ARGUMENT);

    // The park state is DURABLE: the mcp reactor holds the open escalation row (what a reload rebuilds
    // the park from), same request and argument.
    const durable = await waitUntilAsync(async () => (await durableMcpEscalations(persistence))[0]);
    expect(durable.request).toBe("prelude.mcp.authorize");
    expect(durable.argument).toEqual(AUTHORIZE_ARGUMENT);

    // Deposit the credential (what the runtime-hosted flow's callback does), then ack with null — the
    // value is ignored; the retry re-reads the store, so the re-run listing now succeeds and the run
    // completes through the minted tool.
    store.seed();
    await actor.answerEscalation(open.escalation, { kind: "null" });
    const retried = await waitUntil(() => transport.dispatched[1]);
    expect(retried.kind).toBe("listTools");
    await expect(result).resolves.toEqual({ kind: "string", value: "42" });
    expect(actor.listOpenEscalations()).toHaveLength(0);
    await expect(durableMcpEscalations(persistence)).resolves.toHaveLength(0);
  });

  test("an ack over a still-empty store re-escalates with a fresh escalation — the one unbounded loop", async () => {
    const store = credentialStore();
    const transport = new AuthGatedMcpTransport(store, { listing: true, tools: false });
    const actor = makeActor(transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const first = await waitUntil(() => actor.listOpenEscalations()[0]);
    // Answer WITHOUT depositing anything: the retry re-runs the listing, finds the store still empty,
    // and parks again — a fresh escalation, not an error, not a hang on the answered one.
    await actor.answerEscalation(first.escalation, { kind: "null" });
    await waitUntil(() => transport.dispatched[1]);
    const second = await waitUntil(() => {
      const open = actor.listOpenEscalations()[0];
      return open !== undefined && open.escalation !== first.escalation ? open : undefined;
    });
    expect(second.request).toBe("prelude.mcp.authorize");
    expect(actor.listOpenEscalations()).toHaveLength(1);

    // The loop exits the moment an ack finds usable material.
    store.seed();
    await actor.answerEscalation(second.escalation, { kind: "null" });
    await expect(result).resolves.toEqual({ kind: "string", value: "42" });
  });

  test("a minted tool's call parks and the answered retry re-runs the SAME call (tool and argument preserved)", async () => {
    const store = credentialStore();
    const transport = new AuthGatedMcpTransport(store, { listing: false, tools: true });
    const actor = makeActor(transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The ungated listing succeeds at once; the continuation's minted tool call then parks.
    const toolCall = await waitUntil(() => transport.dispatched[1]);
    if (toolCall.kind !== "callTool") throw new Error("expected a callTool dispatch");
    expect(toolCall.tool).toBe("add");
    expect(toolCall.argument).toEqual({ x: 19, y: 23 });
    const open = await waitUntil(() => actor.listOpenEscalations()[0]);
    expect(open.request).toBe("prelude.mcp.authorize");

    store.seed();
    await actor.answerEscalation(open.escalation, { kind: "null" });
    // The retry re-runs the parked call from scratch — same tool, same argument, same delegation
    // (the call was never settled, only parked).
    const retried = await waitUntil(() => transport.dispatched[2]);
    if (retried.kind !== "callTool") throw new Error("expected the retried callTool dispatch");
    expect(retried.tool).toBe("add");
    expect(retried.argument).toEqual({ x: 19, y: 23 });
    expect(retried.delegation).toBe(toolCall.delegation);
    await expect(result).resolves.toEqual({ kind: "string", value: "42" });
  });

  test("the park/ack retry behaves identically under a TYPED caller (no mid-body conform of the retried result)", async () => {
    const store = credentialStore();
    const transport = new AuthGatedMcpTransport(store, { listing: false, tools: true });
    const actor = makeActor(transport, new StoringPersistence(), typedContinuationIr());
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // Park at the tool call, deposit, ack: the retried tool result ("42", a string) violates the
    // continuation's own `{ done: boolean }` output schema and must not be checked against it — the
    // caller's schema binds what the caller returns, which still conforms below.
    await waitUntil(() => (transport.dispatched[1]?.kind === "callTool" ? true : undefined));
    const open = await waitUntil(() => actor.listOpenEscalations()[0]);
    store.seed();
    await actor.answerEscalation(open.escalation, { kind: "null" });
    await expect(result).resolves.toEqual({
      kind: "record",
      fields: { done: { kind: "boolean", value: true } },
    });
  });

  test("cancelling a run while parked tears down cleanly: the escalation goes with the instance", async () => {
    const store = credentialStore();
    const persistence = new StoringPersistence();
    const transport = new AuthGatedMcpTransport(store, { listing: true, tools: false });
    const actor = makeActor(transport, persistence);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    void result.catch(() => {});

    await waitUntil(() => actor.listOpenEscalations()[0]);
    await actor.cancelRun(run, "operator gave up on the authorization");
    await waitUntil(() =>
      persistence.peekRun(run)?.state === "cancelled" ? true : undefined,
    );
    // Both faces of the park are gone: the answerable entry and the durable raiser-owned row (the
    // latter cascades with the dropped mcp call instance).
    expect(actor.listOpenEscalations()).toHaveLength(0);
    await waitUntilAsync(async () =>
      (await durableMcpEscalations(persistence)).length === 0 ? true : undefined,
    );
  });
});

describe("mcp authorize escalation: recovery", () => {
  test("a reload with an open authorize escalation reconstructs the park, and the ack re-runs the listing (never refused)", async () => {
    const store = credentialStore();
    const persistence = new StoringPersistence();
    const first = new AuthGatedMcpTransport(store, { listing: true, tools: false });
    const actor = makeActor(first, persistence);
    const { run } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const open = await waitUntil(() => actor.listOpenEscalations()[0]);
    // Wait for the whole relay chain to be durable (the mcp row and the api-root answerable row).
    await waitUntilAsync(async () => (await durableMcpEscalations(persistence))[0]);

    // Restart: a fresh actor over the same rows, the store STILL empty — proving the parked provide is
    // reconstructed as parked (no re-list, no at-most-once refusal, the run keeps running).
    const second = new AuthGatedMcpTransport(store, { listing: true, tools: false });
    const reloaded = makeActor(second, persistence);
    await reloaded.activate();
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(second.dispatched).toHaveLength(0);
    expect(second.recovered).toHaveLength(0);
    expect(persistence.peekRun(run)?.state).toBe("running");
    // The answerable escalation survived the restart (rebuilt from its durable row), same identity.
    const reloadedOpen = await waitUntil(() => reloaded.listOpenEscalations()[0]);
    expect(reloadedOpen.escalation).toBe(open.escalation);
    expect(reloadedOpen.argument).toEqual(AUTHORIZE_ARGUMENT);

    // Deposit + ack on the RELOADED actor: the parked listing re-runs from scratch and the run
    // completes — the park survived the restart end to end.
    store.seed();
    await reloaded.answerEscalation(reloadedOpen.escalation, { kind: "null" });
    const retried = await waitUntil(() => second.dispatched[0]);
    expect(retried.kind).toBe("listTools");
    await waitUntil(() => (persistence.peekRun(run)?.state === "done" ? true : undefined));
    expect(persistence.peekRun(run)?.result).toEqual({ kind: "string", value: "42" });
  });

  test("a parked TOOL call survives reload whole, and the ack re-runs the SAME tool and arguments", async () => {
    const store = credentialStore();
    const persistence = new StoringPersistence();
    const first = new AuthGatedMcpTransport(store, { listing: false, tools: true });
    const actor = makeActor(first, persistence);
    const { run } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const toolCall = await waitUntil(() => first.dispatched[1]);
    if (toolCall.kind !== "callTool") throw new Error("expected a callTool dispatch");
    const open = await waitUntil(() => actor.listOpenEscalations()[0]);
    await waitUntilAsync(async () => (await durableMcpEscalations(persistence))[0]);

    const second = new AuthGatedMcpTransport(store, { listing: false, tools: true });
    const reloaded = makeActor(second, persistence);
    await reloaded.activate();
    await new Promise((resolve) => setTimeout(resolve, 20));
    // The park held: the tool call was NOT handed to the transport reconciliation (which would refuse
    // it with the restart throw immediately, orphaning the open escalation), and nothing re-ran on its
    // own — the re-run belongs to the ack.
    expect(second.recovered).toHaveLength(0);
    expect(second.dispatched).toHaveLength(0);
    expect(persistence.peekRun(run)?.state).toBe("running");

    // Deposit + ack on the RELOADED actor: the parked dispatch survived the restart (the extension's
    // `parked` variant — a 401-rejected attempt provably never executed, so re-running is
    // at-most-once-safe), and the retry re-runs the SAME call — tool, arguments, and delegation all
    // identical to the pre-restart attempt — exactly like a warm ack.
    store.seed();
    await reloaded.answerEscalation(open.escalation, { kind: "null" });
    const retried = await waitUntil(() => second.dispatched[0]);
    if (retried.kind !== "callTool") throw new Error("expected the retried callTool dispatch");
    expect(retried.tool).toBe(toolCall.tool);
    expect(retried.argument).toEqual({ x: 19, y: 23 });
    expect(retried.delegation).toBe(toolCall.delegation);
    await waitUntil(() => (persistence.peekRun(run)?.state === "done" ? true : undefined));
    expect(persistence.peekRun(run)?.result).toEqual({ kind: "string", value: "42" });
  });
});
