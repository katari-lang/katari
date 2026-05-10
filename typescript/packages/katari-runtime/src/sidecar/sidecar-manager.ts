// SidecarManager — `Map<key, Sidecar>` を抱える長寿命コンテナ。
//
// runtime 側の汎用抽象。api-server では key = SnapshotId として使い、各
// snapshot に 1 個ずつ sidecar を持たせる。
//
// In-memory state — 「FFI module 内部だけ許可」と決めた唯一の例外。
// Sidecar 自身は stateless なので、subprocess が死んでも次回 ensureStarted
// で再立ち上げ + 必要なら親側から `restoredDelegate` を投げて再開できる。

import type { Logger } from "../engine/logger.js";
import type { Sidecar } from "./sidecar.js";
import type { SidecarBundle, ChildToParent, ParentToChild } from "./types.js";

/**
 * Sidecar インスタンスを生成するファクトリ。
 *
 *   - Production: subprocess 版 (将来 katari-port 経由) を返す
 *   - Test:       `InProcessSidecar` を返す
 *
 * `bundle === null` は「sidecar を持たない snapshot」(FFI を使わない場合)
 * のシグナル。factory は null を返すか、no-op sidecar を返す。
 */
export type SidecarFactory<TKey> = (
  key: TKey,
  bundle: SidecarBundle | null,
  logger: Logger,
) => Sidecar | null;

/**
 * Sidecar からの child→parent message を 1 個受け取った時の callback。
 * api-server なら orchestrator が「新しい tick を起こす」ためにこれを使う。
 */
export type SidecarMessageHandler<TKey> = (
  key: TKey,
  msg: ChildToParent,
) => Promise<void>;

export class SidecarManager<TKey> {
  private readonly sidecars = new Map<string, Sidecar>();
  private handler: SidecarMessageHandler<TKey> | null = null;

  constructor(
    private readonly factory: SidecarFactory<TKey>,
    private readonly logger: Logger,
    private readonly keyToString: (key: TKey) => string = (k) => String(k),
  ) {}

  setMessageHandler(handler: SidecarMessageHandler<TKey>): void {
    this.handler = handler;
  }

  async ensureStarted(input: {
    key: TKey;
    bundle: SidecarBundle | null;
  }): Promise<void> {
    const k = this.keyToString(input.key);
    if (this.sidecars.has(k)) return;
    const sidecar = this.factory(input.key, input.bundle, this.logger);
    if (sidecar === null) {
      this.logger.log("debug", "sidecar factory returned null", { key: k });
      return;
    }
    sidecar.onMessage((msg) => {
      const handler = this.handler;
      if (handler === null) {
        this.logger.log("warn", "sidecar message dropped: no handler", {
          key: k,
          type: msg.type,
        });
        return;
      }
      handler(input.key, msg).catch((err) => {
        this.logger.log("error", "sidecar message handler threw", {
          key: k,
          type: msg.type,
          err: err instanceof Error ? err.message : String(err),
        });
      });
    });
    await sidecar.start();
    this.sidecars.set(k, sidecar);
  }

  async send(key: TKey, msg: ParentToChild): Promise<void> {
    const sidecar = this.sidecars.get(this.keyToString(key));
    if (sidecar === undefined) {
      throw new Error(
        `sidecar-manager: no live sidecar for key ${this.keyToString(key)}`,
      );
    }
    await sidecar.send(msg);
  }

  hasSidecar(key: TKey): boolean {
    return this.sidecars.has(this.keyToString(key));
  }

  size(): number {
    return this.sidecars.size;
  }

  async shutdown(): Promise<void> {
    await Promise.all(
      [...this.sidecars.values()].map((s) =>
        s.shutdown().catch((err) => {
          this.logger.log("warn", "sidecar shutdown threw", {
            err: err instanceof Error ? err.message : String(err),
          });
        }),
      ),
    );
    this.sidecars.clear();
  }
}
