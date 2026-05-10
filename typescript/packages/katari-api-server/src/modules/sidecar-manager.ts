// SidecarManager — owns long-lived per-snapshot subprocesses (or in-process
// substitutes for tests) and routes incoming sidecar messages to the
// orchestrator's tick function.
//
// Lifetime:
//   - One instance per api-server process. Sidecars stay alive across
//     HTTP requests; only `shutdown()` (= server SIGTERM) tears them down.
//   - On boot, `recoverOnBoot(snapshots)` re-spawns subprocesses for
//     every snapshot that still has running agents and sends `restored`.
//
// In-memory state — explicitly the only mutable cache the api-server
// keeps. Everything else is DB-backed.

import type { ChildToParent, SidecarBundle } from "katari-runtime/dist/sidecar/types.js";
import type { Logger } from "katari-runtime";
import type { Sidecar } from "./sidecar.js";
import type { SnapshotId } from "../storage/types.js";

export type SidecarFactory = (bundle: SidecarBundle, logger: Logger) => Sidecar;

export type SidecarMessageHandler = (
  snapshotId: SnapshotId,
  msg: ChildToParent,
) => Promise<void>;

export class SidecarManager {
  private readonly sidecars = new Map<SnapshotId, Sidecar>();
  private handler: SidecarMessageHandler | null = null;

  constructor(
    private readonly factory: SidecarFactory,
    private readonly logger: Logger,
  ) {}

  /** The orchestrator registers its `onSidecarMessage` here. */
  setMessageHandler(handler: SidecarMessageHandler): void {
    this.handler = handler;
  }

  async ensureStarted(input: {
    snapshotId: SnapshotId;
    bundle: SidecarBundle | null;
  }): Promise<void> {
    if (this.sidecars.has(input.snapshotId)) return;
    if (input.bundle === null) {
      this.logger.log("debug", "snapshot has no sidecar bundle; FFI invokes will error", {
        snapshotId: input.snapshotId,
      });
      return;
    }
    const sidecar = this.factory(input.bundle, this.logger);
    sidecar.onMessage((msg) => {
      const handler = this.handler;
      if (handler === null) {
        this.logger.log("warn", "sidecar message dropped: no handler", {
          snapshotId: input.snapshotId,
          type: msg.type,
        });
        return;
      }
      handler(input.snapshotId, msg).catch((err) => {
        this.logger.log("error", "sidecar message handler threw", {
          snapshotId: input.snapshotId,
          type: msg.type,
          err: err instanceof Error ? err.message : String(err),
        });
      });
    });
    // sidecar.start() is implementation-specific (Subprocess vs InProcess).
    if ("start" in sidecar && typeof (sidecar as { start: unknown }).start === "function") {
      await (sidecar as { start: () => Promise<void> }).start();
    }
    this.sidecars.set(input.snapshotId, sidecar);
  }

  /** Send an IPC message. Throws if the snapshot's sidecar is not started. */
  async send(
    snapshotId: SnapshotId,
    msg: import("katari-runtime/dist/sidecar/types.js").ParentToChild,
  ): Promise<void> {
    const sidecar = this.sidecars.get(snapshotId);
    if (sidecar === undefined) {
      throw new Error(
        `sidecar-manager: snapshot ${snapshotId} has no live sidecar`,
      );
    }
    await sidecar.send(msg);
  }

  hasSidecar(snapshotId: SnapshotId): boolean {
    return this.sidecars.has(snapshotId);
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
