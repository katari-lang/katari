import type { HandleBlock, ReqId, VarId } from "../../ir/types.js";
import type { ThreadId } from "../id.js";
import type { Value } from "../value.js";
import type { HandlerEntry, ThreadBase } from "./types.js";

/**
 * Executes a BlockHandle (effect handler scope).
 *
 * Creates a body thread whose inheritedHandlers include this handle's ownHandlers.
 * When the body (or its descendants) performs a request matching ownHandlers,
 * spawns a handler body thread in the handle's scope.
 *
 * Handler body results:
 * - next + modifiers → update state vars, resume body.
 * - break → cancel body, transition to then or done.
 *
 * Scope rule: handler body's scope parent = this handle's scope (state var access).
 * Handler body's inheritedHandlers = this handle's inheritedHandlers (not ownHandlers → no recursion).
 */
export type HandleThread = ThreadBase & {
  kind: "handle";
  handleBlock: HandleBlock;
  phase:
    | { kind: "bodyRunning"; bodyThreadId: ThreadId }
    | { kind: "runningHandler"; handlerThreadId: ThreadId }
    | { kind: "runningThen"; childThreadId: ThreadId }
    | { kind: "broken"; value: Value };
  /** Handlers registered by this handle block (reqId → entry). */
  ownHandlers: Map<ReqId, HandlerEntry>;
  /** Current version of each state variable (incremented on handler next). */
  stateVersions: Map<VarId, number>;
};
