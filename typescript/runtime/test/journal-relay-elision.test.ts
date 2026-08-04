// Journal relay elision (docs/2026-08-03-journal-relay-elision.md): an ask that nobody serves is re-raised
// at every instance it crosses, and every hop used to journal the whole payload again — 86 copies per model
// step on a real deployment. The engine now marks a hop that only re-raises someone else's escalation
// (`relayOf` on the escalate, `relayed` on its ack), and the journal — and ONLY the journal — drops those
// duplicate payloads. These tests drive hand-built IR through the ProjectActor over a StoringPersistence and
// assert the journaled stream directly, the same way `run-trace.test.ts` does.
//
// The invariants they pin: a payload is journaled exactly once, at its ORIGIN; elision fires only where the
// engine positively knows the payload exists elsewhere (so a served-and-re-performed request — the
// `with_context` / `with_breaker` middleware shape — starts a NEW origin, and a synthesized panic is an
// origin too); and the wire is untouched, which each test witnesses by the run producing an answer that only
// the full payload could have produced.

import {
  createAgentName,
  type IRModule,
  type QualifiedName,
  type SchemaInfo,
} from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { projectRunEvent } from "../src/modules/run/run-events.repository.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import type { Thread } from "../src/runtime/engine/types.js";
import type { JournalEvent } from "../src/runtime/event/types.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import {
  type FfiHandler,
  type FfiTransport,
  InProcessFfiTransport,
  StubFfiTransport,
} from "../src/runtime/external/runner.js";
import type { ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";

const PROJECT = "project-journal-elision" as ProjectId;
const SNAPSHOT = "snapshot-journal-elision" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };
const ASK = createAgentName("ask_value");
const NULL_VALUE = { kind: "null" };

function makeActor(
  ir: IRModule,
  persistence: StoringPersistence,
  external: FfiTransport = new StubFfiTransport(),
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

/** The journaled events of one kind, in production order. */
function eventsOfKind<K extends JournalEvent["kind"]>(
  events: JournalEvent[],
  kind: K,
): Array<Extract<JournalEvent, { kind: K }>> {
  return events.filter((event): event is Extract<JournalEvent, { kind: K }> => event.kind === kind);
}

/**
 * The chain: `raiser` (a request leaf — where the ask is born) is called by `middle` (which handles nothing),
 * and both sit under `main`'s `handle`. So the ask crosses two instance boundaries: it is born in the raiser
 * and relayed once by the middle. The top handler answers with the question it received, so the run's result
 * is the payload itself — the witness that the WIRE still carried it while the journal elided its copy.
 */
function chainIr(question: string): IRModule {
  return {
    metadata: { schemaVersion: 1 },
    blocks: {
      // main: handle { middle({}) } with ask_value(q) => q.question
      0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      1: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "call", target: 2, output: 10 },
            { kind: "exit", target: 0, value: 10 },
          ],
        },
        parameters: { parameter: 99 },
      },
      2: {
        block: {
          kind: "handle",
          parallel: false,
          initialStates: [],
          body: 3,
          handlers: [{ request: ASK, body: 4 }],
          thenClause: null,
        },
        parameters: {},
      },
      3: {
        block: {
          kind: "sequence",
          result: 31,
          operations: [
            { kind: "makeRecord", entries: [], output: 30 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("middle") },
              argument: 30,
              output: 31,
            },
          ],
        },
        parameters: {},
      },
      // The handler falls through to its tail, implicitly resuming the asker with the question it was asked.
      4: {
        block: {
          kind: "sequence",
          result: 41,
          operations: [{ kind: "getField", source: 40, field: "question", output: 41 }],
        },
        parameters: { parameter: 40 },
      },
      // middle: raiser({ question }) — no handler of its own, so the ask passes straight through.
      5: { block: { kind: "agent", body: 6, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      6: {
        block: {
          kind: "sequence",
          result: 63,
          operations: [
            { kind: "loadLiteral", output: 60, value: { kind: "string", value: question } },
            { kind: "makeRecord", entries: [["question", 60]], output: 61 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("raiser") },
              argument: 61,
              output: 63,
            },
          ],
        },
        parameters: { parameter: 69 },
      },
      // raiser: an agent whose whole body is the request leaf — the ask's origin.
      7: { block: { kind: "agent", body: 8, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      8: { block: { kind: "request", name: ASK, input: 80 }, parameters: { parameter: 80 } },
    },
    entries: {
      [createAgentName("main")]: { block: 0, private: false },
      [createAgentName("middle")]: { block: 5, private: false },
      [createAgentName("raiser")]: { block: 7, private: false },
    },
    names: {},
  };
}

describe("journal relay elision — a chain journals one copy of the payload", () => {
  test("the relay hop's escalate and the deeper ack are elided; the origin's pair keeps the payload", async () => {
    const question = "the whole conversation history";
    const persistence = new StoringPersistence();
    const actor = makeActor(chainIr(question), persistence);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The top handler answered with the `question` field of the argument it received, so the run's own result
    // proves the wire copy was untouched: an elided ask would have handed it a null.
    await expect(result).resolves.toEqual({ kind: "string", value: question });

    const journal = persistence.journalFor(run);
    const escalates = eventsOfKind(journal, "escalate");
    const acks = eventsOfKind(journal, "escalateAck");
    expect(escalates).toHaveLength(2);
    expect(acks).toHaveLength(2);

    const [origin, relay] = escalates;
    if (origin === undefined || relay === undefined) throw new Error("journal shape mismatch");
    // The origin: the ask was born in the raiser instance, so this is the one row holding its payload.
    expect(origin.relayOf).toBeUndefined();
    expect(origin.elided).toBeUndefined();
    expect(origin.ask).toEqual({
      kind: "request",
      request: ASK,
      argument: { kind: "record", fields: { question: { kind: "string", value: question } } },
    });
    // The relay hop: linked to the origin, its duplicate payload dropped, still classifiable as the same
    // request (which is what the events API's `kind` / `search` filters and the console group by).
    expect(relay.relayOf).toBe(origin.escalation);
    expect(relay.elided).toBe(true);
    expect(relay.ask).toEqual({ kind: "request", request: ASK, argument: NULL_VALUE });

    const [relayAck, originAck] = acks;
    if (relayAck === undefined || originAck === undefined) throw new Error("journal shape mismatch");
    // The answer descends the same path: the deeper hop's ack is a copy and elides, and the one the raiser
    // actually consumes — the origin escalate's — keeps its value.
    expect(relayAck.escalation).toBe(relay.escalation);
    expect(relayAck.elided).toBe(true);
    expect(relayAck.value).toEqual(NULL_VALUE);
    expect(originAck.escalation).toBe(origin.escalation);
    expect(originAck.elided).toBeUndefined();
    expect(originAck.value).toEqual({ kind: "string", value: question });
  });
});

describe("journal relay elision — serving a request and re-performing it starts a NEW origin", () => {
  test("a middle that handles the ask and performs a modified twin journals both escalates in full", async () => {
    // The `ai.with_context` / `ai.with_breaker` shape: `middle` HANDLES ask_value and, inside the handler,
    // performs it again with a rewritten question. Running user code between the two makes the second ask a
    // different question with different bytes — it is a new origin, NOT a relay of the first, and the journal
    // must keep both payloads. This is the common case working correctly, not an edge case to defend against.
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        // main: handle { middle({}) } with ask_value(q) => q.question — the top answers with what it was asked.
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "call", target: 2, output: 10 },
              { kind: "exit", target: 0, value: 10 },
            ],
          },
          parameters: { parameter: 99 },
        },
        2: {
          block: {
            kind: "handle",
            parallel: false,
            initialStates: [],
            body: 3,
            handlers: [{ request: ASK, body: 4 }],
            thenClause: null,
          },
          parameters: {},
        },
        3: {
          block: {
            kind: "sequence",
            result: 31,
            operations: [
              { kind: "makeRecord", entries: [], output: 30 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("middle") },
                argument: 30,
                output: 31,
              },
            ],
          },
          parameters: {},
        },
        4: {
          block: {
            kind: "sequence",
            result: 41,
            operations: [{ kind: "getField", source: 40, field: "question", output: 41 }],
          },
          parameters: { parameter: 40 },
        },
        // middle: handle { raiser({ question: "original" }) } with ask_value(q) => raiser({ question: "rephrased" })
        5: { block: { kind: "agent", body: 6, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        6: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "call", target: 7, output: 50 },
              { kind: "exit", target: 5, value: 50 },
            ],
          },
          parameters: { parameter: 69 },
        },
        7: {
          block: {
            kind: "handle",
            parallel: false,
            initialStates: [],
            body: 8,
            handlers: [{ request: ASK, body: 9 }],
            thenClause: null,
          },
          parameters: {},
        },
        8: {
          block: {
            kind: "sequence",
            result: 82,
            operations: [
              { kind: "loadLiteral", output: 80, value: { kind: "string", value: "original" } },
              { kind: "makeRecord", entries: [["question", 80]], output: 81 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("raiser") },
                argument: 81,
                output: 82,
              },
            ],
          },
          parameters: {},
        },
        // The handler's own request escapes past this handle (a rethrow, not a self-catch), carrying the
        // rewritten question upward; its tail value implicitly resumes the original asker.
        9: {
          block: {
            kind: "sequence",
            result: 94,
            operations: [
              { kind: "loadLiteral", output: 91, value: { kind: "string", value: "rephrased" } },
              { kind: "makeRecord", entries: [["question", 91]], output: 92 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("raiser") },
                argument: 92,
                output: 94,
              },
            ],
          },
          parameters: { parameter: 90 },
        },
        10: { block: { kind: "agent", body: 11, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        11: { block: { kind: "request", name: ASK, input: 110 }, parameters: { parameter: 110 } },
      },
      entries: {
        [createAgentName("main")]: { block: 0, private: false },
        [createAgentName("middle")]: { block: 5, private: false },
        [createAgentName("raiser")]: { block: 10, private: false },
      },
      names: {},
    };

    const persistence = new StoringPersistence();
    const actor = makeActor(ir, persistence);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    // The top answered the REPHRASED question, and that answer came back down through the original asker.
    await expect(result).resolves.toEqual({ kind: "string", value: "rephrased" });

    const escalates = eventsOfKind(persistence.journalFor(run), "escalate");
    expect(escalates).toHaveLength(3);
    const [first, second, third] = escalates;
    if (first === undefined || second === undefined || third === undefined) {
      throw new Error("journal shape mismatch");
    }
    // Both performs are origins: each carries its own payload, and the re-performed one is NOT linked to the
    // one it answered — it is a different question, so nothing else journals its bytes.
    expect(first.relayOf).toBeUndefined();
    expect(first.elided).toBeUndefined();
    expect(first.ask).toEqual({
      kind: "request",
      request: ASK,
      argument: { kind: "record", fields: { question: { kind: "string", value: "original" } } },
    });
    expect(second.relayOf).toBeUndefined();
    expect(second.elided).toBeUndefined();
    expect(second.ask).toEqual({
      kind: "request",
      request: ASK,
      argument: { kind: "record", fields: { question: { kind: "string", value: "rephrased" } } },
    });
    // Only the hop that carries the twin's payload out of `middle` unchanged is a relay.
    expect(third.relayOf).toBe(second.escalation);
    expect(third.elided).toBe(true);
  });
});

describe("journal relay elision — a synthesized panic is an origin", () => {
  test("a conform-failure panic relayed through an external proxy journals in full, with no dangling link", async () => {
    // `typed_compute` declares `-> string` but its handler returns an integer, so the core reactor synthesizes
    // a panic at the external proxy (no inbound escalate is behind it). The proxy's relays entry therefore
    // records no provenance, and the escape must journal the panic in full: this is the ONLY copy of it.
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "makeRecord", entries: [], output: 20 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("typed_compute") },
                argument: 20,
                output: 21,
              },
              { kind: "exit", target: 0, value: 21 },
            ],
          },
          parameters: { parameter: 11 },
        },
        6: {
          block: {
            kind: "agent",
            body: 7,
            schema: { input: {}, output: { type: "string" }, requests: [], genericBindings: {} },
            defaults: {},
          },
          parameters: {},
        },
        7: {
          block: { kind: "external", key: "typed_compute", input: 8, reactor: "ffi" },
          parameters: { parameter: 8 },
        },
      },
      entries: {
        [createAgentName("main")]: { block: 0, private: false },
        [createAgentName("typed_compute")]: { block: 6, private: false },
      },
      names: {},
    };

    const handlers: Record<string, FfiHandler> = { typed_compute: () => 42 };
    const persistence = new StoringPersistence();
    const actor = makeActor(ir, persistence, new InProcessFfiTransport(handlers));
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    await expect(result).rejects.toThrow(/output schema/);

    const escalates = eventsOfKind(persistence.journalFor(run), "escalate");
    const panics = escalates.filter(
      (event) => event.ask.kind === "request" && event.ask.request === "prelude.panic",
    );
    const origin = panics[0];
    if (origin === undefined) throw new Error("the panic never reached the journal");
    // The synthesized relay is an origin: no link, no elision, and the message is really there.
    expect(origin.relayOf).toBeUndefined();
    expect(origin.elided).toBeUndefined();
    expect(JSON.stringify(origin.ask)).toContain("output schema");
    // Every link the journal does carry resolves to a row in it — the chain is reconstructible end to end,
    // so no elided row points at a payload that was never journaled.
    const ids = new Set(escalates.map((event) => event.escalation));
    for (const event of escalates) {
      if (event.relayOf !== undefined) expect(ids.has(event.relayOf)).toBe(true);
    }
  });
});

describe("journal relay elision — state persisted before the elision still resumes", () => {
  test("a v0.1.6 relays entry (a bare escalation id) loads, answers, and journals its ack in full", async () => {
    // The elision gave a proxy's `relays` entry the ask's provenance, so the entry stopped being the bare
    // escalation id it was in v0.1.6. A runtime upgraded while asks were in flight reads those old entries
    // back, and before the codec normalized them the first ack of such an escalation read `inbound` off a
    // string — a TypeError the substrate classifies as a deterministic bug, failing the resumed run.
    // main → middle → raiser, with NOBODY handling `ask_value`: the ask reaches the run root and the run
    // suspends there with two proxy relays entries persisted, which is the state this test downgrades.
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: 11,
            operations: [
              { kind: "makeRecord", entries: [], output: 10 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("middle") },
                argument: 10,
                output: 11,
              },
            ],
          },
          parameters: { parameter: 19 },
        },
        2: { block: { kind: "agent", body: 3, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        3: {
          block: {
            kind: "sequence",
            result: 31,
            operations: [
              { kind: "makeRecord", entries: [], output: 30 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("raiser") },
                argument: 30,
                output: 31,
              },
            ],
          },
          parameters: { parameter: 39 },
        },
        4: { block: { kind: "agent", body: 5, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        5: { block: { kind: "request", name: ASK, input: 50 }, parameters: { parameter: 50 } },
      },
      entries: {
        [createAgentName("main")]: { block: 0, private: false },
        [createAgentName("middle")]: { block: 2, private: false },
        [createAgentName("raiser")]: { block: 4, private: false },
      },
      names: {},
    };

    const persistence = new StoringPersistence();
    const suspended = makeActor(ir, persistence);
    const { run } = suspended.startRun(createAgentName("main"), SNAPSHOT, null);
    await waitUntil(() => (suspended.listOpenEscalations().length > 0 ? true : undefined));

    // Rewrite every persisted proxy's relays entries into the v0.1.6 shape — the bare escalation id, with no
    // provenance beside it — which today's types no longer describe (hence the one cast).
    const downgraded: string[] = [];
    persistence.rewriteThreadPayloads((payload) => {
      if (payload.kind !== "delegate" && payload.kind !== "external") return payload;
      const relays: Record<number, string> = {};
      for (const key of Object.keys(payload.relays)) {
        const relay = payload.relays[Number(key)];
        if (relay === undefined) continue;
        downgraded.push(relay.escalation);
        relays[Number(key)] = relay.escalation;
      }
      return { ...payload, relays } as unknown as Thread;
    });
    expect(downgraded.length).toBeGreaterThan(0);

    // A fresh actor over those rows: the load widens each bare entry, and answering drives an ack through
    // every one of them.
    const recovered = makeActor(ir, persistence);
    await recovered.activate();
    const open = await waitUntil(() => {
      const list = recovered.listOpenEscalations();
      return list.length > 0 ? list : undefined;
    });
    const escalation = open[0]?.escalation;
    if (escalation === undefined) throw new Error("no recovered open escalation");
    await recovered.answerEscalation(escalation, { kind: "integer", value: 42 });

    // The run finishes on the answer rather than failing on the ack (`errorMessage` names the crash if it
    // ever comes back).
    const record = await waitUntil(() => {
      const row = persistence.peekRun(run);
      return row === undefined || row.state === "running" ? undefined : row;
    });
    expect(record.errorMessage).toBeNull();
    expect(record.state).toBe("done");
    expect(record.result).toEqual({ kind: "integer", value: 42 });

    // Each downgraded entry answered under the bare id the old row held, and journaled its value in full: a
    // normalized entry reads as a synthesized origin, so elision — which must be positively known — stays off.
    const acks = eventsOfKind(persistence.journalFor(run), "escalateAck");
    for (const id of downgraded) {
      const ack = acks.find((event) => event.escalation === id);
      if (ack === undefined) throw new Error(`no escalateAck for the relayed escalation ${id}`);
      expect(ack.relayed).toBeUndefined();
      expect(ack.value).toEqual({ kind: "integer", value: 42 });
    }
  });
});

describe("journal relay elision — an elided row still answers the trace's filters", () => {
  test("kind and the request name survive redaction; the duplicated payload does not", async () => {
    const question = "the whole conversation history";
    const persistence = new StoringPersistence();
    const actor = makeActor(chainIr(question), persistence);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    await expect(result).resolves.toEqual({ kind: "string", value: question });

    const escalates = eventsOfKind(persistence.journalFor(run), "escalate");
    const [origin, relay] = escalates;
    if (origin === undefined || relay === undefined) throw new Error("journal shape mismatch");
    expect(relay.elided).toBe(true);

    // The two predicates the events API narrows a trace page with, over the row as stored: `kind` reads
    // `event ->> 'kind'`, and `search` is an ILIKE over the whole event JSON rendered to text. Both still
    // match the elided row, so a reader filtering for this request's escalates keeps seeing every hop.
    expect(relay.kind).toBe("escalate");
    expect(JSON.stringify(relay)).toContain(ASK);
    // The read-side projection the console groups by is intact too.
    const view = projectRunEvent({ seq: 2, event: relay, createdAt: new Date() });
    expect(view.kind).toBe("escalate");
    expect(view.request).toBe(ASK);
    // And the point of the whole change: the duplicated payload is gone from the relay row, while the origin
    // row — the one place it is journaled — still holds it.
    expect(JSON.stringify(relay)).not.toContain(question);
    expect(JSON.stringify(origin)).toContain(question);
  });
});
