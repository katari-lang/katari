// CoreModule: engine を Module interface に wrap する薄いアダプター。
//
// 責任:
//   - feed(event):   1 event を applyEvent に通して outbound を返す
//   - persist(tx):   現在の State を `tx.upsert(...)` で永続化
//   - load(tx):      checkpoint があれば deserialize、無ければ createState
//
// CORE は 1 snapshot = 1 IRModule = 1 State。`snapshotId` は永続化キー。
//
// 自己宛 event (= CORE→CORE) は applyEvent の outbound に含まれて bus に返り、
// bus がまた同じ CoreModule.feed に渡す (self-loop は engine 内に閉じない)。

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
