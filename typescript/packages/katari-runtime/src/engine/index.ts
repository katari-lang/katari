// Engine layer barrel — internal use only. The public surface is exposed
// from `katari-runtime/src/index.ts`. Phase A only re-exports the type
// scaffolding; runtime functions land as the implementation progresses.

export { applyEvent, createState } from "./apply.js";
export type { Endpoint } from "./endpoint.js";
export { CORE_ENDPOINT, endpoint } from "./endpoint.js";
export type { EngineError } from "./errors.js";
export {
  EntryNotFoundError,
  IrrecoverableEngineError,
  RecoverableEngineError,
} from "./errors.js";
export type {
  AskKind,
  Event,
  EventPayload,
  ExternalEventPayload,
  InternalEventPayload,
  ModMap,
} from "./event.js";
export { isInternal } from "./event.js";
export { collectGarbage, shouldGc } from "./gc.js";
export type {
  AskId,
  CallId,
  DelegationId,
  EntityId,
  EscalationId,
  ScopeId,
  ThreadId,
} from "./id.js";
export {
  createDelegationId,
  createEntityId,
  createEscalationId,
  createScopeId,
  createThreadId,
} from "./id.js";
export type { LogEntry, Logger, LogLevel } from "./logger.js";
export { buildConsoleLogger, consoleLogger, noopLogger } from "./logger.js";
export type { Result } from "./result.js";
export { emptyResult } from "./result.js";
export type { Scope } from "./scope.js";
export type {
  ActiveShard,
  LoadedShard,
  ProjectIndex,
  ProjectIndexStore,
  ShardId,
  ShardStatus,
  ShardStore,
} from "./shard.js";
export { emptyProjectIndex } from "./shard.js";
export type { EncryptedEngineCheckpoint, EngineCheckpoint } from "./snapshot.js";
export { deserialize, serialize } from "./snapshot.js";
export type { State } from "./state.js";
export type {
  AgentThread,
  AskIdMap,
  ChildRole,
  CtorThread,
  DelegateThread,
  ForThread,
  HandleThread,
  MatchThread,
  PendingAction,
  PostCancelAction,
  PrimThread,
  RequestThread,
  Thread,
  ThreadKind,
  ThreadStatus,
  TupleThread,
  UserThread,
} from "./thread/types.js";
export type { BytesRep, RefHandle, RefModule, RefRep, Value } from "./value.js";
export {
  bytesContentEqual,
  bytesEqualsText,
  bytesHash,
  collectRefs,
  inlineText,
  isBytesValue,
  literalToValue,
  mkRecord,
  mkSecret,
  mkString,
  NULL_VALUE,
  recordEntries,
  tryInlineString,
} from "./value.js";
