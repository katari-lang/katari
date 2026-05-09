// Public API.
//
// All exports come from the new engine layer. Legacy `machine/` and
// `runtime/` modules were removed in Phase D — this file is the single
// source of truth for what `katari-api-server` (and any future host)
// imports.

// ─── Facade ────────────────────────────────────────────────────────────────

export { MachineHandle as EngineHandle } from "./facade.js";
// Provide the legacy `MachineHandle` alias for callers that haven't
// renamed yet. Both names refer to the same class.
export { MachineHandle } from "./facade.js";

// ─── Engine functions ──────────────────────────────────────────────────────

export {
  applyEvent,
  createState,
  CORE_ENDPOINT,
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
  Snapshot,
  Snapshot as EngineSnapshot,
  Snapshot as MachineSnapshot,
} from "./engine/index.js";

// ─── IR + schema types (Haskell mirror) ────────────────────────────────────

export type {
  IRModule,
  BlockId,
  QualifiedName,
} from "./ir/types.js";
export type { SchemaBundle, AgentDefinition, JsonSchema } from "./ir/schema.js";
