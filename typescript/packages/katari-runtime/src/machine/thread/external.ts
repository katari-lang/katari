import type { ExternalName } from "../../ir/types.js";
import type { DelegationId } from "../id.js";
import type { Value } from "../value.js";
import type { ThreadBase } from "./types.js";

/**
 * Executes a BlockExternal (FFI sidecar call).
 *
 * Sole producer/consumer of to-FFI / from-FFI events.
 * On creation, emits a callExternal outbound event and suspends.
 * Resumes when an invokeAck inbound event arrives with a matching delegationId.
 * On cancel, emits cancelExternal outbound event.
 */
export type ExternalThread = ThreadBase & {
  kind: "external";
  externalName: ExternalName;
  /** Labeled arguments resolved at call site. */
  arguments: Map<string, Value>;
  /** Unique delegation ID for this external call. */
  delegationId: DelegationId;
  phase:
    | { kind: "calling" }
    | { kind: "completed" };
};
