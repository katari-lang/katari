// Public API of katari-api-server. Mostly used by tests; the production
// binary entry is `bin.ts`.

export { buildApp, type AppDeps } from "./routes/app.js";
export { MachineRegistry, MachineNotFound, MachineHandle } from "./registry.js";
export type { FFIExecutor, InvokeArgs } from "./ffi/executor.js";
export { withTimeout } from "./ffi/executor.js";
export { InProcessFFIExecutor, type InProcessHandler } from "./ffi/inproc.js";
export { HttpFFIExecutor, type HttpFFIOptions } from "./ffi/http.js";
export { OutboundEventDispatcher } from "./services/outbound-dispatcher.js";
export { MachineRebuilder } from "./services/machine-rebuilder.js";
export { PoisonHandler } from "./services/poison-handler.js";
export {
  AgentService,
  AgentNotFound,
  EntryNotFoundError,
} from "./services/agent-service.js";
export {
  ModuleService,
  ModuleNotFound,
  AgentDefinitionNotFound,
} from "./services/module-service.js";
export { recoverOnBoot } from "./recovery.js";
export { InMemoryStorage } from "./storage/memory-storage.js";
export { PostgresStorage } from "./storage/pg.js";
export type {
  AgentId,
  AgentRow,
  AgentState,
  ModuleRow,
  ModuleSummary,
  Storage,
  VersionId,
} from "./storage/types.js";
