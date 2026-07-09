// The sequence operation executor: runs a `SequenceThread`'s operations one at a time from its cursor.
// Value-producing ops (literals, records, tuples, field reads, pattern binds, closures, agent refs,
// generic application) run synchronously and advance the cursor; the four control-transfer ops suspend
// the thread:
//   - `call` enters a structural node in this instance (an internal child thread);
//   - `delegate` summons a child instance (an outbound external `delegate`, proxied by a DelegateThread);
//   - `exit` / `continue` raise a control ask (return / break / next) up the thread tree.
// The cursor is advanced past a suspending op only when its answer lands (the thread's callAck / askAck),
// so a recovered turn resumes exactly where it left off.

import type {
  CalleeReference,
  ContinueOperation,
  DelegateOperation,
  ExitOperation,
  Operation,
  VariableId,
} from "@katari-lang/types";
import type { AskKind, ModifierMap } from "../event/types.js";
import { newDelegationId, type ScopeId } from "../ids.js";
import { literalToValue } from "../value/codec.js";
import { liftPrivacy } from "../value/privacy.js";
import type { GenericSubstitution, Value } from "../value/types.js";
import { CALL_AGENT_NAME, completeThread, raiseThrow } from "./common.js";
import type { StepContext } from "./context.js";
import { type DispatchResult, dispatchCallable } from "./dynamic-dispatch.js";
import { matchPattern } from "./pattern.js";
import { readVariable, writeVariable } from "./scope.js";
import { getBlock, spawnThread } from "./spawn.js";
import { allocateAskId, allocateCallId, allocateThreadId } from "./store.js";
import { errorData } from "./throw-signal.js";
import type { SequenceThread, Thread } from "./types.js";

const NULL_VALUE: Value = { kind: "null" };

/** The domain error ctor a failed dynamic dispatch throws (`prelude/reflection.ktr` declares it). */
const CALL_ERROR = "prelude.reflection.call_error";

/**
 * Drive a sequence thread from its cursor: run synchronous ops in a tight loop, stop at the first op
 * that suspends, and — if the operations run out — complete with the block's result value (or null).
 */
export function runSequence(ctx: StepContext, thread: SequenceThread): void {
  const block = getBlock(ctx, thread.blockId);
  if (block.kind !== "sequence") {
    throw new Error(`thread ${thread.id} runs a non-sequence block`);
  }
  while (thread.cursor < block.operations.length) {
    const operation = block.operations[thread.cursor];
    if (operation === undefined) break;
    if (!executeOperation(ctx, thread, operation)) {
      return; // suspended on a call / delegate / control transfer
    }
    thread.cursor += 1;
  }
  completeThread(ctx, thread, readResult(ctx, thread.scopeId, block.result));
}

/** Run one operation. Returns `true` if it completed synchronously (advance the cursor), `false` if it
 *  suspended the thread (its cursor advances later, when the answer lands). */
function executeOperation(ctx: StepContext, thread: SequenceThread, operation: Operation): boolean {
  const scope = thread.scopeId;
  switch (operation.kind) {
    case "loadLiteral":
      writeVariable(ctx.store, scope, operation.output, literalToValue(operation.value));
      return true;
    case "loadAgent":
      writeVariable(ctx.store, scope, operation.output, {
        kind: "agent",
        name: operation.name,
        snapshot: ctx.ir.snapshot,
      });
      return true;
    case "makeClosure":
      // Capture the current scope by id; resolving the closure spawns its block with this as parent.
      writeVariable(ctx.store, scope, operation.output, {
        kind: "closure",
        blockId: operation.agent,
        scopeId: scope,
        snapshot: ctx.ir.snapshot,
        module: ctx.ir.module,
      });
      return true;
    case "makeRecord": {
      const fields: Record<string, Value> = {};
      for (const [name, variable] of operation.entries) {
        fields[name] = requireVariable(ctx, scope, variable);
      }
      writeVariable(ctx.store, scope, operation.output, { kind: "record", fields });
      return true;
    }
    case "makeTuple": {
      const elements = operation.elements.map((variable) => requireVariable(ctx, scope, variable));
      writeVariable(ctx.store, scope, operation.output, { kind: "array", elements });
      return true;
    }
    case "getField": {
      const source = requireVariable(ctx, scope, operation.source);
      const field =
        source.kind === "record" ? (source.fields[operation.field] ?? NULL_VALUE) : NULL_VALUE;
      // Reading through a private handle yields a private value (the comonad's field projection), so the
      // read inherits the container's marker on top of the field's own.
      writeVariable(ctx.store, scope, operation.output, liftPrivacy(source.private, field));
      return true;
    }
    case "bindPattern":
      // An irrefutable `let` destructure — exhaustiveness is the checker's guarantee, so binds always.
      matchPattern(ctx, scope, operation.pattern, requireVariable(ctx, scope, operation.source));
      return true;
    case "applyGenerics": {
      const substitution: GenericSubstitution = {};
      for (const [name, schema] of operation.generics) {
        substitution[name] = schema;
      }
      writeVariable(
        ctx.store,
        scope,
        operation.output,
        withGenerics(requireVariable(ctx, scope, operation.source), substitution),
      );
      return true;
    }
    case "call":
      enterCall(ctx, thread, operation.target, operation.output);
      return false;
    case "delegate":
      enterDelegate(ctx, thread, operation);
      return false;
    case "exit":
      raiseExit(ctx, thread, operation);
      return false;
    case "continue":
      raiseContinue(ctx, thread, operation);
      return false;
  }
}

/** Enter a structural node (match / for / handle / parallel) as an in-instance child, awaiting its value. */
function enterCall(
  ctx: StepContext,
  thread: SequenceThread,
  target: number,
  output: number | null,
): void {
  const callId = allocateCallId(ctx.instance);
  thread.pending = { callId, output };
  spawnThread(ctx, {
    parent: thread.id,
    parentCallId: callId,
    parentScopeId: thread.scopeId,
    blockId: target,
    parameters: {},
  });
}

/** Summon a child instance: resolve the callee, spawn the proxy DelegateThread, emit the outbound delegate. */
function enterDelegate(
  ctx: StepContext,
  thread: SequenceThread,
  operation: DelegateOperation,
): void {
  const resolved = resolveCallee(ctx, thread.scopeId, operation.target, operation.argument);
  if ("throwPayload" in resolved) {
    // The dynamic dispatch failed before anything ran — raise the catchable `reflection.call_error`
    // (the thread suspends on the ask; a handler breaks out, or the run fails with the payload).
    raiseThrow(ctx, thread, resolved.throwPayload);
    return;
  }
  // The delegate merges two substitution sources: what the callee VALUE carries (an explicit
  // `callee[T]` applied earlier via `applyGenerics`) and what THIS call site instantiated (inferred
  // by the checker, stamped on the operation). They are disjoint in practice — an already-applied
  // callee is no longer generic at the call — but the call site wins on overlap (it is the more
  // specific record).
  let generics = resolved.generics;
  if (operation.generics !== undefined && operation.generics.length > 0) {
    const merged: GenericSubstitution = { ...(generics ?? {}) };
    for (const [name, schema] of operation.generics) {
      merged[name] = schema;
    }
    generics = merged;
  }
  const callId = allocateCallId(ctx.instance);
  thread.pending = { callId, output: operation.output };

  const delegationId = newDelegationId();
  const proxyId = allocateThreadId(ctx.instance);
  ctx.instance.threads[proxyId] = {
    id: proxyId,
    parent: thread.id,
    parentCallId: callId,
    scopeId: thread.scopeId,
    blockId: thread.blockId,
    status: "running",
    forwardRoutes: {},
    kind: "delegate",
    delegationId,
    relays: {},
  };
  // The delegate routes to the resolved executor: `core` for a compiled callable, the tool's own
  // reactor for a reactor-backed one (a `tool` value resolves to an `external` target + context, so
  // its call goes straight to the reactor — no wrapper hop). Compiled `external agent` calls still
  // emit their own `delegate` from `createExternal`; this site handles callee references and values.
  ctx.emit(
    {
      kind: "delegate",
      delegation: delegationId,
      target: resolved.target,
      argument: resolved.argument,
      ...(generics !== undefined ? { generics } : {}),
    },
    resolved.to,
  );
}

/** Resolve a callee reference + its argument variable into the delegate it stands for. Dynamic dispatch
 *  is resolved HERE, at the emit site: a callee VALUE (and `reflection.call_agent`, whose argument
 *  carries the callable) goes through the shared `dispatchCallable`, so a tool's runtime schema is
 *  validated before anything is emitted and the delegate routes straight to its executor. A dispatch
 *  failure (a non-callable value, a tool schema violation) is the anticipated dynamic-dispatch error:
 *  it resolves to `{ throwPayload }`, which `enterDelegate` raises as a catchable
 *  `reflection.call_error` instead of delegating. */
function resolveCallee(
  ctx: StepContext,
  scope: ScopeId,
  callee: CalleeReference,
  argumentVariable: VariableId,
): DispatchResult | { throwPayload: Value } {
  const argument = requireVariable(ctx, scope, argumentVariable);
  if (callee.kind === "name" && callee.name !== CALL_AGENT_NAME) {
    return {
      target: { kind: "named", name: callee.name, snapshot: ctx.ir.snapshot },
      argument,
      to: "core",
    };
  }
  // The callable being dispatched: the callee value itself, or — for a `call_agent(target, args)`
  // call — the callable its argument record carries. `call_agent` may nest (a tool list holding
  // `call_agent` itself), so peeling loops.
  let callable: Value;
  let args: Value | null;
  if (callee.kind === "name") {
    const peeled = peelCallAgent(argument);
    if ("error" in peeled) return { throwPayload: errorData(CALL_ERROR, peeled.error) };
    callable = peeled.callable;
    args = peeled.args;
  } else {
    callable = requireVariable(ctx, scope, callee.variable);
    args = argument;
  }
  while (callable.kind === "agent" && String(callable.name) === CALL_AGENT_NAME) {
    const peeled = peelCallAgent(args);
    if ("error" in peeled) return { throwPayload: errorData(CALL_ERROR, peeled.error) };
    callable = peeled.callable;
    args = peeled.args;
  }
  const dispatched = dispatchCallable(callable, args);
  if ("error" in dispatched) {
    return { throwPayload: errorData(CALL_ERROR, dispatched.error) };
  }
  return dispatched;
}

/** Read a `call_agent` argument record into the callable + args it carries. */
function peelCallAgent(
  argument: Value | null,
): { callable: Value; args: Value | null } | { error: string } {
  if (argument === null || argument.kind !== "record") {
    return { error: "call_agent: expected an argument record carrying { target, args }" };
  }
  const callable = argument.fields.target;
  if (callable === undefined) {
    return { error: 'call_agent: the argument record is missing "target"' };
  }
  return { callable, args: argument.fields.args ?? null };
}

/** Raise a `return` / `break` / `break-for` exit, by the role of the block it targets. */
function raiseExit(ctx: StepContext, thread: SequenceThread, operation: ExitOperation): void {
  const target = getBlock(ctx, operation.target);
  const value = requireVariable(ctx, thread.scopeId, operation.value);
  const ask: AskKind =
    target.kind === "agent"
      ? { kind: "return", value, target: operation.target }
      : target.kind === "handle"
        ? { kind: "break", value, target: operation.target }
        : target.kind === "for"
          ? { kind: "break-for", value, target: operation.target }
          : unreachableExit(operation.target);
  raiseControlAsk(ctx, thread, ask);
}

/** Raise a `next` / `next-for` continue, by the role of the block it targets, with its state modifiers. */
function raiseContinue(
  ctx: StepContext,
  thread: SequenceThread,
  operation: ContinueOperation,
): void {
  const target = getBlock(ctx, operation.target);
  const value =
    operation.value !== null ? requireVariable(ctx, thread.scopeId, operation.value) : NULL_VALUE;
  const modifiers: ModifierMap = {};
  for (const [stateVariable, valueVariable] of operation.modifiers) {
    modifiers[stateVariable] = requireVariable(ctx, thread.scopeId, valueVariable);
  }
  const ask: AskKind =
    target.kind === "handle"
      ? { kind: "next", value, modifiers, target: operation.target }
      : target.kind === "for"
        ? { kind: "next-for", value, modifiers, target: operation.target }
        : unreachableContinue(operation.target);
  raiseControlAsk(ctx, thread, ask);
}

/** Send a one-way control ask up to the parent (control asks are consumed by their target, never the asker). */
function raiseControlAsk(ctx: StepContext, thread: Thread, ask: AskKind): void {
  if (thread.parent === null) {
    throw new Error("a control transfer reached the instance root with no enclosing target");
  }
  const askId = allocateAskId(ctx.instance);
  ctx.enqueue({ kind: "ask", target: thread.parent, from: thread.id, askId, ask });
}

/** Read a block's result variable, or `null` when the block produces no value. */
function readResult(ctx: StepContext, scope: ScopeId, result: number | null): Value {
  if (result === null) return NULL_VALUE;
  return readVariable(ctx.store, scope, result) ?? NULL_VALUE;
}

/** Read a variable that must be bound (an op reading its own input); an absence is a lowering bug. */
function requireVariable(ctx: StepContext, scope: ScopeId, variable: number): Value {
  const value = readVariable(ctx.store, scope, variable);
  if (value === undefined) {
    throw new Error(`variable ${variable} is unbound in scope ${scope}`);
  }
  return value;
}

/** Attach a generic substitution to a callable value (for get_metadata schema specialisation). */
function withGenerics(value: Value, generics: GenericSubstitution): Value {
  if (value.kind === "closure" || value.kind === "agent") {
    return { ...value, generics };
  }
  throw new Error(`applyGenerics target is not a callable value (kind "${value.kind}")`);
}

function unreachableExit(target: number): never {
  throw new Error(`exit targets block ${target}, which is not an agent / handle / for`);
}

function unreachableContinue(target: number): never {
  throw new Error(`continue targets block ${target}, which is not a handle / for`);
}
