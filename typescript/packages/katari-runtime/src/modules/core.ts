// CoreModule: a thin adapter wrapping the engine into the Module interface.
//
// Responsibilities:
//   - feed(event):   feed one event through applyEvent and return outbound
//   - persist(tx):   persist the current State via `tx.upsert(...)`
//   - load(tx):      deserialize if a checkpoint exists, else createState
//
// CORE has 1 snapshot = 1 IRModule = 1 State. `snapshotId` is the persistence key.
//
// Self-addressed events (= CORE->CORE) are included in applyEvent's outbound,
// returned to the bus, and the bus hands them back to the same CoreModule.feed
// (self-loops do not stay inside the engine).

import { applyEvent, createState } from "../engine/apply.js";
import type { Endpoint } from "../engine/endpoint.js";
import type { ExternalEvent } from "../engine/event.js";
import type { Logger } from "../engine/logger.js";
import {
  deserialize,
  serialize,
  type EngineCheckpoint,
} from "../engine/snapshot.js";
import type { State } from "../engine/state.js";
import type { Module } from "../module.js";
import type { IRModule } from "../ir/types.js";

/**
 * Storage interface that the CoreModule depends on. The host (api-server)
 * provides a concrete implementation backed by Postgres / in-memory.
 */
export interface CoreCheckpointStore {
  get(snapshotId: string): Promise<EngineCheckpoint | null>;
  upsert(snapshotId: string, checkpoint: EngineCheckpoint): Promise<void>;
}

export type CoreModuleOptions = {
  endpoint: Endpoint;
  snapshotId: string;
  irModule: IRModule;
  logger: Logger;
};

/** Tx shape CoreModule.persist / load expect. */
export type CoreTx = { coreCheckpoints: CoreCheckpointStore };

export class CoreModule implements Module<CoreTx> {
  readonly endpoint: Endpoint;
  private readonly snapshotId: string;
  private readonly irModule: IRModule;
  private readonly logger: Logger;
  private state: State;

  constructor(opts: CoreModuleOptions) {
    this.endpoint = opts.endpoint;
    this.snapshotId = opts.snapshotId;
    this.irModule = opts.irModule;
    this.logger = opts.logger;
    this.state = createState(opts.irModule, { selfEndpoint: opts.endpoint });
  }

  async feed(event: ExternalEvent): Promise<{ outbound: ExternalEvent[] }> {
    const result = applyEvent(this.state, event);
    this.state = result.state;
    for (const log of result.logs) {
      this.logger.log(log.level, log.message, log.context);
    }
    // outbound is `Event[]` of external payload kinds — we return them
    // as-is. Cast keeps the wider Event type compatible with ExternalEvent
    // (Event = ExternalEvent ∪ internal-only forms; outbound is always
    // external by construction).
    return { outbound: result.outbound as ExternalEvent[] };
  }

  async persist(tx: CoreTx): Promise<void> {
    await tx.coreCheckpoints.upsert(this.snapshotId, serialize(this.state));
  }

  async load(tx: CoreTx): Promise<void> {
    const checkpoint = await tx.coreCheckpoints.get(this.snapshotId);
    this.state = checkpoint !== null
      ? deserialize(this.irModule, checkpoint)
      : createState(this.irModule, { selfEndpoint: this.endpoint });
  }

  /** Read-only access for tests / debug. */
  get currentState(): State {
    return this.state;
  }
}
