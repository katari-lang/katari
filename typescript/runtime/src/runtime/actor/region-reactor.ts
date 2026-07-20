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
// `cancel` tears ONE fiber down early. Like `join` it is its OWN call, routed by the fiber HANDLE (its scope
// names the nursery). It sends a single `terminate` to that fiber's inner delegation — the SINGLE-fiber form
// of the base's whole-nursery `terminateChildren` cascade — and settles with `null` once the teardown
// confirms. A cancelled fiber is torn down with no joinable outcome (a `cancelled` inner outcome is never
// buffered), so `cancel` makes the fiber UNKNOWN: a later `join` of it PANICS (symmetric to a double-join),
// and a `join` already PARKED on it when the cancel lands is PANICKED too — "stop, I don't want it" (cancel)
// and "await its result" (join) are contradictory intents, so their coexistence is a program error. A cancel
// of a fiber that has already SETTLED (its outcome buffered) or is otherwise gone is an idempotent no-op that
// still succeeds, dropping any buffered outcome so the post-condition ("the fiber is unknown") holds
// regardless of whether the fiber raced the cancel to completion. A forged / dead-scope handle names no live
// nursery, so it PANICS — the same engine-invariant backstop as `join` and `fork`, which also automatically
// rejects a hostile-wire handle (its random scope matches no live nursery).
//
// `watch` is the nursery's WHITE HOLE: it re-emits the fibers' escalations into the enclosing program as the
// ceiling effect `E`, so a handler installed AROUND the watch (a position that still holds the nursery handle)
// services the fibers' requests. A fiber's escalation would normally relay UP through its `provide` (the base
// `relays` bridge) to the enclosing program; `watch` INTERCEPTS it — `onEscalate` recognises a fiber's ask
// (its escalating delegation is a running fiber of a live scope), holds it in the nursery's durable MAILBOX,
// and re-emits it under the WATCH call's own delegation (`relayAskUnder`), so it surfaces at the watch's
// caller — the handler — rather than above the provide. The handler's answer descends the same bridge back to
// the fiber (`onEscalateAck` reuses the base relay descent, keyed on the WATCH call). Re-emission is FIFO and
// SERIAL: a held-open watch call carries one outstanding relay at a time; escalations that arrive while it is
// busy accumulate in the mailbox and drain one-by-one as each answer returns. A nursery with NO watch flushes
// its mailboxed escalations UP through the provide to the run root (`flushUp`). The two are told apart at
// GLOBAL QUIESCENCE
// (`onQuiesce`): a watch drains its scope's mailbox EAGERLY (on registration and after each answer), so a
// mailbox still full when every run is blocked belongs to a genuinely watch-less nursery — the one point where
// "a watch that was going to register already has" holds, so flushing up cannot race a late watch. A cancelled
// fiber's not-yet-emitted escalations are dropped from the mailbox so they are never re-emitted.
// `watch` returns `never`: the call is HELD OPEN (it only ever raises, never settles), closing only when the
// nursery drops or the watch is cancelled.
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
import type { AskKind, ExternalEvent, ReactorName } from "../event/types.js";
import { escalateValue } from "../event/types.js";
import type { DelegationId, EscalationId, InstanceId, SnapshotId } from "../ids.js";
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
 *  at the payload boundary. All five nursery operations dispatch as their own payload variant; any other key
 *  (compiler / wire drift) folds into the defensive `operation` payload, a clear "unimplemented" completion. */
const REGION_PROVIDE_KEY = "prelude.region.provide";
const REGION_FORK_KEY = "prelude.region.fork";
const REGION_JOIN_KEY = "prelude.region.join";
const REGION_CANCEL_KEY = "prelude.region.cancel";
const REGION_WATCH_KEY = "prelude.region.watch";

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

/** A fiber that has settled and whose outcome waits on the provide until a `join` takes it. A
 *  fiber's inner delegation delivers only a `result` (normal completion) here — an escalation (panic / throw /
 *  request) relays UP instead of settling the inner call, and a `cancelled` fiber (torn down with its provide)
 *  has no result to join, so neither is buffered. The `error` arm is the base's defensive residue, buffered
 *  for totality but never produced for a fiber. */
interface BufferedFiber {
  /** The fiber id the fork handle carried — a `join` / `cancel` names it. */
  fiber: string;
  outcome: { kind: "result"; value: Value } | { kind: "error"; message: string };
}

/** One fiber escalation waiting in a nursery's mailbox — held until a `watch` re-emits it (or, watch-less, it
 *  flushes UP through the provide). Persisted on the provide's extension (a `watch` restored across a restart
 *  must not lose the "溜まっていた" requests), which is why the raised `ask`'s carried value is reowned onto the
 *  provide instance when it is enqueued: parked resources survive the commit and the provide's eventual drop
 *  rather than dangling in-transit. */
interface MailboxEntry {
  /** The fiber's own delegation — the leg an answer descends to (via the relay `relayAskUnder` opens), and the
   *  key a `cancel` drops a fiber's not-yet-emitted escalations by. */
  child: DelegationId;
  /** The fiber's escalation id — echoed on the answering `escalateAck` down to the fiber. */
  childEscalation: EscalationId;
  /** The ask the fiber raised — re-emitted verbatim at the watch (or, watch-less, up through the provide). */
  ask: AskKind;
}

/** What a region call holds, a sum every lifecycle method dispatches once: a `provide` scope (its scope id +
 *  the not-yet-dispatched continuation + the settled-fiber buffer — persisted, so the scope survives a
 *  restart), a `fork` (the task + argument it spawns a fiber from — persisted, so an interrupted fork
 *  re-spawns), a `join` (the scope + fiber id it awaits, read from the handle — persisted, so a waiting join
 *  re-parks after a restart), a `cancel` (the scope + fiber id it tears down, read from the handle — persisted,
 *  so an interrupted cancel re-runs its idempotent teardown), a `watch` (the scope whose fibers' escalations it
 *  re-emits, read from the handle — held open, never settling), or an `operation` — an unknown dispatch key
 *  (compiler / wire drift), which fails the call with a clear completion. */
type RegionPayload =
  | {
      kind: "cancel";
      /** The nursery scope and fiber id the cancel tears down, read from the fiber HANDLE (its own scope names
       *  the nursery that spawned it, exactly like `join`). Either is `null` when the handle was malformed — an
       *  uncancellable fiber, refused as a panic. Persisted, so a cancel interrupted before its teardown
       *  confirmed re-runs identically after a restart (a re-sent terminate is idempotent). */
      scope: string | null;
      fiber: string | null;
    }
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
      /** The fibers' escalations waiting to be re-emitted at a `watch` (or, watch-less, flushed up). FIFO,
       *  drained one-by-one as each answer returns. Persisted on the provide's extension, so a restart restores
       *  the "溜まっていた" requests a watch has not yet serviced. */
      mailbox: MailboxEntry[];
    }
  | {
      kind: "watch";
      /** The nursery scope this watch is the white hole of, read from the handed nursery handle (`null` when
       *  the handle was malformed — refused as a dead scope, like `fork`). The call is HELD OPEN (never
       *  settles); it re-emits the scope's mailboxed fiber escalations under its own delegation. */
      scope: string | null;
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
      /** The unknown dispatch key the call arrived under (compiler / wire drift) — named in the completion that refuses it. */
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
      mailbox: MailboxEntry[];
      relays: EscalationRelayRow[];
      innerCalls: InnerCallRow[];
    }
  | { kind: "fork"; scopeId: string | null; task: Value | null; argument: Value | null }
  | { kind: "join"; scopeId: string | null; fiberId: string | null }
  | { kind: "cancel"; scopeId: string | null; fiberId: string | null }
  | {
      kind: "watch";
      scopeId: string | null;
      /** The fiber escalations this held-open watch is currently RE-EMITTING (at most one at a time), bridged
       *  so a restart re-parks the outstanding relay and the handler's answer still descends to the fiber. */
      relays: EscalationRelayRow[];
    }
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
        mailbox: asJson(extension.mailbox),
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
    case "cancel":
      return { kind: "cancel", scopeId: extension.scopeId, fiberId: extension.fiberId };
    case "watch":
      return {
        kind: "watch",
        scopeId: extension.scopeId,
        relays: encodeRelays(extension.relays),
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
        fiberBuffer: warmFieldOf<BufferedFiber[]>(document, "fiberBuffer"),
        mailbox: warmFieldOf<MailboxEntry[]>(document, "mailbox"),
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
    case "cancel":
      return {
        kind: "cancel",
        scopeId: warmFieldOf<string | null>(document, "scopeId"),
        fiberId: warmFieldOf<string | null>(document, "fiberId"),
      };
    case "watch":
      return {
        kind: "watch",
        scopeId: warmFieldOf<string | null>(document, "scopeId"),
        relays: relaysOf(document),
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

  /** The cancels awaiting a still-running fiber's teardown, by that fiber's id — the cancel's call is held open
   *  until the terminate this reactor sent to the fiber's inner delegation confirms (its `cancelled` outcome
   *  lands in `bufferFiberOutcome`, which settles the cancel with `null`). In-memory only, like `waiters`: the
   *  durable twin is the cancel's own row plus the fiber's inner-call bridge, so a restart re-parks it by
   *  re-running `startCancel` in `recover` against the reloaded running-fiber set (a re-sent terminate is
   *  idempotent). A fiber is cancelled once, but a cancel and a join never coexist on it (their intents are
   *  exclusive — `startCancel` panics a parked join), so this and `waiters` are disjoint per fiber. */
  private readonly cancelWaiters = new Map<string, DelegationId>();

  /** The live `watch` calls of each nursery scope, by the scope identity — the white holes a fiber's
   *  escalation is re-emitted at. In-memory routing (like `waiters`): the durable twin is each watch's own
   *  call row, so a restart rebuilds this from `recover`. Kept separate from `ScopeState` so a watch's
   *  registration does not depend on the ORDER a reload reloads the provide vs. its watch (both re-register
   *  independently); the drain (`pumpWatch`) reads the provide's mailbox only once the scope itself is live.
   *  A Set so registration order is FIFO-deterministic when a nursery has more than one watch. */
  private readonly watchesByScope = new Map<string, Set<DelegationId>>();

  /** The reverse of `watchesByScope`: a watch call to the scope it watches — how `onEscalateAck` knows an
   *  answered escalation was a watch re-emission (so it can pump the next mailbox entry) and how `onDropCall`
   *  finds the scope to re-route a dropped watch's pending escalations. */
  private readonly watchScope = new Map<DelegationId, string>();

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
   *  finds its nursery. `openScope` itself starts with an empty running-fiber set; on a reload `recover`
   *  rebuilds it at once from the durable inner-call bridges (`repopulateRunning`), so a `join` can wait on a
   *  fiber that outlived the restart. A fiber that settles after the reload is buffered on-demand regardless. */
  private openScope(scope: string, provide: DelegationId): void {
    this.scopes.set(scope, { provide, running: new Map() });
  }

  /** Close a provide's scope at its drop (idempotent — an already-closed scope removes nothing). Its running
   *  fibers were the provide's inner delegations, already torn down by the base's cancel cascade before the
   *  drop, so there is nothing here to reclaim beyond the membership itself. */
  private closeScope(scope: string): void {
    this.scopes.delete(scope);
  }

  /** Register a `watch` call as a live white hole of `scope` (idempotent) — a fiber's escalation on this scope
   *  is re-emitted at this call. Called from `startWatch` (a fresh watch, which then drains any escalation the
   *  mailbox already holds) and from `recover` (a reloaded watch). */
  private registerWatch(scope: string, watch: DelegationId): void {
    const set = this.watchesByScope.get(scope);
    if (set === undefined) this.watchesByScope.set(scope, new Set([watch]));
    else set.add(watch);
    this.watchScope.set(watch, scope);
  }

  /** Forget a watch at its drop (cancelled, or torn down with its nursery). Its scope's mailbox is re-pumped
   *  by `onDropCall`, so any escalation it had not yet drained re-routes to another watch or flushes up. */
  private unregisterWatch(watch: DelegationId): void {
    const scope = this.watchScope.get(watch);
    if (scope === undefined) return;
    this.watchScope.delete(watch);
    const set = this.watchesByScope.get(scope);
    if (set === undefined) return;
    set.delete(watch);
    if (set.size === 0) this.watchesByScope.delete(scope);
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
        mailbox: [],
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
    if (target.key === REGION_CANCEL_KEY) {
      // `cancel(nursery, handle)`: route on the HANDLE's own scope + fiber id, exactly like `join` — the handle
      // names the nursery that spawned the fiber, so the fiber is torn down where it actually lives even under
      // nested same-marker scopes. A malformed / forged handle yields `null`s, refused as an uncancellable fiber.
      const handle = fiberHandleOf(fields.handle ?? null);
      return { kind: "cancel", scope: handle.scope, fiber: handle.fiber };
    }
    if (target.key === REGION_WATCH_KEY) {
      // `watch(nursery)`: route on the nursery's scope (its identity is the one thing the runtime gates and
      // routes on, exactly like a `fork`). A malformed handle yields a `null` scope, refused as a dead scope.
      return { kind: "watch", scope: scopeOfNursery(fields.nursery ?? null) };
    }
    // An unknown key (compiler / wire drift) — defensive: carry it so `dispatch` fails the call with a clear
    // completion, never a silent misroute into a real operation.
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
    if (payload.kind === "cancel") {
      // Sending the fiber's terminate is a `send`, which must happen inside a turn — hand it back to the loop.
      this.schedule(() => this.startCancel(delegation));
      return;
    }
    if (payload.kind === "watch") {
      // Validating the scope and re-emitting a mailboxed escalation are `send`-shaped, so hand them back to the
      // loop. The call is HELD OPEN — `startWatch` never completes it (watch returns `never`).
      this.schedule(() => this.startWatch(delegation));
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

  /** Fail a join whose handle names no joinable fiber (malformed, already joined, cancelled, or lost) as a
   *  panic. A cancelled fiber reaches here as UNKNOWN — its `cancel` dropped it from the running set and the
   *  buffer — so a join of it is refused on the same path as any other non-joinable handle. */
  private panicUnjoinableFiber(delegation: DelegationId, fiber: string | null): void {
    this.complete({
      delegation,
      outcome: {
        kind: "error",
        message: `region.join: the fiber ${fiber ?? "(malformed handle)"} is not joinable in this nursery; it is unknown, already joined, cancelled, or was lost to a runtime restart`,
      },
    });
  }

  /** Tear ONE fiber down early (a reactor turn). Route on the handle's scope + fiber id: a live fiber has its
   *  inner delegation terminated (the single-fiber form of the provide's cancel cascade) and the cancel is held
   *  open until that teardown confirms; a fiber already SETTLED or gone is an idempotent no-op that still
   *  succeeds, its buffered outcome (if any) dropped so the fiber becomes uniformly UNKNOWN. A handle whose
   *  scope is not a live nursery — a forged / hostile-wire handle (its random scope matches nothing) or a dead
   *  scope — PANICS (the checker pins the handle's scope to a live nursery, so this is an engine-invariant
   *  break; `cancel` declares no throw and region has no error sum, the same backstop as `join` / `fork`). */
  private startCancel(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined || payload.kind !== "cancel") return; // resolved / cancelled meanwhile
    const { scope, fiber } = payload;
    const scopeState = scope === null ? undefined : this.scopes.get(scope);
    if (scope === null || fiber === null || scopeState === undefined) {
      this.panicUncancellableFiber(delegation, fiber);
      return;
    }
    const running = scopeState.running.get(fiber);
    if (running !== undefined) {
      // A cancel is already tearing this fiber down (a concurrent double-cancel — two fibers sharing the
      // handle): the fiber is already going, so this one is idempotently redundant. Succeed at once without
      // disturbing the first cancel's waiter, which settles when the teardown confirms (overwriting it would
      // orphan the first cancel, hanging it until the nursery drops).
      if (this.cancelWaiters.has(fiber)) {
        this.settleCancel(delegation);
        return;
      }
      // A live fiber. A join PARKED on it cannot coexist with its cancel — "await its result" and "stop, I
      // don't want it" are contradictory intents — so panic that join (it will never settle otherwise: the
      // cancel takes the fiber's teardown outcome). Then terminate the fiber's inner delegation and hold this
      // cancel open until the teardown confirms in `bufferFiberOutcome`.
      const parkedJoin = this.waiters.get(fiber);
      if (parkedJoin !== undefined) {
        this.waiters.delete(fiber);
        this.panicJoinCancelled(parkedJoin, fiber);
      }
      // Drop this fiber's not-yet-emitted escalations so a watch never re-emits a cancelled fiber's requests.
      this.dropFiberMailbox(scopeState.provide, running);
      this.cancelWaiters.set(fiber, delegation);
      this.terminateFiber(scopeState.provide, running);
      return;
    }
    // Not running: the fiber already settled (buffered) or is otherwise gone (already joined / cancelled). A
    // cancel is idempotent — succeed with `null` — and drop any buffered outcome so a fiber that raced the
    // cancel to completion still ends UNKNOWN (a later join panics), a race-independent post-condition. A
    // parked join cannot exist here: a join parks only on a running fiber.
    this.dropBufferedFiber(scopeState.provide, fiber);
    this.settleCancel(delegation);
  }

  /** Terminate one fiber's inner delegation — the single-fiber form of the base's whole-nursery
   *  `terminateChildren` cascade. The fiber is the PROVIDE's inner delegation (parented there by `fork`), so
   *  the terminate rides the provide's trace context and the answering `terminateAck` reaches the base's
   *  `onTerminateAck` under the provide, delivering a `cancelled` outcome to `bufferFiberOutcome`. A fiber whose
   *  row is already gone / cancelling needs no fresh terminate — its outcome is already on its way, and the
   *  cancel waiter settles when it lands. */
  private terminateFiber(provide: DelegationId, fiberDelegation: DelegationId): void {
    const row = this.issuedRowOf(fiberDelegation);
    const run = this.handledRunOf(provide);
    if (row === undefined || row.state !== "running" || run === undefined) return;
    this.send({
      kind: "terminate",
      delegation: fiberDelegation,
      from: this.name,
      to: row.peer,
      run,
    });
  }

  /** Drop a fiber's buffered outcome if one is present (a cancel of an already-settled fiber). The dropped
   *  result's resources were re-owned onto the provide instance when the fiber settled; leaving them there
   *  reclaims them at the provide's drop, exactly like any un-joined buffered outcome (no leak). */
  private dropBufferedFiber(provide: DelegationId, fiber: string): void {
    const payload = this.payloadOf(provide);
    if (payload === undefined || payload.kind !== "provide") return;
    const index = payload.fiberBuffer.findIndex((buffered) => buffered.fiber === fiber);
    if (index < 0) return;
    payload.fiberBuffer.splice(index, 1);
    this.markCallDirty(provide);
  }

  /** Settle a cancel with `null` (its declared result) once the fiber it targeted is gone. */
  private settleCancel(delegation: DelegationId): void {
    this.complete({ delegation, outcome: { kind: "result", value: null } });
  }

  /** Panic a join that was parked on a fiber its `cancel` then tore down — cancel and join are exclusive. */
  private panicJoinCancelled(join: DelegationId, fiber: string): void {
    this.complete({
      delegation: join,
      outcome: {
        kind: "error",
        message: `region.join: the fiber ${fiber} was cancelled while this join awaited it; a cancelled fiber cannot be joined (cancel and join are exclusive)`,
      },
    });
  }

  /** Fail a cancel whose handle names no live nursery scope (malformed / forged, or a dead scope) as a panic —
   *  the same engine-invariant backstop as an unjoinable fiber, and the automatic rejection of a hostile-wire
   *  handle whose random scope matches nothing. */
  private panicUncancellableFiber(delegation: DelegationId, fiber: string | null): void {
    this.complete({
      delegation,
      outcome: {
        kind: "error",
        message: `region.cancel: the fiber ${fiber ?? "(malformed handle)"} is not cancellable; its handle names no live nursery scope (a forged handle, or its region.provide has returned)`,
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

  /** A settled fiber's outcome, on a fresh turn. A CANCEL awaiting this fiber's teardown takes it first — the
   *  fiber is gone, so the cancel succeeds with `null` and nothing is buffered (whether the outcome is the
   *  terminate's `cancelled` or a `result` the fiber raced to before the terminate landed). Otherwise a join
   *  already WAITING on this fiber takes it directly — the settle re-owns the fiber's resources through to the
   *  join's caller, and nothing is buffered. Otherwise it is buffered on the provide until a later `join` drains
   *  it (the row re-persists with the enlarged buffer). A `cancelled` fiber with no cancel waiting (torn down
   *  with its provide) has no result to join and is discarded — its provide is being torn down, so no LIVE join
   *  can observe it (a join in the same nursery is torn down alongside), and the buffer is dropped at the
   *  provide's drop anyway. The fiber's result resources were already re-owned onto the provide's instance by
   *  the base (`onDelegateAck`): a waiting join hands them on; an unjoined buffered outcome (or one a cancel
   *  discards) reclaims them at the provide's drop (no leak). */
  private bufferFiberOutcome(
    provide: DelegationId,
    fiber: string,
    outcome: InnerDelivery["outcome"],
  ): void {
    const payload = this.payloadOf(provide);
    if (payload === undefined || payload.kind !== "provide") return; // the provide resolved meanwhile
    // Retire the fiber from its scope's running set (a no-op for a fiber never re-registered after a reload).
    this.scopes.get(payload.scope)?.running.delete(fiber);
    // A cancel is awaiting THIS fiber's teardown: its terminate confirmed (a `cancelled` outcome), or the fiber
    // raced to completion just before the terminate landed (a `result` now discarded). Either way the fiber is
    // gone, so the cancel succeeds — and nothing is buffered (a cancelled fiber has no joinable outcome).
    const cancelling = this.cancelWaiters.get(fiber);
    if (cancelling !== undefined) {
      this.cancelWaiters.delete(fiber);
      this.settleCancel(cancelling);
      return;
    }
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

  // ─── watch: the white hole (fiber escalations re-emitted at the watch's position) ─────────────────

  /** The one-time watch validation (a reactor turn): confirm the nursery is still live, register this watch as
   *  a white hole of its scope, then drain any escalations the mailbox is already holding (the ones that beat
   *  the watch's registration — this is what catches them without racing a premature flush-up). The call is
   *  HELD OPEN — never completed here, since `watch` returns `never` (it only ever re-emits). A dead / forged
   *  scope is refused as a panic, the same requires-a-live-provide backstop as `fork` / `cancel`. */
  private startWatch(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined || payload.kind !== "watch") return; // resolved / cancelled meanwhile
    const scope = payload.scope;
    if (scope === null || !this.scopes.has(scope)) {
      this.panicUnwatchableScope(delegation, scope);
      return;
    }
    this.registerWatch(scope, delegation);
    this.pumpWatch(scope);
  }

  /** A fiber's escalation reached this reactor. If it is a fiber of a live nursery, HOLD it in the nursery's
   *  mailbox (reowning its carried value onto the provide so the parked ask survives a commit / the provide's
   *  drop) and, when a watch is already registered, re-emit it there at once. An escalation that beats its
   *  watch's registration stays mailboxed until `startWatch` drains it; one on a genuinely watch-less nursery
   *  flushes up only at `onQuiesce`. Any non-fiber escalation (the continuation's own request) relays up through
   *  the provide unchanged (the base path). */
  protected override onEscalate(
    event: Extract<ExternalEvent, { kind: "escalate" }>,
    context: { caller: InstanceId | undefined },
  ): void {
    const scope = this.fiberScopeOf(event.delegation);
    if (scope === undefined) {
      super.onEscalate(event, context);
      return;
    }
    const scopeState = this.scopes.get(scope);
    const provide = scopeState?.provide;
    const payload = provide === undefined ? undefined : this.payloadOf(provide);
    if (provide === undefined || payload === undefined || payload.kind !== "provide") {
      super.onEscalate(event, context);
      return;
    }
    const carried = escalateValue(event.ask);
    const provideInstance = this.callInstance(provide);
    if (carried !== null && provideInstance !== undefined)
      this.reownIncoming(carried, provideInstance);
    payload.mailbox.push({
      child: event.delegation,
      childEscalation: event.escalation,
      ask: event.ask,
    });
    this.markCallDirty(provide);
    // Re-emit at the watch NOW if one is already registered (the common case once the region is running); an
    // escalation that arrives BEFORE the watch registers stays in the mailbox and `startWatch` drains it when
    // the watch lands. It is flushed UP only at global quiescence (`onQuiesce`) — the point where the
    // continuation is blocked, so a watch that was going to register already has, and a mailbox still holding
    // an escalation belongs to a genuinely watch-less nursery (the flush-up relay to the run root).
    if ((this.watchesByScope.get(scope)?.size ?? 0) > 0) this.pumpWatch(scope);
  }

  /** The answer to an escalation this reactor relayed reached it. The base descent (a relayed answer flows to
   *  the child, an own-panic answer settles the call) runs FIRST; then, if it was a WATCH re-emission that the
   *  base just retired, the watch is idle again, so pump its scope's next mailbox entry (FIFO, serial). */
  protected override onEscalateAck(
    event: Extract<ExternalEvent, { kind: "escalateAck" }>,
    context: { raiser: InstanceId | undefined },
  ): void {
    const scope = this.watchScope.get(event.delegation);
    const wasWatchRelay =
      scope !== undefined && this.hasEscalationRelay(event.delegation, event.escalation);
    super.onEscalateAck(event, context);
    if (wasWatchRelay && scope !== undefined) this.schedule(() => this.pumpWatch(scope));
  }

  /** At GLOBAL QUIESCENCE (every run of every reactor is blocked), flush up any nursery whose mailbox still
   *  holds escalations and has NO watch — the flush-up relay a watch-less region does. This is
   *  the one safe point to decide "watch-less": if a watch were going to register, the continuation would still
   *  be dispatching it (not quiescent), so a mailbox still full at quiescence belongs to a genuinely watch-less
   *  nursery. A WATCHED scope is NOT drained here — its watch drains it eagerly (`startWatch` on registration,
   *  `onEscalateAck` after each answer) — so this never fights the white hole, and never spins (each flush
   *  empties its mailbox, so the next quiescence finds nothing to do). */
  override onQuiesce(): void {
    for (const [scope, state] of this.scopes) {
      if ((this.watchesByScope.get(scope)?.size ?? 0) > 0) continue; // watched — drained by the watch itself
      const payload = this.payloadOf(state.provide);
      if (payload !== undefined && payload.kind === "provide" && payload.mailbox.length > 0) {
        this.schedule(() => this.flushUp(scope));
      }
    }
  }

  /** Re-emit the nursery's mailboxed escalations at its watches — one per idle watch, in watch-registration
   *  order (FIFO across watches) and mailbox order (FIFO within), each re-raised under the watch's own
   *  delegation so it surfaces at the watch's caller (the handler). A busy watch (already re-emitting one,
   *  awaiting its answer) is skipped; the leftover entries wait for `onEscalateAck` to pump again. */
  private pumpWatch(scope: string): void {
    const scopeState = this.scopes.get(scope);
    const watches = this.watchesByScope.get(scope);
    if (scopeState === undefined || watches === undefined) return;
    const providePayload = this.payloadOf(scopeState.provide);
    if (providePayload === undefined || providePayload.kind !== "provide") return;
    for (const watch of watches) {
      if (providePayload.mailbox.length === 0) break;
      if (this.hasOpenRelay(watch)) continue; // busy — one outstanding re-emission at a time
      const entry = providePayload.mailbox.shift();
      if (entry === undefined) break;
      this.markCallDirty(scopeState.provide);
      if (!this.relayAskUnder(watch, entry.child, entry.childEscalation, entry.ask)) {
        // The watch is winding down (a racing cancel): put the entry back and stop — its drop re-pumps the
        // scope, re-routing what it could not take to another watch or up through the provide.
        providePayload.mailbox.unshift(entry);
        break;
      }
    }
  }

  /** Relay a watch-less nursery's mailboxed escalations UP through the provide to the enclosing program — the
   *  flush-up path a watch-less nursery takes. Each entry re-raises under the
   *  provide's own delegation (so its answer descends the base relay bridge back to the fiber). */
  private flushUp(scope: string): void {
    const scopeState = this.scopes.get(scope);
    if (scopeState === undefined) return;
    const providePayload = this.payloadOf(scopeState.provide);
    if (providePayload === undefined || providePayload.kind !== "provide") return;
    if (providePayload.mailbox.length === 0) return;
    const entries = providePayload.mailbox.splice(0);
    this.markCallDirty(scopeState.provide);
    for (const entry of entries) {
      this.relayAskUnder(scopeState.provide, entry.child, entry.childEscalation, entry.ask);
    }
  }

  /** The nursery scope a still-running fiber's delegation belongs to, or `undefined` when the escalating
   *  delegation is not a fiber (the provide's continuation, whose escalations relay up unchanged). A scan over
   *  the live scopes' running sets — each is small (a nursery's in-flight fibers), and a fiber escalation is
   *  far rarer than an ordinary event, so no reverse index is warranted. */
  private fiberScopeOf(delegation: DelegationId): string | undefined {
    for (const [scope, state] of this.scopes) {
      for (const running of state.running.values()) {
        if (running === delegation) return scope;
      }
    }
    return undefined;
  }

  /** Drop a fiber's NOT-YET-EMITTED escalations from its nursery's mailbox — a `cancel` makes the fiber
   *  unknown, so its queued requests must never be re-emitted (an escalation already re-emitted at a watch is
   *  left to answer moot, since its cancelled fiber's delegation is gone). */
  private dropFiberMailbox(provide: DelegationId, fiberDelegation: DelegationId): void {
    const payload = this.payloadOf(provide);
    if (payload === undefined || payload.kind !== "provide") return;
    const kept = payload.mailbox.filter((entry) => entry.child !== fiberDelegation);
    if (kept.length === payload.mailbox.length) return;
    payload.mailbox = kept;
    this.markCallDirty(provide);
  }

  /** Fail a watch whose handle names no live nursery scope (malformed / forged, or a dead scope) as a panic —
   *  the same engine-invariant backstop as an unjoinable / uncancellable fiber (the checker gates `watch` on a
   *  live `Scope`, so reaching this state is an invariant break; `watch`'s row declares no throw). */
  private panicUnwatchableScope(delegation: DelegationId, scope: string | null): void {
    this.complete({
      delegation,
      outcome: {
        kind: "error",
        message: `region.watch: the nursery scope ${scope ?? "(malformed handle)"} is not live; a watch names no open nursery (a forged handle, or its region.provide has returned)`,
      },
    });
  }

  /** Reactivation. A reloaded PROVIDE re-registers its scope, rebuilds its running-fiber set from the reloaded
   *  inner-call bridges (so a join can wait on a fiber that outlived the restart), and either re-dispatches its
   *  continuation (still stored — the block never started) or resumes it (already dispatched, so it, and its
   *  running fibers, are durable core work); its settled-fiber buffer reloaded on the payload. A reloaded FORK
   *  re-spawns: a fork's only effect is opening an inner delegation, so re-running an interrupted one is safe
   *  (a committed fork is already gone — reaching here means its spawn never committed). A reloaded JOIN re-runs
   *  its drain / park: it drains the buffer if the fiber landed before the crash, else re-parks its waiter
   *  against the running fiber (the openScope + repopulateRunning of every provide ran synchronously in this
   *  same reload, before the scheduled `startJoin` turn). A reloaded CANCEL re-runs its idempotent teardown: it
   *  re-terminates the fiber if it is still running (a re-sent terminate is a no-op on an already-cancelling
   *  delegation), else succeeds at once (the fiber's teardown committed before the crash — it is gone). A
   *  reloaded WATCH re-registers as its scope's white hole SYNCHRONOUSLY (before any scheduled pump), its
   *  outstanding relay restored from the durable row so the handler's answer still descends to the fiber; the
   *  provide re-pumps its reloaded mailbox (the "溜まっていた" requests), routing them to the watch (or, watch-less,
   *  up). There is no external process to reconcile (like `webhook` / `time`). An `operation` call is
   *  at-most-once: it never really began (it fails immediately), so a reloaded one refuses again, never re-run. */
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
      case "cancel":
        this.schedule(() => this.startCancel(delegation));
        return;
      case "watch":
        // Register synchronously (like a provide's `openScope`), so the provide's scheduled `pumpWatch` this
        // reload finds the watch; the live-scope check waits for the pump (the provide may reload later).
        if (payload.scope !== null) this.registerWatch(payload.scope, delegation);
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
        // Re-drain any escalations a watch had not yet serviced before the crash — routed to the watch once
        // every call has re-registered (the scheduled pump runs after this synchronous reload pass); a
        // watch-less reload leaves the mailbox for `onQuiesce` to flush up.
        if (payload.mailbox.length > 0) this.schedule(() => this.pumpWatch(payload.scope));
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
   *  at drop). A waiting `join`, a waiting `cancel`, and an `operation` call likewise just confirm — each owns
   *  no work beyond an in-memory waiter, which its drop hook forgets. */
  protected abort(delegation: DelegationId): void {
    this.schedule(() => this.complete({ delegation, outcome: { kind: "cancelled" } }));
  }

  /** A call resolved: close a provide's scope, forget a join's / cancel's in-memory waiter, or unregister a
   *  watch and re-pump its scope (the drop hook covers every resolution path at once). A join / cancel that
   *  resolved by SETTLING already dropped its own waiter; this catches one torn down while still waiting (its
   *  own cancel), so a later fiber settle finds nothing stale to resume. A dropped WATCH re-pumps its scope so
   *  anything it had not yet re-emitted re-routes to another watch or flushes up. */
  protected override onDropCall(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined) return;
    if (payload.kind === "provide") {
      this.closeScope(payload.scope);
      return;
    }
    if (payload.kind === "watch") {
      const scope = this.watchScope.get(delegation);
      this.unregisterWatch(delegation);
      // Re-route anything this watch had not yet re-emitted to a REMAINING watch of the scope; a scope left
      // watch-less by the drop leaves its mailbox for `onQuiesce` to flush up.
      if (scope !== undefined) this.schedule(() => this.pumpWatch(scope));
      return;
    }
    if (
      payload.kind === "join" &&
      payload.fiber !== null &&
      this.waiters.get(payload.fiber) === delegation
    ) {
      this.waiters.delete(payload.fiber);
      return;
    }
    if (
      payload.kind === "cancel" &&
      payload.fiber !== null &&
      this.cancelWaiters.get(payload.fiber) === delegation
    ) {
      this.cancelWaiters.delete(payload.fiber);
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
          mailbox: payload.mailbox,
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
      case "cancel":
        return encodeRegionExtension({
          kind: "cancel",
          scopeId: payload.scope,
          fiberId: payload.fiber,
        });
      case "watch":
        return encodeRegionExtension({
          kind: "watch",
          scopeId: payload.scope,
          relays: row.relays,
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
            mailbox: decoded.mailbox,
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
      case "cancel":
        return {
          payload: { kind: "cancel", scope: decoded.scopeId, fiber: decoded.fiberId },
          relays: [],
          innerCalls: [],
        };
      case "watch":
        return {
          payload: { kind: "watch", scope: decoded.scopeId },
          relays: decoded.relays,
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
    // Waiters (join and cancel) and watch registrations are in-memory routing; a reset (poisoned commit)
    // rebuilds them from the reloaded rows — each waiting join's `startJoin` / cancel's `startCancel`, and each
    // watch's registration + the provide's mailbox re-pump, in `recover`.
    this.waiters.clear();
    this.cancelWaiters.clear();
    this.watchesByScope.clear();
    this.watchScope.clear();
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
