// The `oauth` reactor, driven through the whole ProjectActor: `oauth.token(name)` resolves a stored
// credential to a bearer token through the credentials core, settling with the token as a `string of
// private` value. The three outcomes of `resolveToken` are the three behaviours under test:
//   - `{ token }` — the run resolves with the token, PRIVATE-marked (redacts at every user-facing boundary,
//     exactly like `env.get_secret`);
//   - `{ needsAuthorize }` — the call PARKS on a `prelude.oauth.authorize` escalation carrying just the
//     credential `{ name }` (no url — a configured credential has no server to show); answering it re-reads
//     the store and resumes, still private-marked;
//   - a TRANSIENT resolution failure (the store read throws) — the call escalates a typed
//     `throw[oauth.server_error]` a katari-side handler catches.

import {
  createAgentName,
  type IRModule,
  type QualifiedName,
  type SchemaInfo,
} from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import type { PersistedOpenEscalation } from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import type { CredentialStore, StoredCredential } from "../src/runtime/external/credentials.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import { StubMcpTransport } from "../src/runtime/external/mcp-transport.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import type { ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import { valueToJson } from "../src/runtime/value/codec.js";

const PROJECT = "project-oauth-reactor" as ProjectId;
const SNAPSHOT = "snapshot-oauth-reactor" as SnapshotId;
const CREDENTIAL_NAME = "github";
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };
const THROW = createAgentName("prelude.throw");
const TOKEN = createAgentName("prelude.oauth.token");

/** A configured credential that is valid by clock (its access token is served without a refresh). */
const CREDENTIAL: StoredCredential = {
  profile: "configured",
  accessToken: "bearer-abc",
  refreshToken: null,
  expiresAt: Date.now() + 3_600_000,
  tokenEndpoint: "https://idp.example.test/token",
  scopes: ["read"],
  clientName: "github-client",
};

// agent main() { oauth.token(name = "github") }               — resolves and returns the token
// agent guarded() { handle { oauth.token(name = "github") } with throw(e) => break "caught" }
// agent prelude.oauth.token() -> external(reactor "oauth")     — the reactor entry
// agent prelude.throw() -> request(prelude.throw)              — the throw wrapper the handler needs
const OAUTH_IR: IRModule = {
  metadata: { schemaVersion: 1 },
  blocks: {
    0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
    1: {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "loadLiteral", output: 11, value: { kind: "string", value: CREDENTIAL_NAME } },
          { kind: "makeRecord", entries: [["name", 11]], output: 12 },
          { kind: "delegate", target: { kind: "name", name: TOKEN }, argument: 12, output: 13 },
          { kind: "exit", target: 0, value: 13 },
        ],
      },
      parameters: { parameter: 10 },
    },
    // prelude.oauth.token: the external agent whose body routes to the oauth reactor.
    2: { block: { kind: "agent", body: 3, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
    3: {
      block: { kind: "external", key: "prelude.oauth.token", input: 30, reactor: "oauth" },
      parameters: { parameter: 30 },
    },
    // guarded: a throw-handler around the same call, returning "caught" on a server_error.
    4: { block: { kind: "agent", body: 5, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
    5: {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "call", target: 6, output: 50 },
          { kind: "exit", target: 4, value: 50 },
        ],
      },
      parameters: { parameter: 59 },
    },
    6: {
      block: {
        kind: "handle",
        parallel: false,
        initialStates: [],
        body: 7,
        handlers: [{ request: THROW, body: 8 }],
        thenClause: null,
      },
      parameters: {},
    },
    7: {
      block: {
        kind: "sequence",
        result: 73,
        operations: [
          { kind: "loadLiteral", output: 70, value: { kind: "string", value: CREDENTIAL_NAME } },
          { kind: "makeRecord", entries: [["name", 70]], output: 71 },
          { kind: "delegate", target: { kind: "name", name: TOKEN }, argument: 71, output: 73 },
        ],
      },
      parameters: {},
    },
    8: {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "loadLiteral", output: 80, value: { kind: "string", value: "caught" } },
          { kind: "exit", target: 6, value: 80 },
        ],
      },
      parameters: { parameter: 81 },
    },
    // The prelude.throw wrapper the handler catches.
    20: { block: { kind: "agent", body: 21, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
    21: { block: { kind: "request", name: THROW, input: 70 }, parameters: { parameter: 70 } },
  },
  entries: {
    [createAgentName("main")]: { block: 0, private: false },
    [createAgentName("guarded")]: { block: 4, private: false },
    [TOKEN]: { block: 2, private: false },
    [THROW]: { block: 20, private: false },
  },
  names: {},
};

/** A one-credential store the reactor resolves through, with a switchable mode: `present` serves the
 *  credential, `absent` returns null (park), `throws` fails the load (a transient error), and `hangs`
 *  never settles the load (an in-flight resolution a crash interrupts). `loadCount` counts the reads, so
 *  a test can assert a reloaded PARKED call does NOT re-resolve on its own (it waits for the ack). */
function credentialStore(): CredentialStore & {
  mode: "present" | "absent" | "throws" | "hangs";
  loadCount: number;
} {
  const store: CredentialStore & {
    mode: "present" | "absent" | "throws" | "hangs";
    loadCount: number;
  } = {
    mode: "absent",
    loadCount: 0,
    async load(name) {
      store.loadCount += 1;
      if (store.mode === "hangs") return new Promise(() => {});
      if (store.mode === "throws") throw new Error("the credential store is unreachable");
      if (store.mode === "present" && name === CREDENTIAL_NAME) {
        return { credential: CREDENTIAL, generation: 1 };
      }
      return null;
    },
    async save() {
      return false;
    },
    async resolveConfiguredClient() {
      return null;
    },
  };
  return store;
}

function makeActor(store: CredentialStore, persistence = new StoringPersistence()): ProjectActor {
  const registry = new SnapshotRegistry();
  for (const name of Object.keys(OAUTH_IR.entries)) {
    registry.set(SNAPSHOT, moduleOfName(name as QualifiedName), OAUTH_IR);
  }
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims: new PrimRegistry(),
    blobs: new InMemoryBlobStore(),
    external: new StubFfiTransport(),
    http: new StubHttpTransport(),
    mcp: new StubMcpTransport(),
    credentials: store,
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

describe("oauth reactor: token resolution", () => {
  test("a resolvable credential settles the run with the token, private-marked", async () => {
    const store = credentialStore();
    store.mode = "present";
    const actor = makeActor(store);
    const result = await actor.startRun(createAgentName("main"), SNAPSHOT, null).result;

    // The resolved token is the credential's access token, and it is PRIVATE — it redacts at every
    // user-facing boundary (a run result, the trace), exactly like `env.get_secret`.
    expect(result).toEqual({ kind: "string", value: "bearer-abc", private: true });
    expect(valueToJson(result, "redact")).toEqual({ $katari_redacted: true });
    // Revealed toward a submission sink (an http Authorization header), the real token is present.
    expect(valueToJson(result, "reveal")).toBe("bearer-abc");
  });
});

describe("oauth reactor: the authorize park", () => {
  test("a missing credential parks on a name-only authorize escalation; the answered ack resumes private", async () => {
    const store = credentialStore();
    store.mode = "absent";
    const actor = makeActor(store);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The resolution finds no credential and parks: a user-facing escalation opens at the api root,
    // carrying the authorize request and the `{ name }` argument ONLY (no url — a configured credential
    // has no server URL to show; its presentation renders url null).
    const open = await waitUntil(() => actor.listOpenEscalations()[0]);
    expect(open.request).toBe("prelude.oauth.authorize");
    expect(open.argument).toEqual({
      kind: "record",
      fields: { name: { kind: "string", value: CREDENTIAL_NAME } },
    });

    // Deposit the credential (what the runtime-hosted flow does) and ack (the value is ignored): the retry
    // re-reads the store, resolves the token, and the run completes with it — still private-marked.
    store.mode = "present";
    await actor.answerEscalation(open.escalation, { kind: "null" });
    await expect(result).resolves.toEqual({ kind: "string", value: "bearer-abc", private: true });
    expect(actor.listOpenEscalations()).toHaveLength(0);
  });

  test("an ack over a still-missing credential re-escalates with a fresh escalation (the one loop)", async () => {
    const store = credentialStore();
    store.mode = "absent";
    const actor = makeActor(store);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    void result.catch(() => {});

    const first = await waitUntil(() => actor.listOpenEscalations()[0]);
    // Answer WITHOUT depositing: the retry re-resolves, still finds nothing, and parks again — a fresh
    // escalation, not an error, not a hang on the answered one.
    await actor.answerEscalation(first.escalation, { kind: "null" });
    const second = await waitUntil(() => {
      const open = actor.listOpenEscalations()[0];
      return open !== undefined && open.escalation !== first.escalation ? open : undefined;
    });
    expect(second.request).toBe("prelude.oauth.authorize");
    expect(actor.listOpenEscalations()).toHaveLength(1);

    // The loop exits the moment an ack finds usable material.
    store.mode = "present";
    await actor.answerEscalation(second.escalation, { kind: "null" });
    await expect(result).resolves.toEqual({ kind: "string", value: "bearer-abc", private: true });
  });
});

describe("oauth reactor: transient failures", () => {
  test("a transient resolution failure escalates a typed server_error a handler catches", async () => {
    const store = credentialStore();
    store.mode = "throws";
    const actor = makeActor(store);
    // The `guarded` entry wraps the call in a `prelude.throw` handler returning "caught": the transient
    // store failure surfaces as `throw[oauth.server_error]`, which the handler catches and recovers from.
    const result = await actor.startRun(createAgentName("guarded"), SNAPSHOT, null).result;
    expect(result).toEqual({ kind: "string", value: "caught" });
  });

  test("an unhandled transient failure fails the run (the throw is not swallowed)", async () => {
    const store = credentialStore();
    store.mode = "throws";
    const persistence = new StoringPersistence();
    const actor = makeActor(store, persistence);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    // `main` has no handler, so the typed throw fails the run — its result rejects with the payload, and
    // the run lands in the terminal `error` state carrying the `oauth.server_error` constructor.
    await expect(result).rejects.toThrow(/prelude\.oauth\.server_error/);
    expect(persistence.peekRun(run)?.state).toBe("error");
  });
});

// ─── recovery ───────────────────────────────────────────────────────────────────────────────────────

/** The DURABLE authorize rows the oauth reactor holds open (raiser-owned `escalations`, `from = oauth`) —
 *  the park state's source of truth, read back through the loader exactly as a reactivation would. */
async function durableOauthEscalations(
  persistence: StoringPersistence,
): Promise<PersistedOpenEscalation[]> {
  let rows: PersistedOpenEscalation[] = [];
  await persistence.load(PROJECT, async (loader) => {
    rows = await loader.base.raisedEscalations("oauth");
  });
  return rows;
}

/** The durable oauth-kind call rows — how many token calls a reload would reconstruct. */
async function durableOauthCalls(persistence: StoringPersistence): Promise<number> {
  let count = 0;
  await persistence.load(PROJECT, async (loader) => {
    count = (await loader.external.instances("oauth")).length;
  });
  return count;
}

async function waitUntilAsync<T>(predicate: () => Promise<T | undefined>): Promise<T> {
  for (let attempt = 0; attempt < 1000; attempt++) {
    const value = await predicate();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error("waitUntilAsync: predicate never held");
}

describe("oauth reactor: recovery", () => {
  test("a parked token call survives reload whole, and the post-reload ack re-resolves", async () => {
    const store = credentialStore();
    store.mode = "absent";
    const persistence = new StoringPersistence();
    const actor = makeActor(store, persistence);
    const { run } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const open = await waitUntil(() => actor.listOpenEscalations()[0]);
    // Wait for the whole relay chain to be durable (the oauth reactor's row and the answerable one).
    await waitUntilAsync(async () => (await durableOauthEscalations(persistence))[0]);
    const loadsBeforeReload = store.loadCount;

    // Restart: a fresh actor over the same rows, the store STILL empty. The open authorize row IS the
    // durable park state (`reconstructPark`), so the reloaded call waits for the ack — it must NOT
    // re-resolve on its own (the store is not re-read) and the run keeps running.
    const reloaded = makeActor(store, persistence);
    await reloaded.activate();
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(store.loadCount).toBe(loadsBeforeReload);
    expect(persistence.peekRun(run)?.state).toBe("running");
    // The answerable escalation survived the restart (rebuilt from its durable row), same identity and
    // the same name-only argument.
    const reloadedOpen = await waitUntil(() => reloaded.listOpenEscalations()[0]);
    expect(reloadedOpen.escalation).toBe(open.escalation);
    expect(reloadedOpen.argument).toEqual({
      kind: "record",
      fields: { name: { kind: "string", value: CREDENTIAL_NAME } },
    });

    // Deposit + ack on the RELOADED actor: the retry re-reads the store from scratch and the run
    // completes with the private-marked token — the park survived the restart end to end.
    store.mode = "present";
    await reloaded.answerEscalation(reloadedOpen.escalation, { kind: "null" });
    await waitUntil(() => (persistence.peekRun(run)?.state === "done" ? true : undefined));
    expect(persistence.peekRun(run)?.result).toEqual({
      kind: "string",
      value: "bearer-abc",
      private: true,
    });
  });

  test("an in-flight (non-parked) token call re-resolves across a restart — at-most-once-safe", async () => {
    // A resolution is a read plus an idempotent, immediately-persisted refresh, so — unlike http / mcp
    // transport calls — a reloaded RUNNING call re-resolves from the current store (`recover`), the
    // time.now shape, rather than being refused as an interrupted at-most-once attempt.
    const store = credentialStore();
    store.mode = "hangs";
    const persistence = new StoringPersistence();
    const actor = makeActor(store, persistence);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    void result.catch(() => {});

    // The call is dispatched (its resolution hangs mid-flight) and its row is durable — the crash point.
    await waitUntilAsync(async () =>
      (await durableOauthCalls(persistence)) === 1 ? true : undefined,
    );
    expect(actor.listOpenEscalations()).toHaveLength(0);

    // Restart with the store now serving the credential: the reloaded running call re-resolves and the
    // run completes — no park, no refusal, and still private-marked.
    store.mode = "present";
    const reloaded = makeActor(store, persistence);
    await reloaded.activate();
    await waitUntil(() => (persistence.peekRun(run)?.state === "done" ? true : undefined));
    expect(persistence.peekRun(run)?.result).toEqual({
      kind: "string",
      value: "bearer-abc",
      private: true,
    });
  });
});
