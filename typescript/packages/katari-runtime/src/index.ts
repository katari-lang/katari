// Public API.
//
// Stage A keeps the *legacy* surface (machine/runtime classes) unchanged
// so the existing katari-api-server keeps building. The *new* engine is
// also exported, with a distinct prefix where the names would otherwise
// collide. Phase H of the refactor drops the legacy block once
// api-server has migrated.

// ───────────────────────────────────────────────────────────────────────────
// Legacy surface — unchanged from before the refactor.
// ───────────────────────────────────────────────────────────────────────────

export type { MachineState } from "./machine/machine.js";
export { createMachine, applyEvent } from "./machine/machine.js";
export { processQueue } from "./machine/runner.js";
export {
  Thread,
  ChildThread,
  APIThread,
  UserThread,
  PrimThread,
  RequestThread,
  ExternalThread,
  CtorThread,
  MatchThread,
  ForThread,
  HandleThread,
  TupleThread,
  ArrayThread,
} from "./machine/thread/index.js";
export type {
  CallId,
  QueueEvent,
  ThreadInit,
  ChildThreadInit,
  CreateThreadInit,
  Boundaries,
  BoundaryKey,
} from "./machine/thread/index.js";
export type { Value } from "./machine/value.js";
export type { Scope } from "./machine/scope.js";
export {
  collectGarbage,
  serializeScope,
  deserializeScope,
} from "./machine/scope.js";
export type { SerializedScope } from "./machine/scope.js";
export type {
  Endpoint,
  MachineEventPayload,
  MachineEvent,
} from "./machine/events.js";
export type {
  ThreadId,
  ScopeId,
  DelegationId,
  EscalationId,
} from "./machine/id.js";
export {
  createDelegationId,
  createThreadId,
  createScopeId,
} from "./machine/id.js";

export {
  RecoverableEngineError,
  EntryNotFoundError,
  IrrecoverableEngineError,
} from "./runtime/errors.js";
export { MachineHandle } from "./runtime/facade.js";
export {
  serializeMachine,
  deserializeMachine,
} from "./runtime/snapshot.js";
export type {
  MachineSnapshot,
  SerializedThread,
} from "./runtime/snapshot.js";
export {
  buildConsoleLogger,
  consoleLogger,
  noopLogger,
  type Logger,
  type LogLevel,
} from "./runtime/logger.js";

export type { IRModule, BlockId, QualifiedName } from "./ir/types.js";
export type { SchemaBundle, AgentDefinition, JsonSchema } from "./ir/schema.js";

// ───────────────────────────────────────────────────────────────────────────
// New engine surface — prefixed with `Engine` / `engine` where names
// would clash with the legacy entries above.
// ───────────────────────────────────────────────────────────────────────────

export { MachineHandle as EngineHandle } from "./facade.js";

export {
  applyEvent as engineApplyEvent,
  createState as createEngineState,
  CORE_ENDPOINT,
  endpoint,
  NULL_VALUE,
  literalToValue,
  isInternal,
  emptyResult,
  serialize as serializeEngineState,
  deserialize as deserializeEngineState,
  collectGarbage as engineCollectGarbage,
  shouldGc,
  LoggerTag,
} from "./engine/index.js";

export type {
  AskId,
  Value as EngineValue,
  Scope as EngineScope,
  AskKind,
  Event as EngineEvent,
  EventPayload as EngineEventPayload,
  ExternalEventPayload as EngineExternalPayload,
  InternalEventPayload as EngineInternalPayload,
  ModMap,
  Thread as EngineThread,
  ThreadKind,
  ThreadStatus,
  AskIdMap,
  UserThread as EngineUserThread,
  HandleThread as EngineHandleThread,
  ForThread as EngineForThread,
  MatchThread as EngineMatchThread,
  RequestThread as EngineRequestThread,
  ExternalThread as EngineExternalThread,
  PrimThread as EnginePrimThread,
  CtorThread as EngineCtorThread,
  TupleThread as EngineTupleThread,
  ArrayThread as EngineArrayThread,
  ChildRole,
  PendingAction,
  PostCancelAction,
  State as EngineState,
  Diff,
  EngineError,
  LogEntry,
  Result as EngineResult,
  Snapshot as EngineSnapshot,
} from "./engine/index.js";
