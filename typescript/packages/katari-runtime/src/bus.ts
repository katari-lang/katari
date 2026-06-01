// ExternalEventBus: a thin queue that routes cross-module events between
// the 3 modules.
//
// Design principles:
//   - The bus just looks at the `to` endpoint and calls `feed` on the
//     matching module
//   - Routes any (from, to) pair (including API<->API / FFI<->FFI)
//   - A module's `feed` returns 0..n outbound events per 1 inbound
//   - Self-addressed events (e.g. CORE->CORE) are not special-cased; they
//     loop back through the bus
//   - Async work (e.g. FFI Runner sidecar IPC responses) can be injected
//     after the fact via `bus.push(event)`
//
// CORE-internal thread-tree events (create / done / cancel / ask / askAck)
// are confined to the engine-side internal queue. They do not flow through
// the bus.

import type { Endpoint } from "./engine/endpoint.js";
import type { ExternalEvent } from "./engine/event.js";
import type { Logger } from "./engine/logger.js";
import type { Module } from "./module.js";

export type RegisteredModule = {
  /** Display name for logs / debugging. */
  name: string;
  // The bus only invokes `feed`; persist/load are called by the host
  // (orchestrator) directly on the typed concrete module. We carry the
  // `Module` shape just to express that constraint.
  module: Module;
};

/** Compact, log-friendly summary of an event (ids vary by kind). */
function busEventContext(event: ExternalEvent): Record<string, unknown> {
  const payload = event.payload;
  const context: Record<string, unknown> = {
    from: event.from,
    to: event.to,
    kind: payload.kind,
  };
  if ("delegationId" in payload) context.delegationId = payload.delegationId;
  if ("escalationId" in payload) context.escalationId = payload.escalationId;
  if ("agentDefId" in payload) context.agentDefId = payload.agentDefId;
  return context;
}

export class ExternalEventBus {
  private readonly modules = new Map<Endpoint, RegisteredModule>();
  private readonly queue: ExternalEvent[] = [];
  private drainPromise: Promise<void> | null = null;

  constructor(private readonly logger: Logger) {}

  /** Register a module. A helper for bulk-registering an `(name, module)` array is also provided. */
  register(entry: RegisteredModule): void {
    if (this.modules.has(entry.module.endpoint)) {
      throw new Error(`bus: duplicate module endpoint ${entry.module.endpoint}`);
    }
    this.modules.set(entry.module.endpoint, entry);
  }

  registerAll(entries: RegisteredModule[]): void {
    for (const e of entries) this.register(e);
  }

  /** Inject an event asynchronously (e.g. when the FFI Runner receives a sidecar response). */
  push(event: ExternalEvent): void {
    this.queue.push(event);
  }

  /**
   * Drain the queue until it is empty. If new events are pushed during a
   * drain, the same loop keeps processing them. Re-entrant calls wait for
   * the in-progress drain to finish (shared promise).
   */
  async drain(): Promise<void> {
    if (this.drainPromise !== null) return this.drainPromise;
    this.drainPromise = this.doDrain();
    try {
      await this.drainPromise;
    } finally {
      this.drainPromise = null;
    }
  }

  private async doDrain(): Promise<void> {
    while (this.queue.length > 0) {
      const event = this.queue.shift()!;
      this.logger.log("debug", "bus: event", busEventContext(event));
      const target = this.modules.get(event.to);
      if (target === undefined) {
        this.logger.log("warn", "bus: no module for endpoint; dropping event", {
          from: event.from,
          to: event.to,
          kind: event.payload.kind,
        });
        continue;
      }
      const { outbound } = await target.module.feed(event);
      for (const ev of outbound) this.queue.push(ev);
    }
  }

  // NOTE: persist / load are NOT mediated by the bus. Each module has
  // its own concrete tx shape (CORE wants CoreCheckpointStore, FFI is
  // no-op, API wants the SQL tx directly), so the orchestrator calls
  // them on the typed concrete reference instead of through the bus.
}
