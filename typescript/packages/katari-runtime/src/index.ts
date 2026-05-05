// Public API — re-export machine types
export type { MachineState } from "./machine/machine.js";
export { createMachine, applyEvent } from "./machine/machine.js";
export { processQueue } from "./machine/runner.js";
export type {
  Thread,
  ThreadBase,
  CallId,
  QueueEvent,
  CreateThreadInit,
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
export type { Value } from "./machine/value.js";
export type { Scope } from "./machine/scope.js";
export { collectGarbage } from "./machine/scope.js";
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
