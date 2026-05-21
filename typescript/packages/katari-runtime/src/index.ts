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
  EntryNotFoundError,
  IrrecoverableEngineError,
  RecoverableEngineError,
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
  LogEntry,
  LogLevel,
  Logger,
  Result,
  Result as EngineResult,
  EngineCheckpoint,
} from "./engine/index.js";

// ─── IR + schema types (Haskell mirror) ────────────────────────────────────

export type {
  IRModule,
  BlockId,
  QualifiedName,
} from "./ir/types.js";
export type { SchemaBundle, AgentDefinition, JsonSchema } from "./ir/schema.js";
export type { Json } from "./json.js";

// ─── Raw ↔ Value codec (REST / sidecar / CLI boundary) ────────────────────

export {
  valueFromRaw,
  valueToRaw,
  RawValueDecodeError,
  CTOR_DISCRIMINATOR,
  CALLABLE_DISCRIMINATOR,
} from "./value-codec.js";
export type { RawValue } from "./value-codec.js";

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

export type { Sidecar } from "./sidecar/sidecar.js";

export { SubprocessSidecar } from "./sidecar/subprocess-sidecar.js";
export type { SubprocessSidecarOptions } from "./sidecar/subprocess-sidecar.js";

export { MockSidecar } from "./sidecar/mock-sidecar.js";
export type {
  MockAgentHandler,
  MockSidecarOptions,
} from "./sidecar/mock-sidecar.js";

export { loadSubprocessSidecar } from "./sidecar/bundle-loader.js";
export type { LoadSubprocessSidecarOptions } from "./sidecar/bundle-loader.js";

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
