// Module: core abstraction of the 3-module + 6-event symmetric design.
//
// API / CORE / FFI / ENV modules each implement this interface. The bus only
// holds an (endpoint -> module) table and calls `module.feed` based on the
// event's `to` field.
//
// **Self-contained modules (Phase E)**: a module is a warm, per-project actor
// that implements the katari-protocol and owns its own domain logic AND its
// own persistence. `feed` is the only interface method: the module opens its
// own transaction (1 quantum = 1 tx), loads what it touches, applies the
// event, persists, and commits — all internally. There is no host-driven
// `load` / `persist` step anymore; the host (the bus + the project actor) is a
// thin proxy that only routes events and calls `feed`.
//
// Serialization is the module's concern too: the CORE module is serialized
// per-project (the project actor's serial loop) so its warm shard cache stays
// consistent; per-shard concurrency is a later, mutex-granularity-only change.

import type { Endpoint } from "./engine/endpoint.js";
import type { ExternalEvent } from "./engine/event.js";

export interface Module {
  /** Self-identifier. The bus routes by `event.to === endpoint`. */
  readonly endpoint: Endpoint;

  /**
   * Process one inbound event and return the events it produces.
   *
   * The module is responsible for its own transaction + persistence: a
   * `feed` is one self-contained quantum. Outbound events flow back through
   * the bus; asynchronous work that can't be resolved synchronously (e.g.
   * FFI sidecar IPC responses) is injected later via `bus.push(...)`.
   */
  feed(event: ExternalEvent): Promise<{ outbound: ExternalEvent[] }>;
}
