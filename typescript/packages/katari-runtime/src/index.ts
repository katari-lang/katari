// Public API — re-export machine types
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
export { createDelegationId, createThreadId, createScopeId } from "./machine/id.js";

// Runtime layer (pure facade, snapshot, logger).
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
  consoleLogger,
  noopLogger,
  type Logger,
  type LogLevel,
} from "./runtime/logger.js";

// IR types frequently consumed by api-server.
export type { IRModule, BlockId, QualifiedName } from "./ir/types.js";
export type { SchemaBundle, AgentDefinition, JsonSchema } from "./ir/schema.js";
