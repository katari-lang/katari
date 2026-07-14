// The uniform-escalation contract, end to end (docs/2026-07-14-uniform-escalation-rows.md): EVERY escalate
// opens a durable raiser-owned row — a failure (panic / throw), a control escape, and a user-facing request
// alike — and the base draws no distinction; the classification lives only at the leaf that raises and the
// handler that resolves. The CRUX these tests pin is leak-freedom: on EVERY failure-resolution path — a
// run-failing panic, a CAUGHT throw, and an in-flight-failure recovery — no escalation row survives once the
// failure is resolved. Every failure row has a MORTAL raiser (an instance in the run subtree, never the
// permanent run instance — a run-start pre-birth failure is rejected at the boundary), so the run teardown
// CASCADES every one of them; there is no explicit retire. They also pin the audit (a resolved failure
// records question + a null answer) and the §5 read filter (a failure `to = api` row never enters the
// answerable set).

import {
  createAgentName,
  type IRModule,
  type Operation,
  type QualifiedName,
  type SchemaInfo,
} from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { TransientError } from "../src/runtime/actor/failure.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import {
  type FfiCompletion,
  type FfiTransport,
  StubFfiTransport,
} from "../src/runtime/external/runner.js";
import {
  type DelegationId,
  newDelegationId,
  newEscalationId,
  newInstanceId,
  type ProjectId,
  type SnapshotId,
} from "../src/runtime/ids.js";
import type { IrSource } from "../src/runtime/ir.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";

const PROJECT = "project-escalation-uniform" as ProjectId;
const SNAPSHOT = "snapshot-escalation-uniform" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };
const THROW = createAgentName("prelude.throw");

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

/** An FFI transport that dispatches (recording the key) but never completes — the durable suspend point of
 *  a mid-run in-flight external call. A fresh instance models a fresh process, so `recover` refuses
 *  at-most-once with a no-result error (the runtime never re-runs external work), which the reactor turns
 *  into a panic. */
function recordingRunner(): { runner: FfiTransport; dispatched: string[] } {
  const dispatched: string[] = [];
  let sink: ((completion: FfiCompletion) => void) | null = null;
  const runner: FfiTransport = {
    onComplete(register) {
      sink = register;
    },
    onDelegate() {},
    dispatch(call) {
      dispatched.push(call.key); // never completes — the durable suspend point
    },
    recover(delegation: DelegationId) {
      sink?.({
        delegation,
        outcome: { kind: "error", message: "interrupted by a runtime restart (at-most-once)" },
      });
    },
    abort() {},
    deliverDelegateResult() {},
    close() {},
  };
  return { runner, dispatched };
}

async function waitUntil<T>(predicate: () => T | undefined): Promise<T> {
  for (let attempt = 0; attempt < 1000; attempt++) {
    const value = predicate();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error("waitUntil: predicate never held");
}

/** The `prelude.throw` wrapper pair a compiled raise delegates to (its agent entry + the request leaf). */
function throwWrapper(agentId: number, leafId: number, inputVar: number) {
  return {
    [agentId]: {
      block: { kind: "agent", body: leafId, schema: EMPTY_SCHEMA, defaults: {} },
      parameters: {},
    },
    [leafId]: {
      block: { kind: "request", name: THROW, input: inputVar },
      parameters: { parameter: inputVar },
    },
  } as const;
}

/** `{ error: { message } }` raise operations: build the payload record and delegate to `prelude.throw`. */
function raiseOperations(message: string, base: number, output: number): Operation[] {
  return [
    { kind: "loadLiteral", output: base, value: { kind: "string", value: message } },
    { kind: "makeRecord", entries: [["message", base]], output: base + 1 },
    { kind: "makeRecord", entries: [["error", base + 1]], output: base + 2 },
    { kind: "delegate", target: { kind: "name", name: THROW }, argument: base + 2, output },
  ];
}

describe("uniform escalation — leak-freedom on a run-failing panic", () => {
  test("a multi-hop panic fails the run, and EVERY escalation row cascades away (top + intermediates)", async () => {
    // agent main() { helper({}) }
    // agent helper() { prelude.add({ left: 1, right: "x" }) }   — the add prim panics (a string is not a
    // number). The panic escalates prelude.add -> helper -> main -> the run root, opening a raiser-owned row
    // at each hop (three rows: the add instance, helper, main). Unhandled, it fails the run: there is NO
    // explicit retire — the run teardown terminates the whole subtree, and each row CASCADES with its mortal
    // raiser (the add / helper / main core instances, none of them the permanent run instance). None survive.
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
                target: { kind: "name", name: createAgentName("helper") },
                argument: 20,
                output: 21,
              },
              { kind: "exit", target: 0, value: 21 },
            ],
          },
          parameters: { parameter: 11 },
        },
        2: { block: { kind: "agent", body: 3, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        3: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 30, value: { kind: "integer", value: 1 } },
              { kind: "loadLiteral", output: 31, value: { kind: "string", value: "x" } },
              {
                kind: "makeRecord",
                entries: [
                  ["left", 30],
                  ["right", 31],
                ],
                output: 32,
              },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("prelude.add") },
                argument: 32,
                output: 33,
              },
              { kind: "exit", target: 2, value: 33 },
            ],
          },
          parameters: { parameter: 12 },
        },
        4: { block: { kind: "agent", body: 5, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        5: {
          block: { kind: "primitive", name: "prelude.add", input: 50 },
          parameters: { parameter: 50 },
        },
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("helper")]: 2,
        [createAgentName("prelude.add")]: 4,
      },
      names: {},
    };

    const persistence = new StoringPersistence();
    const actor = makeActor(ir, persistence);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    await expect(result).rejects.toThrow(/panic.*number/);
    // Full quiescence: the run root and its whole subtree tore down.
    await waitUntil(() => (persistence.instanceCount() === 0 ? true : undefined));
    // The run is durably failed with the panic message.
    const record = persistence.peekRun(run);
    expect(record?.state).toBe("error");
    expect(record?.errorMessage).toMatch(/panic.*number/);
    // The CRUX: not one escalation row leaked — every row (top and intermediates alike) cascaded with its
    // mortal raiser when the run subtree tore down. No api-explicit retire is involved.
    expect(persistence.escalationCount()).toBe(0);
    // The failure is recorded in the run's history (the audit is the complete log of resolved escalations):
    // a failed escalation carries its question and a null answer.
    const audits = persistence.auditsFor(run);
    expect(audits).toHaveLength(1);
    expect(audits[0]?.answer).toBeNull();
    // The api never mistook the failure for an answerable request.
    expect(actor.listOpenEscalations()).toHaveLength(0);
  });
});

describe("uniform escalation — leak-freedom on a CAUGHT throw", () => {
  test("a sub-agent's throw caught by a parent `handle throw` tears down the raiser subtree; its rows cascade", async () => {
    // agent main() { handle { sub({}) } with throw(e) => break -1 }
    // agent sub() { throw({ message: "boom" }) }
    // sub raises a throw (via the `prelude.throw` wrapper), so TWO raiser-owned rows open: the wrapper
    // instance's and sub's. main's `handle throw` catches it and breaks — a throw answers with `never`, so it
    // is non-resumable; catching it cancels the handle body, which terminates the sub-call, tearing the whole
    // raiser subtree (sub + the wrapper) down. Both rows must cascade with those instances — a caught failure
    // leaks nothing. The run completes normally with the recovery value (no api failure, no audit).
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
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
            handlers: [{ request: THROW, body: 4 }],
            thenClause: null,
          },
          parameters: {},
        },
        // handle body: sub({}) — a delegate to the throwing sub-agent
        3: {
          block: {
            kind: "sequence",
            result: 31,
            operations: [
              { kind: "makeRecord", entries: [], output: 30 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("sub") },
                argument: 30,
                output: 31,
              },
            ],
          },
          parameters: {},
        },
        // handler body: break -1
        4: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 40, value: { kind: "integer", value: -1 } },
              { kind: "exit", target: 2, value: 40 },
            ],
          },
          parameters: { parameter: 41 },
        },
        // sub(): raise throw({ message: "boom" })
        5: { block: { kind: "agent", body: 6, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        6: {
          block: {
            kind: "sequence",
            result: 63,
            operations: [...raiseOperations("boom", 60, 63)],
          },
          parameters: { parameter: 69 },
        },
        ...throwWrapper(7, 8, 80),
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("sub")]: 5,
        [THROW]: 7,
      },
      names: {},
    };

    const persistence = new StoringPersistence();
    const actor = makeActor(ir, persistence);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The handle catches the throw and breaks with the recovery value.
    await expect(result).resolves.toEqual({ kind: "integer", value: -1 });
    // The caught raiser subtree (sub + the throw wrapper) tore down entirely.
    await waitUntil(() => (persistence.instanceCount() === 0 ? true : undefined));
    // The CRUX for the catch path: both raiser-owned rows cascaded with the torn-down raiser subtree —
    // nothing leaked, even though the api never saw the throw (it was caught below the run root).
    expect(persistence.escalationCount()).toBe(0);
    // A caught throw is not a run failure, so it records no audit row.
    expect(persistence.auditsFor(run)).toHaveLength(0);
    // The run completed normally.
    expect(persistence.peekRun(run)?.state).toBe("done");
  });
});

describe("uniform escalation — run-start boundary rejection", () => {
  test("an unresolvable entry agent is rejected at the run-start boundary (no run, no core escalation)", async () => {
    // The run-start API resolves the entry agent up front (`conformRunArgument`, what the facade turns into a
    // 400). An unresolvable entry is REJECTED here rather than launched — so a run's own root delegate never
    // reaches core's acceptance surface unresolved, where its raiser would be the PERMANENT run instance (the
    // run's result container, which must never own an ephemeral escalation row). Nothing is created.
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: 2,
            operations: [{ kind: "loadLiteral", output: 2, value: { kind: "integer", value: 0 } }],
          },
          parameters: { parameter: 11 },
        },
      },
      entries: { [createAgentName("main")]: 0 }, // only `main` exists — `missing.agent` does not
      names: {},
    };
    const persistence = new StoringPersistence();
    const actor = makeActor(ir, persistence);

    const rejection = await actor.conformRunArgument(
      createAgentName("missing.agent"),
      SNAPSHOT,
      null,
    );
    expect(rejection).toMatch(/missing\.agent.*cannot be resolved/);
    // The boundary rejected it before anything started: no run, no instance, no escalation row.
    expect(persistence.escalationCount()).toBe(0);
    expect(persistence.instanceCount()).toBe(0);
    // A resolvable entry passes the same check (null = safe to launch).
    await expect(actor.conformRunArgument(createAgentName("main"), SNAPSHOT, null)).resolves.toBeNull();
  });

  test("a TRANSIENT IR-load blip at run-start is surfaced as retryable — the run is NOT launched (no wedge)", async () => {
    // A transient IR-store read blip during validation must NOT defer-and-launch: launching an UNVALIDATED
    // run would let a deterministic pre-birth failure at core wedge it forever (its raiser being the
    // permanent run instance, whose loud throw drops the delegate). So `conformRunArgument` RETHROWS the
    // transient (the facade maps it to a 503) rather than returning `null` — nothing is launched, and a
    // retry is safe because no durable run was created.
    const persistence = new StoringPersistence();
    // An IR source whose `preload` always fails transiently (the run-start validation preloads the entry's
    // snapshot first) — modelling a DB read blip. Its other methods are never reached before that throw.
    const transientIr: IrSource = {
      async preload() {
        throw new TransientError("transient IR-store read blip at run-start");
      },
      access() {
        throw new Error("unreachable — validation failed at preload");
      },
      locate() {
        throw new Error("unreachable — validation failed at preload");
      },
    };
    const actor = new ProjectActor({
      projectId: PROJECT,
      ir: transientIr,
      prims: new PrimRegistry(),
      blobs: new InMemoryBlobStore(),
      external: new StubFfiTransport(),
      http: new StubHttpTransport(),
      persistence,
    });

    // The transient is surfaced (rethrown), NOT swallowed into a `null` that would launch the run.
    await expect(
      actor.conformRunArgument(createAgentName("main"), SNAPSHOT, null),
    ).rejects.toBeInstanceOf(TransientError);
    // The whole point: no run was launched, so nothing is wedged — a fresh retry starts clean.
    expect(persistence.instanceCount()).toBe(0);
    expect(persistence.escalationCount()).toBe(0);
  });
});

describe("uniform escalation — the twin witnesses the immediate raiser FK (the gap the e2e caught)", () => {
  test("StoringPersistence rejects an escalation whose raiser envelope is absent — exactly as Postgres does", async () => {
    // The bug the uniform-escalation wave shipped: EVERY escalate now opens a durable raiser-owned row, and a
    // FAILURE raiser (a caught throw's / an unhandled panic's instance) is born AND dropped inside one commit
    // batch — so its envelope is never persisted (`markInstanceDropped` supersedes the birth upsert), yet the
    // row carries the `escalations.raiser_instance_id` FK. That FK is IMMEDIATE (non-deferrable, unlike
    // `delegations.caller_instance_id`), so real Postgres rejects the insert at statement time and the whole
    // turn's tx rolls back — a 500. The in-memory twin USED TO accept the dangling insert silently (a lenient
    // Map), which is exactly why 378 unit tests were green while the e2e returned a 500. The twin now enforces
    // the same FK, so a dangling insert throws here just as it does in the DB.
    const persistence = new StoringPersistence();
    const raiser = newInstanceId();
    const run = newInstanceId();
    const row = {
      escalation: newEscalationId(),
      raiser,
      fromReactor: "core",
      toReactor: "core",
      delegation: newDelegationId(),
      run,
      request: "prelude.throw",
      argument: null,
    } as const;

    // No envelope for `raiser` — the dangling insert must be rejected (the FK witness the twin lacked).
    await expect(
      persistence.transaction(PROJECT, async (tx) => {
        await tx.base.putEscalation(row);
      }),
    ).rejects.toThrow(/raiser_instance_id FK/);
    expect(persistence.escalationCount()).toBe(0);

    // With the raiser envelope written first (a live raiser, as a well-formed commit always orders it — the
    // base flushes envelopes before escalations), the identical insert succeeds and the row is durable.
    await persistence.transaction(PROJECT, async (tx) => {
      await tx.base.putInstanceEnvelope({
        id: raiser,
        kind: "core",
        delegationId: row.delegation,
        callerReactor: "api",
        runId: run,
        status: "running",
      });
      await tx.base.putEscalation(row);
    });
    expect(persistence.escalationCount()).toBe(1);
  });
});

describe("uniform escalation — recovery of an in-flight failure (cascade, no explicit retire)", () => {
  test("a mid-run in-flight external failure recovers, fails the run, and its failure row is gone via cascade", async () => {
    // agent main() { compute({}) } — compute is an ffi external that never completes in the first actor (a
    // durable mid-run suspend: the run is `running`, the call in flight). A fresh actor (a fresh process)
    // reactivates and refuses the call at-most-once: the failure escalates as a panic RAISED BY THE MORTAL
    // ffi call instance, bubbles to the run root (opening a row at each mortal hop), and — unhandled — fails
    // the run. The failure rows are retired NOT by any explicit api delete (removed) but by CASCADE: the
    // mortal ffi call instance and the run-root core instance drop on teardown, taking their raised rows with
    // them. So a recovered failure leaves no row behind, exactly like the warm multi-hop panic path.
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
                target: { kind: "name", name: createAgentName("compute") },
                argument: 20,
                output: 21,
              },
              { kind: "exit", target: 0, value: 21 },
            ],
          },
          parameters: { parameter: 11 },
        },
        6: { block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        7: {
          block: { kind: "external", key: "compute", input: 8, reactor: "ffi" },
          parameters: { parameter: 8 },
        },
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("compute")]: 6,
      },
      names: {},
    };

    const persistence = new StoringPersistence();

    // First actor: compute dispatches and hangs (never completes) — the durable in-flight suspend point.
    const first = recordingRunner();
    const actorOne = makeActor(ir, persistence, first.runner);
    const { run } = actorOne.startRun(createAgentName("main"), SNAPSHOT, null);
    await waitUntil(() => (first.dispatched.includes("compute") ? true : undefined));
    // The run is durably still running, with the in-flight ffi call.
    expect(persistence.peekRun(run)?.state).toBe("running");
    await waitUntil(() => (persistence.envelopeCount("ffi") >= 1 ? true : undefined));

    // Crash + recover in a fresh actor (a fresh process): the call is refused at-most-once, the panic bubbles
    // out and fails the run.
    const second = recordingRunner();
    const actorTwo = makeActor(ir, persistence, second.runner);
    await actorTwo.activate();
    // The recovered (still-open) failure rows are never answerable (the §5 read filter).
    expect(actorTwo.listOpenEscalations()).toHaveLength(0);

    const failed = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "error" ? record : undefined;
    });
    expect(failed.errorMessage).toMatch(/interrupted by a runtime restart/);
    // The CRUX for recovery: the whole run subtree tore down — and with it, every failure escalation row
    // cascaded (no explicit retire). A quiesced failed run holds zero escalation rows and no live instances.
    await waitUntil(() => (persistence.instanceCount() === 0 ? true : undefined));
    await waitUntil(() => (persistence.envelopeCount("ffi") === 0 ? true : undefined));
    expect(persistence.escalationCount()).toBe(0);
    // The resolved failure is audited (question + a null answer).
    const audits = persistence.auditsFor(run);
    expect(audits).toHaveLength(1);
    expect(audits[0]?.answer).toBeNull();
  });
});
