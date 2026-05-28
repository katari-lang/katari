// Public API of katari-api-server. Used by tests; production entry = bin.ts.

export type {
  FfiStore,
  MockAgentHandler,
  Sidecar,
  SidecarBundle,
  SidecarFactory,
  SidecarMessageHandler,
} from "@katari-lang/runtime";
// Runtime-provided abstractions re-exported for convenience.
export {
  API_ENDPOINT,
  CORE_ENDPOINT,
  FFI_ENDPOINT,
  FfiModule,
  loadSubprocessSidecar,
  MockSidecar,
  SidecarManager,
  SubprocessSidecar,
} from "@katari-lang/runtime";
export { ApiModule } from "./adapters/api-module.js";
export { StorageFfiStore } from "./adapters/ffi-store.js";
export { NoSnapshotForProject, Orchestrator, SnapshotNotFound } from "./orchestrator.js";
export type { ApiServerTickContext } from "./orchestrator-adapter.js";
export { ApiServerOrchestrator, createApiServerOrchestrator } from "./orchestrator-adapter.js";
export { recoverOnBoot } from "./recovery.js";
export { type AppDeps, buildApp } from "./routes/app.js";
export {
  ProjectNotFound,
  ProjectService,
} from "./services/project-service.js";
export {
  AgentNotFound,
  SnapshotService,
} from "./services/snapshot-service.js";
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
