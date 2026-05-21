// ExternalEventBus: 3 module 間の cross-module event を routing する薄い queue。
//
// 設計原則:
//   - bus は `to` endpoint を見て該当 module の `feed` を呼ぶだけ
//   - どの (from, to) ペアでも routing する (API↔API / FFI↔FFI 含む)
//   - module の `feed` は 1 inbound → outbound 0..n を返す
//   - 自己宛 event (例: CORE→CORE) も特別扱いせず bus 経由で復帰する
//   - 非同期処理 (例: FFI Runner の sidecar IPC 応答) は `bus.push(event)` で
//     後追い注入できる
//
// CORE 内部の thread-tree event (create / done / cancel / ask / askAck) は
// engine 側の internal queue に閉じる。bus には流れない。

import type { ExternalEvent } from "./engine/event.js";
import type { Endpoint } from "./engine/endpoint.js";
import type { Module } from "./module.js";
import type { Logger } from "./engine/logger.js";

export type RegisteredModule = {
  /** Display name for logs / debugging. */
  name: string;
  // The bus only invokes `feed`; persist/load are called by the host
  // (orchestrator) directly on the typed concrete module. We carry the
  // `Module<unknown>` shape just to express that constraint.
  module: Module<unknown>;
};

export class ExternalEventBus {
  private readonly modules = new Map<Endpoint, RegisteredModule>();
  private readonly queue: ExternalEvent[] = [];
  private draining = false;

  constructor(private readonly logger: Logger) {}

  /** Register a module. `(name, module)` の配列を一括登録するヘルパも提供。 */
  register(entry: RegisteredModule): void {
    if (this.modules.has(entry.module.endpoint)) {
      throw new Error(
        `bus: duplicate module endpoint ${entry.module.endpoint}`,
      );
    }
    this.modules.set(entry.module.endpoint, entry);
  }

  registerAll(entries: RegisteredModule[]): void {
    for (const e of entries) this.register(e);
  }

  /** Async に event を流し込む (例: FFI Runner が sidecar 応答受信時)。 */
  push(event: ExternalEvent): void {
    this.queue.push(event);
  }

  /**
   * Queue が空になるまで drain する。drain 中に新しい event が push されたら
   * 同じループで処理を続ける。重複呼び出しは即 return (= reentrant safe)。
   */
  async drain(): Promise<void> {
    if (this.draining) return;
    this.draining = true;
    try {
      while (this.queue.length > 0) {
        const event = this.queue.shift()!;
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
    } finally {
      this.draining = false;
    }
  }

  // NOTE: persist / load are NOT mediated by the bus. Each module has
  // its own concrete tx shape (CORE wants CoreCheckpointStore, FFI is
  // no-op, API wants the SQL tx directly), so the orchestrator calls
  // them on the typed concrete reference instead of through the bus.
}
