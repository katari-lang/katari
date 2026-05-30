// SidecarManager — long-lived container that holds `Map<key, Sidecar>`.
//
// A generic abstraction on the runtime side. In api-server, key = SnapshotId
// is used, with one sidecar per snapshot.
//
// In-memory state — the sole exception we allow ("inside the FFI module only").
// The sidecar itself is stateless, so if the subprocess dies it can be
// re-launched on the next ensureStarted + if needed the parent side can
// send `restoredDelegate` to resume.

import type { Logger } from "../engine/logger.js";
import type { Sidecar } from "./sidecar.js";
import type { ChildToParent, ParentToChild, SidecarBundle } from "./types.js";

/**
 * Factory that creates Sidecar instances.
 *
 *   - Production: returns the subprocess version (in the future via katari-port)
 *   - Test:       returns `InProcessSidecar`
 *
 * `bundle === null` is the signal for "snapshot without a sidecar" (when
 * FFI is not used). The factory either returns null or a no-op sidecar.
 */
export type SidecarFactory<TKey> = (
  key: TKey,
  bundle: SidecarBundle | null,
  logger: Logger,
  /** Per-start env for the child (Katari Protocol coordinates: URL / token /
   *  project / owner). `undefined` for factories that don't spawn a process. */
  env: Record<string, string> | undefined,
) => Promise<Sidecar | null> | Sidecar | null;

/**
 * Callback for receiving one child->parent message from a sidecar.
 * In api-server, the orchestrator uses this to "start a new tick".
 */
export type SidecarMessageHandler<TKey> = (key: TKey, msg: ChildToParent) => Promise<void>;

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
    env?: Record<string, string>;
  }): Promise<void> {
    const k = this.keyToString(input.key);
    if (this.sidecars.has(k)) return;
    const sidecar = await this.factory(input.key, input.bundle, this.logger, input.env);
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
      throw new Error(`sidecar-manager: no live sidecar for key ${this.keyToString(key)}`);
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
