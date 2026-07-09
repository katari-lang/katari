// Dynamic dispatch: resolving a callable VALUE (an `agent` reference, a `closure`, or a reactor-backed
// `tool`) and its argument into the `delegate` it stands for. This is the one place value→target dispatch
// lives, shared by every emit site that turns a runtime-decided callable into a real sub-call:
//   - the engine's delegate operation (`reflection.call_agent` and a callee VALUE — resolved where the
//     call is emitted, so the delegate routes straight to its executor);
//   - the FFI sidecar's `KatariAgent.call` (`FfiReactor`) and the webhook reactor's callback dispatch.
// Keeping them on one function means a tool's runtime schema check and the target shapes cannot drift
// between the language-level and the boundary entry points.

import type { DelegateTarget, ReactorName } from "../event/types.js";
import type { GenericSubstitution, Value } from "../value/types.js";
import { conformValue, renderConformFailures } from "../value/validation.js";

/** A resolved dynamic dispatch: the delegate `target` the callable stands for, the `argument` to run it
 *  with, the reactor the delegate routes `to` (core for compiled callables, the tool's own reactor for a
 *  reactor-backed one), and the callable's carried generic instantiation. */
export interface DispatchResult {
  target: DelegateTarget;
  argument: Value | null;
  to: ReactorName;
  generics?: GenericSubstitution;
}

/** The reactors that may back a tool value. Values are runtime-minted, so an unknown name here means a
 *  corrupted / drifted value — the dispatch fails rather than routing an event nowhere. */
const TOOL_REACTORS = new Set<string>(["mcp"]);

/** Resolve a callable value + its argument into the delegate it dispatches to, or `{ error }` when the
 *  value is not callable / a tool's argument violates its attached schema.
 *
 *  A `tool` (a reactor-backed agent) is dynamic dispatch with a runtime-decided signature: its argument
 *  is validated against the attached `inputSchema` here (a mismatch is the failure a dynamic dispatch
 *  anticipates), then the delegate targets the tool's REACTOR directly — the argument passes through
 *  verbatim, and the tool's `context` rides the external target out-of-band, exactly like a closure's
 *  captured scope rides its target. The caller decides how to surface an `error` —
 *  `reflection.call_error` at language-level sites, a panic at the FFI boundary. */
export function dispatchCallable(
  callable: Value,
  args: Value | null,
): DispatchResult | { error: string } {
  if (callable.kind === "agent") {
    return {
      target: { kind: "named", name: callable.name, snapshot: callable.snapshot },
      argument: args,
      to: "core",
      ...(callable.generics !== undefined ? { generics: callable.generics } : {}),
    };
  }
  if (callable.kind === "closure") {
    return {
      target: {
        kind: "closure",
        blockId: callable.blockId,
        scopeId: callable.scopeId,
        snapshot: callable.snapshot,
        module: callable.module,
      },
      argument: args,
      to: "core",
      ...(callable.generics !== undefined ? { generics: callable.generics } : {}),
    };
  }
  if (callable.kind === "tool") {
    if (!TOOL_REACTORS.has(callable.reactor)) {
      return { error: `tool "${callable.name}": unknown backing reactor "${callable.reactor}"` };
    }
    const check = conformValue(args ?? { kind: "record", fields: {} }, callable.inputSchema);
    if (!check.ok) {
      return {
        error: `tool "${callable.name}": the argument does not conform to the tool's input schema — ${renderConformFailures(check.failures)}`,
      };
    }
    return {
      target: {
        kind: "external",
        key: callable.name,
        snapshot: callable.snapshot,
        context: callable.context,
      },
      argument: args,
      // The set membership above pins the string to a real reactor name.
      to: callable.reactor as ReactorName,
    };
  }
  return { error: `not a callable value (got ${callable.kind})` };
}
