// Public API of katari-api-server. Used by tests; production entry = bin.ts.

export { buildApp, type AppDeps } from "./routes/app.js";

export { Orchestrator, SnapshotNotFound, NoSnapshotForProject } from "./orchestrator.js";
export { createApiServerOrchestrator, ApiServerOrchestrator } from "./orchestrator-adapter.js";
export type { ApiServerTickContext } from "./orchestrator-adapter.js";
export {
  ProjectService,
  ProjectNotFound,
} from "./services/project-service.js";
export {
  SnapshotService,
  AgentNotFound,
} from "./services/snapshot-service.js";

export { ApiModule } from "./adapters/api-module.js";
export { StorageFfiStore } from "./adapters/ffi-store.js";

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
  CancelReason,
  DelegationRow,
  DelegationState,
  EscalationRow,
  EscalationState,
  FfiPendingDelegation,
  FfiPendingEscalation,
  Project,
  ProjectId,
  RunsAuditRow,
  RunsAuditState,
  Snapshot,
  SnapshotId,
  SnapshotSummary,
  Storage,
} from "./storage/types.js";
