// Public API.
//
// All exports come from the new engine layer. Legacy `machine/` and
// `runtime/` modules were removed in Phase D — this file is the single
// source of truth for what `katari-api-server` (and any future host)
// imports.

// ─── Engine functions ──────────────────────────────────────────────────────

export {
  applyEvent,
  createState,
  endpoint,
  NULL_VALUE,
  literalToValue,
  isInternal,
  emptyResult,
  serialize,
  deserialize,
  collectGarbage,
  shouldGc,
  LoggerTag,
  RecoverableEngineError,
  IrrecoverableEngineError,
  EntryNotFoundError,
  buildConsoleLogger,
  consoleLogger,
  noopLogger,
  createDelegationId,
  createEscalationId,
  createScopeId,
  createThreadId,
} from "./engine/index.js";

// ─── Engine types ──────────────────────────────────────────────────────────

export type {
  Endpoint,
  AskId,
  CallId,
  DelegationId,
  EscalationId,
  ScopeId,
  ThreadId,
  Value,
  Value as EngineValue,
  Scope,
  Scope as EngineScope,
  AskKind,
  Event,
  Event as EngineEvent,
  Event as MachineEvent,
  EventPayload,
  ExternalEventPayload,
  InternalEventPayload,
  ModMap,
  Thread,
  Thread as EngineThread,
  ThreadKind,
  ThreadStatus,
  AskIdMap,
  AgentThread,
  UserThread,
  HandleThread,
  ForThread,
  MatchThread,
  RequestThread,
  ExternalThread,
  PrimThread,
  CtorThread,
  TupleThread,
  ArrayThread,
  ChildRole,
  PendingAction,
  PostCancelAction,
  State,
  State as EngineState,
  State as MachineState,
  Diff,
  EngineError,
  LogEntry,
  LogLevel,
  Logger,
  Result,
  Result as EngineResult,
  EngineCheckpoint,
  EngineCheckpoint as Snapshot,
  EngineCheckpoint as EngineSnapshot,
  EngineCheckpoint as MachineSnapshot,
} from "./engine/index.js";

// ─── IR + schema types (Haskell mirror) ────────────────────────────────────

export type {
  IRModule,
  BlockId,
  QualifiedName,
} from "./ir/types.js";
export type { SchemaBundle, AgentDefinition, JsonSchema } from "./ir/schema.js";

// ─── Agent def id (cross-module opaque) ────────────────────────────────────

export {
  encodeCoreAgentDefId,
  decodeCoreAgentDefId,
  encodeFfiAgentDefId,
  decodeFfiAgentDefId,
} from "./agent-def-id.js";
export type {
  AgentDefId,
  CoreAgentDefId,
  FfiAgentDefId,
} from "./agent-def-id.js";

// ─── 3 module + bus 抽象 ───────────────────────────────────────────────────

export type { Module } from "./module.js";
export { ExternalEventBus } from "./bus.js";
export type { RegisteredModule } from "./bus.js";
export type { ExternalEvent } from "./engine/event.js";

export { CoreModule } from "./modules/core.js";
export type {
  CoreCheckpointStore,
  CoreModuleOptions,
} from "./modules/core.js";

export { FfiModule } from "./modules/ffi.js";
export type { FfiModuleOptions } from "./modules/ffi.js";

export {
  API_ENDPOINT,
  CORE_ENDPOINT,
  FFI_ENDPOINT,
} from "./modules/endpoints.js";

// ─── Sidecar (FFI runner ↔ subprocess IPC) ─────────────────────────────────

export type {
  SidecarBundle,
  ParentToChild,
  ChildToParent,
} from "./sidecar/types.js";

export { InProcessSidecar } from "./sidecar/sidecar.js";
export type { Sidecar, InProcessHandler } from "./sidecar/sidecar.js";

export { SidecarManager } from "./sidecar/sidecar-manager.js";
export type {
  SidecarFactory,
  SidecarMessageHandler,
} from "./sidecar/sidecar-manager.js";

export type {
  FfiStore,
  FfiPendingDelegation,
  FfiPendingEscalation,
} from "./sidecar/store.js";
