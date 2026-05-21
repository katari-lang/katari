// Sidecar abstraction: the parent-side handle to a single child sidecar.
//
// Runtime code only knows this interface. Concrete implementations:
//
//   - {@link SubprocessSidecar}: production. Spawns `node bundle.mjs`
//     and speaks the 11-variant IPC (5 P2C + 6 C2P, see protocol.ts)
//     over stdio.
//   - {@link MockSidecar}: tests. Implements `Sidecar` directly with an
//     in-memory dispatcher so tests don't pay subprocess cost.
//
// Sidecar itself is **stateless** across restarts — when the parent
// reboots, the FFI Module replays in-flight delegations from its
// persistent store as `ipcDelegateRestarted` IPC messages.

import type { ChildToParent, ParentToChild } from "./types.js";

export interface Sidecar {
  /** Parent → Child message. */
  send(msg: ParentToChild): Promise<void>;

  /** Register a callback for Child → Parent messages. Only one at a time. */
  onMessage(cb: (msg: ChildToParent) => void): void;

  /** Bring the sidecar up (e.g. spawn subprocess, wait for `ready`). */
  start(): Promise<void>;

  /** Release resources. Idempotent. */
  shutdown(): Promise<void>;
}
