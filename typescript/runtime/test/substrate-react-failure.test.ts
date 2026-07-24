// When a reactor's `react` deterministically THROWS, that is a bug — a deterministic failure is supposed to
// surface as a panic, not a throw — so the substrate contains the poison by dropping the event (never
// replay-looping it). The drop used to be silent: the event's run got no outcome and hung forever, its only
// trace a log line. Now the substrate synthesizes an `error` outcome for the dropped event's run, attributed
// by the event's own `run` trace context (no graph walk) — so the run is observable. A `TransientError` is a
// different class (an infra blip) and still retries the turn from durable state, never failing the run.
//
// The harness wires a real `ApiReactor` (which records the run outcome) and a `Substrate` to a scripted core
// stub that throws on the run's `delegate` — the poison — but reacts normally to the follow-up `terminate`
// the failure path emits (exactly as a real core would: a terminate is a different react path than the event
// that threw). The rest of the registry is inert placeholders never routed to.

import { createAgentName, type QualifiedName } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { createLogger } from "../src/lib/logger.js";
import { ApiReactor } from "../src/runtime/actor/api-reactor.js";
import type { Loader, PersistenceTx } from "../src/runtime/actor/persistence.js";
import { Reactor } from "../src/runtime/actor/reactor.js";
import { ResourcePool } from "../src/runtime/actor/resource-pool.js";
import type { StoreRows } from "../src/runtime/actor/store-responder.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { Substrate, type SubstrateHost } from "../src/runtime/actor/substrate.js";
import { createProjectStore } from "../src/runtime/engine/store.js";
import { TransientError } from "../src/runtime/engine/transient-error.js";
import type { ExternalEvent, ReactorName } from "../src/runtime/event/types.js";
import {
  apiRootIdOf,
  type InstanceId,
  newDelegationId,
  newInstanceId,
  newOutboxSeq,
  type ProjectId,
  type SnapshotId,
} from "../src/runtime/ids.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";

const PROJECT = "project-substrate-react-failure" as ProjectId;
const SNAPSHOT = "snapshot-substrate-react-failure" as SnapshotId;

/** The empty durable KV rows the api reactor answers `prelude.store.*` against — never exercised here. */
const EMPTY_STORE_ROWS: StoreRows = {
  async read() {
    return undefined;
  },
  async upsert() {},
  async remove() {},
  async listKeys() {
    return [];
  },
};

/** A minimal concrete reactor: the base's generic persist / load, no own extension. Used for the inert
 *  registry placeholders and as the scripted core's base. */
class StubReactor extends Reactor {
  constructor(
    readonly name: ReactorName,
    pool: ResourcePool,
  ) {
    super(pool);
  }

  async persist(tx: PersistenceTx): Promise<void> {
    await this.persistBase(tx.base);
  }

  async load(loader: Loader): Promise<void> {
    await this.loadBase(loader.base);
  }
}

/** A core stub whose reaction to a run's `delegate` is scripted (it may throw) — the ONLY poison surface. It
 *  counts its delegate reactions (to prove a deterministic throw is not retried, but a transient one is), and
 *  reacts to every other event (the failure path's `terminate`) through the inert base, exactly as a real
 *  core handles a terminate on a different path than the event that threw. */
class ScriptedCore extends StubReactor {
  delegateReactions = 0;

  constructor(
    pool: ResourcePool,
    private readonly delegateBehavior: (attempt: number) => void,
  ) {
    super("core", pool);
  }

  override react(event: ExternalEvent): void | Promise<void> {
    if (event.kind === "delegate") {
      this.delegateReactions += 1;
      this.delegateBehavior(this.delegateReactions);
      return; // Otherwise the delegate is "handled" (no engine here): consumed, no ack, no retry.
    }
    return super.react(event);
  }
}

interface Harness {
  substrate: Substrate;
  persistence: StoringPersistence;
  core: ScriptedCore;
  run: InstanceId;
  failedRuns: Array<{ run: InstanceId; error: unknown }>;
}

/** Seed the durable state a crash leaves after `startRun` committed but before the run ran: the run
 *  delegation, the `runs` row, and the undelivered `delegate` in the outbox. `activate` replays the delegate,
 *  which routes to the scripted core. */
function seedDurableRun(persistence: StoringPersistence): { run: InstanceId } {
  const run = newInstanceId();
  const delegation = newDelegationId();
  persistence.seedDelegation(delegation, { caller: run, fromReactor: "api", toReactor: "core" });
  persistence.seedRun(run, {
    name: "main",
    qualifiedName: createAgentName("main"),
    snapshotId: SNAPSHOT,
    argument: null,
  });
  persistence.seedOutbox({
    seq: newOutboxSeq(),
    event: {
      kind: "delegate",
      from: "api",
      to: "core",
      run,
      delegation,
      target: { kind: "named", name: createAgentName("main"), snapshot: SNAPSHOT },
      argument: null,
    },
  });
  return { run };
}

/** A reactor the harness reloads on every reactivation — the base `Reactor` plus the per-concrete `load`. */
type ReloadableReactor = Reactor & { load(loader: Loader): Promise<void> };

function makeHarness(delegateBehavior: (attempt: number) => void): Harness {
  const persistence = new StoringPersistence();
  const { run } = seedDurableRun(persistence);
  const store = createProjectStore();
  const pool = new ResourcePool(PROJECT, store);
  // Assigned at the end; the api / host closures below read it only when a turn actually runs (well after).
  let substrate: Substrate;
  const api: ApiReactor = new ApiReactor(
    apiRootIdOf(PROJECT),
    { enqueue: (thunk) => substrate.enqueueCommand(api, thunk) },
    pool,
    PROJECT,
    EMPTY_STORE_ROWS,
  );
  const core = new ScriptedCore(pool, delegateBehavior);
  // The inert placeholders — never routed to, they only fill the registry and reload as empty on reactivation.
  const ffi = new StubReactor("ffi", pool);
  const http = new StubReactor("http", pool);
  const webhook = new StubReactor("webhook", pool);
  const mcp = new StubReactor("mcp", pool);
  const time = new StubReactor("time", pool);
  const oauth = new StubReactor("oauth", pool);
  const region = new StubReactor("region", pool);
  const registry: Record<ReactorName, Reactor> = {
    core,
    api,
    ffi,
    http,
    webhook,
    mcp,
    time,
    oauth,
    region,
  };
  // Every reactor defines `load`; the registry's `Reactor` values do not surface it, so keep them typed here.
  const reactors: ReloadableReactor[] = [core, api, ffi, http, webhook, mcp, time, oauth, region];

  // The failures the substrate synthesizes, recorded so a test can assert one WAS (or was NOT) raised.
  const failedRuns: Array<{ run: InstanceId; error: unknown }> = [];

  const host: SubstrateHost = {
    // Mirror the project actor's reactivation: reset every reactor, reload from durable rows, replay the outbox.
    reactivate: async () => {
      for (const reactor of reactors) reactor.reset();
      await persistence.load(PROJECT, async (loader) => {
        for (const reactor of reactors) await reactor.load(loader);
        for (const message of await loader.outbox.pending()) {
          substrate.enqueueOutbox(message.event, message.seq);
        }
      });
    },
    onPoison: (error) =>
      api.poisonRunPromises(error instanceof Error ? error : new Error(String(error))),
    failRun: (failingRun, error) => {
      failedRuns.push({ run: failingRun, error });
      const message = `internal error: ${error instanceof Error ? error.message : String(error)}`;
      void api.failRun(failingRun, message).catch(() => {});
    },
  };

  substrate = new Substrate(
    PROJECT,
    persistence,
    registry,
    pool,
    new InMemoryBlobStore(),
    host,
    createLogger({ level: "error", bindings: { module: "substrate-test" } }),
  );

  return { substrate, persistence, core, run, failedRuns };
}

async function waitUntil<T>(predicate: () => T | undefined): Promise<T> {
  for (let attempt = 0; attempt < 1000; attempt++) {
    const value = predicate();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error("waitUntil: predicate never held");
}

describe("substrate: a deterministic react throw fails its run instead of hanging", () => {
  test("a dropped poison event synthesizes an error outcome for its run", async () => {
    // The scripted core throws a plain Error on the run's delegate — a deterministic bug. The substrate must
    // drop the event AND fail the run, so it is observable rather than hung.
    const harness = makeHarness(() => {
      throw new Error("react boom");
    });
    await harness.substrate.activate();

    const failed = await waitUntil(() => {
      const record = harness.persistence.peekRun(harness.run);
      return record?.state === "error" ? record : undefined;
    });
    // The run's error outcome carries the thrown message (through the api reactor's `failRun`).
    expect(failed.errorMessage).toMatch(/react boom/);
    // The failure was attributed to exactly this run, by the event's own `run` trace context.
    expect(harness.failedRuns).toHaveLength(1);
    expect(harness.failedRuns[0]?.run).toBe(harness.run);
    // A deterministic throw is contained, not retried — the delegate reacted exactly once.
    expect(harness.core.delegateReactions).toBe(1);
    // The run reached a terminal state: its delegation is retired and nothing is left suspended / undrained.
    expect(harness.persistence.runDelegationOf(harness.run)).toBeUndefined();
    await waitUntil(() =>
      harness.persistence.outboxSize() === 0 && harness.persistence.instanceCount() === 0
        ? true
        : undefined,
    );
  });

  test("a TransientError retries the turn from durable state and never fails the run", async () => {
    // The scripted core raises a TransientError (an infra blip) on the first two delegate reactions, then
    // handles it. The substrate must drop + reload + replay (NOT fail the run) so the retry lands — the run
    // stays running throughout and no failure is ever synthesized.
    const harness = makeHarness((attempt) => {
      if (attempt <= 2) throw new TransientError("db blip");
    });
    await harness.substrate.activate();

    // The turn was retried past its transient failures (more than the single reaction a deterministic drop
    // would allow).
    await waitUntil(() => (harness.core.delegateReactions >= 3 ? true : undefined));
    // No run failure was ever synthesized — a TransientError is retried, not treated as a poison bug.
    expect(harness.failedRuns).toHaveLength(0);
    // The run is not failed: its record stays `running` and its delegation stays live.
    expect(harness.persistence.peekRun(harness.run)?.state).toBe("running");
    expect(harness.persistence.runDelegationOf(harness.run)).toBeDefined();
  });
});
