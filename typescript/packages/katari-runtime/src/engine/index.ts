// Engine layer barrel — internal use only. The public surface is exposed
// from `katari-runtime/src/index.ts`. Phase A only re-exports the type
// scaffolding; runtime functions land as the implementation progresses.

export type { Endpoint } from "./endpoint.js";
export { CORE_ENDPOINT, endpoint } from "./endpoint.js";

export type {
  AskId,
  CallId,
  DelegationId,
  EscalationId,
  ScopeId,
  ThreadId,
} from "./id.js";
export {
  createDelegationId,
  createEscalationId,
  createScopeId,
  createThreadId,
} from "./id.js";

export type { Value } from "./value.js";
export { NULL_VALUE, literalToValue } from "./value.js";

export type { Scope } from "./scope.js";

export type {
  AskKind,
  Event,
  EventPayload,
  ExternalEventPayload,
  InternalEventPayload,
  ModMap,
} from "./event.js";
export { isInternal } from "./event.js";

export type {
  Thread,
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
} from "./thread/types.js";

export type { State } from "./state.js";

export type { Diff } from "./diff.js";

export type { EngineError } from "./errors.js";
export {
  RecoverableEngineError,
  IrrecoverableEngineError,
  EntryNotFoundError,
} from "./errors.js";

export type { LogEntry, LogLevel, Logger } from "./logger.js";
export { LoggerTag, buildConsoleLogger, consoleLogger, noopLogger } from "./logger.js";

export type { Result } from "./result.js";
export { emptyResult } from "./result.js";

export { applyEvent, createState } from "./apply.js";

export type { Snapshot } from "./snapshot.js";
export { serialize, deserialize } from "./snapshot.js";

export { collectGarbage, shouldGc } from "./gc.js";
