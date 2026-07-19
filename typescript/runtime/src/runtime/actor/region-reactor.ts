// RegionReactor: the `region` reactor — the built-in structured-concurrency NURSERY as a call reactor (see
// `ExternalCallReactor` for the shared callee-call lifecycle). Like `time`, it is an in-runtime scheduler
// with no external process to reconcile: the compiled `prelude.region.*` externals arrive as their qualified
// names on the wire, told apart ONCE at the `openPayload` boundary.
//
// This wave implements only `provide` — the SCOPED provider (the `runST` shape), the concurrency
// specialisation of `mcp.provide`. A `provide` opens a nursery scope (an in-runtime identity minted at open,
// registered while the block is live), MINTS a `nursery` handle value carrying that scope identity, and
// dispatches the CONTINUATION as ONE inner delegation receiving `{ value: nursery }`. The whole call settles
// with the continuation's outcome (the serve / webhook `innerOutcomeAsCompletion` template), and settling —
// or cancelling — closes the scope. There is no listing (no server to enumerate) and no transport, so unlike
// `mcp.provide` the continuation dispatches directly on the first post-commit turn rather than after a side
// `listTools` delegation lands.
//
// The scope's identity is a routing key ONLY: the compiler's phantom `scope` marker enforces the "no fiber
// outlives its provide" story at type-check time, so the runtime never inspects the marker — it registers the
// scope while the provide is live and closes it at drop, and later waves' `fork` / `join` / `cancel` gate on
// `scopes.has(scope)` exactly as `mcp` gates a minted tool call on its still-open provide scope. The nursery
// handle carries that identity so a `fork` can find its nursery.
//
// `fork` / `join` / `watch` / `cancel` are NOT implemented in this wave: the `provide` continuation the tests
// run never calls them, so their keys can only reach `openPayload` as a defensive case — folded into the
// `operation` payload variant, which fails the call with a clear "not yet implemented" completion. Wave 3
// replaces the `fork` key's handling with a real fiber spawn.
//
// Durably a `provide` persists its endpoint payload (its scope id + the still-stored continuation + the
// inner-delegation bridges) and survives a restart COMPLETELY, re-registering the scope and resuming its
// continuation as durable core work — there is no external process, so recovery has nothing to reconcile
// (like `webhook` / `time`). It mints no public capability token (unlike `mcp.serve` / `webhook`, a nursery
// has no inbound URL).

import { randomBytes } from "node:crypto";
import type { Json } from "@katari-lang/types";
import { dispatchCallable } from "../engine/dynamic-dispatch.js";
import type { ReactorName } from "../event/types.js";
import type { DelegationId, SnapshotId } from "../ids.js";
import type { Value } from "../value/types.js";
import {
  asJson,
  documentOf,
  encodeInnerCalls,
  encodeRelays,
  innerCallsOf,
  relaysOf,
  stringFieldOf,
  warmFieldOf,
} from "./extension-codec.js";
import {
  type CallRow,
  type DecodedCallExtension,
  type EscalationRelayRow,
  ExternalCallReactor,
  type ExternalTarget,
  type InnerCallRow,
  type InnerDelivery,
  innerOutcomeAsCompletion,
} from "./external-call-reactor.js";
import type { ResourcePool } from "./resource-pool.js";

/** The reserved dispatch keys the compiled `prelude.region.*` externals arrive under — compared exactly here,
 *  at the payload boundary. Only `provide` is dispatched this wave; the other four are folded into the
 *  `operation` payload (a "not yet implemented" completion) until their waves land. */
const REGION_PROVIDE_KEY = "prelude.region.provide";

/** The field the minted nursery handle carries its scope identity under — a namespaced marker key (disjoint
 *  from any user-authored record key, which never lives in the `$katari_` namespace), so the handle reads as a
 *  runtime value, not user data. Later waves' `fork` / `join` / `watch` / `cancel` read the scope from here to
 *  route to THIS nursery. The nursery type is a phantom `agent` the program never calls, so an opaque record
 *  carrying only the identity is its honest runtime shape (the identity is all the runtime routes on — the
 *  fiber-effect ceiling `E` is a compile-time bound the runtime never checks). */
const NURSERY_SCOPE_FIELD = "$katari_region_scope";

/** The continuation's reserved inner-call token: a provide's continuation IS the whole call, so its settlement
 *  settles the provide (the same role `mcp`'s / `webhook`'s subscriber token plays). Later waves' fibers use
 *  fresh `fiber:` tokens, distinct from this one. */
const CONTINUATION_CALL = "continuation";

/** What a region call holds, a two-way sum every lifecycle method dispatches once: a `provide` scope (its
 *  scope id + the not-yet-dispatched continuation — persisted, so the scope survives a restart), or an
 *  `operation` — a `fork` / `join` / `watch` / `cancel` this wave has not implemented, which fails the call
 *  with a clear completion. Wave 3 turns the `fork` key into its own real variant. */
type RegionPayload =
  | {
      kind: "provide";
      /** The snapshot the continuation dispatches against — persisted, so a reloaded scope dispatches
       *  against the same version. */
      snapshot: SnapshotId;
      /** The runtime scope identity minted at open — carried in the nursery handle, registered while the
       *  provide is live, closed at drop. Persisted so a restart re-registers exactly it. */
      scope: string;
      /** The continuation to run inside the scope — consumed (set to `null`) once dispatched, so a reload
       *  distinguishes a not-yet-started provide (re-dispatch it) from an active one (resume). */
      continuation: Value | null;
    }
  | {
      kind: "operation";
      /** The reserved key the call arrived under — named in the "not yet implemented" completion. */
      operation: string;
    };

/** A region call's durable extension document — a REAL sum, one tag. A `provide` persists its endpoint payload
 *  (scope id + continuation + bridges) so a restart re-registers it; an `operation` persists only its key (it
 *  fails immediately, but a crash mid-flight still reloads it as the same refusal). */
export type RegionExtension =
  | {
      kind: "provide";
      snapshotId: SnapshotId;
      scopeId: string;
      continuation: Value | null;
      relays: EscalationRelayRow[];
      innerCalls: InnerCallRow[];
    }
  | { kind: "operation"; operation: string };

/** Encode a region call's extension document (pure — the persistence port seals it as a whole; the
 *  continuation may capture private leaves, and they seal in place). */
export function encodeRegionExtension(extension: RegionExtension): Json {
  switch (extension.kind) {
    case "provide":
      return {
        kind: "provide",
        snapshotId: extension.snapshotId,
        scopeId: extension.scopeId,
        continuation: asJson(extension.continuation),
        relays: encodeRelays(extension.relays),
        innerCalls: encodeInnerCalls(extension.innerCalls),
      };
    case "operation":
      return { kind: "operation", operation: extension.operation };
  }
}

/** Decode a region call's extension document (pure) — one tag dispatch. */
export function decodeRegionExtension(extension: Json): RegionExtension {
  const document = documentOf(extension);
  const kind = stringFieldOf(document, "kind");
  switch (kind) {
    case "provide":
      return {
        kind: "provide",
        snapshotId: stringFieldOf(document, "snapshotId") as SnapshotId,
        scopeId: stringFieldOf(document, "scopeId"),
        continuation: warmFieldOf<Value | null>(document, "continuation"),
        relays: relaysOf(document),
        innerCalls: innerCallsOf(document),
      };
    case "operation":
      return { kind: "operation", operation: stringFieldOf(document, "operation") };
    default:
      throw new Error(`unknown region extension kind "${kind}" (corrupt row)`);
  }
}

export class RegionReactor extends ExternalCallReactor<RegionPayload> {
  readonly name: ReactorName = "region";

  /** The live provide scopes, by their identity. Registered at dispatch / reload of a running provide,
   *  released at drop — later waves' `fork` / `join` / `cancel` check membership here (the requires-a-live-
   *  provide gate). A bare set suffices: a nursery scope owns no connection (unlike an mcp descriptor), so
   *  there is nothing to refcount or evict beyond the membership itself. */
  private readonly scopes = new Set<string>();

  constructor(
    /** Schedule a fresh reactor turn (the substrate's serial mailbox) — how a provide's post-commit work
     *  (the continuation dispatch, a synthesised completion) re-enters the transactional loop, so its inner
     *  delegation opens inside a turn and commits with it. */
    private readonly schedule: (work: () => void) => void,
    pool: ResourcePool,
  ) {
    super(pool);
  }

  // ─── the provide scope registry ────────────────────────────────────────────────────────────────

  /** Register a provide's scope as live. Called at a fresh dispatch and at every reload of a running
   *  provide, so a later `fork` finds its nursery. */
  private openScope(scope: string): void {
    this.scopes.add(scope);
  }

  /** Close a provide's scope at its drop (idempotent — an already-closed scope removes nothing). */
  private closeScope(scope: string): void {
    this.scopes.delete(scope);
  }

  // ─── the ExternalCallReactor hooks ───────────────────────────────────────────────────────────────

  protected openPayload(target: ExternalTarget, argument: Value | null): RegionPayload {
    if (target.key === REGION_PROVIDE_KEY) {
      const fields = argument !== null && argument.kind === "record" ? argument.fields : {};
      return {
        kind: "provide",
        snapshot: target.snapshot,
        // 18 random bytes, base64url — the scope identity the nursery handle carries and later waves check.
        scope: `regionscope:${randomBytes(18).toString("base64url")}`,
        continuation: fields.continuation ?? null,
      };
    }
    // `fork` / `join` / `watch` / `cancel` — not implemented this wave. The continuation never calls them, so
    // this is defensive: carry the key so `dispatch` fails the call with a clear completion (never a silent
    // misroute into `provide`).
    return { kind: "operation", operation: target.key };
  }

  protected dispatch(delegation: DelegationId, payload: RegionPayload): void {
    if (payload.kind === "operation") {
      this.schedule(() =>
        this.complete({
          delegation,
          outcome: {
            kind: "error",
            message: `${payload.operation}: the region reactor does not implement this operation yet`,
          },
        }),
      );
      return;
    }
    // Post-commit: register the scope, then hand the one-time continuation dispatch back to the serial loop
    // (opening its inner delegation must happen inside a turn). A fresh provide without a continuation is a
    // malformed call that would otherwise register a scope and sit forever — fail it at once.
    this.openScope(payload.scope);
    if (payload.continuation === null) {
      this.schedule(() =>
        this.complete({
          delegation,
          outcome: { kind: "error", message: "region.provide: the continuation is missing" },
        }),
      );
      return;
    }
    this.schedule(() => this.startContinuation(delegation));
  }

  /** The one-time continuation dispatch (a reactor turn): mint the nursery handle for this scope and delegate
   *  the continuation with `{ value: nursery }`. Its settlement is the whole call's settlement (see
   *  `deliverInnerOutcome`). The continuation is then consumed (`null`), so a reload from here resumes it as
   *  durable core work instead of re-dispatching. */
  private startContinuation(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined || payload.kind !== "provide") return; // resolved / cancelled meanwhile
    const continuation = payload.continuation;
    if (continuation === null) return; // already dispatched (a duplicate schedule) — nothing to do
    const nursery = mintNursery(payload.scope);
    // `{ value: nursery }` conforms to the continuation's declared input BY CONSTRUCTION: `region.provide`'s
    // signature types the continuation as `agent (value: nursery[Scope, E]) -> ...`, and this internal
    // dispatch does not go through a dynamic-input boundary's pre-check — so it never mismatches at the
    // acceptance surface and needs no guard of its own (a `dispatchCallable` error is a non-callable
    // continuation, still handled below).
    const argument: Value = { kind: "record", fields: { value: nursery } };
    const dispatched = dispatchCallable(continuation, argument);
    if ("error" in dispatched) {
      this.complete({
        delegation,
        outcome: {
          kind: "error",
          message: `region.provide: the continuation is ${dispatched.error}`,
        },
      });
      return;
    }
    const opened = this.openInnerDelegation(
      delegation,
      dispatched.target,
      dispatched.to,
      dispatched.argument,
      CONTINUATION_CALL,
      dispatched.generics,
    );
    if (opened === null) return; // the provide is winding down — its own cancel path settles it
    // Consumed: from here the continuation is a durable inner delegation, so stop persisting it (a reload
    // resumes that delegation instead of re-dispatching). `openInnerDelegation` already marked the call dirty.
    payload.continuation = null;
  }

  /** A settled inner delegation. The continuation IS the whole call — feed its outcome back as the completion
   *  on a fresh turn (values lower to the completion's wire Json and decode back at the base, `reveal` so
   *  content survives the internal round-trip). No other inner-call token exists this wave; a fiber's outcome
   *  (a fresh `fiber:` token) resolves here in wave 3. */
  protected override deliverInnerOutcome(delivery: InnerDelivery): void {
    if (delivery.call === CONTINUATION_CALL) {
      this.schedule(() =>
        this.complete({
          delegation: delivery.delegation,
          outcome: innerOutcomeAsCompletion(delivery.outcome),
        }),
      );
    }
  }

  /** Reactivation: re-register a reloaded provide's scope, and either re-dispatch its continuation (still
   *  stored — the block never started) or resume it (already dispatched, so it is durable core work). There is
   *  no external process to reconcile — a provide survives a restart completely (like `webhook` / `time`). An
   *  `operation` call is at-most-once: it never really began (it fails immediately), so a reloaded one refuses
   *  again, never re-run. */
  protected recover(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined || payload.kind !== "provide") {
      this.schedule(() =>
        this.complete({
          delegation,
          outcome: {
            kind: "error",
            message: "region: an unimplemented operation was interrupted by a runtime restart",
          },
        }),
      );
      return;
    }
    this.openScope(payload.scope);
    if (payload.continuation !== null) this.schedule(() => this.startContinuation(delegation));
  }

  /** A cancel's transport half: confirm on a fresh turn (a provide has no external work of its own — its
   *  children, the continuation and later its fibers, drain through the base's cancel cascade; the scope
   *  closes at drop). An `operation` call likewise just confirms. */
  protected abort(delegation: DelegationId): void {
    this.schedule(() => this.complete({ delegation, outcome: { kind: "cancelled" } }));
  }

  /** A call resolved: close a provide's scope (the drop hook covers every resolution path at once). */
  protected override onDropCall(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload !== undefined && payload.kind === "provide") this.closeScope(payload.scope);
  }

  protected encodeCallExtension(row: CallRow<RegionPayload>): Json {
    const payload = row.payload;
    switch (payload.kind) {
      case "provide":
        return encodeRegionExtension({
          kind: "provide",
          snapshotId: payload.snapshot,
          scopeId: payload.scope,
          continuation: payload.continuation,
          relays: row.relays,
          innerCalls: row.innerCalls,
        });
      case "operation":
        return encodeRegionExtension({ kind: "operation", operation: payload.operation });
    }
  }

  protected decodeCallExtension(extension: Json): DecodedCallExtension<RegionPayload> {
    const decoded = decodeRegionExtension(extension);
    switch (decoded.kind) {
      case "provide":
        return {
          payload: {
            kind: "provide",
            snapshot: decoded.snapshotId,
            scope: decoded.scopeId,
            continuation: decoded.continuation,
          },
          relays: decoded.relays,
          innerCalls: decoded.innerCalls,
        };
      case "operation":
        return {
          payload: { kind: "operation", operation: decoded.operation },
          relays: [],
          innerCalls: [],
        };
    }
  }

  override reset(): void {
    super.reset();
    this.scopes.clear();
  }
}

/** Mint the nursery handle `region.provide` hands its continuation for `scope`: an opaque record carrying only
 *  the scope identity, under the namespaced marker field. Later waves' `fork` / `join` / `watch` / `cancel`
 *  read the identity from here to route an operation to THIS nursery. */
function mintNursery(scope: string): Value {
  return {
    kind: "record",
    fields: { [NURSERY_SCOPE_FIELD]: { kind: "string", value: scope } },
  };
}
