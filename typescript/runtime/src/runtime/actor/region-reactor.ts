// RegionReactor: the `region` reactor — the built-in structured-concurrency NURSERY as a call reactor (see
// `ExternalCallReactor` for the shared callee-call lifecycle). Like `time`, it is an in-runtime scheduler
// with no external process to reconcile: the compiled `prelude.region.*` externals arrive as their qualified
// names on the wire, told apart ONCE at the `openPayload` boundary.
//
// `provide` is the SCOPED provider (the `runST` shape), the concurrency specialisation of `mcp.provide`. A
// `provide` opens a nursery scope (an in-runtime identity minted at open, registered while the block is live),
// MINTS a `nursery` handle value carrying that scope identity, and dispatches the CONTINUATION as ONE inner
// delegation receiving `{ value: nursery }`. The whole call settles with the continuation's outcome (the
// serve / webhook `innerOutcomeAsCompletion` template), and settling — or cancelling — closes the scope.
// There is no listing (no server to enumerate) and no transport, so unlike `mcp.provide` the continuation
// dispatches directly on the first post-commit turn rather than after a side `listTools` delegation lands.
//
// `fork` spawns a fiber into a live nursery. It is its OWN call (a separate `prelude.region.fork` delegate),
// yet the fiber it starts is NOT the fork call's child: `fork` opens the task as an inner delegation of the
// nursery's PROVIDE call, then settles ITSELF at once with a `fiber` handle value. Parenting the fiber on the
// provide is what buys the structured-concurrency story from the base for free — the fiber's escalations
// relay UP through the provide (the `relays` bridge) into the enclosing program, and the fiber is cancelled
// by the provide's own cancel cascade (`terminateChildren`) when the block returns, so no fiber outlives its
// nursery. A fiber that SETTLES before it is joined has its outcome buffered on the provide (the durable
// `fiberBuffer`) until a `join` takes it.
//
// `join` awaits ONE fiber and returns the value it settled with. Like `fork` it is its OWN call, routed by the
// fiber HANDLE it is handed — the handle names the scope of the nursery that spawned the fiber (not the
// `nursery` argument, which the type system only pins `Scope` through), so a fiber is always awaited in its
// OWN nursery even under nested same-marker scopes. If the fiber already SETTLED its outcome is in the
// provide's `fiberBuffer`: `join` removes it (single-consumer — the buffer entry is taken once) and settles at
// once, handing the fiber's result RESOURCES from the provide instance across to the join's own instance so
// its `delegateAck` reowns them to the join's caller (the fiber's blobs / scopes were re-owned onto the
// provide when it settled). If the fiber is still RUNNING, `join` holds its call open and parks a WAITER (an
// in-memory `Map<fiberId, joinDelegation>`, like `mcp`'s served-call waiters) that `bufferFiberOutcome`
// settles directly instead of buffering when that fiber later lands. A handle that is neither buffered nor
// running is not joinable — already joined (single-consumer), a malformed handle, or a fiber lost to the
// buffer's post-commit durability window — and since the checker pins the handle's scope to a live nursery,
// reaching that runtime state is an engine-invariant break, so it PANICS (`join`'s row declares no throw, and
// region has no error sum — the same backstop as a dead-scope fork).
//
// The scope's identity is a routing key ONLY: the compiler's phantom `scope` marker enforces the "no fiber
// outlives its provide" story at type-check time, so the runtime never inspects the marker — it registers the
// scope while the provide is live (mapping it to that provide's call, so a `fork` finds the nursery to spawn
// into) and closes it at drop. A `fork` whose scope is not live is refused — the requires-a-live-provide
// boundary, exactly as `mcp` gates a minted tool call on its still-open provide scope; since `fork`'s type
// discharges `Scope` at its provide, a dead-scope fork is impossible under the checker, so the runtime refusal
// is an engine-invariant backstop (a panic — `fork`'s row declares no throw, and region has no error sum).
//
// `watch` / `cancel` are NOT implemented in this wave: their keys reach `openPayload` only as a defensive
// case, folded into the `operation` payload variant, which fails the call with a clear "not yet implemented"
// completion until their wave lands.
//
// Durably a `provide` persists its endpoint payload (its scope id + the still-stored continuation + the
// settled-fiber buffer + the inner-delegation bridges) and survives a restart COMPLETELY, re-registering the
// scope and resuming its continuation and running fibers as durable core work — there is no external process,
// so recovery has nothing to reconcile (like `webhook` / `time`). A `fork` persists its (task + argument)
// re-dispatch and simply re-spawns on reload: its only effect is opening an internal delegation, so re-running
// an interrupted one is safe (a committed fork is already gone). A `join` persists its (scope + fiber) so a
// join left waiting by a restart re-drains / re-parks against the reloaded buffer and running-fiber set; it,
// too, has no external effect to reconcile. None of these mint a public capability token (unlike `mcp.serve` /
// `webhook`, a nursery has no inbound URL).

import { randomBytes } from "node:crypto";
import type { Json } from "@katari-lang/types";
import { dispatchCallable } from "../engine/dynamic-dispatch.js";
import type { ReactorName } from "../event/types.js";
import type { DelegationId, SnapshotId } from "../ids.js";
import { valueToJson } from "../value/codec.js";
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
 *  at the payload boundary. `provide` / `fork` / `join` are dispatched this wave; `watch` / `cancel` fold into
 *  the `operation` payload (a "not yet implemented" completion) until their wave lands. */
const REGION_PROVIDE_KEY = "prelude.region.provide";
const REGION_FORK_KEY = "prelude.region.fork";
const REGION_JOIN_KEY = "prelude.region.join";

/** The field the minted nursery handle carries its scope identity under — a namespaced marker key (disjoint
 *  from any user-authored record key, which never lives in the `$katari_` namespace), so the handle reads as a
 *  runtime value, not user data. A `fork` reads the scope from the nursery it is handed to route to THIS
 *  nursery; the fiber handle it returns carries the SAME field (plus its fiber id) so a `join` / `cancel`
 *  routes back. The nursery type is a phantom `agent` the program never calls, so an opaque record carrying
 *  only the identity is its honest runtime shape (the identity is all the runtime routes on — the fiber-effect
 *  ceiling `E` is a compile-time bound the runtime never checks). */
const NURSERY_SCOPE_FIELD = "$katari_region_scope";

/** The field the fiber handle carries its fiber id under (alongside the scope) — the same namespaced-marker
 *  convention as the scope, so a `fiber[Scope, T]` handle reads as an opaque runtime value. A `join` / `cancel`
 *  reads it to name WHICH fiber of the nursery to await / tear down. */
const NURSERY_FIBER_FIELD = "$katari_region_fiber";

/** The continuation's reserved inner-call token: a provide's continuation IS the whole call, so its settlement
 *  settles the provide (the same role `mcp`'s / `webhook`'s subscriber token plays). A fiber uses a fresh
 *  `fiber:` token (its own id), which is disjoint from this one — so `deliverInnerOutcome` tells a fiber's
 *  settlement from the continuation's by comparing against this constant. */
const CONTINUATION_CALL = "continuation";

/** The prefix every fiber's inner-call token (its id) carries, so a fiber token is disjoint from
 *  `CONTINUATION_CALL` and recognisable among a provide's inner-call bridges — which `repopulateRunning`
 *  filters on reload to rebuild the running-fiber set a `join` waits on. */
const FIBER_TOKEN_PREFIX = "fiber:";

/** A fiber that has settled and whose outcome waits on the provide until a `join` takes it (wave 4). A
 *  fiber's inner delegation delivers only a `result` (normal completion) here — an escalation (panic / throw /
 *  request) relays UP instead of settling the inner call, and a `cancelled` fiber (torn down with its provide)
 *  has no result to join, so neither is buffered. The `error` arm is the base's defensive residue, buffered
 *  for totality but never produced for a fiber. */
interface BufferedFiber {
  /** The fiber id the fork handle carried — a `join` / `cancel` names it. */
  fiber: string;
  outcome: { kind: "result"; value: Value } | { kind: "error"; message: string };
}

/** What a region call holds, a sum every lifecycle method dispatches once: a `provide` scope (its scope id +
 *  the not-yet-dispatched continuation + the settled-fiber buffer — persisted, so the scope survives a
 *  restart), a `fork` (the task + argument it spawns a fiber from — persisted, so an interrupted fork
 *  re-spawns), a `join` (the scope + fiber id it awaits, read from the handle — persisted, so a waiting join
 *  re-parks after a restart), or an `operation` — a `watch` / `cancel` this wave has not implemented, which
 *  fails the call with a clear completion. */
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
      /** The fibers that have settled and await a `join`. The durable buffer for this nursery — persisted on
       *  the provide's extension, so a restart restores it. A RUNNING fiber is NOT here: its source of truth
       *  is the base inner-call bridge (its `fiber:` token), which the base already persists; this holds only
       *  the SETTLED ones the base has already retired. */
      fiberBuffer: BufferedFiber[];
    }
  | {
      kind: "fork";
      /** The nursery scope the fiber spawns into, read from the handed nursery handle (`null` when the handle
       *  was malformed — refused as a dead scope). Checked live before spawning. */
      scope: string | null;
      /** The child agent to run as a fiber, and the argument applied to it — persisted, so a fork interrupted
       *  before it spawned re-dispatches identically. */
      task: Value | null;
      argument: Value | null;
    }
  | {
      kind: "join";
      /** The nursery scope and fiber id the join awaits, read from the fiber HANDLE (its own scope names the
       *  nursery that spawned it, so a fiber is joined where it lives even under nested same-marker scopes).
       *  Either is `null` when the handle was malformed — an unjoinable fiber, refused as a panic. Persisted,
       *  so a join left waiting by a restart re-parks its waiter against the reloaded running fiber. */
      scope: string | null;
      fiber: string | null;
    }
  | {
      kind: "operation";
      /** The reserved key the call arrived under — named in the "not yet implemented" completion. */
      operation: string;
    };

/** A region call's durable extension document — a REAL sum, one tag. A `provide` persists its endpoint payload
 *  (scope id + continuation + settled-fiber buffer + bridges) so a restart re-registers it; a `fork` persists
 *  its (task + argument) re-dispatch; an `operation` persists only its key (it fails immediately, but a crash
 *  mid-flight still reloads it as the same refusal). */
export type RegionExtension =
  | {
      kind: "provide";
      snapshotId: SnapshotId;
      scopeId: string;
      continuation: Value | null;
      fiberBuffer: BufferedFiber[];
      relays: EscalationRelayRow[];
      innerCalls: InnerCallRow[];
    }
  | { kind: "fork"; scopeId: string | null; task: Value | null; argument: Value | null }
  | { kind: "join"; scopeId: string | null; fiberId: string | null }
  | { kind: "operation"; operation: string };

/** Encode a region call's extension document (pure — the persistence port seals it as a whole; the
 *  continuation, a fork's task / argument, and a buffered fiber's result may capture private leaves, and they
 *  seal in place). */
export function encodeRegionExtension(extension: RegionExtension): Json {
  switch (extension.kind) {
    case "provide":
      return {
        kind: "provide",
        snapshotId: extension.snapshotId,
        scopeId: extension.scopeId,
        continuation: asJson(extension.continuation),
        fiberBuffer: asJson(extension.fiberBuffer),
        relays: encodeRelays(extension.relays),
        innerCalls: encodeInnerCalls(extension.innerCalls),
      };
    case "fork":
      return {
        kind: "fork",
        scopeId: extension.scopeId,
        task: asJson(extension.task),
        argument: asJson(extension.argument),
      };
    case "join":
      return { kind: "join", scopeId: extension.scopeId, fiberId: extension.fiberId };
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
        fiberBuffer: warmFieldOf<BufferedFiber[]>(document, "fiberBuffer"),
        relays: relaysOf(document),
        innerCalls: innerCallsOf(document),
      };
    case "fork":
      return {
        kind: "fork",
        scopeId: warmFieldOf<string | null>(document, "scopeId"),
        task: warmFieldOf<Value | null>(document, "task"),
        argument: warmFieldOf<Value | null>(document, "argument"),
      };
    case "join":
      return {
        kind: "join",
        scopeId: warmFieldOf<string | null>(document, "scopeId"),
        fiberId: warmFieldOf<string | null>(document, "fiberId"),
      };
    case "operation":
      return { kind: "operation", operation: stringFieldOf(document, "operation") };
    default:
      throw new Error(`unknown region extension kind "${kind}" (corrupt row)`);
  }
}

export class RegionReactor extends ExternalCallReactor<RegionPayload> {
  readonly name: ReactorName = "region";

  /** The live provide scopes, by their identity: the provide call each opened (a `fork` opens its fiber as an
   *  inner delegation of THIS call), and that nursery's RUNNING fibers (their inner-delegation ids, so a later
   *  `join` / `cancel` finds them). Registered at dispatch / reload of a running provide, released at drop —
   *  `fork` checks membership here (the requires-a-live-provide gate). A settled fiber lives NOT here but in
   *  the provide payload's `fiberBuffer` (the durable buffer a `join` drains); the running map is in-memory
   *  routing whose durable twin is the base inner-call bridges. */
  private readonly scopes = new Map<string, ScopeState>();

  /** The joins parked on a still-running fiber, by that fiber's id — the join's call is held open until the
   *  fiber lands. In-memory only (like `mcp`'s served-call waiters): the durable twin is the join's own
   *  `running` row plus the fiber's inner-call bridge, so a restart re-parks the waiter from `startJoin` in
   *  `recover` against the running-fiber set `repopulateRunning` rebuilt. Single-consumer — one fiber is joined
   *  once, so a second wait on a fiber already awaited is refused (a running fiber's double-join panic). */
  private readonly waiters = new Map<string, DelegationId>();

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

  /** Register a provide's scope as live, mapping it to the provide call that opened it (the parent a `fork`
   *  spawns its fiber under). Called at a fresh dispatch and at every reload of a running provide, so a `fork`
   *  finds its nursery. A reload starts with an empty running-fiber set: a still-running fiber's source of
   *  truth is the base inner-call bridge that reloads alongside, and this wave never re-reads it (a `join`
   *  does, in wave 4 — see the reload note there); a fiber that settles after the reload is buffered on-
   *  demand regardless. */
  private openScope(scope: string, provide: DelegationId): void {
    this.scopes.set(scope, { provide, running: new Map() });
  }

  /** Close a provide's scope at its drop (idempotent — an already-closed scope removes nothing). Its running
   *  fibers were the provide's inner delegations, already torn down by the base's cancel cascade before the
   *  drop, so there is nothing here to reclaim beyond the membership itself. */
  private closeScope(scope: string): void {
    this.scopes.delete(scope);
  }

  // ─── the ExternalCallReactor hooks ───────────────────────────────────────────────────────────────

  protected openPayload(target: ExternalTarget, argument: Value | null): RegionPayload {
    const fields = argument !== null && argument.kind === "record" ? argument.fields : {};
    if (target.key === REGION_PROVIDE_KEY) {
      return {
        kind: "provide",
        snapshot: target.snapshot,
        // 18 random bytes, base64url — the scope identity the nursery handle carries and a `fork` checks.
        scope: `regionscope:${randomBytes(18).toString("base64url")}`,
        continuation: fields.continuation ?? null,
        fiberBuffer: [],
      };
    }
    if (target.key === REGION_FORK_KEY) {
      // The nursery handle rides the argument (`fork(nursery, task, argument)`); its scope identity is the one
      // thing the runtime routes on — read it out now, so `dispatch` gates on a plain string. A malformed
      // handle yields a `null` scope, refused as a dead scope.
      return {
        kind: "fork",
        scope: scopeOfNursery(fields.nursery ?? null),
        task: fields.task ?? null,
        argument: fields.argument ?? null,
      };
    }
    if (target.key === REGION_JOIN_KEY) {
      // `join(nursery, handle)`: route on the HANDLE's own scope + fiber id, not the `nursery` argument (which
      // the type system only pins `Scope` through). The handle names the nursery that spawned the fiber, so a
      // fiber is awaited where it actually lives even when two nested nurseries share a scope MARKER but hold
      // distinct runtime identities. A malformed handle yields `null`s, refused as an unjoinable fiber.
      const handle = fiberHandleOf(fields.handle ?? null);
      return { kind: "join", scope: handle.scope, fiber: handle.fiber };
    }
    // `watch` / `cancel` — not implemented this wave. The continuation the tests run never calls them, so this
    // is defensive: carry the key so `dispatch` fails the call with a clear completion (never a silent misroute
    // into `provide` / `fork` / `join`).
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
    if (payload.kind === "fork") {
      // Hand the spawn back to the serial loop: opening the fiber's inner delegation is a `send`, which must
      // happen inside a turn (`dispatch` runs post-commit).
      this.schedule(() => this.startFork(delegation));
      return;
    }
    if (payload.kind === "join") {
      // Draining the buffer / parking a waiter mutates warm state a turn must own, so hand it back to the loop.
      this.schedule(() => this.startJoin(delegation));
      return;
    }
    // Post-commit: register the scope (mapping it to this provide, so a `fork` spawns into it), then hand the
    // one-time continuation dispatch back to the serial loop (opening its inner delegation must happen inside
    // a turn). A fresh provide without a continuation is a malformed call that would otherwise register a
    // scope and sit forever — fail it at once.
    this.openScope(payload.scope, delegation);
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

  /** The one-time fiber spawn (a reactor turn): check the nursery is still live, then open the task as an
   *  inner delegation of the nursery's PROVIDE call (not this fork call), and settle THIS call at once with a
   *  `fiber` handle. Parenting the fiber on the provide is what makes it a true child of the nursery — the
   *  base relays its escalations up through the provide and cancels it in the provide's cancel cascade — while
   *  `fork` returns immediately, as its signature promises. A dead scope, a missing / non-callable task, or a
   *  nursery already winding down fails the fork (a panic — `fork` declares no throw, and a dead-scope fork is
   *  a checker-prevented invariant break). */
  private startFork(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined || payload.kind !== "fork") return; // resolved / cancelled meanwhile
    const scopeState = payload.scope === null ? undefined : this.scopes.get(payload.scope);
    if (scopeState === undefined || payload.scope === null) {
      // The requires-a-live-provide boundary: the nursery's provide has closed (or the handle was malformed).
      this.complete({
        delegation,
        outcome: {
          kind: "error",
          message:
            "region.fork: the nursery's provide scope has closed; a fiber cannot be forked after its region.provide returns",
        },
      });
      return;
    }
    if (payload.task === null) {
      this.complete({
        delegation,
        outcome: { kind: "error", message: "region.fork: the task is missing" },
      });
      return;
    }
    // `task` is `agent (input: A) -> T`, so it receives `{ input: <argument> }` (the same parameter-record
    // convention the continuation's `{ value: nursery }` uses). This internal dispatch does not cross a
    // dynamic-input boundary's pre-check, so the record conforms by construction; a `dispatchCallable` error
    // is a non-callable task, handled below.
    const input: Value = {
      kind: "record",
      fields: { input: payload.argument ?? { kind: "null" } },
    };
    const dispatched = dispatchCallable(payload.task, input);
    if ("error" in dispatched) {
      this.complete({
        delegation,
        outcome: { kind: "error", message: `region.fork: the task is ${dispatched.error}` },
      });
      return;
    }
    const fiber = mintFiberId();
    const opened = this.openInnerDelegation(
      scopeState.provide,
      dispatched.target,
      dispatched.to,
      dispatched.argument,
      fiber,
      dispatched.generics,
    );
    if (opened === null) {
      // The provide moved to winding down between the scope check and the spawn (a racing cancel) — refuse.
      this.complete({
        delegation,
        outcome: { kind: "error", message: "region.fork: the nursery is closing" },
      });
      return;
    }
    scopeState.running.set(fiber, opened);
    // The fork returns the handle NOW; the fiber runs on independently under the provide. (The fork call owns
    // no children of its own, so this settlement drains immediately.)
    this.complete({
      delegation,
      outcome: { kind: "result", value: mintFiberHandle(payload.scope, fiber) },
    });
  }

  /** Await one fiber (a reactor turn). Route on the handle's scope + fiber id: if the fiber already SETTLED its
   *  outcome is in the nursery's `fiberBuffer` — remove it (single-consumer) and settle the join at once; if it
   *  is still RUNNING, hold the join open and park a waiter `bufferFiberOutcome` settles when the fiber lands. A
   *  handle that is neither buffered nor running — a malformed handle, a fiber already joined, or one lost to
   *  the buffer's post-commit durability window — is not joinable, so PANIC (the checker pins the handle's scope
   *  to a live nursery, so this is an engine-invariant break; `join` declares no throw and region has no error
   *  sum, the same backstop as a dead-scope fork). */
  private startJoin(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined || payload.kind !== "join") return; // resolved / cancelled meanwhile
    const { scope, fiber } = payload;
    const scopeState = scope === null ? undefined : this.scopes.get(scope);
    if (scope === null || fiber === null || scopeState === undefined) {
      this.panicUnjoinableFiber(delegation, fiber);
      return;
    }
    const provide = scopeState.provide;
    const providePayload = this.payloadOf(provide);
    if (providePayload !== undefined && providePayload.kind === "provide") {
      const index = providePayload.fiberBuffer.findIndex((buffered) => buffered.fiber === fiber);
      const buffered = index < 0 ? undefined : providePayload.fiberBuffer[index];
      if (buffered !== undefined) {
        // Take the settled outcome (single-consumer) and re-persist the shrunk buffer with the join's own
        // settlement, so the drain and the settle commit together (a crash before the commit reloads both).
        providePayload.fiberBuffer.splice(index, 1);
        this.markCallDirty(provide);
        this.settleJoin(delegation, provide, buffered.outcome);
        return;
      }
    }
    if (scopeState.running.has(fiber)) {
      // Still running: hold the join open and park a waiter. A fiber already awaited by another join cannot be
      // awaited a second time (single-consumer), so a double-join of a running fiber panics like a stale one.
      if (this.waiters.has(fiber)) {
        this.panicUnjoinableFiber(delegation, fiber);
        return;
      }
      this.waiters.set(fiber, delegation);
      return;
    }
    this.panicUnjoinableFiber(delegation, fiber);
  }

  /** Settle a join with a fiber's outcome — the buffer drain and the waiter path share this. A `result` hands
   *  back the fiber's value: its resources were re-owned onto the PROVIDE instance when the fiber settled (the
   *  base's `onDelegateAck`), so move them across to the JOIN call's instance first — release them from the
   *  provide, claim them onto the join — and the join's own `delegateAck` then releases them to the join's
   *  caller, ending the reown at the core that called `join`. An `error` (the engine backstop — a fiber's
   *  failure relays UP, never settling its inner call, so this is never produced for a real fiber) fails the
   *  join as a panic. */
  private settleJoin(
    delegation: DelegationId,
    provide: DelegationId,
    outcome: BufferedFiber["outcome"],
  ): void {
    if (outcome.kind === "error") {
      this.complete({ delegation, outcome: { kind: "error", message: outcome.message } });
      return;
    }
    const provideInstance = this.callInstance(provide);
    const joinInstance = this.callInstance(delegation);
    if (provideInstance !== undefined && joinInstance !== undefined) {
      this.pool.release(outcome.value, provideInstance);
      this.reownIncoming(outcome.value, joinInstance);
    }
    // Lower to the completion's wire Json (the base decodes it back), `reveal` so content survives the internal
    // round-trip — the same shape `deliverInnerOutcome` feeds a continuation's outcome back through.
    this.complete({
      delegation,
      outcome: { kind: "result", value: valueToJson(outcome.value, "reveal") },
    });
  }

  /** Fail a join whose handle names no joinable fiber (malformed, already joined, or lost) as a panic. */
  private panicUnjoinableFiber(delegation: DelegationId, fiber: string | null): void {
    this.complete({
      delegation,
      outcome: {
        kind: "error",
        message: `region.join: the fiber ${fiber ?? "(malformed handle)"} is not joinable in this nursery; it is unknown, already joined, or was lost to a runtime restart`,
      },
    });
  }

  /** A settled inner delegation. The CONTINUATION is the whole provide call — feed its outcome back as the
   *  completion on a fresh turn (values lower to the completion's wire Json and decode back at the base,
   *  `reveal` so content survives the internal round-trip). Every other token is a FIBER's settlement:
   *  hand its outcome to a join already waiting on it, else buffer it on the provide until a `join` takes it. */
  protected override deliverInnerOutcome(delivery: InnerDelivery): void {
    if (delivery.call === CONTINUATION_CALL) {
      this.schedule(() =>
        this.complete({
          delegation: delivery.delegation,
          outcome: innerOutcomeAsCompletion(delivery.outcome),
        }),
      );
      return;
    }
    this.schedule(() =>
      this.bufferFiberOutcome(delivery.delegation, delivery.call, delivery.outcome),
    );
  }

  /** A settled fiber's outcome, on a fresh turn. A join already WAITING on this fiber takes it directly — the
   *  settle re-owns the fiber's resources through to the join's caller, and nothing is buffered. Otherwise it
   *  is buffered on the provide until a later `join` drains it (the row re-persists with the enlarged buffer).
   *  A `cancelled` fiber (torn down with its provide) has no result to join and is discarded — its provide is
   *  being torn down, so no LIVE join can observe it (a join in the same nursery is torn down alongside), and
   *  the buffer is dropped at the provide's drop anyway. The fiber's result resources were already re-owned
   *  onto the provide's instance by the base (`onDelegateAck`): a waiting join hands them on; an unjoined
   *  buffered outcome reclaims them at the provide's drop (no leak). */
  private bufferFiberOutcome(
    provide: DelegationId,
    fiber: string,
    outcome: InnerDelivery["outcome"],
  ): void {
    const payload = this.payloadOf(provide);
    if (payload === undefined || payload.kind !== "provide") return; // the provide resolved meanwhile
    // Retire the fiber from its scope's running set (a no-op for a fiber never re-registered after a reload).
    this.scopes.get(payload.scope)?.running.delete(fiber);
    if (outcome.kind === "cancelled") return; // torn down with the provide — nothing joinable
    const waiting = this.waiters.get(fiber);
    if (waiting !== undefined) {
      this.waiters.delete(fiber);
      this.settleJoin(waiting, provide, outcome);
      return;
    }
    payload.fiberBuffer.push({ fiber, outcome });
    this.markCallDirty(provide);
  }

  /** Reactivation. A reloaded PROVIDE re-registers its scope, rebuilds its running-fiber set from the reloaded
   *  inner-call bridges (so a join can wait on a fiber that outlived the restart), and either re-dispatches its
   *  continuation (still stored — the block never started) or resumes it (already dispatched, so it, and its
   *  running fibers, are durable core work); its settled-fiber buffer reloaded on the payload. A reloaded FORK
   *  re-spawns: a fork's only effect is opening an inner delegation, so re-running an interrupted one is safe
   *  (a committed fork is already gone — reaching here means its spawn never committed). A reloaded JOIN re-runs
   *  its drain / park: it drains the buffer if the fiber landed before the crash, else re-parks its waiter
   *  against the running fiber (the openScope + repopulateRunning of every provide ran synchronously in this
   *  same reload, before the scheduled `startJoin` turn). There is no external process to reconcile (like
   *  `webhook` / `time`). An `operation` call is at-most-once: it never really began (it fails immediately), so
   *  a reloaded one refuses again, never re-run. */
  protected recover(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined) return;
    switch (payload.kind) {
      case "fork":
        this.schedule(() => this.startFork(delegation));
        return;
      case "join":
        this.schedule(() => this.startJoin(delegation));
        return;
      case "operation":
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
      case "provide":
        this.openScope(payload.scope, delegation);
        this.repopulateRunning(payload.scope, delegation);
        if (payload.continuation !== null) this.schedule(() => this.startContinuation(delegation));
        return;
    }
  }

  /** Rebuild a reloaded provide's running-fiber set from its durable inner-call bridges: every bridge whose
   *  token carries the fiber prefix is a still-running fiber (the continuation's own bridge is filtered out by
   *  the prefix), so a `join` arriving after a restart can wait on it. A settled fiber is NOT here — it left the
   *  bridges for the durable `fiberBuffer`, which a `join` drains instead. Runs synchronously in `recover` (not
   *  scheduled), so every scope is fully populated before any scheduled `startJoin` turn reads it. */
  private repopulateRunning(scope: string, provide: DelegationId): void {
    const scopeState = this.scopes.get(scope);
    if (scopeState === undefined) return;
    for (const row of this.innerCallRowsOf(provide)) {
      if (row.call.startsWith(FIBER_TOKEN_PREFIX)) scopeState.running.set(row.call, row.delegation);
    }
  }

  /** A cancel's transport half: confirm on a fresh turn (a provide has no external work of its own — its
   *  children, the continuation and later its fibers, drain through the base's cancel cascade; the scope closes
   *  at drop). A waiting `join` and an `operation` call likewise just confirm — a waiting join owns no work
   *  beyond its in-memory waiter, which its drop hook forgets. */
  protected abort(delegation: DelegationId): void {
    this.schedule(() => this.complete({ delegation, outcome: { kind: "cancelled" } }));
  }

  /** A call resolved: close a provide's scope, or forget a join's waiter (the drop hook covers every resolution
   *  path at once). A join that resolved by SETTLING already dropped its own waiter; this catches a join torn
   *  down while still waiting (a cancel), so a later fiber settle finds nothing stale to resume. */
  protected override onDropCall(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined) return;
    if (payload.kind === "provide") {
      this.closeScope(payload.scope);
      return;
    }
    if (
      payload.kind === "join" &&
      payload.fiber !== null &&
      this.waiters.get(payload.fiber) === delegation
    ) {
      this.waiters.delete(payload.fiber);
    }
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
          fiberBuffer: payload.fiberBuffer,
          relays: row.relays,
          innerCalls: row.innerCalls,
        });
      case "fork":
        return encodeRegionExtension({
          kind: "fork",
          scopeId: payload.scope,
          task: payload.task,
          argument: payload.argument,
        });
      case "join":
        return encodeRegionExtension({
          kind: "join",
          scopeId: payload.scope,
          fiberId: payload.fiber,
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
            fiberBuffer: decoded.fiberBuffer,
          },
          relays: decoded.relays,
          innerCalls: decoded.innerCalls,
        };
      case "fork":
        return {
          payload: {
            kind: "fork",
            scope: decoded.scopeId,
            task: decoded.task,
            argument: decoded.argument,
          },
          relays: [],
          innerCalls: [],
        };
      case "join":
        return {
          payload: { kind: "join", scope: decoded.scopeId, fiber: decoded.fiberId },
          relays: [],
          innerCalls: [],
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
    // Waiters are in-memory routing; a reset (poisoned commit) rebuilds them from the reloaded running set +
    // each waiting join's `startJoin` in `recover`.
    this.waiters.clear();
  }
}

/** One live nursery's routing state: the provide call that opened it (a `fork`'s fiber parents on this), and
 *  its RUNNING fibers by id (their inner-delegation ids — a `join` / `cancel` awaits / tears one down). A
 *  settled fiber leaves this map for the provide payload's `fiberBuffer`. */
interface ScopeState {
  provide: DelegationId;
  running: Map<string, DelegationId>;
}

/** Mint the nursery handle `region.provide` hands its continuation for `scope`: an opaque record carrying only
 *  the scope identity, under the namespaced marker field. A `fork` / `join` / `watch` / `cancel` reads the
 *  identity from here to route an operation to THIS nursery. */
function mintNursery(scope: string): Value {
  return {
    kind: "record",
    fields: { [NURSERY_SCOPE_FIELD]: { kind: "string", value: scope } },
  };
}

/** The scope identity a nursery handle carries, or `null` when the handle is malformed (not a record, or no
 *  string scope field) — a fork of `null` is refused as a dead scope. */
function scopeOfNursery(nursery: Value | null): string | null {
  if (nursery === null || nursery.kind !== "record") return null;
  const scope = nursery.fields[NURSERY_SCOPE_FIELD];
  return scope !== undefined && scope.kind === "string" ? scope.value : null;
}

/** The scope + fiber id a fiber HANDLE carries (each `null` when the handle is malformed) — a `join` reads
 *  both from the handle, since the handle's own scope names the nursery that spawned the fiber (so the fiber is
 *  awaited where it lives, not in whatever `nursery` argument the call was handed). */
function fiberHandleOf(handle: Value | null): { scope: string | null; fiber: string | null } {
  if (handle === null || handle.kind !== "record") return { scope: null, fiber: null };
  const scope = handle.fields[NURSERY_SCOPE_FIELD];
  const fiber = handle.fields[NURSERY_FIBER_FIELD];
  return {
    scope: scope !== undefined && scope.kind === "string" ? scope.value : null,
    fiber: fiber !== undefined && fiber.kind === "string" ? fiber.value : null,
  };
}

/** A fresh fiber id — the inner-call token the fiber's delegation is bridged under AND the id its handle
 *  carries. Random (not a counter), so it stays unique across a restart that resets in-memory counters. */
function mintFiberId(): string {
  return `${FIBER_TOKEN_PREFIX}${randomBytes(12).toString("base64url")}`;
}

/** Mint the `fiber[Scope, T]` handle `fork` returns, as the completion's wire Json: an opaque record carrying
 *  its nursery's scope identity and its own fiber id, under the namespaced marker fields — so a `join` /
 *  `cancel` routes back to THIS fiber of THIS nursery. Plain string leaves and no reserved wire discriminator,
 *  so the base's `jsonToValue` reconstructs it as a bare record with no ack-decoding seam of its own. */
function mintFiberHandle(scope: string, fiber: string): Json {
  return { [NURSERY_SCOPE_FIELD]: scope, [NURSERY_FIBER_FIELD]: fiber };
}
