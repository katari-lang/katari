// Per-thread-kind handlers for the six internal events (create / callAck / cancel / cancelAck / ask /
// askAck), dispatched by `thread.kind`. This is the intra-instance core: structural nodes (match / for /
// parallel), the agent root, leaf bodies (primitive / construct), and the delegate proxy's in-instance
// side. The cross-instance halves — the agent's escalation of an escaping ask, the handle's request
// dispatch, the delegate proxy's escalate relay and terminate, and the external (FFI) leaf — are wired
// in the instance / FFI layers; here they raise a clear "not in this layer yet" error.

import type { Block } from "@katari-lang/types";
import type { AskKind } from "../event/types.js";
import type { AskId, CallId, ThreadId } from "../ids.js";
import { literalToValue } from "../value/codec.js";
import type { Value } from "../value/types.js";
import { childrenOf, completeThread, dropDescendants, proxyAsk, removeThread } from "./common.js";
import type { StepContext } from "./context.js";
import { runSequence } from "./operations.js";
import { matchPattern } from "./pattern.js";
import { readVariable, writeVariable } from "./scope.js";
import { getBlock, spawnThread } from "./spawn.js";
import { allocateCallId } from "./store.js";
import type {
  AgentThread,
  ForThread,
  MatchThread,
  ParallelThread,
  SequenceThread,
  Thread,
} from "./types.js";

const NULL_VALUE: Value = { kind: "null" };

// ─── create ───────────────────────────────────────────────────────────────────────────────────

/** Run a freshly-spawned thread's first step. Async only for the primitive leaf (it awaits its prim). */
export async function dispatchCreate(ctx: StepContext, thread: Thread): Promise<void> {
  switch (thread.kind) {
    case "agent":
      createAgent(ctx, thread);
      return;
    case "sequence":
      runSequence(ctx, thread);
      return;
    case "primitive":
      await createPrimitive(ctx, thread);
      return;
    case "construct":
      createConstruct(ctx, thread);
      return;
    case "match":
      createMatch(ctx, thread);
      return;
    case "parallel":
      createParallel(ctx, thread);
      return;
    case "for":
      createFor(ctx, thread);
      return;
    case "delegate":
      // The outbound delegate was emitted by the spawning op; the proxy just waits for its delegateAck.
      return;
    case "handle":
    case "request":
    case "external":
      throw notInThisLayer(thread.kind);
  }
}

// ─── callAck (a child completed; deliver its value) ─────────────────────────────────────────────

export function dispatchCallAck(
  ctx: StepContext,
  thread: Thread,
  callId: CallId,
  value: Value,
): void {
  switch (thread.kind) {
    case "agent":
      completeInstance(ctx, value);
      return;
    case "sequence":
      resumeSequence(ctx, thread, callId, value);
      return;
    case "match":
      // The chosen arm's value is the match's value.
      completeThread(ctx, thread, value);
      return;
    case "parallel":
      collectParallel(ctx, thread, callId, value);
      return;
    case "for":
      if (thread.thenPending !== null && thread.thenPending === callId) {
        // The then-clause finished; its value is the loop's value.
        completeThread(ctx, thread, value);
        return;
      }
      // A body iteration fell through (implicit `next` with its result value); no state change.
      collectIteration(ctx, thread, callId, value, undefined);
      return;
    case "delegate":
    case "handle":
    case "primitive":
    case "construct":
    case "request":
    case "external":
      throw new Error(`thread kind "${thread.kind}" does not expect a callAck`);
  }
}

// ─── ask (a child raised a control / request ask) ───────────────────────────────────────────────

export function dispatchAsk(
  ctx: StepContext,
  thread: Thread,
  from: ThreadId,
  askId: AskId,
  ask: AskKind,
): void {
  switch (thread.kind) {
    case "agent":
      agentAsk(ctx, thread, from, askId, ask);
      return;
    case "for":
      forAsk(ctx, thread, from, askId, ask);
      return;
    case "sequence":
    case "match":
    case "parallel":
    case "delegate":
      // None of these is a control target or a request handler: bubble every ask up unchanged.
      proxyAsk(ctx, thread, ask, from, askId);
      return;
    case "handle":
    case "primitive":
    case "construct":
    case "request":
    case "external":
      throw notInThisLayer(thread.kind);
  }
}

// ─── askAck (an answered ask resumes its asker) ─────────────────────────────────────────────────

// In this layer no thread is a genuine `request` asker (request leaves are wired with the effect system),
// so a direct askAck — one not consumed by a proxy continuation in the drive loop — is always a bug here.
export function dispatchAskAck(
  _ctx: StepContext,
  thread: Thread,
  askId: AskId,
  _value: Value,
): void {
  throw new Error(`thread kind "${thread.kind}" did not expect a direct askAck (askId ${askId})`);
}

// ─── cancel / cancelAck (subtree teardown) ──────────────────────────────────────────────────────

export function dispatchCancel(ctx: StepContext, thread: Thread): void {
  // A delegate child owns a live child instance; tearing it down is the instance layer's terminate.
  if (thread.kind === "delegate" || thread.kind === "external") {
    throw notInThisLayer(thread.kind);
  }
  dropDescendants(ctx, thread.id);
  if (thread.parent !== null && thread.parentCallId !== null) {
    ctx.enqueue({ kind: "cancelAck", target: thread.parent, callId: thread.parentCallId });
  }
  removeThread(ctx, thread.id);
}

export function dispatchCancelAck(_ctx: StepContext, thread: Thread, callId: CallId): void {
  // The synchronous subtree drop above does not await child acks yet; the async cancel/terminate
  // protocol (needed once delegate children must terminate) lands with the instance layer.
  throw new Error(`unexpected cancelAck for thread ${thread.id} (callId ${callId})`);
}

// ─── agent root ─────────────────────────────────────────────────────────────────────────────────

function createAgent(ctx: StepContext, thread: AgentThread): void {
  const agentBlock = getBlock(ctx, thread.blockId);
  if (agentBlock.kind !== "agent") {
    throw new Error(`instance root ${thread.id} is not an agent block`);
  }
  // Apply defaults: fill any omitted optional parameter on the argument record before the body runs.
  const argument = applyDefaults(ctx.instance.argument, agentBlock);
  const callId = allocateCallId(ctx.instance);
  thread.pending = { callId, output: null };
  spawnThread(ctx, {
    parent: thread.id,
    parentCallId: callId,
    parentScopeId: thread.scopeId,
    blockId: agentBlock.body,
    parameters: { parameter: argument },
  });
}

function agentAsk(
  ctx: StepContext,
  thread: AgentThread,
  _from: ThreadId,
  _askId: AskId,
  ask: AskKind,
): void {
  if (ask.kind === "return" && ask.target === thread.blockId) {
    // The body returned: unwind it and complete the instance with the returned value.
    completeInstance(ctx, ask.value);
    return;
  }
  // A request, or a control ask targeting a lexical ancestor in a parent instance, escapes here as an
  // outbound escalate — wired in the instance layer.
  throw notInThisLayer("agent (escalation)");
}

/** Complete the running instance with `value`: tear down its threads and emit the delegateAck. The full
 *  instance teardown (scopes, ascent, self-delete) lands with the instance layer; here we ack the caller. */
function completeInstance(ctx: StepContext, value: Value): void {
  const delegationId = ctx.instance.delegationId;
  if (delegationId !== null) {
    ctx.emit({ kind: "delegateAck", delegation: delegationId, value });
  }
  ctx.instance.threads = {};
}

/** Fill omitted optional parameters on the argument record from the agent block's `defaults`. */
function applyDefaults(
  argument: Value | null,
  agentBlock: Extract<Block, { kind: "agent" }>,
): Value {
  const record: Value =
    argument !== null && argument.kind === "record" ? argument : { kind: "record", fields: {} };
  const defaults = agentBlock.defaults;
  if (Object.keys(defaults).length === 0) return record;
  const fields = { ...record.fields };
  for (const [name, literal] of Object.entries(defaults)) {
    if (!(name in fields)) {
      fields[name] = literalToValue(literal);
    }
  }
  return { kind: "record", fields };
}

// ─── sequence ───────────────────────────────────────────────────────────────────────────────────

function resumeSequence(
  ctx: StepContext,
  thread: SequenceThread,
  callId: CallId,
  value: Value,
): void {
  if (thread.pending === null || thread.pending.callId !== callId) {
    throw new Error(`sequence ${thread.id} got an unexpected callAck (callId ${callId})`);
  }
  if (thread.pending.output !== null) {
    writeVariable(ctx.store, thread.scopeId, thread.pending.output, value);
  }
  thread.pending = null;
  thread.cursor += 1;
  runSequence(ctx, thread);
}

// ─── primitive / construct leaves ───────────────────────────────────────────────────────────────

async function createPrimitive(ctx: StepContext, thread: Thread): Promise<void> {
  const block = getBlock(ctx, thread.blockId);
  if (block.kind !== "primitive") throw new Error(`thread ${thread.id} is not a primitive block`);
  const argument = readVariable(ctx.store, thread.scopeId, block.input) ?? NULL_VALUE;
  const value = await ctx.prims.run(block.name, argument);
  completeThread(ctx, thread, value);
}

function createConstruct(ctx: StepContext, thread: Thread): void {
  const block = getBlock(ctx, thread.blockId);
  if (block.kind !== "construct") throw new Error(`thread ${thread.id} is not a construct block`);
  const argument = readVariable(ctx.store, thread.scopeId, block.input) ?? NULL_VALUE;
  const fields = argument.kind === "record" ? argument.fields : {};
  completeThread(ctx, thread, { kind: "record", fields, ctor: block.name });
}

// ─── match ──────────────────────────────────────────────────────────────────────────────────────

function createMatch(ctx: StepContext, thread: MatchThread): void {
  const block = getBlock(ctx, thread.blockId);
  if (block.kind !== "match") throw new Error(`thread ${thread.id} is not a match block`);
  const subject = readVariable(ctx.store, thread.scopeId, block.subject) ?? NULL_VALUE;
  for (const arm of block.arms) {
    if (matchPattern(ctx, thread.scopeId, arm.pattern, subject)) {
      enterArm(ctx, thread, arm.body);
      return;
    }
  }
  if (block.fallback !== null) {
    enterArm(ctx, thread, block.fallback);
    return;
  }
  throw new Error(`non-exhaustive match in thread ${thread.id}`);
}

function enterArm(ctx: StepContext, thread: MatchThread, body: number): void {
  const callId = allocateCallId(ctx.instance);
  thread.pending = { callId, output: null };
  spawnThread(ctx, {
    parent: thread.id,
    parentCallId: callId,
    parentScopeId: thread.scopeId,
    blockId: body,
    parameters: {},
  });
}

// ─── parallel ─────────────────────────────────────────────────────────────────────────────────

function createParallel(ctx: StepContext, thread: ParallelThread): void {
  const block = getBlock(ctx, thread.blockId);
  if (block.kind !== "parallel") throw new Error(`thread ${thread.id} is not a parallel block`);
  if (block.elements.length === 0) {
    completeThread(ctx, thread, { kind: "array", elements: [] });
    return;
  }
  block.elements.forEach((element, index) => {
    const callId = allocateCallId(ctx.instance);
    thread.pending[index] = callId;
    spawnThread(ctx, {
      parent: thread.id,
      parentCallId: callId,
      parentScopeId: thread.scopeId,
      blockId: element,
      parameters: {},
    });
  });
}

function collectParallel(
  ctx: StepContext,
  thread: ParallelThread,
  callId: CallId,
  value: Value,
): void {
  const index = indexOfCall(thread.pending, callId);
  thread.collected[index] = value;
  delete thread.pending[index];
  if (Object.keys(thread.pending).length === 0) {
    completeThread(ctx, thread, materializeOrdered(thread.collected));
  }
}

// ─── for (mapping loop) ─────────────────────────────────────────────────────────────────────────

function createFor(ctx: StepContext, thread: ForThread): void {
  const block = getBlock(ctx, thread.blockId);
  if (block.kind !== "for") throw new Error(`thread ${thread.id} is not a for block`);
  const source = readVariable(ctx.store, thread.scopeId, block.source) ?? NULL_VALUE;
  const elements = source.kind === "array" ? source.elements : [];
  // Seed the loop state keyed by each state's body variable (so a `with` modifier updates it directly).
  const body = getBlock(ctx, block.body);
  const bodyParameters = ctx.ir.block(block.body).parameters;
  if (body.kind === "sequence") {
    block.initialStates.forEach((initial, index) => {
      const stateVariable = bodyParameters[`state_${index}`];
      if (stateVariable !== undefined) {
        thread.states[stateVariable] =
          readVariable(ctx.store, thread.scopeId, initial) ?? NULL_VALUE;
      }
    });
  }
  if (elements.length === 0) {
    finishFor(ctx, thread, block.thenClause);
    return;
  }
  if (thread.parallel) {
    elements.forEach((element, index) => {
      startIteration(ctx, thread, block.body, index, element);
    });
  } else {
    const first = elements[0];
    if (first !== undefined) startIteration(ctx, thread, block.body, 0, first);
  }
}

/** Spawn one for-body iteration, seeded with the element under `iterator` and the current `state_N`s. */
function startIteration(
  ctx: StepContext,
  thread: ForThread,
  bodyBlock: number,
  index: number,
  element: Value,
): void {
  const parameters: Record<string, Value> = { iterator: element };
  const bodyParameters = ctx.ir.block(bodyBlock).parameters;
  for (const [name, variable] of Object.entries(bodyParameters)) {
    const stateValue = thread.states[variable];
    if (name.startsWith("state_") && stateValue !== undefined) {
      parameters[name] = stateValue;
    }
  }
  const callId = allocateCallId(ctx.instance);
  thread.pending[index] = callId;
  spawnThread(ctx, {
    parent: thread.id,
    parentCallId: callId,
    parentScopeId: thread.scopeId,
    blockId: bodyBlock,
    parameters,
  });
}

/** Collect one iteration's mapped value, apply any state modifiers, and advance (sequential) or finish. */
function collectIteration(
  ctx: StepContext,
  thread: ForThread,
  callId: CallId,
  value: Value,
  modifiers: Record<number, Value> | undefined,
): void {
  const index = indexOfCall(thread.pending, callId);
  thread.collected[index] = value;
  delete thread.pending[index];
  if (modifiers !== undefined) {
    for (const [variable, modifierValue] of Object.entries(modifiers)) {
      thread.states[Number(variable)] = modifierValue;
    }
  }
  const block = getBlock(ctx, thread.blockId);
  if (block.kind !== "for") throw new Error(`thread ${thread.id} is not a for block`);
  if (thread.parallel) {
    if (Object.keys(thread.pending).length === 0) finishFor(ctx, thread, block.thenClause);
    return;
  }
  // Sequential: start the next element, or finish once the source is exhausted.
  const source = readVariable(ctx.store, thread.scopeId, block.source) ?? NULL_VALUE;
  const elements = source.kind === "array" ? source.elements : [];
  thread.cursor += 1;
  const next = elements[thread.cursor];
  if (next !== undefined) {
    startIteration(ctx, thread, block.body, thread.cursor, next);
  } else {
    finishFor(ctx, thread, block.thenClause);
  }
}

function forAsk(
  ctx: StepContext,
  thread: ForThread,
  from: ThreadId,
  askId: AskId,
  ask: AskKind,
): void {
  if (ask.kind === "next-for" && ask.target === thread.blockId) {
    const child = ctx.instance.threads[from];
    const callId = child?.parentCallId ?? null;
    if (callId === null) throw new Error(`next-for from ${from} has no iteration call`);
    dropDescendants(ctx, from);
    removeThread(ctx, from);
    collectIteration(ctx, thread, callId, ask.value, ask.modifiers);
    return;
  }
  if (ask.kind === "break-for" && ask.target === thread.blockId) {
    // Early exit: stop iterating and complete with the mapping collected so far (then-clause applies).
    for (const child of childrenOf(ctx, thread.id)) {
      dropDescendants(ctx, child.id);
      removeThread(ctx, child.id);
    }
    const block = getBlock(ctx, thread.blockId);
    if (block.kind !== "for") throw new Error(`thread ${thread.id} is not a for block`);
    finishFor(ctx, thread, block.thenClause);
    return;
  }
  // return / break to an ancestor, or a request: bubble up.
  proxyAsk(ctx, thread, ask, from, askId);
}

/** Finish the loop: build the ordered mapping array, then run the then-clause (if any) or yield the array. */
function finishFor(ctx: StepContext, thread: ForThread, thenClause: { body: number } | null): void {
  const mapping = materializeOrdered(thread.collected);
  if (thenClause === null) {
    completeThread(ctx, thread, mapping);
    return;
  }
  const parameters: Record<string, Value> = { result: mapping };
  const thenParameters = ctx.ir.block(thenClause.body).parameters;
  for (const [name, variable] of Object.entries(thenParameters)) {
    const stateValue = thread.states[variable];
    if (name.startsWith("state_") && stateValue !== undefined) {
      parameters[name] = stateValue;
    }
  }
  const callId = allocateCallId(ctx.instance);
  thread.thenPending = callId;
  spawnThread(ctx, {
    parent: thread.id,
    parentCallId: callId,
    parentScopeId: thread.scopeId,
    blockId: thenClause.body,
    parameters,
  });
}

// ─── shared ──────────────────────────────────────────────────────────────────────────────────────

/** Find the index whose pending call matches `callId` (parallel / for children keyed by index). */
function indexOfCall(pending: Record<number, CallId>, callId: CallId): number {
  for (const [index, pendingCall] of Object.entries(pending)) {
    if (pendingCall === callId) return Number(index);
  }
  throw new Error(`no pending child for callId ${callId}`);
}

/** Materialise a sparse index->value map into a dense, source-ordered array. */
function materializeOrdered(collected: Record<number, Value>): Value {
  const indices = Object.keys(collected)
    .map(Number)
    .sort((left, right) => left - right);
  return { kind: "array", elements: indices.map((index) => collected[index] ?? NULL_VALUE) };
}

function notInThisLayer(what: string): Error {
  return new Error(`thread kind "${what}" is wired in a later layer (effect system / FFI)`);
}
