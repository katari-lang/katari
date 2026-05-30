// Public API.
//
// All exports come from the new engine layer. Legacy `machine/` and
// `runtime/` modules were removed in Phase D — this file is the single
// source of truth for what `katari-api-server` (and any future host)
// imports.

// ─── Engine functions ──────────────────────────────────────────────────────

export {
  applyEvent,
  buildConsoleLogger,
  collectGarbage,
  consoleLogger,
  createDelegationId,
  createEscalationId,
  createScopeId,
  createState,
  createThreadId,
  deserialize,
  EntryNotFoundError,
  emptyResult,
  endpoint,
  IrrecoverableEngineError,
  inlineText,
  isBytesValue,
  isInternal,
  literalToValue,
  mkSecret,
  mkString,
  NULL_VALUE,
  noopLogger,
  RecoverableEngineError,
  serialize,
  shouldGc,
  tryInlineString,
} from "./engine/index.js";

// ─── Engine types ──────────────────────────────────────────────────────────

export type {
  AgentThread,
  ArrayThread,
  AskId,
  AskIdMap,
  AskKind,
  BytesRep,
  CallId,
  ChildRole,
  CtorThread,
  DelegateThread,
  DelegationId,
  Endpoint,
  EngineCheckpoint,
  EscalationId,
  Event,
  Event as EngineEvent,
  EventPayload,
  ExternalEventPayload,
  ForThread,
  HandleThread,
  InternalEventPayload,
  LogEntry,
  Logger,
  LogLevel,
  MatchThread,
  ModMap,
  PendingAction,
  PostCancelAction,
  PrimThread,
  RefModule,
  RefRep,
  RequestThread,
  Result,
  Result as EngineResult,
  Scope,
  Scope as EngineScope,
  ScopeId,
  State,
  State as EngineState,
  Thread,
  Thread as EngineThread,
  ThreadId,
  ThreadKind,
  ThreadStatus,
  TupleThread,
  UserThread,
  Value,
  Value as EngineValue,
} from "./engine/index.js";

// ─── Storage: value store (3-layer byte-sequence storage) ──────────────────

export { hashBytes, hashText } from "./storage/hash.js";
export type {
  CreateFileInput,
  EphemeralOwner,
  FileRecord,
  OpenInput,
  ProduceHandle,
  ProduceResult,
  PutInput,
  RefState,
  ValueRefState,
  ValueSemanticKind,
  ValueStore,
} from "./storage/value-store.js";
export { MAX_PRODUCE_BYTES } from "./storage/value-store.js";

// ─── IR + schema types (Haskell mirror) ────────────────────────────────────

export type { AgentDefinition, JsonSchema, SchemaBundle } from "./ir/schema.js";
export type {
  BlockId,
  IRModule,
  QualifiedName,
} from "./ir/types.js";
export type { Json } from "./json.js";

// ─── Raw ↔ Value codec (REST / sidecar / CLI boundary) ────────────────────

export type { RawValue } from "./value-codec.js";
export {
  CALLABLE_DISCRIMINATOR,
  CTOR_DISCRIMINATOR,
  RawValueDecodeError,
  SECRET_DISCRIMINATOR,
  valueFromRaw,
  valueToRaw,
} from "./value-codec.js";

// ─── Secret crypto + Value ↔ EncryptedValue (storage boundary) ────────────

export {
  decryptSecret,
  encryptSecret,
  resetKeyCacheForTesting,
  SecretCryptoError,
} from "./secret-crypto.js";
export type { EncryptedSecret, EncryptedValue } from "./value-secret-codec.js";
export {
  decryptValueRecord,
  decryptValueTree,
  encryptValueRecord,
  encryptValueTree,
  redactSecretsInEncrypted,
} from "./value-secret-codec.js";

// ─── Agent def id (cross-module opaque) ────────────────────────────────────

export type {
  AgentDefId,
  CoreAgentDefId,
  FfiAgentDefId,
} from "./agent-def-id.js";
export {
  decodeCoreAgentDefId,
  decodeFfiAgentDefId,
  encodeCoreAgentDefId,
  encodeFfiAgentDefId,
} from "./agent-def-id.js";

// ─── 3-module + bus abstraction ────────────────────────────────────────────

export type { RegisteredModule } from "./bus.js";
export { ExternalEventBus } from "./bus.js";
export type { ExternalEvent } from "./engine/event.js";
export type { Module } from "./module.js";
export type {
  CoreCheckpointStore,
  CoreModuleOptions,
} from "./modules/core.js";
export { CoreModule } from "./modules/core.js";
export type {
  DelegationStore,
  DelegationStoreRow,
} from "./modules/delegation-store.js";
export { NULL_DELEGATION_STORE } from "./modules/delegation-store.js";
export {
  API_ENDPOINT,
  CORE_ENDPOINT,
  ENV_ENDPOINT,
  FFI_ENDPOINT,
} from "./modules/endpoints.js";
export type { EnvModuleOptions } from "./modules/env.js";

export { EnvModule } from "./modules/env.js";
export type { FfiModuleOptions } from "./modules/ffi.js";
export { FfiModule } from "./modules/ffi.js";

// ─── Sidecar (FFI runner ↔ subprocess IPC) ─────────────────────────────────

export type { LoadSubprocessSidecarOptions } from "./sidecar/bundle-loader.js";
export { loadSubprocessSidecar } from "./sidecar/bundle-loader.js";
export type { EnvEntry, EnvStore } from "./sidecar/env-store.js";
export type {
  MockAgentHandler,
  MockSidecarOptions,
} from "./sidecar/mock-sidecar.js";

export { MockSidecar } from "./sidecar/mock-sidecar.js";
export type { Sidecar } from "./sidecar/sidecar.js";
export type {
  SidecarFactory,
  SidecarMessageHandler,
} from "./sidecar/sidecar-manager.js";
export { SidecarManager } from "./sidecar/sidecar-manager.js";
export type {
  FfiPendingDelegation,
  FfiPendingEscalation,
  FfiStore,
} from "./sidecar/store.js";
export type { SubprocessSidecarOptions } from "./sidecar/subprocess-sidecar.js";
export { SubprocessSidecar } from "./sidecar/subprocess-sidecar.js";
export type {
  ChildToParent,
  ParentToChild,
  SidecarBundle,
} from "./sidecar/types.js";

// ─── Orchestrator ─────────────────────────────────────────────────────────

export type {
  ApiLikeModule,
  OrchestratorProjectId,
  OrchestratorSnapshotId,
  OrchestratorStorage,
  RecoveryOptions,
  ResolvedSnapshot,
  TickContext,
  TickModules,
  TickModulesFactory,
} from "./orchestrator/index.js";
export {
  NoSnapshotForProject,
  Orchestrator,
  recoverOnBoot,
  SnapshotNotFound,
} from "./orchestrator/index.js";
