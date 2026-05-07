// Public API of katari-api-server. Mostly used by tests; the production
// binary entry is `bin.ts`.

export { buildApp, type AppDeps } from "./routes/app.js";
export { MachineRegistry, MachineNotFound } from "./registry.js";
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
