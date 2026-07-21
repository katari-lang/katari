// The sequence operation executor: runs a `SequenceThread`'s operations one at a time from its cursor.
// Value-producing ops (literals, records, tuples, field reads, pattern binds, closures, agent refs,
// generic application) and the binding-releasing `drop` run synchronously and advance the cursor; the
// four control-transfer ops suspend the thread:
//   - `call` enters a structural node in this instance (an internal child thread);
//   - `delegate` summons a child instance (an outbound external `delegate`, proxied by a DelegateThread);
//   - `exit` / `continue` raise a control ask (return / break / next) up the thread tree.
// The cursor is advanced past a suspending op only when its answer lands (the thread's callAck / askAck),
// so a recovered turn resumes exactly where it left off.

import type {
  Block,
  CalleeReference,
  ContinueOperation,
  DelegateOperation,
  ExitOperation,
  GenericArgumentSchema,
  GenericId,
  JSONSchema,
  Operation,
  QualifiedName,
  VariableId,
} from "@katari-lang/types";
import type { AskKind, ModifierMap } from "../event/types.js";
import { newDelegationId, type ScopeId, type SnapshotId } from "../ids.js";
import { literalToValue } from "../value/codec.js";
import { liftPrivacy } from "../value/privacy.js";
import type { GenericSubstitution, Value } from "../value/types.js";
import {
  fillGenericSchema,
  renderConformFailures,
  typeSubstitutionOf,
} from "../value/validation.js";
import { CALL_AGENT_NAME, completeThread, constructValue, raiseThrow } from "./common.js";
import type { StepContext } from "./context.js";
import { CALL_ERROR, type DispatchResult, dispatchCallable } from "./dynamic-dispatch.js";
import { conformCallableArgumentSync } from "./interop-prims.js";
import { matchPattern } from "./pattern.js";
import { dropVariable, readVariable, writeVariable } from "./scope.js";
import { getBlock, spawnThread } from "./spawn.js";
import { allocateAskId, allocateCallId, allocateThreadId } from "./store.js";
import { errorData } from "./throw-signal.js";
import type { SequenceThread, Thread } from "./types.js";

const NULL_VALUE: Value = { kind: "null" };

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
    case "drop":
      // Every listed binding was written by this same sequence, and the compiler's liveness pass proved
      // it unreadable past this point — deleting it can never break a later read, it only shrinks the
      // scope row persisted at each turn boundary. A miscompiled drop would surface as the
      // unbound-variable throw in `requireVariable` (which names the variable id) at the next read.
      for (const variable of operation.variables) {
        dropVariable(ctx.store, scope, variable);
      }
      return true;
    case "defer":
      // Arm a `finally` block as a finalizer of THIS instance: push (block, this thread's scope) onto the
      // instance's finalizer stack. The scope is captured so the finalizer chains to it (reads the enclosing
      // bindings) when the drain spawns it at the terminal. Arming is synchronous — the cursor advances.
      ctx.instance.finalizers.push({ block: operation.block, scopeId: scope });
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
      // A leaf callee (a stdlib primitive, a data constructor) may complete synchronously — the op
      // then advances like any value-producing op instead of suspending on a child instance.
      return enterDelegate(ctx, thread, operation);
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

/** Execute a `delegate` op by the plan its callee resolves to. Returns `true` when the op completed
 *  synchronously (an inlined construct leaf — the cursor advances), `false` when the thread suspended
 *  (a real delegation, an inlined primitive leaf, or a raised dispatch error). */
function enterDelegate(
  ctx: StepContext,
  thread: SequenceThread,
  operation: DelegateOperation,
): boolean {
  const plan = planDelegate(ctx, thread.scopeId, operation);
  switch (plan.kind) {
    case "raise":
      // The dynamic dispatch failed before anything ran — raise the catchable `reflection.call_error`
      // (the thread suspends on the ask; a handler breaks out, or the run fails with the payload).
      raiseThrow(ctx, thread, plan.payload);
      return false;
    case "construct":
      // The inlined constructor completes in place, so the op advances like any value-producing op.
      if (operation.output !== null) {
        writeVariable(
          ctx.store,
          thread.scopeId,
          operation.output,
          constructValue(plan.argument, plan.constructorName),
        );
      }
      return true;
    case "primitive":
      spawnInlinePrimitive(ctx, thread, operation.output, plan);
      return false;
    case "delegate":
      emitDelegate(ctx, thread, operation.output, plan);
      return false;
  }
}

/** What a resolved `delegate` op executes: one of the two in-instance leaf runs (the fast path), the
 *  ordinary child-instance delegation, or — for a dispatch that failed before anything ran — a raise. */
type DelegatePlan =
  /** A failed dynamic dispatch: raise `payload` as the catchable `reflection.call_error`. */
  | { kind: "raise"; payload: Value }
  /** A data-constructor leaf: tag `argument` with the ctor synchronously — no thread, no suspension.
   *  (`constructorName`, not `constructor`, so the field never collides with the prototype property.) */
  | { kind: "construct"; constructorName: QualifiedName; argument: Value }
  /** A primitive leaf: run the prim on an in-instance leaf thread within this same turn. */
  | { kind: "primitive"; name: string; argument: Value; generics?: GenericSubstitution }
  /** A real delegation: the resolved dispatch, carrying the already-merged generic instantiation. */
  | ({ kind: "delegate" } & DispatchResult);

/** Resolve a `delegate` op — its callee, argument, and generic instantiation — into the plan it
 *  executes. A named core callee whose body is a pure leaf (a stdlib primitive, a data constructor)
 *  plans an IN-THIS-INSTANCE run — no child instance, no outbox round trip, no journal rows. Measured
 *  to be the bulk of a run's events (thousands of `prelude.*` delegations per AI reply), so this is the
 *  difference between a run journaling ~10k events and ~100. Every other callee plans the ordinary
 *  delegation, and a failed dynamic dispatch plans a raise. */
function planDelegate(
  ctx: StepContext,
  scope: ScopeId,
  operation: DelegateOperation,
): DelegatePlan {
  const resolved = resolveCallee(ctx, scope, operation.target, operation.argument);
  if ("throwPayload" in resolved) return { kind: "raise", payload: resolved.throwPayload };
  const { dispatch, viaCallAgent } = resolved;
  // `call_agent`'s own generics (its `R` / `E`, stamped on the operation) parameterise `call_agent`'s
  // result / effect — NOT the dynamic target's input — so they must not rebind the target's params. Merging
  // them would let a target param named `R` be validated against `call_agent`'s inferred result at the
  // acceptance surface, diverging from the engine pre-check (which used the target's OWN generics) and
  // turning a would-be catchable `call_error` into an uncatchable panic. The target carries its own
  // instantiation on the value, so a `call_agent` delegate takes exactly that; a direct / value call still
  // merges the call-site instantiation the checker stamped for the callee itself.
  const generics = composeAmbientGenerics(
    ctx,
    viaCallAgent ? dispatch.generics : mergeGenerics(dispatch.generics, operation.generics),
  );
  if (dispatch.target.kind === "named" && dispatch.to === "core") {
    const leaf = resolveLeafBody(ctx, dispatch.target.name, dispatch.target.snapshot);
    if (leaf !== null && leaf.kind === "construct") {
      return {
        kind: "construct",
        constructorName: leaf.name,
        argument: dispatch.argument ?? NULL_VALUE,
      };
    }
    if (leaf !== null && leaf.kind === "primitive") {
      // The prim registry key is the primitive BLOCK's name (exactly what the in-module path reads).
      return {
        kind: "primitive",
        name: leaf.name,
        argument: dispatch.argument ?? NULL_VALUE,
        ...(generics !== undefined ? { generics } : {}),
      };
    }
  }
  return {
    kind: "delegate",
    target: dispatch.target,
    argument: dispatch.argument,
    to: dispatch.to,
    ...(generics !== undefined ? { generics } : {}),
  };
}

/** Merge a delegate's two substitution sources: what the callee VALUE carries (an explicit `callee[T]`
 *  applied earlier via `applyGenerics`) and what THIS call site instantiated (inferred by the checker,
 *  stamped on the operation). They are disjoint in practice — an already-applied callee is no longer
 *  generic at the call — but the call site wins on overlap (it is the more specific record). */
function mergeGenerics(
  carried: GenericSubstitution | undefined,
  stamped: Array<[string, GenericArgumentSchema]> | undefined,
): GenericSubstitution | undefined {
  if (stamped === undefined || stamped.length === 0) return carried;
  const merged: GenericSubstitution = { ...(carried ?? {}) };
  for (const [name, schema] of stamped) {
    merged[name] = schema;
  }
  return merged;
}

/** Resolve a delegate's generic arguments against the CALLER's ambient substitution — the missing half
 *  of generic composition. The call site stamps `foo[T]` as a `$generic` placeholder referring to the
 *  ENCLOSING agent's own type parameter (a `bar[T]` passing its own `T` down); left raw, that placeholder
 *  reaches the callee — an inline prim's `context.generics` (`reflection.schema_of[T]`, `json.validate[T]`)
 *  or a child instance's `ambientGenerics` — where it is read as the argument itself, so a reflected schema
 *  ships the bare `{"$generic": id}` instead of the concrete type. Filling each argument against the caller's
 *  own instantiation here makes the substitution that flows downstream as concrete as the caller is. A
 *  non-generic caller (no ambient) or an argument with no placeholder is returned untouched. */
function composeAmbientGenerics(
  ctx: StepContext,
  generics: GenericSubstitution | undefined,
): GenericSubstitution | undefined {
  if (generics === undefined) return undefined;
  const substitution = callerTypeSubstitution(ctx);
  if (substitution.size === 0) return generics;
  const composed: GenericSubstitution = {};
  for (const [name, argument] of Object.entries(generics)) {
    composed[name] =
      argument.kind === "type"
        ? { kind: "type", schema: fillGenericSchema(substitution, argument.schema) }
        : argument;
  }
  return composed;
}

/** The caller instance's own `[T]` bindings as a `GenericId` -> schema map (empty when it is not itself
 *  generic). The bridge from the ambient substitution (name-keyed) to the `$generic` ids a stamped
 *  argument carries, so `composeAmbientGenerics` can fill them. Reads the running agent's own block, always
 *  in this instance's module/snapshot (`ctx.ir`); a resolution hiccup degrades to "no substitution" rather
 *  than derailing the delegate. */
function callerTypeSubstitution(ctx: StepContext): ReadonlyMap<GenericId, JSONSchema> {
  const ambient = ctx.instance.ambientGenerics;
  if (ambient === undefined) return EMPTY_SUBSTITUTION;
  const target = ctx.instance.target;
  try {
    const blockId =
      target.kind === "named"
        ? ctx.irSource.locate(target.snapshot, target.name).blockId
        : target.kind === "closure"
          ? target.blockId
          : null;
    if (blockId === null) return EMPTY_SUBSTITUTION;
    const block = ctx.ir.block(blockId).block;
    if (block.kind !== "agent") return EMPTY_SUBSTITUTION;
    return typeSubstitutionOf(block.schema.genericBindings, ambient);
  } catch {
    return EMPTY_SUBSTITUTION;
  }
}

const EMPTY_SUBSTITUTION: ReadonlyMap<GenericId, JSONSchema> = new Map();

/** Resolve a named core callee down to an inlinable leaf body (a `construct` / `primitive` block), or
 *  `null` when it is not one. Resolution reads the callee's module through `irSource` (sync — the
 *  instance's snapshot is preloaded before its turns run). A callee with argument DEFAULTS resolves to
 *  `null`: filling them is the delegation-acceptance seam's job, not worth duplicating here. */
function resolveLeafBody(
  ctx: StepContext,
  name: QualifiedName,
  snapshot: SnapshotId,
): Extract<Block, { kind: "construct" | "primitive" }> | null {
  let agent: Block;
  let body: Block;
  // `IrSource` exposes only throwing lookups, so this catch is scoped to exactly these resolution
  // reads: ANY hiccup there (an unloaded foreign snapshot, a missing entry / module / block) means
  // "not a leaf", falling back to the ordinary delegation — which fails (or succeeds) with its
  // existing semantics. A non-agent entry has no body to read, so it stands in for its own body and
  // the kind checks below reject it.
  try {
    const located = ctx.irSource.locate(snapshot, name);
    const access = ctx.irSource.access(snapshot, located.module);
    agent = access.block(located.blockId).block;
    body = agent.kind === "agent" ? access.block(agent.body).block : agent;
  } catch {
    return null;
  }
  if (agent.kind !== "agent" || Object.keys(agent.defaults ?? {}).length > 0) return null;
  return body.kind === "construct" || body.kind === "primitive" ? body : null;
}

/** Spawn the in-instance leaf thread an inlined `primitive` plan runs on. The leaf's `invocation`
 *  carries the resolved name / argument / generics itself (the callee's block lives in a foreign module
 *  this instance cannot read); it completes within this same turn, so it never persists, and its
 *  failure path (typed throw / panic) bubbles from the leaf exactly like an in-module primitive
 *  body's. */
function spawnInlinePrimitive(
  ctx: StepContext,
  thread: SequenceThread,
  output: VariableId | null,
  plan: Extract<DelegatePlan, { kind: "primitive" }>,
): void {
  const callId = allocateCallId(ctx.instance);
  thread.pending = { callId, output };
  const leafId = allocateThreadId(ctx.instance);
  ctx.instance.threads[leafId] = {
    id: leafId,
    parent: thread.id,
    parentCallId: callId,
    scopeId: thread.scopeId,
    // Never read (the inline invocation carries everything); the spawning block is a valid placeholder.
    blockId: thread.blockId,
    status: "running",
    // An inlined leaf runs within the spawning thread's subtree — it shares its origin.
    origin: thread.origin,
    forwardRoutes: {},
    kind: "primitive",
    invocation: {
      kind: "inline",
      name: plan.name,
      argument: plan.argument,
      ...(plan.generics !== undefined ? { generics: plan.generics } : {}),
    },
  };
  ctx.enqueue({ kind: "create", thread: leafId });
}

/** Summon a child instance for a `delegate` plan: spawn the proxy DelegateThread and emit the outbound
 *  `delegate`. It routes to the resolved executor: `core` for a compiled callable, the tool's own
 *  reactor for a reactor-backed one (a `tool` value resolves to an `external` target + context, so its
 *  call goes straight to the reactor — no wrapper hop). Compiled `external agent` calls still emit
 *  their own `delegate` from `createExternal`; this site handles callee references and values. */
function emitDelegate(
  ctx: StepContext,
  thread: SequenceThread,
  output: VariableId | null,
  plan: Extract<DelegatePlan, { kind: "delegate" }>,
): void {
  const callId = allocateCallId(ctx.instance);
  thread.pending = { callId, output };
  const delegationId = newDelegationId();
  const proxyId = allocateThreadId(ctx.instance);
  const proxyBase = {
    id: proxyId,
    parent: thread.id,
    parentCallId: callId,
    scopeId: thread.scopeId,
    blockId: thread.blockId,
    status: "running" as const,
    // The proxy for an outbound delegate shares the spawning thread's origin (a finalizer's sub-calls too).
    origin: thread.origin,
    forwardRoutes: {},
    delegationId,
    relays: {},
  };
  // A callee resolved to another reactor (a dynamically dispatched tool) gets an `external` proxy
  // carrying that reactor, so the proxy's downward legs — a descending `escalateAck` (a parked mcp
  // call's authorize answer), a cancel's `terminate` — route back to the reactor actually running the
  // callee. A `delegate` proxy would send them to core, which never handled the delegation and would
  // drop them on the floor. The role is `dispatched`: the ack value is an ordinary mid-body
  // intermediate, so the core reactor must NOT conform it against this instance's own output schema
  // (that check belongs to the `wrapper` role, whose ack value is the instance's result).
  ctx.instance.threads[proxyId] =
    plan.to === "core"
      ? { ...proxyBase, kind: "delegate" }
      : { ...proxyBase, kind: "external", reactor: plan.to, role: "dispatched" };
  ctx.emit(
    {
      kind: "delegate",
      delegation: delegationId,
      target: plan.target,
      argument: plan.argument,
      ...(plan.generics !== undefined ? { generics: plan.generics } : {}),
    },
    plan.to,
  );
}

/** Resolve a callee reference + its argument variable into the delegate it stands for. Dynamic dispatch
 *  is resolved HERE, at the emit site: EVERY callee becomes a callable value (a static name wraps into
 *  the `agent` value denoting it, which dispatches back to the same named core target) and runs the one
 *  shared `dispatchCallable`, so a tool's runtime schema is validated before anything is emitted and
 *  the delegate routes straight to its executor. A dispatch failure (a non-callable value, a tool
 *  schema violation) is the anticipated dynamic-dispatch error: it resolves to `{ throwPayload }`,
 *  which `enterDelegate` raises as a catchable `reflection.call_error` instead of delegating. */
function resolveCallee(
  ctx: StepContext,
  scope: ScopeId,
  callee: CalleeReference,
  argumentVariable: VariableId,
): { dispatch: DispatchResult; viaCallAgent: boolean } | { throwPayload: Value } {
  let args: Value | null = requireVariable(ctx, scope, argumentVariable);
  let callable: Value =
    callee.kind === "name"
      ? { kind: "agent", name: callee.name, snapshot: ctx.ir.snapshot }
      : requireVariable(ctx, scope, callee.variable);
  // A `call_agent(target, args)` call carries its real callable in the argument record, so peel it out
  // — in a loop, because `call_agent` may nest (a tool list holding `call_agent` itself). The magic
  // name needs no callee-kind special case: a static `call_agent` callee is just an `agent` value that
  // enters the loop on its first iteration.
  let viaCallAgent = false;
  while (callable.kind === "agent" && callable.name === CALL_AGENT_NAME) {
    viaCallAgent = true;
    const peeled = peelCallAgent(args);
    if ("error" in peeled) return { throwPayload: errorData(CALL_ERROR, peeled.error) };
    callable = peeled.callable;
    args = peeled.args;
  }
  // A `call_agent` target's argument is DYNAMIC — the AI / caller built it, unchecked by the type system.
  // The value codec has already read every `$katari_` marker into its real value (a `$katari_ref` into a
  // real `file`), so the argument arrives in shape: validate it against the target's input schema and turn a
  // mismatch into the catchable `reflection.call_error` the `call_agent` row declares (reaching the callee's
  // acceptance surface — whose mismatch is a defensive PANIC — would strand it). A `tool` target is
  // validated by `dispatchCallable` below; a direct (non-`call_agent`) call site is type-checked already.
  if (viaCallAgent && (callable.kind === "agent" || callable.kind === "closure")) {
    const failure = conformCallAgentArgument(ctx, callable, args);
    if (failure !== null) return { throwPayload: errorData(CALL_ERROR, failure) };
  }
  const dispatched = dispatchCallable(callable, args);
  if ("error" in dispatched) {
    return { throwPayload: errorData(CALL_ERROR, dispatched.error) };
  }
  return { dispatch: dispatched, viaCallAgent };
}

/** Pre-validate a DYNAMIC (`call_agent`) target's argument against its declared input schema, resolving the
 *  schema synchronously the way `resolveLeafBody` does (the target's snapshot is loaded before its turns run;
 *  a foreign / unloaded snapshot, or a non-agent block, falls back to `null` — the acceptance surface guards
 *  that residue). Returns a one-line failure message, or `null` when the argument conforms. */
function conformCallAgentArgument(
  ctx: StepContext,
  callable: Extract<Value, { kind: "agent" | "closure" }>,
  args: Value | null,
): string | null {
  const failures = conformCallableArgumentSync(callable, args, ctx.irSource);
  if (failures === null) return null;
  const target = callable.kind === "agent" ? String(callable.name) : "closure";
  return `${target}: the argument does not conform to the input schema — ${renderConformFailures(failures)}`;
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

/** Raise a `return` / `break` / `break-for` exit, by the role of the block it targets. A `for` and a
 *  `forever` share the `break-for` ask: both catch it on the thread whose block the `target` names, and a
 *  `forever` break completes the loop with the value exactly as a `for` break does. */
function raiseExit(ctx: StepContext, thread: SequenceThread, operation: ExitOperation): void {
  const target = getBlock(ctx, operation.target);
  const value = requireVariable(ctx, thread.scopeId, operation.value);
  const ask: AskKind =
    target.kind === "agent"
      ? { kind: "return", value, target: operation.target }
      : target.kind === "handle"
        ? { kind: "break", value, target: operation.target }
        : target.kind === "for" || target.kind === "forever"
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
      : target.kind === "for" || target.kind === "forever"
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
