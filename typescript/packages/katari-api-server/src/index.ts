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
export { FfiModule } from "./modules/ffi-module.js";
export { SidecarManager } from "./modules/sidecar-manager.js";
export type {
  Sidecar,
  InProcessHandler,
} from "./modules/sidecar.js";
export {
  InProcessSidecar,
  SubprocessSidecar,
} from "./modules/sidecar.js";

export {
  API_ENDPOINT,
  CORE_ENDPOINT,
  FFI_ENDPOINT,
} from "./modules/endpoints.js";

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
  SidecarBundle,
  Snapshot,
  SnapshotId,
  SnapshotSummary,
  Storage,
} from "./storage/types.js";
