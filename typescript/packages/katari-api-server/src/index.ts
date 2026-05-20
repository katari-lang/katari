// Public API of katari-api-server. Used by tests; production entry = bin.ts.

export { buildApp, type AppDeps } from "./routes/app.js";

export { Orchestrator, SnapshotNotFound } from "./orchestrator.js";
export {
  ProjectService,
  ProjectNotFound,
} from "./services/project-service.js";
export {
  SnapshotService,
  AgentDefinitionNotFound,
} from "./services/snapshot-service.js";

export { ApiModule } from "./modules/api-module.js";
export { StorageFfiStore } from "./modules/ffi-store.js";

// Runtime-provided abstractions re-exported for convenience.
export {
  API_ENDPOINT,
  CORE_ENDPOINT,
  FFI_ENDPOINT,
  FfiModule,
  MockSidecar,
  SidecarManager,
  SubprocessSidecar,
  loadSubprocessSidecar,
} from "@katari-lang/runtime";
export type {
  FfiStore,
  MockAgentHandler,
  Sidecar,
  SidecarBundle,
  SidecarFactory,
  SidecarMessageHandler,
} from "@katari-lang/runtime";

export { recoverOnBoot } from "./recovery.js";
export { InMemoryStorage } from "./storage/memory-storage.js";
export { PostgresStorage } from "./storage/pg.js";
export type {
  AgentId,
  AgentRow,
  AgentState,
  ApiPendingEscalation,
  FfiPendingDelegation,
  FfiPendingEscalation,
  Project,
  ProjectId,
  Snapshot,
  SnapshotId,
  SnapshotSummary,
  Storage,
} from "./storage/types.js";
