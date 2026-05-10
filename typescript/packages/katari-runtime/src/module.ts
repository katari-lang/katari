// Module: 3 module + 6 event 対称設計の core 抽象。
//
// API / CORE / FFI の各 module はこの interface を実装する。bus は (endpoint
// → module) の対応表しか持たず、event の `to` を見て module.feed を呼ぶだけ。
//
// **責任分担**:
//   - Module: 自分宛の event を 1 つ処理して outbound を返す。永続化も自分で。
//   - Bus:   event を queue して `to` を見て dispatch するだけ。中身は見ない。
//
// 永続化 (persist / load) は module ごとに状態の形が違うので、tx 引数は
// 抽象 (`unknown`)。各 module 実装が自前で型 narrowing する。

import type { ExternalEvent } from "./engine/event.js";
import type { Endpoint } from "./engine/endpoint.js";

export interface Module {
  /** Self-identifier. bus が `event.to === endpoint` で routing する。 */
  readonly endpoint: Endpoint;

  /**
   * Inbound event を 1 つ処理。
   *
   * 同期で確定した outbound を返す。非同期処理 (例: FFI sidecar の IPC 応答)
   * は別経路で `bus.push(...)` して bus drain を継続させる。
   */
  feed(event: ExternalEvent): Promise<{ outbound: ExternalEvent[] }>;

  /** State を tx に保存。bus drain 完了時に呼ばれる。 */
  persist(tx: unknown): Promise<void>;

  /**
   * State を tx から復元。リクエスト処理開始時に呼ばれる。state を持たない
   * module (現状の API module 等) は no-op で良い。
   */
  load(tx: unknown): Promise<void>;
}
