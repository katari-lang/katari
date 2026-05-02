import type { IRModule } from "../ir/types.js";
import type { Value } from "./value.js";
import type { IrModuleId, ThreadId } from "./types.js";

/**
 * Events that drive the State Machine.
 * The machine is synchronous; these are the only external entry points.
 */
export type MachineEvent =
  /** Start a top-level agent invocation. Runtime assigns a new ThreadId. */
  | { kind: "invoke"; irModuleId: IrModuleId; qualifiedName: string; args: Value[] }
  /** Fill the result of an ext call or other external input. */
  | { kind: "fillValue"; threadId: ThreadId; value: Value }
  /** Cancel a thread and all threads in its subtree. */
  | { kind: "cancelThread"; threadId: ThreadId }
  /** Load a new IR module. Runtime assigns a new IrModuleId. */
  | { kind: "loadIrModule"; irModule: IRModule };

// applyEvent signature (implementation deferred):
// export function applyEvent(state: MachineState, event: MachineEvent): MachineState
