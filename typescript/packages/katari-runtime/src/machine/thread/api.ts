import type { DelegationId, ThreadId } from "../id.js";
import type { ThreadBase } from "./types.js";

/**
 * Top-level thread managing user interactions.
 * No corresponding Block — one per machine instance.
 *
 * Routes invoke/cancel inbound events to root threads,
 * and produces invokeDone/invokeCancelled outbound events.
 */
export type APIThread = ThreadBase & {
  kind: "api";
  /** Active delegations: delegationId → root thread created for this invocation. */
  activeDelegations: Map<DelegationId, ThreadId>;
};
