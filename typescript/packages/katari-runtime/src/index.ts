// Public API — re-export machine types
export type { MachineState } from "./machine/machine.js";
export type {
  Thread,
  ThreadBase,
  ThreadStatus,
  HandlerEntry,
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
export type { Scope, MemoryCell, MemoryKey } from "./machine/scope.js";
export type { InboundEvent, OutboundEvent, InternalEvent } from "./machine/events.js";
export type { ThreadId, ScopeId, DelegationId, EscalationId } from "./machine/id.js";
