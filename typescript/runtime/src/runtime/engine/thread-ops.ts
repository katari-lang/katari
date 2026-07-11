// Per-thread-kind handlers for the six internal events (create / callAck / cancel / cancelAck / ask /
// askAck), dispatched by `thread.kind`, plus the graceful cancel cascade. This is the whole intra-
// instance engine: the agent root (incl. its return / escalation boundary), leaf bodies (primitive /
// construct / request / external), structural nodes (match / for / handle / parallel), and the delegate
// proxy's in-instance side. The cross-instance plumbing (routing escalate / escalateAck / terminate /
// terminateAck, FFI completions) is the actor's; here we emit the outbound events and resume on the
// inbound ones via the actor.

import type { Block } from "@katari-lang/types";
import { isUserFacingRequest } from "../escalation-filter.js";
import type { AskKind, ReactorName } from "../event/types.js";
import type { AskId, CallId, ThreadId } from "../ids.js";
import { literalToValue } from "../value/codec.js";
import { isTainted, markPrivate } from "../value/privacy.js";
import type { GenericSubstitution, Value } from "../value/types.js";
import {
  childrenOf,
  completeInstance,
  completeThread,
  constructValue,
  escapeAsk,
  proxyAsk,
  raisePanic,
  raiseThrow,
  removeThread,
  terminateInstance,
} from "./common.js";
import type { StepContext } from "./context.js";
import { runSequence } from "./operations.js";
import { matchPattern } from "./pattern.js";
import { readVariable, writeVariable } from "./scope.js";
import { getBlock, spawnThread } from "./spawn.js";
import { allocateAskId, allocateCallId } from "./store.js";
import { KatariThrow } from "./throw-signal.js";
import type {
  AgentThread,
  CancelExit,
  ExternalThread,
  FinalizerDisposition,
  ForThread,
  HandleThread,
  MatchThread,
  ParallelThread,
  PrimitiveThread,
  RequestThread,
  SequenceThread,
  Thread,
} from "./types.js";

const NULL_VALUE: Value = { kind: "null" };

/** The reactor a proxy thread's downward leg (a `terminate` or `escalateAck`) descends to — its child's
 *  reactor. An `external` proxy's child runs in its `reactor` (`ffi` / `http`); a `delegate` (core sub-call)
 *  proxy's in `core`. This is the proxy-side companion of the `to` an external `delegate` was emitted with. */
function proxyCalleeReactor(thread: Thread): ReactorName {
  return thread.kind === "external" ? thread.reactor : "core";
}

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
    case "request":
      createRequest(ctx, thread);
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
    case "handle":
      createHandle(ctx, thread);
      return;
    case "external":
      // Like a delegate proxy, but it emits its own outbound `delegate` (to ffi) here on create.
      createExternal(ctx, thread);
      return;
    case "delegate":
      // The outbound delegate was emitted by the spawning op; the proxy just waits for its delegateAck.
      return;
  }
}

// ─── callAck (a child completed; deliver its value) ─────────────────────────────────────────────

export function dispatchCallAck(
  ctx: StepContext,
  thread: Thread,
  callId: CallId,
  value: Value,
): void {
  if (thread.status === "cancelling") {
    // A child completed normally during teardown; it removed itself, so just note the progress.
    noteChildGone(ctx, thread.id);
    return;
  }
  switch (thread.kind) {
    case "agent":
      if (ctx.instance.phase.kind === "finalizing") {
        // A finalizer thread completed: run the next armed one, or emit the deferred terminal ack.
        runNextFinalizer(ctx);
        return;
      }
      // The body completed normally (no explicit return): reach the terminal, running finalizers first.
      beginTerminal(ctx, { kind: "completed", value });
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
      handleForCallAck(ctx, thread, callId, value);
      return;
    case "handle":
      handleHandleCallAck(ctx, thread, callId, value);
      return;
    case "delegate":
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
  if (thread.status === "cancelling") return; // ignore asks from a subtree being torn down
  switch (thread.kind) {
    case "agent":
      agentAsk(ctx, thread, from, askId, ask);
      return;
    case "for":
      forAsk(ctx, thread, from, askId, ask);
      return;
    case "handle":
      handleAsk(ctx, thread, from, askId, ask);
      return;
    case "sequence":
    case "match":
    case "parallel":
    case "delegate":
    case "external":
      // None of these is a control target or a request handler: bubble every ask up unchanged. (A delegate /
      // external proxy has no in-instance children to ask it, so this is reached only defensively.)
      proxyAsk(ctx, thread, ask, from, askId);
      return;
    case "primitive":
    case "construct":
    case "request":
      throw new Error(`leaf thread "${thread.kind}" does not receive asks`);
  }
}

// ─── askAck (an answered ask resumes its asker) ─────────────────────────────────────────────────

// An askAck is addressed to a thread, which either forwards it on one more hop or, if it is the genuine
// asker, consumes it:
//   - a `delegate` / `external` proxy relaying an inbound escalation sends the answer back out as that
//     escalate's `escalateAck` (its `relays` entry);
//   - any other proxying thread (and the agent root resolving a returned escalateAck) forwards it one hop
//     down to the child that raised it (its `forwardRoutes` entry);
//   - with no route, the thread is the genuine asker — a request leaf — and it completes with the value.
export function dispatchAskAck(ctx: StepContext, thread: Thread, askId: AskId, value: Value): void {
  if (thread.status === "cancelling") return; // a late answer for a thread being torn down
  if (thread.kind === "delegate" || thread.kind === "external") {
    const escalation = thread.relays[askId];
    if (escalation !== undefined) {
      delete thread.relays[askId];
      // The escalateAck descends to this proxy's child — a core sub-call (`delegate`) or an ffi call
      // (`external`); the proxy's own kind names the callee reactor.
      ctx.emit(
        { kind: "escalateAck", delegation: thread.delegationId, escalation, value },
        proxyCalleeReactor(thread),
      );
      return;
    }
  }
  const route = thread.forwardRoutes[askId];
  if (route !== undefined) {
    delete thread.forwardRoutes[askId];
    ctx.enqueue({ kind: "askAck", target: route.thread, askId: route.askId, value });
    return;
  }
  if (thread.kind === "request") {
    completeThread(ctx, thread, value);
    return;
  }
  throw new Error(`thread kind "${thread.kind}" did not expect a direct askAck (askId ${askId})`);
}

// ─── graceful cancel cascade ────────────────────────────────────────────────────────────────────

/**
 * Begin cancelling a thread's subtree; once it has fully torn down, perform `exit`. With no in-flight
 * children the exit is immediate; otherwise every child is sent a `cancel` (a delegate child a
 * `terminate`, an external call an abort — see `dispatchCancel`) and the exit waits for their acks.
 */
function beginCancel(ctx: StepContext, thread: Thread, exit: CancelExit): void {
  thread.status = "cancelling";
  ctx.instance.cancelExits[thread.id] = exit;
  const children = childrenOf(ctx, thread.id);
  if (children.length === 0) {
    finishCancel(ctx, thread);
    return;
  }
  for (const child of children) {
    ctx.enqueue({ kind: "cancel", target: child.id });
  }
}

/** Perform a cancelled thread's `CancelExit` now that its subtree is gone, then retire / resume it. */
function finishCancel(ctx: StepContext, thread: Thread): void {
  const exit = ctx.instance.cancelExits[thread.id] ?? { kind: "ackParent" };
  delete ctx.instance.cancelExits[thread.id];
  switch (exit.kind) {
    case "ackParent":
      if (thread.parent !== null && thread.parentCallId !== null) {
        ctx.enqueue({ kind: "cancelAck", target: thread.parent, callId: thread.parentCallId });
      }
      removeThread(ctx, thread.id);
      return;
    case "returnInstance":
      // An explicit `return` completed the instance: reach the terminal, running finalizers first.
      beginTerminal(ctx, { kind: "completed", value: exit.value });
      return;
    case "terminateInstance":
      // The user body's cancel cascade cleared: reach the cancel terminal, running finalizers first (unless
      // the instance failed, in which case `beginTerminal` skips them).
      beginTerminal(ctx, { kind: "cancelled" });
      return;
    case "completeWith":
      completeThread(ctx, thread, exit.value);
      return;
  }
}

/** A child of `parentId` is gone (cancelAck, or an out-of-band completion during teardown): if the
 *  parent is cancelling and now childless, finish its cancel. */
function noteChildGone(ctx: StepContext, parentId: ThreadId): void {
  const parent = ctx.instance.threads[parentId];
  if (
    parent !== undefined &&
    parent.status === "cancelling" &&
    childrenOf(ctx, parentId).length === 0
  ) {
    finishCancel(ctx, parent);
  }
}

export function dispatchCancel(ctx: StepContext, thread: Thread): void {
  switch (thread.kind) {
    case "agent":
      if (ctx.instance.phase.kind === "finalizing") {
        // Atomicity: a cancel arriving mid-drain neither cancels the running finalizers nor restarts
        // anything. Flip the deferred terminal to `cancelled` in place and let the drain finish — its
        // terminal then acks the cancel and discards the completed result. (`finalizing` implies not
        // failed: a panic escaping mid-drain would have moved the phase to `failed`.)
        ctx.instance.phase = { kind: "finalizing", disposition: { kind: "cancelled" } };
        return;
      }
      // The instance is being terminated: tear down the user body, then (unless it failed) run finalizers
      // before the terminateAck. A failed instance takes this path too — `beginTerminal` skips its finalizers.
      beginCancel(ctx, thread, { kind: "terminateInstance" });
      return;
    case "delegate":
    case "external":
      // Terminate the child (a core sub-call, or the ffi call); its terminateAck becomes this proxy's
      // cancelAck (via the reactors). The proxy stays `cancelling` until that terminateAck arrives, so the
      // callee has really stopped before it acks its parent — graceful, unlike an immediate finish.
      thread.status = "cancelling";
      ctx.instance.cancelExits[thread.id] = { kind: "ackParent" };
      // The terminate descends to this proxy's child; the proxy's kind names the callee reactor.
      ctx.emit({ kind: "terminate", delegation: thread.delegationId }, proxyCalleeReactor(thread));
      return;
    case "primitive":
    case "construct":
    case "request":
      // Leaves have no children (a suspended request abandons its escalation as its instance retires).
      thread.status = "cancelling";
      ctx.instance.cancelExits[thread.id] = { kind: "ackParent" };
      finishCancel(ctx, thread);
      return;
    case "sequence":
    case "match":
    case "for":
    case "parallel":
    case "handle":
      beginCancel(ctx, thread, { kind: "ackParent" });
      return;
  }
}

export function dispatchCancelAck(ctx: StepContext, thread: Thread, callId: CallId): void {
  if (thread.status === "cancelling") {
    // The parent itself is being torn down (e.g. a `break-for` cancelling the whole loop while one
    // iteration's `next-for` cancel was still in flight): whichever teardown reached the parent first wins,
    // and a child's cancelAck now carries no further meaning — its pending `next` / `next-for` collect is
    // moot (it drops with the subtree). Just record the child gone, mirroring `dispatchCallAck`.
    noteChildGone(ctx, thread.id);
    return;
  }
  if (thread.kind === "handle" && thread.postCancelActions[callId] !== undefined) {
    // A targeted `next`-cancel of a handler body finished: answer the request it was handling.
    fireHandlerAnswer(ctx, thread, callId);
    return;
  }
  if (thread.kind === "for" && thread.postCancelCollect[callId] !== undefined) {
    // A targeted `next`-cancel of a for iteration finished: collect its value and advance (the for
    // analogue of `fireHandlerAnswer`).
    const action = thread.postCancelCollect[callId];
    delete thread.postCancelCollect[callId];
    collectIteration(ctx, thread, callId, action.value, action.modifiers);
    return;
  }
  noteChildGone(ctx, thread.id);
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
  from: ThreadId,
  askId: AskId,
  ask: AskKind,
): void {
  if (ask.kind === "return" && ask.target === thread.blockId) {
    // The body returned: unwind the body subtree, then complete the instance with the value.
    beginCancel(ctx, thread, { kind: "returnInstance", value: ask.value });
    return;
  }
  // Runtime backstop for the `finally` io-only rule (the compiler forbids this statically): a finalizer may
  // not perform a user-facing escalation that would proxy through the parent — io-effect delegations
  // (http / mcp / webhook, in-instance leaf prims) go straight to their reactor and never reach here, but a
  // capability request would. Panic naming the restriction rather than escaping to a handler / the user. The
  // panic itself is a failure request (not user-facing), so it escapes normally — the instance then fails.
  if (ask.kind === "request" && isUserFacingRequest(ask.request)) {
    const child = ctx.instance.threads[from];
    if (child !== undefined && child.origin === "finalizer") {
      raisePanic(ctx, child, FINALLY_ESCALATION_PANIC);
      return;
    }
  }
  // A request, or a control ask targeting a lexical ancestor instance: escape as an outbound escalate.
  escapeAsk(ctx, from, askId, ask);
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

// ─── finalizers (the `finally` terminal) ──────────────────────────────────────────────────────────

/** The panic a finalizer's forbidden escalation raises (backstop for the compiler's io-only `finally` rule). */
const FINALLY_ESCALATION_PANIC =
  "a finally block may not perform an escalation that proxies through the parent (finally is io-only)";

/**
 * Reach the instance's terminal. A trusted instance with armed finalizers DEFERS its ack: it enters the
 * `finalizing` phase and drains the stack in reverse before acking `disposition` (the original result for a
 * normal completion, a discarded result for a cancel). A `failed` instance (a panic escaped) or one with no
 * finalizers acks immediately — a panicked instance's state is not trusted, so its finalizers are skipped.
 */
function beginTerminal(ctx: StepContext, disposition: FinalizerDisposition): void {
  const instance = ctx.instance;
  if (instance.phase.kind === "failed" || instance.finalizers.length === 0) {
    emitTerminal(ctx, disposition);
    return;
  }
  instance.phase = { kind: "finalizing", disposition };
  // The user tree is gone; the root now drives finalizers as ordinary children, so restore it to `running`
  // (a cancel-induced terminal left it `cancelling`) and drop the cancel exit that would ack its parent.
  const root = agentRootOf(ctx);
  root.status = "running";
  delete instance.cancelExits[root.id];
  runNextFinalizer(ctx);
}

/** Emit the instance's terminal ack for `disposition` and retire it (its finalizers, if any, already drained). */
function emitTerminal(ctx: StepContext, disposition: FinalizerDisposition): void {
  switch (disposition.kind) {
    case "completed":
      completeInstance(ctx, disposition.value); // the deferred delegateAck with the original result
      return;
    case "cancelled":
      terminateInstance(ctx); // the deferred terminateAck (the completed result, if any, is discarded)
      return;
  }
}

/**
 * Run the next armed finalizer (reverse arming order) as an ordinary child of the agent root, or — the stack
 * drained — emit the deferred terminal ack. Each finalizer chains to the scope it was armed in (so it reads
 * the enclosing bindings) and is stamped `finalizer` so a user cancel never cascades into its subtree.
 */
function runNextFinalizer(ctx: StepContext): void {
  const instance = ctx.instance;
  if (instance.phase.kind !== "finalizing") return;
  const armed = instance.finalizers.pop();
  if (armed === undefined) {
    const { disposition } = instance.phase;
    instance.phase = { kind: "running" };
    emitTerminal(ctx, disposition);
    return;
  }
  const root = agentRootOf(ctx);
  const callId = allocateCallId(instance);
  root.pending = { callId, output: null };
  spawnThread(ctx, {
    parent: root.id,
    parentCallId: callId,
    parentScopeId: armed.scopeId,
    blockId: armed.block,
    parameters: {},
    origin: "finalizer",
  });
}

/** The instance's root `AgentThread` — the finalizer drain's parent and the instance's terminal boundary. */
function agentRootOf(ctx: StepContext): AgentThread {
  const root = ctx.instance.threads[ctx.instance.rootThreadId];
  if (root === undefined || root.kind !== "agent") {
    throw new Error("the instance root is not an agent thread (engine bug)");
  }
  return root;
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

// ─── leaf bodies (primitive / construct / request / external) ────────────────────────────────────

async function createPrimitive(ctx: StepContext, thread: PrimitiveThread): Promise<void> {
  // An `inline` invocation (the cross-module fast path) carries its own name / argument / generics —
  // the callee's block lives in a foreign module this instance cannot read. A `block` invocation reads
  // them off its block, and its generics are the instance's ambient (the delegate that summoned the
  // instance stamped them).
  let name: string;
  let argument: Value;
  let generics: GenericSubstitution | undefined;
  switch (thread.invocation.kind) {
    case "inline":
      name = thread.invocation.name;
      argument = thread.invocation.argument;
      generics = thread.invocation.generics;
      break;
    case "block": {
      const block = getBlock(ctx, thread.blockId);
      if (block.kind !== "primitive") {
        throw new Error(`thread ${thread.id} is not a primitive block`);
      }
      name = block.name;
      argument = readVariable(ctx.store, thread.scopeId, block.input) ?? NULL_VALUE;
      generics = ctx.instance.ambientGenerics;
      break;
    }
  }
  // A prim failure is never a crash: an anticipated, typed failure (`KatariThrow` — malformed JSON, a
  // schema mismatch) raises `prelude.throw` with its payload; any other JS error is a `panic` (a zero
  // divisor, an engine backstop). Both bubble toward a handler / the run — only the throw is catchable.
  let value: Value;
  try {
    value = await ctx.prims.run(name, argument, {
      projectId: ctx.projectId,
      ir: ctx.irSource,
      blobs: ctx.blobs,
      // The warm blob catalog: a metadata prim (`file.size`) reads the row a slim ref points at.
      blobEntryOf: (blobId) => ctx.store.blobs[blobId],
      ...(generics !== undefined ? { generics } : {}),
    });
  } catch (error) {
    if (error instanceof KatariThrow) {
      // Taint is monotonic through the failure path too: a private argument makes the payload private.
      raiseThrow(ctx, thread, isTainted(argument) ? markPrivate(error.payload) : error.payload);
    } else {
      raisePanic(ctx, thread, error instanceof Error ? error.message : String(error));
    }
    return;
  }
  // Taint is monotonic through a pure primitive: if any part of the argument is private, so is the result
  // (`concat`-ing a secret yields a secret; comparing one leaks a bit). A source prim (env / secret) marks
  // its own result private regardless; `markPrivate` is idempotent, so this only ever adds the marker.
  completeThread(ctx, thread, isTainted(argument) ? markPrivate(value) : value);
}

function createConstruct(ctx: StepContext, thread: Thread): void {
  const block = getBlock(ctx, thread.blockId);
  if (block.kind !== "construct") throw new Error(`thread ${thread.id} is not a construct block`);
  const argument = readVariable(ctx.store, thread.scopeId, block.input) ?? NULL_VALUE;
  completeThread(ctx, thread, constructValue(argument, block.name));
}

/** A request leaf raises its request as an ask to its parent (the instance root agent), which has no
 *  handler of its own, so it escapes as an outbound escalate. The thread suspends until its askAck. */
function createRequest(ctx: StepContext, thread: RequestThread): void {
  const block = getBlock(ctx, thread.blockId);
  if (block.kind !== "request") throw new Error(`thread ${thread.id} is not a request block`);
  if (thread.parent === null) throw new Error(`request thread ${thread.id} has no parent`);
  const argument = readVariable(ctx.store, thread.scopeId, block.input) ?? NULL_VALUE;
  const askId = allocateAskId(ctx.instance);
  ctx.enqueue({
    kind: "ask",
    target: thread.parent,
    from: thread.id,
    askId,
    ask: { kind: "request", request: block.name, argument },
  });
}

/** Emit the external call as a `delegate` to the `ffi` reactor and suspend as its proxy — exactly like a
 *  sub-call delegate, but the callee is the ffi handler (`{ external, key }`) rather than a core instance.
 *  The `delegateAck` (result), an `escalate` (an FFI error → a panic), or a `terminateAck` (abort) resumes it
 *  through the shared proxy machinery. */
function createExternal(ctx: StepContext, thread: ExternalThread): void {
  const block = getBlock(ctx, thread.blockId);
  if (block.kind !== "external") throw new Error(`thread ${thread.id} is not an external block`);
  const argument = readVariable(ctx.store, thread.scopeId, block.input) ?? null;
  // An external call is a delegate to its reactor (`ffi` or `http`) — its only difference from a core
  // sub-call is `to`. The proxy carries the same `reactor`, so its later legs route consistently.
  ctx.emit(
    {
      kind: "delegate",
      delegation: thread.delegationId,
      // The (ffi) handler lives in this agent's snapshot bundle, so the ffi transport spawns that bundle;
      // http ignores the snapshot.
      target: {
        kind: "external",
        key: block.key,
        snapshot: ctx.ir.snapshot,
      },
      argument,
      // The external agent's own instantiation (this instance's ambient) rides to the reactor, so a
      // reactor that decodes its reply against a result generic — the mcp direct call against its `T` —
      // reads the schema the call site stamped. A reactor that ignores it (ffi / http) is unaffected.
      ...(ctx.instance.ambientGenerics !== undefined
        ? { generics: ctx.instance.ambientGenerics }
        : {}),
    },
    // `to` is the call reactor this routes to (`ffi` / `http`), from the block's marker via the proxy thread;
    // the target does not repeat it.
    thread.reactor,
  );
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
  // The checker guarantees exhaustiveness; reaching here is a runtime panic, not a crash.
  raisePanic(ctx, thread, "non-exhaustive match");
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

/** A `for` source's elements, each lifted by the source's privacy: iterating a private array binds each
 *  element as private (the same projection rule as reading a field of a private record). */
function forElements(source: Value): Value[] {
  if (source.kind !== "array") return [];
  return source.private === true ? source.elements.map(markPrivate) : source.elements;
}

function createFor(ctx: StepContext, thread: ForThread): void {
  const block = forBlock(ctx, thread);
  const source = readVariable(ctx.store, thread.scopeId, block.source) ?? NULL_VALUE;
  const elements = forElements(source);
  // Seed the loop state keyed by each state's body variable (so a `with` modifier updates it directly).
  const bodyParameters = ctx.ir.block(block.body).parameters;
  block.initialStates.forEach((initial, index) => {
    const stateVariable = bodyParameters[`state_${index}`];
    if (stateVariable !== undefined) {
      thread.states[stateVariable] = readVariable(ctx.store, thread.scopeId, initial) ?? NULL_VALUE;
    }
  });
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

function handleForCallAck(ctx: StepContext, thread: ForThread, callId: CallId, value: Value): void {
  if (thread.thenPending !== null && thread.thenPending === callId) {
    completeThread(ctx, thread, value); // the then-clause finished; its value is the loop's value
    return;
  }
  // A body iteration fell through (implicit `next` with its result value); no state change.
  collectIteration(ctx, thread, callId, value, undefined);
}

/** Spawn one for-body iteration, seeded with the element under `iterator` and the current `state_N`s. */
function startIteration(
  ctx: StepContext,
  thread: ForThread,
  bodyBlock: number,
  index: number,
  element: Value,
): void {
  const parameters: Record<string, Value> = {
    iterator: element,
    ...stateParameters(ctx, thread, bodyBlock),
  };
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
  const block = forBlock(ctx, thread);
  if (thread.parallel) {
    if (Object.keys(thread.pending).length === 0) finishFor(ctx, thread, block.thenClause);
    return;
  }
  // Sequential: start the next element, or finish once the source is exhausted.
  const source = readVariable(ctx.store, thread.scopeId, block.source) ?? NULL_VALUE;
  const elements = forElements(source);
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
    // A body iteration `next`ed: cancel that iteration's subtree through the same cascade as a handle's
    // `next` (the `next` may have escaped from inside still-running nested structure — a `par` element,
    // a match arm — so an ad-hoc drop would leak it), then collect the value on its teardown.
    const child = ctx.instance.threads[from];
    const callId = child?.parentCallId ?? null;
    if (child === undefined || callId === null) {
      throw new Error(`next-for from ${from} has no iteration call`);
    }
    thread.postCancelCollect[callId] = { value: ask.value, modifiers: ask.modifiers };
    beginCancel(ctx, child, { kind: "ackParent" });
    return;
  }
  if (ask.kind === "break-for" && ask.target === thread.blockId) {
    // Early exit with the break value: cancel all the in-flight iterations, then complete with that
    // value. The then-clause reduces the collected mapping only on natural exhaustion; a `break-for`
    // bypasses it entirely, exactly as a `handle`'s `break` bypasses its then-clause.
    beginCancel(ctx, thread, { kind: "completeWith", value: ask.value });
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
  const parameters: Record<string, Value> = {
    result: mapping,
    ...stateParameters(ctx, thread, thenClause.body),
  };
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

// ─── handle (effect handler) ─────────────────────────────────────────────────────────────────────

function createHandle(ctx: StepContext, thread: HandleThread): void {
  const block = handleBlock(ctx, thread);
  // Seed states (keyed by the shared body variable id) from the caller scope.
  const bodyParameters = ctx.ir.block(block.body).parameters;
  block.initialStates.forEach((initial, index) => {
    const stateVariable = bodyParameters[`state_${index}`];
    if (stateVariable !== undefined) {
      thread.states[stateVariable] = readVariable(ctx.store, thread.scopeId, initial) ?? NULL_VALUE;
    }
  });
  // Spawn the protected body, seeded with the current state_N.
  const callId = allocateCallId(ctx.instance);
  thread.bodyCall = callId;
  spawnThread(ctx, {
    parent: thread.id,
    parentCallId: callId,
    parentScopeId: thread.scopeId,
    blockId: block.body,
    parameters: stateParameters(ctx, thread, block.body),
  });
}

function handleHandleCallAck(
  ctx: StepContext,
  thread: HandleThread,
  callId: CallId,
  value: Value,
): void {
  if (callId === thread.thenPending) {
    completeThread(ctx, thread, value); // the then-clause's value is the handle's value
    return;
  }
  if (callId === thread.bodyCall) {
    // The protected body completed normally: run the then-clause (or yield its value).
    thread.bodyCall = null;
    const block = handleBlock(ctx, thread);
    if (block.thenClause === null) {
      completeThread(ctx, thread, value);
      return;
    }
    const parameters: Record<string, Value> = {
      result: value,
      ...stateParameters(ctx, thread, block.thenClause.body),
    };
    const thenCallId = allocateCallId(ctx.instance);
    thread.thenPending = thenCallId;
    spawnThread(ctx, {
      parent: thread.id,
      parentCallId: thenCallId,
      parentScopeId: thread.scopeId,
      blockId: block.thenClause.body,
      parameters,
    });
    return;
  }
  // A handler body fell through to its tail without an explicit jump: its tail value is an implicit
  // `next` (resume the asker, no state modifiers) — mirroring a `for` body's implicit next. The handler
  // body has already retired with this callAck, so there is no subtree to cancel; answer the request
  // directly and free the handler slot.
  const answer = thread.handlers[callId];
  if (answer === undefined) {
    throw new Error(`handle ${thread.id} got an unexpected callAck (callId ${callId})`);
  }
  delete thread.handlers[callId];
  resumeRequestAsker(ctx, thread, answer, value);
}

function handleAsk(
  ctx: StepContext,
  thread: HandleThread,
  from: ThreadId,
  askId: AskId,
  ask: AskKind,
): void {
  const block = handleBlock(ctx, thread);
  if (ask.kind === "request") {
    // A request from one of our OWN handler bodies is a rethrow, not a new occurrence: statically the
    // handler's effects belong to the enclosing scope (they ride the handler type's generic `E`), so it
    // must escape past this handle — re-matching it here would catch it forever (self-catch loop).
    const sender = ctx.instance.threads[from];
    const fromOwnHandler =
      sender !== undefined &&
      sender.parent === thread.id &&
      sender.parentCallId !== null &&
      thread.handlers[sender.parentCallId] !== undefined;
    const handler = fromOwnHandler
      ? undefined
      : block.handlers.find((entry) => entry.request === ask.request);
    if (handler === undefined) {
      proxyAsk(ctx, thread, ask, from, askId); // not ours
      return;
    }
    const request = { from, askId, request: ask.request, argument: ask.argument };
    if (thread.parallel || !handleBusy(thread)) {
      dispatchHandler(ctx, thread, handler.body, request);
    } else {
      thread.pendingRequests.push(request);
    }
    return;
  }
  if (ask.kind === "next" && ask.target === thread.blockId) {
    handleNext(ctx, thread, from, ask.value, ask.modifiers);
    return;
  }
  if (ask.kind === "break" && ask.target === thread.blockId) {
    // Exit the handle with the value: cancel the body + any handlers, then complete.
    thread.pendingRequests = [];
    beginCancel(ctx, thread, { kind: "completeWith", value: ask.value });
    return;
  }
  // A control ask for an ancestor, or a request not ours: bubble up.
  proxyAsk(ctx, thread, ask, from, askId);
}

/** Spawn a handler body for a caught request, seeded with the request argument + current states, and
 *  record the ask it will answer on `next`. */
function dispatchHandler(
  ctx: StepContext,
  thread: HandleThread,
  body: number,
  request: { from: ThreadId; askId: AskId; argument: Value | null },
): void {
  const callId = allocateCallId(ctx.instance);
  thread.handlers[callId] = { answerThread: request.from, answerAskId: request.askId };
  spawnThread(ctx, {
    parent: thread.id,
    parentCallId: callId,
    parentScopeId: thread.scopeId,
    blockId: body,
    parameters: {
      parameter: request.argument ?? NULL_VALUE,
      ...stateParameters(ctx, thread, body),
    },
  });
}

/** A handler resumed the asker via `next`: apply state modifiers, then targeted-cancel the handler body
 *  and (on its teardown) fire the request's answer. */
function handleNext(
  ctx: StepContext,
  thread: HandleThread,
  from: ThreadId,
  value: Value,
  modifiers: Record<number, Value>,
): void {
  const handlerThread = ctx.instance.threads[from];
  const handlerCall = handlerThread?.parentCallId ?? null;
  if (handlerThread === undefined || handlerCall === null) {
    throw new Error(`next from ${from} is not a handler body of handle ${thread.id}`);
  }
  const answer = thread.handlers[handlerCall];
  if (answer === undefined) {
    throw new Error(`next from ${from} has no outstanding request on handle ${thread.id}`);
  }
  for (const [variable, modifierValue] of Object.entries(modifiers)) {
    thread.states[Number(variable)] = modifierValue;
  }
  thread.postCancelActions[handlerCall] = { ...answer, value };
  delete thread.handlers[handlerCall];
  beginCancel(ctx, handlerThread, { kind: "ackParent" });
}

/** Once a `next`-cancelled handler body is gone, resume the request asker and dispatch any queued request. */
function fireHandlerAnswer(ctx: StepContext, thread: HandleThread, handlerCall: CallId): void {
  const action = thread.postCancelActions[handlerCall];
  delete thread.postCancelActions[handlerCall];
  if (action === undefined) return;
  resumeRequestAsker(
    ctx,
    thread,
    { answerThread: action.answerThread, answerAskId: action.answerAskId },
    action.value,
  );
}

/** Resume a caught request's asker with `value` (a handler's explicit `next` value or its fall-through
 *  tail value), then — in sequential mode, now that this handler slot is free — dispatch the next queued
 *  request. Shared by the explicit-`next` (post-cancel) path and the implicit-`next` fall-through path. */
function resumeRequestAsker(
  ctx: StepContext,
  thread: HandleThread,
  answer: { answerThread: ThreadId; answerAskId: AskId },
  value: Value,
): void {
  ctx.enqueue({ kind: "askAck", target: answer.answerThread, askId: answer.answerAskId, value });
  if (thread.parallel || handleBusy(thread)) return;
  const next = thread.pendingRequests.shift();
  if (next === undefined) return;
  const block = handleBlock(ctx, thread);
  const handler = block.handlers.find((entry) => entry.request === next.request);
  if (handler !== undefined) dispatchHandler(ctx, thread, handler.body, next);
}

/** A handler body or then-clause is in flight (the sequential gate). The protected body does not count. */
function handleBusy(thread: HandleThread): boolean {
  return Object.keys(thread.handlers).length > 0 || thread.thenPending !== null;
}

// ─── shared ──────────────────────────────────────────────────────────────────────────────────────

/** Build the `state_N` parameter values for a block (body / handler / then-clause) from current states. */
function stateParameters(
  ctx: StepContext,
  thread: ForThread | HandleThread,
  blockId: number,
): Record<string, Value> {
  const parameters: Record<string, Value> = {};
  for (const [name, variable] of Object.entries(ctx.ir.block(blockId).parameters)) {
    const value = thread.states[variable];
    if (name.startsWith("state_") && value !== undefined) {
      parameters[name] = value;
    }
  }
  return parameters;
}

function forBlock(ctx: StepContext, thread: ForThread): Extract<Block, { kind: "for" }> {
  const block = getBlock(ctx, thread.blockId);
  if (block.kind !== "for") throw new Error(`thread ${thread.id} is not a for block`);
  return block;
}

function handleBlock(ctx: StepContext, thread: HandleThread): Extract<Block, { kind: "handle" }> {
  const block = getBlock(ctx, thread.blockId);
  if (block.kind !== "handle") throw new Error(`thread ${thread.id} is not a handle block`);
  return block;
}

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
