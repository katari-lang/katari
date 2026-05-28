// Module: core abstraction of the 3-module + 6-event symmetric design.
//
// API / CORE / FFI modules each implement this interface. The bus only
// holds an (endpoint -> module) table and calls module.feed based on
// the event's `to` field.
//
// **Responsibility split**:
//   - Module: processes one event addressed to itself and returns outbound.
//             Persistence is its own job.
//   - Bus:   queues events and dispatches based on `to` — doesn't look inside.
//
// The tx argument of `persist` / `load` has a different type per module impl
// (CORE module: `{coreCheckpoints: CoreCheckpointStore}`, FFI module: no-op,
// API module: receives a SQL tx directly). The `Module<Tx>` type parameter
// lets each impl declare the type it needs, and the bus handles it as
// `Module<unknown>` (= safe because dispatch doesn't inspect tx contents).

import type { Endpoint } from "./engine/endpoint.js";
import type { ExternalEvent } from "./engine/event.js";

export interface Module<Tx = unknown> {
  /** Self-identifier. The bus routes by `event.to === endpoint`. */
  readonly endpoint: Endpoint;

  /**
   * Process one inbound event.
   *
   * Returns outbound events determined synchronously. Asynchronous work
   * (e.g. FFI sidecar IPC responses) goes through a separate route
   * (`bus.push(...)`) to continue the bus drain.
   */
  feed(event: ExternalEvent): Promise<{ outbound: ExternalEvent[] }>;

  /** Save state to tx. Called when bus drain completes. */
  persist(tx: Tx): Promise<void>;

  /**
   * Restore state from tx. Called at the start of request processing.
   * Stateless modules (e.g. the current API module) can be a no-op.
   */
  load(tx: Tx): Promise<void>;
}
