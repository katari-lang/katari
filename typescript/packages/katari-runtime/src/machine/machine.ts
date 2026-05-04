import type { IRModule } from "../ir/types.js";
import type { ScopeId, ThreadId } from "./id.js";
import type { InternalEvent } from "./events.js";
import type { Scope } from "./scope.js";
import type { Thread } from "./thread/types.js";

/**
 * Complete machine state.
 * Mutated in-place by the scheduler during event processing.
 * Pure from the API layer's perspective: applyEvent returns (state, outboundEvents).
 */
export type MachineState = {
  irModule: IRModule;
  threads: Map<ThreadId, Thread>;
  scopes: Map<ScopeId, Scope>;
  /** Internal event queue drained by the scheduler. */
  eventQueue: InternalEvent[];
};
