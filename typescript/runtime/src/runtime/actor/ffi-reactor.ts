// FfiReactor: the `ffi` reactor — the external (FFI) world as a call reactor (see 'ExternalCallReactor' for
// the shared callee-call lifecycle). An external call reaches it as a `delegate` routed from core's
// `ExternalThread` proxy; it dispatches the handler through its subprocess transport and the base turns the
// completion into the call's `delegateAck` / `escalate` / `terminateAck`. It owns its in-flight calls as
// durable `ffi`-kind external-call rows (its callee-side warm state) — symmetric to core owning its
// instances. Execution is AT-MOST-ONCE, like http: recovery never re-runs a handler (a handler whose
// process died fails as a panic; retrying is katari-level policy), so the argument is not persisted
// either — a reloaded call carries none, exactly like an http call.
//
// A running handler can call back INTO the runtime (`innerDelegate` — the transport's inbound agent-call
// channel): this reactor only resolves the request to a delegate target and hands it to the base. A `named`
// callee resolves against the parent call's own snapshot (an agent and its FFI handler deploy together) — a
// qualified agent name for `core` (the default), or an external key for another call reactor (`ffi` /
// `http`). A `value` callee is a callable the handler received (`KatariAgent.call`); the shared dynamic
// dispatch resolves it to its target (a tool validates its argument against its schema) and it runs on
// `core`, carrying its own generics. Unlike the katari `call_agent` primitive, a bad callable value here is
// a plain error (a panic): a malformed value crossing the FFI boundary is a bug, not a catchable failure.
// Everything else (the delegation lifecycle, terminate distribution, escalation proxying, the durable
// correlation) is the base's; the settled outcome comes back through `deliverInnerOutcome`, lowered here.

import { createAgentName, type Json } from "@katari-lang/types";
import { type DispatchResult, dispatchCallable } from "../engine/dynamic-dispatch.js";
import { conformCallableArgumentSync } from "../engine/interop-prims.js";
import type { ReactorName } from "../event/types.js";
import type { FfiInnerDelegate, FfiTransport } from "../external/runner.js";
import type { DelegateOutcome } from "../external/sidecar-protocol.js";
import type { DelegationId, ProjectId, SnapshotId } from "../ids.js";
import type { IrSource } from "../ir.js";
import { jsonToValue, valueToJson } from "../value/codec.js";
import type { Value } from "../value/types.js";
import { renderConformFailures } from "../value/validation.js";
import {
  documentOf,
  encodeInnerCalls,
  encodeRelays,
  innerCallsOf,
  relaysOf,
  stringFieldOf,
} from "./extension-codec.js";
import {
  type CallRow,
  type DecodedCallExtension,
  type EscalationRelayRow,
  ExternalCallReactor,
  type ExternalTarget,
  type InnerCallRow,
  type InnerDelivery,
} from "./external-call-reactor.js";
import { messageOf } from "./failure.js";
import type { ResourcePool } from "./resource-pool.js";

/** An ffi call's transport data: the snapshot whose sidecar bundle hosts the handler, the dispatch key, and
 *  the argument. Only the snapshot + key persist (recovery never re-runs, so the argument is never re-sent —
 *  a reloaded call carries `null`, like http). */
interface FfiPayload {
  snapshot: SnapshotId;
  key: string;
  argument: Value | null;
}

/** The ffi extension document: what an in-flight handler call must reconstruct from — the version pin
 *  (whose compiled sidecar bundle hosts the handler), the dispatch key, and the inner-delegation bridges.
 *  The argument is deliberately absent: recovery never re-runs a handler (at-most-once), so nothing ever
 *  reads it back — and not storing it keeps one less secret-bearing value at rest. */
export interface FfiExtension {
  snapshotId: SnapshotId;
  key: string;
  relays: EscalationRelayRow[];
  innerCalls: InnerCallRow[];
}

/** Encode an ffi call's extension document (pure — the persistence port seals it as a whole). */
export function encodeFfiExtension(extension: FfiExtension): Json {
  return {
    snapshotId: extension.snapshotId,
    key: extension.key,
    relays: encodeRelays(extension.relays),
    innerCalls: encodeInnerCalls(extension.innerCalls),
  };
}

/** Decode an ffi call's extension document (pure) — also what the run-tree repository renders an ffi
 *  node's dispatch key / snapshot from, so the document's schema has exactly one owner. */
export function decodeFfiExtension(extension: Json): FfiExtension {
  const document = documentOf(extension);
  return {
    snapshotId: stringFieldOf(document, "snapshotId") as SnapshotId,
    key: stringFieldOf(document, "key"),
    relays: relaysOf(document),
    innerCalls: innerCallsOf(document),
  };
}

export class FfiReactor extends ExternalCallReactor<FfiPayload> {
  readonly name: ReactorName = "ffi";

  constructor(
    private readonly projectId: ProjectId,
    private readonly transport: FfiTransport,
    pool: ResourcePool,
    private readonly irSource: IrSource,
  ) {
    super(pool);
  }

  protected openPayload(target: ExternalTarget, argument: Value | null): FfiPayload {
    return { snapshot: target.snapshot, key: target.key, argument };
  }

  protected dispatch(delegation: DelegationId, payload: FfiPayload): void {
    this.transport.dispatch({
      projectId: this.projectId,
      delegation,
      snapshot: payload.snapshot,
      key: payload.key,
      // FFI is an allowed sink for secrets (an API key flows to its external call), so a private argument is
      // revealed to the sidecar here — unlike the user-facing API, which redacts.
      argument: payload.argument === null ? null : valueToJson(payload.argument, "reveal"),
    });
  }

  protected recover(delegation: DelegationId): void {
    this.transport.recover(delegation);
  }

  protected abort(delegation: DelegationId): void {
    this.transport.abort(delegation);
  }

  protected encodeCallExtension(row: CallRow<FfiPayload>): Json {
    return encodeFfiExtension({
      snapshotId: row.payload.snapshot,
      key: row.payload.key,
      relays: row.relays,
      innerCalls: row.innerCalls,
    });
  }

  protected decodeCallExtension(extension: Json): DecodedCallExtension<FfiPayload> {
    const decoded = decodeFfiExtension(extension);
    return {
      // The argument is not persisted (at-most-once recovery never re-sends), so a reloaded call has none.
      payload: { snapshot: decoded.snapshotId, key: decoded.key, argument: null },
      relays: decoded.relays,
      innerCalls: decoded.innerCalls,
    };
  }

  // ─── the inner agent-call channel (a handler calling back into the runtime) ─────────────────────

  /** A running handler asked to call another agent. Resolve the request to a delegate target against the
   *  parent call's snapshot and open the inner delegation through the base; a request that cannot be
   *  accepted (an unknown reactor, an undecodable argument, a call that is gone or cancelling) is failed
   *  back to the sidecar immediately — nothing was opened, so there is nothing durable to settle. */
  innerDelegate(request: FfiInnerDelegate): void {
    const payload = this.payloadOf(request.delegation);
    if (payload === undefined) {
      this.failInnerDelegate(request, { kind: "cancelled" });
      return;
    }
    const resolved = resolveInnerCall(request, payload.snapshot, this.irSource);
    if ("error" in resolved) {
      this.failInnerDelegate(request, { kind: "error", message: resolved.error });
      return;
    }
    const delegation = this.openInnerDelegation(
      request.delegation,
      resolved.target,
      resolved.to,
      resolved.argument,
      request.call,
      resolved.generics,
    );
    if (delegation === null) this.failInnerDelegate(request, { kind: "cancelled" });
  }

  /** Fail an inner call straight back to the sidecar, outside the durable protocol (no delegation was
   *  opened). Delivered directly — this runs in an originated turn, and the rejection depends on no
   *  durable state, so post-commit staging would gain nothing. */
  private failInnerDelegate(
    request: FfiInnerDelegate,
    outcome: { kind: "error"; message: string } | { kind: "cancelled" },
  ): void {
    this.transport.deliverDelegateResult({
      delegation: request.delegation,
      call: request.call,
      outcome,
    });
  }

  protected deliverInnerOutcome(delivery: InnerDelivery): void {
    this.transport.deliverDelegateResult({
      delegation: delivery.delegation,
      call: delivery.call,
      outcome: lowerInnerOutcome(delivery.outcome),
    });
  }

  // `registerProducedBlob` (a handler's mid-call upload over the blob side channel) is the base
  // `ExternalCallReactor` method — shared with the mcp reactor, whose transport produces blobs from a
  // tool result's image content the same way.
}

/** Lower a settled inner outcome to the sidecar's wire form. A `result` crosses the FFI sidecar's secret sink
 *  (revealed, exactly like the outer call's argument); an `error` / `cancelled` pass through unchanged. A
 *  callee's failure no longer settles the inner call (it proxies up), so no `throw` reaches this boundary. */
function lowerInnerOutcome(outcome: InnerDelivery["outcome"]): DelegateOutcome {
  switch (outcome.kind) {
    case "result":
      return { kind: "result", value: valueToJson(outcome.value, "reveal") };
    default:
      return outcome;
  }
}

/** Resolve an inner call the sidecar asked for. A `named` callee resolves against the parent call's
 *  snapshot — an agent and its FFI handlers deploy together, so the sidecar names siblings of its own
 *  version (`core` runs a named agent, `ffi` / `http` an external key; http ignores the snapshot; `api` is
 *  not a callee, and an unknown name is a spelling error). A `value` callee is a callable the handler
 *  received: the shared dynamic dispatch resolves it to its target and it runs on `core`, carrying its own
 *  generics. `context.call` is DYNAMIC dispatch, like the AI's `call_agent`: an INPUT / dispatch error is the
 *  CALLER's, so it is a catchable `{ error }` (surfaced to `context.call` as `KatariCallError`) — the
 *  argument is pre-validated against the callee's declared input schema here (a `tool` by `dispatchCallable`,
 *  an agent / closure by `conformCallableArgumentSync`), so a mismatch never reaches the acceptance surface as
 *  an uncatchable panic. Only a callee's EXECUTION failure proxies up (the no-catch model, unchanged). */
function resolveInnerCall(
  request: FfiInnerDelegate,
  snapshot: SnapshotId,
  irSource: IrSource,
): DispatchResult | { error: string } {
  const decoded = decodeArgument(request.argument);
  if ("error" in decoded) return decoded;
  const callee = request.callee;
  switch (callee.kind) {
    case "named": {
      if (callee.agent.length === 0) return { error: "the agent to call must be a non-empty name" };
      const reactor = callee.reactor ?? "core";
      switch (reactor) {
        case "core": {
          const name = createAgentName(callee.agent);
          // Resolve the target up front. `context.call` is dynamic dispatch, so an unresolvable named agent
          // (a spelling error in the sidecar's call) is the CALLER's dispatch error — a catchable `{ error }`
          // here, exactly like a non-conforming argument — never core's acceptance-surface panic, which the
          // ffi call instance (not core) would have to own the escalation row for. The parent call's snapshot
          // is loaded (its handler is running against it), so this resolves synchronously.
          try {
            irSource.locate(snapshot, name);
          } catch (error) {
            return { error: `${callee.agent}: the agent cannot be resolved — ${messageOf(error)}` };
          }
          const failures = conformCallableArgumentSync(
            { kind: "agent", name, snapshot },
            decoded.value,
            irSource,
          );
          if (failures !== null) {
            return {
              error: `${callee.agent}: the argument does not conform to the input schema — ${renderConformFailures(failures)}`,
            };
          }
          return { target: { kind: "named", name, snapshot }, to: "core", argument: decoded.value };
        }
        case "ffi":
        case "http":
          return {
            target: { kind: "external", key: callee.agent, snapshot },
            to: reactor,
            argument: decoded.value,
          };
        default:
          return { error: `unknown reactor "${reactor}" (expected "core", "ffi", or "http")` };
      }
    }
    case "value": {
      let callable: Value;
      try {
        callable = jsonToValue(callee.callable);
      } catch (error) {
        return { error: `the callable is not a decodable value: ${messageOf(error)}` };
      }
      // An agent / closure callee's input is pre-validated here (a `tool` and a non-callable value fall to
      // `dispatchCallable`, which validates the tool and errors on the non-callable), so a bad argument is a
      // catchable dispatch error rather than the acceptance surface's panic.
      const failures = conformCallableArgumentSync(callable, decoded.value, irSource);
      if (failures !== null) {
        return {
          error: `the argument does not conform to the input schema — ${renderConformFailures(failures)}`,
        };
      }
      // The shared dispatch already returns the exact `DispatchResult` this resolver promises.
      return dispatchCallable(callable, decoded.value);
    }
  }
}

/** Decode an inner call's wire argument into an engine value, or report it as a failure. */
function decodeArgument(argument: Json | null): { value: Value | null } | { error: string } {
  try {
    return { value: argument === null ? null : jsonToValue(argument) };
  } catch (error) {
    return { error: `the call argument is not a decodable value: ${messageOf(error)}` };
  }
}
