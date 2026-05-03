import { IRModule } from "../../ir/types.js";
import { Thread } from "./thread.js";
import { ClosureId } from "./value.js";
import { ScopeId, ThreadId } from "./id.js";
import { MemoryCell, Scope } from "./memory.js";

/**
 * **Mutable** machine state
 */
export type MachineState = {
  irModule: IRModule;
  threads: Map<ThreadId, Thread>;
  scopes: Map<ScopeId, Scope>;
};
