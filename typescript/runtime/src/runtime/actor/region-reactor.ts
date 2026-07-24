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
// nursery. A fiber that SETTLES is RETIRED on the spot: tasks are `-> null` (the stdlib's fork pins it —
// results ride escalations, not settlements), so the settled value carries nothing and is discarded. There
// is deliberately NO `join` and no settled-outcome buffer: a fiber is a detached worker, not a future —
// `parallel` is the fork-JOIN story, a region is the fork-ESCALATE story — so nothing durable accumulates
// for fibers nobody awaits, which is exactly what a never-closing resident nursery needs.
//
// `cancel` tears ONE fiber down early. Like `fork` it is its OWN call, routed by the fiber HANDLE (its scope
// names the nursery). It sends a single `terminate` to that fiber's inner delegation — the SINGLE-fiber form
// of the base's whole-nursery `terminateChildren` cascade — and settles with `null` once the teardown
// confirms. A cancel
// of a fiber that has already SETTLED (its outcome buffered) or is otherwise gone is an idempotent no-op that
// still succeeds, dropping any buffered outcome so the post-condition ("the fiber is unknown") holds
// regardless of whether the fiber raced the cancel to completion. A forged / dead-scope handle names no live
// nursery, so it PANICS — the same engine-invariant backstop as `fork` and `watch`, which also automatically
// rejects a hostile-wire handle (its random scope matches no live nursery).
//
// `watch` is the nursery's WHITE HOLE: it re-emits the fibers' escalations into the enclosing program as the
// ceiling effect `E`, so a handler installed AROUND the watch (a position that still holds the nursery handle)
// services the fibers' requests. A fiber's escalation would normally relay UP through its `provide` (the base
// `relays` bridge) to the enclosing program; `watch` INTERCEPTS it — `onEscalate` recognises a fiber's ask
// (its escalating delegation is a running fiber of a live scope), holds it in the nursery's durable MAILBOX,
// and re-emits it under the WATCH call's own delegation (`relayAskUnder`), so it surfaces at the watch's
// caller — the handler — rather than above the provide. The handler's answer descends the same bridge back to
// the fiber (the base relay descent, keyed on the WATCH call and the escalation id). Re-emission is CONCURRENT:
// a watch is a transparent white hole with NO serialization of its own — it carries as many outstanding relays
// as there are mailboxed escalations, re-emitting each the moment it arrives. The ONLY serialization point is
// the RECEIVING handler: a sequential (`var`) handler re-serializes its own stream at its FIFO (in arrival
// order), a `parallel handler` does not — so two escalations to DIFFERENT handlers are always concurrent (no
// cross-handler starvation), two to the SAME var handler serialize at that handler in arrival order. A fiber's
// escalation surfaces at a watch and NOWHERE ELSE: until a watch registers, it stays BUFFERED in the nursery's
// durable mailbox, however long that takes — a fiber may fork, then wait on an FFI / http / AI call before it
// escalates, and its watch may be installed only after some human-latency hold answers. A nursery that never
// registers a watch simply holds its mailbox: it is NEVER flushed up to the enclosing program, because the
// provide's declared row is `R with Eouter | io` (the fibers' `E` is NOT in it), so surfacing a fiber's request
// above the provide would leak a request the nursery never promised. A cancelled fiber's not-yet-emitted
// escalations are dropped from the mailbox so they are never re-emitted.
// `watch` returns `never`: the call is HELD OPEN (it only ever raises, never settles), closing only when the
// nursery drops or the watch is cancelled.
//
// THE NURSERY IS THE REGISTRY (the stdlib's `region.ktr` contract): anything that talks ABOUT fibers reads
// the runtime's own truth, never a Katari-side mirror. `fork` takes an optional NAME tag, recorded durably on
// the provide's `names` map while the fiber runs; `roster` answers the RUNNING set as `fiber_info(id, name)`
// data values in fork order, straight off the running map; `cancel_by_id` addresses a fiber by the
// runtime-minted id (a live one runs the exact `cancel` teardown and answers `cancelled(id)`; a stale id — an
// anticipated, often model-supplied miss — answers `unknown_fiber(id)`, never a panic); and a fiber's PANIC is
// intercepted at `onEscalate` and re-emitted as the typed `crashed(id, name, message)` event — a SYNTHETIC
// mailbox entry with no child leg (the fiber is dead; the runtime tears it down like a cancel, and the
// handler's eventual answer is swallowed via the base's moot-answer guard). A `crashed` entry buffers in the
// mailbox like any other, waiting for a watch to re-emit it — a watch-less nursery simply holds it.
//
// Durably a `provide` persists its endpoint payload (its scope id + the still-stored continuation + the
// settled-fiber buffer + the inner-delegation bridges) and survives a restart COMPLETELY, re-registering the
// scope and resuming its continuation and running fibers as durable core work — there is no external process,
// so recovery has nothing to reconcile (like `webhook` / `time`). A `fork` persists its (task + argument)
// re-dispatch and simply re-spawns on reload: its only effect is opening an internal delegation, so re-running
// an interrupted one is safe (a committed fork is already gone). A `cancel` persists its (scope + fiber); it,
// too, has no external effect to reconcile. None of these mint a public capability token (unlike `mcp.serve` /
// `webhook`, a nursery has no inbound URL).

import { randomBytes } from "node:crypto";
import { createAgentName, type Json, type QualifiedName } from "@katari-lang/types";
import type { Logger } from "../../lib/logger.js";
import { NURSERY_FIBER_FIELD, NURSERY_SCOPE_FIELD, PANIC_REQUEST } from "../engine/common.js";
import { dispatchCallable } from "../engine/dynamic-dispatch.js";
import type { AskKind, ExternalEvent, ReactorName } from "../event/types.js";
import { escalateValue } from "../event/types.js";
import {
  type DelegationId,
  type EscalationId,
  type InstanceId,
  newDelegationId,
  newEscalationId,
  type SnapshotId,
} from "../ids.js";
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
 *  at the payload boundary. Every nursery operation dispatches as its own payload variant; any other key
 *  (compiler / wire drift) folds into the defensive `operation` payload, a clear "unimplemented" completion.
 *  (The nursery / fiber handles those payloads read carry their identities under the namespaced marker fields
 *  `NURSERY_SCOPE_FIELD` / `NURSERY_FIBER_FIELD`, shared from `engine/common.ts` — the `fiber_id` prim reads
 *  the same fields on the engine side, which must not import actor code.) */
const REGION_PROVIDE_KEY = "prelude.region.provide";
const REGION_FORK_KEY = "prelude.region.fork";
const REGION_CANCEL_KEY = "prelude.region.cancel";
const REGION_WATCH_KEY = "prelude.region.watch";
const REGION_ROSTER_KEY = "prelude.region.roster";
const REGION_CANCEL_BY_ID_KEY = "prelude.region.cancel_by_id";

/** The typed event a fiber's PANIC becomes at the nursery (the stdlib's `region.crashed` request): the
 *  runtime tears the dead fiber down and re-emits the ending as DATA — `{ id, name, message }` — instead of
 *  letting the raw panic unwind the watch context. The runtime is this request's one author. */
const REGION_CRASHED_REQUEST = createAgentName("prelude.region.crashed");

/** The data constructors the registry-facing operations answer with, matching the stdlib's `data`
 *  declarations exactly (a Katari `match` dispatches on these names). */
const FIBER_INFO_CONSTRUCTOR = createAgentName("prelude.region.fiber_info");
const CANCELLED_CONSTRUCTOR = createAgentName("prelude.region.cancelled");
const UNKNOWN_FIBER_CONSTRUCTOR = createAgentName("prelude.region.unknown_fiber");

/** The continuation's reserved inner-call token: a provide's continuation IS the whole call, so its settlement
 *  settles the provide (the same role `mcp`'s / `webhook`'s subscriber token plays). A fiber uses a fresh
 *  `fiber:` token (its own id), which is disjoint from this one — so `deliverInnerOutcome` tells a fiber's
 *  settlement from the continuation's by comparing against this constant. */
const CONTINUATION_CALL = "continuation";

/** The prefix every fiber's inner-call token (its id) carries, so a fiber token is disjoint from
 *  `CONTINUATION_CALL` and recognisable among a provide's inner-call bridges — which `repopulateRunning`
 *  filters on reload to rebuild the running-fiber set a `cancel` routes against. */
const FIBER_TOKEN_PREFIX = "fiber:";

/** One fiber escalation waiting in a nursery's mailbox — held until a `watch` re-emits it (a watch-less nursery
 *  simply holds it forever). Persisted on the provide's extension (a `watch` restored across a restart
 *  must not lose the "溜まっていた" requests), which is why the raised `ask`'s carried value is reowned onto the
 *  provide instance when it is enqueued: parked resources survive the commit and the provide's eventual drop
 *  rather than dangling in-transit. */
interface MailboxEntry {
  /** The fiber's own delegation — the leg an answer descends to (via the relay `relayAskUnder` opens), and the
   *  key a `cancel` drops a fiber's not-yet-emitted escalations by. `null` marks a SYNTHETIC entry — a
   *  runtime-authored `crashed` event whose fiber is already dead, so there is no leg to answer: its
   *  re-emission relays under fresh ids that name no live delegation, and the base's moot-answer guard
   *  swallows the handler's answer (see `emitEntry`). */
  child: DelegationId | null;
  /** The fiber's escalation id — echoed on the answering `escalateAck` down to the fiber (`null` on a
   *  synthetic entry, which has no answer to route). */
  childEscalation: EscalationId | null;
  /** The ask the fiber raised — re-emitted verbatim at the watch once one registers. */
  ask: AskKind;
}

/** What a region call holds, a sum every lifecycle method dispatches once: a `provide` scope (its scope id +
 *  the not-yet-dispatched continuation + the mailbox + the running fibers' name tags — persisted, so the
 *  scope survives a restart), a `fork` (the task + argument + name it spawns a fiber from — persisted, so an
 *  interrupted fork re-spawns), a `cancel` (the scope + fiber id it tears down, read from the handle —
 *  persisted, so an interrupted cancel re-runs its idempotent teardown), a `cancel_by_id` (the scope + the
 *  data-addressed fiber id — persisted the same way), a `roster` (the scope whose running set it reads — a
 *  pure read, re-completable after a restart), a `watch` (the scope whose fibers' escalations it re-emits,
 *  read from the handle — held open, never settling), or an `operation` — an unknown dispatch key (compiler /
 *  wire drift), which fails the call with a clear completion. */
type RegionPayload =
  | {
      kind: "cancel";
      /** The nursery scope and fiber id the cancel tears down, read from the fiber HANDLE (its own scope names
       *  the nursery that spawned it). Either is `null` when the handle was malformed — an
       *  uncancellable fiber, refused as a panic. Persisted, so a cancel interrupted before its teardown
       *  confirmed re-runs identically after a restart (a re-sent terminate is idempotent). */
      scope: string | null;
      fiber: string | null;
    }
  | {
      kind: "cancel_by_id";
      /** The nursery scope, read from the NURSERY handle (a dead / forged one is an invariant break, refused
       *  as a panic — unlike the id, which is anticipated data). Persisted like a `cancel`, so an interrupted
       *  teardown re-runs idempotently after a restart. */
      scope: string | null;
      /** The runtime-minted fiber id to tear down, read from the plain `id` argument (`null` when it was not
       *  a string — folded into the unknown-id miss, since ids are data, not capabilities). */
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
      /** The fibers' escalations waiting for a `watch` to REGISTER. Once a watch is live the mailbox drains
       *  WHOLE and at once (each escalation re-emitted the moment it arrives — a watch imposes no serialization
       *  of its own), so this holds only the pre-registration backlog; a nursery that never registers a watch
       *  holds it indefinitely (there is no flush-up). FIFO, which is what a downstream sequential handler
       *  needs. Persisted on the provide's extension, so a restart restores the "溜まっていた" requests no watch
       *  had yet claimed. */
      mailbox: MailboxEntry[];
      /** The RUNNING fibers' name tags, by fiber id — the `fork(name)` echo `roster` and `crashed` report.
       *  Only named, still-running fibers have an entry (absence IS "unnamed"; `retireFiber` cleans it), and
       *  it persists with the provide so the roster facts survive a restart alongside the running set. */
      names: Record<string, string>;
    }
  | {
      kind: "roster";
      /** The nursery scope whose RUNNING fibers this call lists, read from the handed nursery handle (`null`
       *  when the handle was malformed — refused as a dead scope, like `watch`). A pure read of the live
       *  running set, so a reloaded roster simply re-completes. */
      scope: string | null;
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
      /** The opaque name tag the fork carried (the compiler fills the default, so absent / non-string reads
       *  as "" — unnamed). Recorded on the provide's `names` at spawn, so `roster` / `crashed` echo it. */
      name: string;
    }
  | {
      kind: "operation";
      /** The unknown dispatch key the call arrived under (compiler / wire drift) — named in the completion that refuses it. */
      operation: string;
    };

/** A region call's durable extension document — a REAL sum, one tag. A `provide` persists its endpoint payload
 *  (scope id + continuation + bridges) so a restart re-registers it; a `fork` persists
 *  its (task + argument) re-dispatch; an `operation` persists only its key (it fails immediately, but a crash
 *  mid-flight still reloads it as the same refusal). */
export type RegionExtension =
  | {
      kind: "provide";
      snapshotId: SnapshotId;
      scopeId: string;
      continuation: Value | null;
      mailbox: MailboxEntry[];
      /** The running fibers' name tags (see the payload's `names`) — durable so `roster` and `crashed` still
       *  echo them after a restart. */
      names: Record<string, string>;
      relays: EscalationRelayRow[];
      innerCalls: InnerCallRow[];
    }
  | {
      kind: "fork";
      scopeId: string | null;
      task: Value | null;
      argument: Value | null;
      name: string;
    }
  | { kind: "cancel"; scopeId: string | null; fiberId: string | null }
  | { kind: "cancel_by_id"; scopeId: string | null; fiberId: string | null }
  | { kind: "roster"; scopeId: string | null }
  | {
      kind: "watch";
      scopeId: string | null;
      /** The fiber escalations this held-open watch is currently RE-EMITTING (possibly MANY concurrently — a
       *  watch carries one relay per outstanding escalation), bridged so a restart re-parks every outstanding
       *  relay and each handler's answer still descends to its own fiber. */
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
        mailbox: asJson(extension.mailbox),
        names: extension.names,
        relays: encodeRelays(extension.relays),
        innerCalls: encodeInnerCalls(extension.innerCalls),
      };
    case "fork":
      return {
        kind: "fork",
        scopeId: extension.scopeId,
        task: asJson(extension.task),
        argument: asJson(extension.argument),
        name: extension.name,
      };
    case "cancel":
      return { kind: "cancel", scopeId: extension.scopeId, fiberId: extension.fiberId };
    case "cancel_by_id":
      return { kind: "cancel_by_id", scopeId: extension.scopeId, fiberId: extension.fiberId };
    case "roster":
      return { kind: "roster", scopeId: extension.scopeId };
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
        mailbox: warmFieldOf<MailboxEntry[]>(document, "mailbox"),
        names: namesOf(document),
        relays: relaysOf(document),
        innerCalls: innerCallsOf(document),
      };
    case "fork": {
      // Read the name leniently (an absent field is ""): a pre-names row must reload as an unnamed fork
      // rather than crash the whole load pass.
      const name = document.name;
      return {
        kind: "fork",
        scopeId: warmFieldOf<string | null>(document, "scopeId"),
        task: warmFieldOf<Value | null>(document, "task"),
        argument: warmFieldOf<Value | null>(document, "argument"),
        name: typeof name === "string" ? name : "",
      };
    }
    case "cancel":
      return {
        kind: "cancel",
        scopeId: warmFieldOf<string | null>(document, "scopeId"),
        fiberId: warmFieldOf<string | null>(document, "fiberId"),
      };
    case "cancel_by_id":
      return {
        kind: "cancel_by_id",
        scopeId: warmFieldOf<string | null>(document, "scopeId"),
        fiberId: warmFieldOf<string | null>(document, "fiberId"),
      };
    case "roster":
      return {
        kind: "roster",
        scopeId: warmFieldOf<string | null>(document, "scopeId"),
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

/** The provide's durable name-tag map, read leniently: a row written before `names` existed (or with a
 *  non-object field) reloads as "no named fibers" rather than crashing the load pass — names are echo
 *  material, not routing, so degrading beats refusing the whole nursery. */
function namesOf(document: Record<string, Json>): Record<string, string> {
  const raw = document.names;
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return {};
  const names: Record<string, string> = {};
  for (const [fiber, name] of Object.entries(raw)) {
    if (typeof name === "string") names[fiber] = name;
  }
  return names;
}

export class RegionReactor extends ExternalCallReactor<RegionPayload> {
  readonly name: ReactorName = "region";

  /** The live provide scopes, by their identity: the provide call each opened (a `fork` opens its fiber as an
   *  inner delegation of THIS call), and that nursery's RUNNING fibers (their inner-delegation ids, so a later
   *  `cancel` finds them). Registered at dispatch / reload of a running provide, released at drop —
   *  `fork` checks membership here (the requires-a-live-provide gate). A SETTLED fiber lives nowhere: it is
   *  retired on the spot and its `null` outcome discarded (results ride escalations); the running map is
   *  in-memory routing whose durable twin is the base inner-call bridges. */
  private readonly scopes = new Map<string, ScopeState>();

  /** The cancels awaiting a still-running fiber's teardown, by that fiber's id — the cancel's call is held open
   *  until the terminate this reactor sent to the fiber's inner delegation confirms (its `cancelled` outcome
   *  lands in `retireFiber`, which settles the cancel with `null`). In-memory only (like `mcp`'s served-call
   *  waiters): the durable twin is the cancel's own row plus the fiber's inner-call bridge, so a restart
   *  re-parks it by re-running `startCancel` in `recover` against the reloaded running-fiber set (a re-sent
   *  terminate is idempotent). */
  private readonly cancelWaiters = new Map<string, DelegationId>();

  /** The live `watch` calls of each nursery scope, by the scope identity — the white holes a fiber's
   *  escalation is re-emitted at. In-memory routing (like `cancelWaiters`): the durable twin is each watch's own
   *  call row, so a restart rebuilds this from `recover`. Kept separate from `ScopeState` so a watch's
   *  registration does not depend on the ORDER a reload reloads the provide vs. its watch (both re-register
   *  independently); the drain (`pumpWatch`) reads the provide's mailbox only once the scope itself is live.
   *  A Set so registration order is FIFO-deterministic when a nursery has more than one watch. */
  private readonly watchesByScope = new Map<string, Set<DelegationId>>();

  /** The reverse of `watchesByScope`: a watch call to the scope it watches — how `onDropCall` finds the scope
   *  to re-route a dropped watch's not-yet-emitted escalations to a remaining watch (or leave them buffered). */
  private readonly watchScope = new Map<DelegationId, string>();

  constructor(
    /** Schedule a fresh reactor turn (the substrate's serial mailbox) — how a provide's post-commit work
     *  (the continuation dispatch, a synthesised completion) re-enters the transactional loop, so its inner
     *  delegation opens inside a turn and commits with it. */
    private readonly schedule: (work: () => void) => void,
    pool: ResourcePool,
    /** Warns when a fiber crashes into a nursery with no watch installed: with the quiescence flush-up gone,
     *  such a `crashed` event no longer auto-surfaces at the run root, so the one visible trace of the crash is
     *  this line (the semantics are unchanged — the event waits, buffered, for a watch). */
    private readonly logger: Logger,
  ) {
    super(pool);
  }

  // ─── the provide scope registry ────────────────────────────────────────────────────────────────

  /** Register a provide's scope as live, mapping it to the provide call that opened it (the parent a `fork`
   *  spawns its fiber under). Called at a fresh dispatch and at every reload of a running provide, so a `fork`
   *  finds its nursery. `openScope` itself starts with an empty running-fiber set; on a reload `recover`
   *  rebuilds it at once from the durable inner-call bridges (`repopulateRunning`), so a `cancel` can route to a
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
   *  by `onDropCall`, so any escalation it had not yet drained re-routes to another watch, or stays buffered
   *  until a fresh watch registers. */
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
        mailbox: [],
        names: {},
      };
    }
    if (target.key === REGION_FORK_KEY) {
      // The nursery handle rides the argument (`fork(nursery, task, argument, name)`); its scope identity is
      // the one thing the runtime routes on — read it out now, so `dispatch` gates on a plain string. A
      // malformed handle yields a `null` scope, refused as a dead scope. The name is a plain tag with a
      // compiler-filled default, so anything but a string reads as "" (unnamed).
      const name = fields.name;
      return {
        kind: "fork",
        scope: scopeOfNursery(fields.nursery ?? null),
        task: fields.task ?? null,
        argument: fields.argument ?? null,
        name: name !== undefined && name.kind === "string" ? name.value : "",
      };
    }
    if (target.key === REGION_ROSTER_KEY) {
      // `roster(nursery)`: route on the nursery's scope, exactly like `watch` — a malformed handle yields a
      // `null` scope, refused as a dead scope.
      return { kind: "roster", scope: scopeOfNursery(fields.nursery ?? null) };
    }
    if (target.key === REGION_CANCEL_BY_ID_KEY) {
      // `cancel_by_id(nursery, id)`: the NURSERY handle gates (its scope must name a live nursery — a forged
      // handle is an invariant break), while the id is plain data resolved against the running set at
      // dispatch; a non-string id folds into the unknown-id miss rather than a refusal.
      const id = fields.id;
      return {
        kind: "cancel_by_id",
        scope: scopeOfNursery(fields.nursery ?? null),
        fiber: id !== undefined && id.kind === "string" ? id.value : null,
      };
    }
    if (target.key === REGION_CANCEL_KEY) {
      // `cancel(nursery, handle)`: route on the HANDLE's own scope + fiber id, not the `nursery` argument
      // (which the type system only pins `Scope` through) — the handle names the nursery that spawned the
      // fiber, so the fiber is torn down where it actually lives even under nested same-marker scopes. A
      // malformed / forged handle yields `null`s, refused as an uncancellable fiber.
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
    if (payload.kind === "cancel") {
      // Sending the fiber's terminate is a `send`, which must happen inside a turn — hand it back to the loop.
      this.schedule(() => this.startCancel(delegation));
      return;
    }
    if (payload.kind === "cancel_by_id") {
      // The id-addressed cancel shares the terminate path, so it too re-enters the loop for its `send`s.
      this.schedule(() => this.startCancelById(delegation));
      return;
    }
    if (payload.kind === "roster") {
      // Completing is `send`-shaped as well; the read itself is pure, so the whole roster is one turn.
      this.schedule(() => this.startRoster(delegation));
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
    // Transfer the task closure's captured lexical scopes OFF the forking instance onto the PROVIDE instance,
    // before the fiber is spawned. A forked closure captures the FORKER's scope, but the fiber is DETACHED —
    // `fork` returns a handle at once and the forker runs on (and, in the common case, returns), so its
    // intra-instance GC and its teardown reclaim that scope out from under the still-running fiber (the GC
    // soundness invariant — "a borrowed scope keeps its borrower suspended" — does not hold for a fiber). The
    // provide structurally OUTLIVES every fiber (the nursery cancels them all at drop) and every forker (the
    // phantom `Scope` marker confines a live nursery to the provide's dynamic extent), so parking the captured
    // environment on it keeps it alive exactly as long as any fiber can read through it, and its own drop
    // reclaims it. Mirrors how a fiber's RETURNED resources reown onto the provide (`onDelegateAck`) — the
    // inbound twin of that outbound.
    //
    // The forker is the OWNER of the closure's own captured scope, NOT the fork delegate's issuer: `region.fork`
    // is an external agent, so the delegate reaching this reactor was issued by its wrapper instance, one hop
    // removed from the user code that built the closure. `release` then moves only the forker's OWN scopes (a
    // borrowed ancestor owned by another still-live instance stays put, kept alive by its own owner — no
    // regression for a closure capturing above the nursery); a named-agent task owns no captured scope, so this
    // is a no-op for it. The argument crosses into the fiber too and can capture the same forker's scopes.
    const provideInstance = this.callInstance(scopeState.provide);
    const forker =
      payload.task.kind === "closure" ? this.pool.ownerOfScope(payload.task.scopeId) : null;
    if (provideInstance !== undefined && forker !== null && forker !== provideInstance) {
      this.pool.release(payload.task, forker);
      this.reownIncoming(payload.task, provideInstance);
      if (payload.argument !== null) {
        this.pool.release(payload.argument, forker);
        this.reownIncoming(payload.argument, provideInstance);
      }
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
    // Record the name tag on the PROVIDE — the durable owner of the roster facts (`roster` and `crashed`
    // echo it, and it must survive a restart alongside the running set). An empty name is not stored:
    // absence IS "unnamed". `openInnerDelegation` already marked the provide dirty this turn, so the map
    // persists with the same commit that persists the fiber's bridge.
    if (payload.name !== "") {
      const providePayload = this.payloadOf(scopeState.provide);
      if (providePayload !== undefined && providePayload.kind === "provide") {
        providePayload.names[fiber] = payload.name;
      }
    }
    // The fork returns the handle NOW; the fiber runs on independently under the provide. (The fork call owns
    // no children of its own, so this settlement drains immediately.)
    this.complete({
      delegation,
      outcome: { kind: "result", value: mintFiberHandle(payload.scope, fiber) },
    });
  }

  /** Tear ONE fiber down early (a reactor turn). Route on the handle's scope + fiber id: a live fiber has its
   *  inner delegation terminated (the single-fiber form of the provide's cancel cascade) and the cancel is held
   *  open until that teardown confirms; a fiber already SETTLED or gone is an idempotent no-op that still
   *  succeeds. A handle whose
   *  scope is not a live nursery — a forged / hostile-wire handle (its random scope matches nothing) or a dead
   *  scope — PANICS (the checker pins the handle's scope to a live nursery, so this is an engine-invariant
   *  break; `cancel` declares no throw and region has no error sum, the same backstop as `fork`). */
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
      // A live fiber: terminate its inner delegation and hold this cancel open until the teardown confirms
      // in `retireFiber`.
      // Drop this fiber's not-yet-emitted escalations so a watch never re-emits a cancelled fiber's requests.
      this.dropFiberMailbox(scopeState.provide, running);
      this.cancelWaiters.set(fiber, delegation);
      this.terminateFiber(scopeState.provide, running);
      return;
    }
    // Not running: the fiber already settled (retired, its outcome discarded) or was already cancelled.
    // A cancel is idempotent — succeed with `null`.
    this.settleCancel(delegation);
  }

  /** Tear down the fiber the runtime knows by ID (a reactor turn) — the data-addressed form of `cancel`, for
   *  callers whose currency is ids rather than held handles. The NURSERY handle still gates: a dead / forged
   *  scope is an invariant break, refused as a panic like `watch` / `fork`. The id, by contrast, is
   *  anticipated input (often model-supplied): one matching no running fiber answers with the
   *  `unknown_fiber` outcome, and a live one runs exactly the `cancel` teardown, settling with `cancelled`
   *  once the teardown confirms in `retireFiber`. A fiber another cancel is already tearing down completes
   *  at once with `cancelled` — the fiber is going either way, and waiting would only race the first
   *  cancel's waiter. */
  private startCancelById(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined || payload.kind !== "cancel_by_id") return; // resolved / cancelled meanwhile
    const scopeState = payload.scope === null ? undefined : this.scopes.get(payload.scope);
    if (payload.scope === null || scopeState === undefined) {
      this.complete({
        delegation,
        outcome: {
          kind: "error",
          message: `region.cancel_by_id: the nursery scope ${payload.scope ?? "(malformed handle)"} is not live (a forged handle, or its region.provide has returned)`,
        },
      });
      return;
    }
    const fiber = payload.fiber ?? "";
    const running = scopeState.running.get(fiber);
    if (running === undefined) {
      this.completeWithOutcome(delegation, UNKNOWN_FIBER_CONSTRUCTOR, fiber);
      return;
    }
    if (this.cancelWaiters.has(fiber)) {
      this.completeWithOutcome(delegation, CANCELLED_CONSTRUCTOR, fiber);
      return;
    }
    // The live-fiber path is byte-for-byte the plain cancel's: drop the fiber's queued escalations, park
    // this call as the teardown's waiter, terminate the inner delegation.
    this.dropFiberMailbox(scopeState.provide, running);
    this.cancelWaiters.set(fiber, delegation);
    this.terminateFiber(scopeState.provide, running);
  }

  /** List the nursery's RUNNING fibers (a reactor turn): one `fiber_info(id, name)` per live fiber, in fork
   *  order (the running map's insertion order, which the durable inner-call bridges preserve across a
   *  restart). The runtime's own liveness is the ONLY copy — a settled or cancelled fiber is simply absent —
   *  so there is nothing to reconcile. A dead / forged scope is refused as a panic, like `watch`. */
  private startRoster(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined || payload.kind !== "roster") return; // resolved / cancelled meanwhile
    const scopeState = payload.scope === null ? undefined : this.scopes.get(payload.scope);
    if (payload.scope === null || scopeState === undefined) {
      this.complete({
        delegation,
        outcome: {
          kind: "error",
          message: `region.roster: the nursery scope ${payload.scope ?? "(malformed handle)"} is not live (a forged handle, or its region.provide has returned)`,
        },
      });
      return;
    }
    const providePayload = this.payloadOf(scopeState.provide);
    const names = providePayload?.kind === "provide" ? providePayload.names : {};
    const infos: Value = {
      kind: "array",
      elements: [...scopeState.running.keys()].map(
        (fiber): Value => ({
          kind: "record",
          ctor: FIBER_INFO_CONSTRUCTOR,
          fields: {
            id: { kind: "string", value: fiber },
            name: { kind: "string", value: names[fiber] ?? "" },
          },
        }),
      ),
    };
    // Lower to the completion's wire Json the same way an inner outcome lowers (`reveal` — this boundary
    // faces the engine): the constructor tags ride the `$katari_constructor` convention, which the base
    // wire decoder reconstructs into data values a Katari `match` dispatches on.
    this.complete({ delegation, outcome: { kind: "result", value: valueToJson(infos, "reveal") } });
  }

  /** Settle an id-addressed cancel with one of its `cancel_outcome` data values — `cancelled(id)` or
   *  `unknown_fiber(id)` — lowered to the completion's wire Json under the `$katari_constructor`
   *  convention, so the decoded result is a data value a Katari `match` dispatches on. */
  private completeWithOutcome(
    delegation: DelegationId,
    constructorName: QualifiedName,
    id: string,
  ): void {
    const outcome: Value = {
      kind: "record",
      ctor: constructorName,
      fields: { id: { kind: "string", value: id } },
    };
    this.complete({
      delegation,
      outcome: { kind: "result", value: valueToJson(outcome, "reveal") },
    });
  }

  /** Terminate one fiber's inner delegation — the single-fiber form of the base's whole-nursery
   *  `terminateChildren` cascade. The fiber is the PROVIDE's inner delegation (parented there by `fork`), so
   *  the terminate rides the provide's trace context and the answering `terminateAck` reaches the base's
   *  `onTerminateAck` under the provide, delivering a `cancelled` outcome to `retireFiber`. A fiber whose
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

  /** Settle a cancel with `null` (its declared result) once the fiber it targeted is gone. */
  private settleCancel(delegation: DelegationId): void {
    this.complete({ delegation, outcome: { kind: "result", value: null } });
  }

  /** Fail a cancel whose handle names no live nursery scope (malformed / forged, or a dead scope) as a panic —
   *  the engine-invariant backstop, and the automatic rejection of a hostile-wire
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
   *  retire it (a waiting cancel settles; the outcome is discarded — results ride escalations). */
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
    this.schedule(() => this.retireFiber(delivery.delegation, delivery.call));
  }

  /** A settled fiber, on a fresh turn: RETIRE it. A CANCEL awaiting this fiber's teardown settles — whether
   *  the outcome is the terminate's `cancelled` or a `result` the fiber raced to before the terminate landed,
   *  the fiber is gone either way. The outcome itself is DISCARDED unconditionally: there is no `join`, tasks
   *  are `-> null` (the stdlib's fork pins it), so a settled value carries nothing — results ride the fiber's
   *  escalations, delivered before it could end. Nothing durable remains of a finished fiber, which is what a
   *  never-closing resident nursery needs. (A stale-IR fiber that somehow settles with a resource-carrying
   *  value keeps the base's behavior: re-owned onto the provide by `onDelegateAck`, reclaimed at its drop.) */
  private retireFiber(provide: DelegationId, fiber: string): void {
    const payload = this.payloadOf(provide);
    if (payload === undefined || payload.kind !== "provide") return; // the provide resolved meanwhile
    // Retire the fiber from its scope's running set (a no-op for a fiber never re-registered after a reload).
    this.scopes.get(payload.scope)?.running.delete(fiber);
    // A name tag is roster / crashed material for a RUNNING fiber only — clean it with the running entry,
    // so the durable map never accumulates settled fibers.
    if (payload.names[fiber] !== undefined) {
      delete payload.names[fiber];
      this.markCallDirty(provide);
    }
    const cancelling = this.cancelWaiters.get(fiber);
    if (cancelling !== undefined) {
      this.cancelWaiters.delete(fiber);
      this.settleCancelWaiter(cancelling, fiber);
    }
  }

  /** Settle a confirmed teardown's waiting cancel according to ITS OWN call shape: a plain `cancel` declares
   *  `null` (unchanged), while an id-addressed `cancel_by_id` declares the `cancelled` outcome naming the
   *  fiber — the one place the two cancel forms diverge. */
  private settleCancelWaiter(delegation: DelegationId, fiber: string): void {
    if (this.payloadOf(delegation)?.kind === "cancel_by_id") {
      this.completeWithOutcome(delegation, CANCELLED_CONSTRUCTOR, fiber);
      return;
    }
    this.settleCancel(delegation);
  }

  // ─── watch: the white hole (fiber escalations re-emitted at the watch's position) ─────────────────

  /** The one-time watch validation (a reactor turn): confirm the nursery is still live, register this watch as
   *  a white hole of its scope, then drain any escalations the mailbox is already holding (the ones that beat
   *  the watch's registration — the durable backlog buffered until this moment). The call is
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
   *  watch's registration stays mailboxed until `startWatch` drains it; a nursery that never registers a watch
   *  keeps it buffered indefinitely (it is never surfaced above the provide — the fibers' `E` is not in the
   *  provide's declared row). A fiber's PANIC is intercepted here instead of mailboxed: it becomes the typed
   *  `crashed` event (`crashFiber`). Any non-fiber escalation (the continuation's own request) relays up
   *  through the provide unchanged (the base path). */
  protected override onEscalate(
    event: Extract<ExternalEvent, { kind: "escalate" }>,
    context: { caller: InstanceId | undefined },
  ): void {
    const located = this.runningFiberOf(event.delegation);
    if (located === undefined) {
      super.onEscalate(event, context);
      return;
    }
    const scope = located.scope;
    const scopeState = this.scopes.get(scope);
    const provide = scopeState?.provide;
    const payload = provide === undefined ? undefined : this.payloadOf(provide);
    if (provide === undefined || payload === undefined || payload.kind !== "provide") {
      super.onEscalate(event, context);
      return;
    }
    if (event.ask.kind === "request" && event.ask.request === PANIC_REQUEST) {
      this.crashFiber(located.fiber, provide, payload, event);
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
    // the watch lands. A nursery with no watch keeps it buffered — there is no flush-up, so a watch installed
    // arbitrarily late still finds every pre-registration escalation waiting for it.
    if ((this.watchesByScope.get(scope)?.size ?? 0) > 0) this.pumpWatch(scope);
  }

  /** A fiber PANICKED — the one ending a task cannot report itself. The fiber is dead at this instant (a
   *  panic never resumes), so instead of mailboxing the raw panic: tear the fiber down exactly like a
   *  `cancel` (drop its queued escalations, terminate its inner delegation — but with NO waiter, since
   *  nobody asked), and report the ending as DATA — a SYNTHETIC `crashed` mailbox entry carrying the
   *  fiber's id, its recorded name tag, and the panic's message. The entry rides the same FIFO as
   *  ordinary entries, so it surfaces at the watch once one registers — a watch-less nursery simply holds it
   *  buffered, so a crash with no watch installed is WARNED here (it no longer auto-surfaces at the run root).
   *  Having no child leg, its eventual answer is discarded (see `emitEntry`). The panic escalation
   *  itself is never answered — its durable row dies with the fiber's teardown, like a cancelled fiber's
   *  moot escalation. */
  private crashFiber(
    fiber: string,
    provide: DelegationId,
    payload: Extract<RegionPayload, { kind: "provide" }>,
    event: Extract<ExternalEvent, { kind: "escalate" }>,
  ): void {
    const name = payload.names[fiber] ?? "";
    const message = panicMessageOf(event.ask);
    this.dropFiberMailbox(provide, event.delegation);
    this.terminateFiber(provide, event.delegation);
    payload.mailbox.push({
      child: null,
      childEscalation: null,
      ask: {
        kind: "request",
        request: REGION_CRASHED_REQUEST,
        argument: {
          kind: "record",
          fields: {
            id: { kind: "string", value: fiber },
            name: { kind: "string", value: name },
            message: { kind: "string", value: message },
          },
        },
      },
    });
    this.markCallDirty(provide);
    if ((this.watchesByScope.get(payload.scope)?.size ?? 0) > 0) this.pumpWatch(payload.scope);
    // No watch is installed, so this crash will not surface anywhere until one registers (and none may). Warn
    // so an operator has a trace of the crash even while the typed `crashed` event waits, buffered, unread.
    else
      this.logger.warn(
        "region: a fiber crashed into a nursery with no watch; the crashed event is buffered",
        {
          fiber,
          name,
          message,
        },
      );
  }

  // A relayed answer needs no region-specific handling: the base `onEscalateAck` descends each answer to its
  // own fiber, keyed on the escalation id, so many outstanding relays per watch are answered independently.
  // There is no "pump the next mailbox entry" step — a watch re-emits EVERY mailboxed escalation the moment
  // it arrives (see `pumpWatch`), so nothing eligible is ever left waiting for an answer to free the watch.

  /** Re-emit ALL of the nursery's mailboxed escalations at its watches, CONCURRENTLY — a watch is a
   *  transparent WHITE HOLE that imposes NO serialization of its own, so every mailboxed escalation is
   *  re-raised at once (each under a watch's own delegation, so it surfaces at the watch's caller — the
   *  handler). Serialization, when it matters, is the RECEIVING handler's: a sequential (`var`) handler
   *  re-serializes its own stream at its FIFO, a `parallel handler` does not — so two escalations to DIFFERENT
   *  handlers are always concurrent (no cross-handler starvation), while two to the SAME var handler serialize
   *  at that handler in arrival order. Entries are re-emitted in mailbox (arrival) order and — across several
   *  watches of one nursery — round-robin, each escalation to exactly ONE watch, so a downstream sequential
   *  handler sees them in arrival order (the FIFO-into-a-var-handler guarantee). A watch winding down (a racing
   *  cancel) cannot take an entry; it re-routes to another watch, or — if none can take it — stays mailboxed,
   *  in order, for the dropping watch's re-pump (`onDropCall`) or for whatever watch registers next. */
  private pumpWatch(scope: string): void {
    const scopeState = this.scopes.get(scope);
    const watches = this.watchesByScope.get(scope);
    if (scopeState === undefined || watches === undefined || watches.size === 0) return;
    const providePayload = this.payloadOf(scopeState.provide);
    if (providePayload === undefined || providePayload.kind !== "provide") return;
    if (providePayload.mailbox.length === 0) return;
    const watchList = [...watches];
    // Drain the WHOLE mailbox this turn: everything currently held is re-emitted, not one-then-await.
    const draining = providePayload.mailbox;
    providePayload.mailbox = [];
    const undelivered: MailboxEntry[] = [];
    let cursor = 0;
    for (const entry of draining) {
      let delivered = false;
      // Round-robin the watches, retrying past any winding down, so each entry lands on exactly one live watch.
      for (let attempt = 0; attempt < watchList.length; attempt += 1) {
        const watch = watchList[(cursor + attempt) % watchList.length];
        if (watch !== undefined && this.emitEntry(watch, entry)) {
          cursor = (cursor + attempt + 1) % watchList.length;
          delivered = true;
          break;
        }
      }
      if (!delivered) undelivered.push(entry);
    }
    // Anything no live watch could take (every watch winding down) stays mailboxed, in order, ahead of
    // whatever arrived meanwhile — the dropping watch's re-pump, or the next watch to register, handles it.
    providePayload.mailbox = undelivered.concat(providePayload.mailbox);
    this.markCallDirty(scopeState.provide);
  }

  /** Re-raise one mailbox entry under `under` (always a watch — a fiber's escalation surfaces at a watch and
   *  nowhere else). An ordinary entry relays with its fiber's own leg, so the handler's answer descends to the
   *  fiber. A SYNTHETIC entry (a runtime-authored `crashed` event — its fiber is already dead) relays under
   *  FRESH ids that name no live delegation: the relay row bridges the answer like any other, but when it
   *  descends, the base's moot-answer guard (`issuedPeerOf` finds no peer for the fake child) swallows it — the
   *  exact behaviour a cancelled fiber's in-flight answer already gets, reused rather than re-invented. */
  private emitEntry(under: DelegationId, entry: MailboxEntry): boolean {
    return this.relayAskUnder(
      under,
      entry.child ?? newDelegationId(),
      entry.childEscalation ?? newEscalationId(),
      entry.ask,
    );
  }

  /** The nursery scope and fiber id a still-running fiber's delegation belongs to, or `undefined` when the
   *  escalating delegation is not a fiber (the provide's continuation, whose escalations relay up unchanged).
   *  A scan over the live scopes' running sets — each is small (a nursery's in-flight fibers), and a fiber
   *  escalation is far rarer than an ordinary event, so no reverse index is warranted. The fiber id rides
   *  along because a panic's `crashed` report names it. */
  private runningFiberOf(delegation: DelegationId): { scope: string; fiber: string } | undefined {
    for (const [scope, state] of this.scopes) {
      for (const [fiber, running] of state.running) {
        if (running === delegation) return { scope, fiber };
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
   *  the same engine-invariant backstop as an uncancellable fiber (the checker gates `watch` on a
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
   *  inner-call bridges (so a cancel can route to a fiber that outlived the restart), and either re-dispatches
   *  its continuation (still stored — the block never started) or resumes it (already dispatched, so it, and
   *  its running fibers, are durable core work). A reloaded FORK
   *  re-spawns: a fork's only effect is opening an inner delegation, so re-running an interrupted one is safe
   *  (a committed fork is already gone — reaching here means its spawn never committed). A reloaded CANCEL re-runs its idempotent teardown: it
   *  re-terminates the fiber if it is still running (a re-sent terminate is a no-op on an already-cancelling
   *  delegation), else succeeds at once (the fiber's teardown committed before the crash — it is gone). A
   *  reloaded WATCH re-registers as its scope's white hole SYNCHRONOUSLY (before any scheduled pump), its
   *  outstanding relays (possibly many) restored from the durable row so each handler's answer still descends to
   *  its own fiber; the
   *  provide re-pumps its reloaded mailbox (the "溜まっていた" requests), routing them to the watch — or, watch-less,
   *  leaving them buffered for whatever watch registers next. There is no external process to reconcile (like
   *  `webhook` / `time`). An `operation` call is
   *  at-most-once: it never really began (it fails immediately), so a reloaded one refuses again, never re-run. */
  protected recover(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined) return;
    switch (payload.kind) {
      case "fork":
        this.schedule(() => this.startFork(delegation));
        return;
      case "cancel":
        this.schedule(() => this.startCancel(delegation));
        return;
      case "cancel_by_id":
        // Same shape as a reloaded cancel: re-run the idempotent teardown against the reloaded running
        // set — a re-sent terminate is a no-op, and a fiber whose teardown committed answers `unknown_fiber`
        // (the id-addressed contract: the fiber is gone, however it went).
        this.schedule(() => this.startCancelById(delegation));
        return;
      case "roster":
        // A roster is a pure read of the live running set, so re-completing an interrupted one is as safe
        // as re-running an interrupted fork's spawn. Scheduled, so every provide has re-registered first.
        this.schedule(() => this.startRoster(delegation));
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
        // watch-less reload keeps the mailbox buffered, awaiting whatever watch registers next.
        if (payload.mailbox.length > 0) this.schedule(() => this.pumpWatch(payload.scope));
        if (payload.continuation !== null) this.schedule(() => this.startContinuation(delegation));
        return;
    }
  }

  /** Rebuild a reloaded provide's running-fiber set from its durable inner-call bridges: every bridge whose
   *  token carries the fiber prefix is a still-running fiber (the continuation's own bridge is filtered out by
   *  the prefix), so a `cancel` / `cancel_by_id` / `roster` arriving after a restart routes against it. A
   *  settled fiber is NOT here — it was retired on the spot, and nothing durable remains of it. Runs
   *  synchronously in `recover` (not scheduled), so every scope is fully populated before any scheduled
   *  operation turn reads it. */
  private repopulateRunning(scope: string, provide: DelegationId): void {
    const scopeState = this.scopes.get(scope);
    if (scopeState === undefined) return;
    for (const row of this.innerCallRowsOf(provide)) {
      if (row.call.startsWith(FIBER_TOKEN_PREFIX)) scopeState.running.set(row.call, row.delegation);
    }
  }

  /** A cancel's transport half: confirm on a fresh turn (a provide has no external work of its own — its
   *  children, the continuation and later its fibers, drain through the base's cancel cascade; the scope closes
   *  at drop). A waiting `cancel` and an `operation` call likewise just confirm — each owns
   *  no work beyond an in-memory waiter, which its drop hook forgets. */
  protected abort(delegation: DelegationId): void {
    this.schedule(() => this.complete({ delegation, outcome: { kind: "cancelled" } }));
  }

  /** A call resolved: close a provide's scope, forget a cancel's in-memory waiter, or unregister a
   *  watch and re-pump its scope (the drop hook covers every resolution path at once). A cancel that
   *  resolved by SETTLING already dropped its own waiter; this catches one torn down while still waiting (its
   *  own cancel), so a later fiber settle finds nothing stale to resume. A dropped WATCH re-pumps its scope so
   *  anything it had not yet re-emitted re-routes to another watch, or stays buffered for the next one. */
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
      // watch-less by the drop keeps its mailbox buffered, awaiting whatever watch registers next.
      if (scope !== undefined) this.schedule(() => this.pumpWatch(scope));
      return;
    }
    if (
      (payload.kind === "cancel" || payload.kind === "cancel_by_id") &&
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
          mailbox: payload.mailbox,
          names: payload.names,
          relays: row.relays,
          innerCalls: row.innerCalls,
        });
      case "fork":
        return encodeRegionExtension({
          kind: "fork",
          scopeId: payload.scope,
          task: payload.task,
          argument: payload.argument,
          name: payload.name,
        });
      case "cancel":
        return encodeRegionExtension({
          kind: "cancel",
          scopeId: payload.scope,
          fiberId: payload.fiber,
        });
      case "cancel_by_id":
        return encodeRegionExtension({
          kind: "cancel_by_id",
          scopeId: payload.scope,
          fiberId: payload.fiber,
        });
      case "roster":
        return encodeRegionExtension({ kind: "roster", scopeId: payload.scope });
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
            mailbox: decoded.mailbox,
            names: decoded.names,
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
            name: decoded.name,
          },
          relays: [],
          innerCalls: [],
        };
      case "cancel":
        return {
          payload: { kind: "cancel", scope: decoded.scopeId, fiber: decoded.fiberId },
          relays: [],
          innerCalls: [],
        };
      case "cancel_by_id":
        return {
          payload: { kind: "cancel_by_id", scope: decoded.scopeId, fiber: decoded.fiberId },
          relays: [],
          innerCalls: [],
        };
      case "roster":
        return {
          payload: { kind: "roster", scope: decoded.scopeId },
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
    // Cancel waiters and watch registrations are in-memory routing; a reset (poisoned commit) rebuilds them
    // from the reloaded rows — each waiting cancel's `startCancel`, and each watch's registration + the
    // provide's mailbox re-pump, in `recover`.
    this.cancelWaiters.clear();
    this.watchesByScope.clear();
    this.watchScope.clear();
  }
}

/** One live nursery's routing state: the provide call that opened it (a `fork`'s fiber parents on this), and
 *  its RUNNING fibers by id, in fork order (their inner-delegation ids — a `cancel` tears one down, a
 *  `roster` lists them). A settled fiber simply leaves this map — nothing durable remains of it. */
interface ScopeState {
  provide: DelegationId;
  running: Map<string, DelegationId>;
}

/** Mint the nursery handle `region.provide` hands its continuation for `scope`: an opaque record carrying only
 *  the scope identity, under the namespaced marker field. A `fork` / `watch` / `roster` / `cancel` reads the
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

/** The scope + fiber id a fiber HANDLE carries (each `null` when the handle is malformed) — a `cancel` reads
 *  both from the handle, since the handle's own scope names the nursery that spawned the fiber (so the fiber is
 *  cancelled where it lives, not in whatever `nursery` argument the call was handed). */
function fiberHandleOf(handle: Value | null): { scope: string | null; fiber: string | null } {
  if (handle === null || handle.kind !== "record") return { scope: null, fiber: null };
  const scope = handle.fields[NURSERY_SCOPE_FIELD];
  const fiber = handle.fields[NURSERY_FIBER_FIELD];
  return {
    scope: scope !== undefined && scope.kind === "string" ? scope.value : null,
    fiber: fiber !== undefined && fiber.kind === "string" ? fiber.value : null,
  };
}

/** The panic message a fiber died with, read from the panic ask's `{ msg }` record for the `crashed`
 *  report. The engine authors every panic with a plain string (`panicArgument`), so anything else — a
 *  malformed record, or a blob-backed string ref, which this synchronous path cannot materialise —
 *  degrades to a placeholder rather than an unrenderable value in the typed event. */
function panicMessageOf(ask: AskKind): string {
  const argument = ask.kind === "request" ? ask.argument : null;
  const message = argument !== null && argument.kind === "record" ? argument.fields.msg : undefined;
  return message !== undefined && message.kind === "string"
    ? message.value
    : "(unrenderable panic message)";
}

/** A fresh fiber id — the inner-call token the fiber's delegation is bridged under AND the id its handle
 *  carries. Random (not a counter), so it stays unique across a restart that resets in-memory counters. */
function mintFiberId(): string {
  return `${FIBER_TOKEN_PREFIX}${randomBytes(12).toString("base64url")}`;
}

/** Mint the `fiber[Scope]` handle `fork` returns, as the completion's wire Json: an opaque record carrying
 *  its nursery's scope identity and its own fiber id, under the namespaced marker fields — so a `cancel`
 *  routes back to THIS fiber of THIS nursery. Plain string leaves and no reserved wire discriminator,
 *  so the base's `jsonToValue` reconstructs it as a bare record with no ack-decoding seam of its own. */
function mintFiberHandle(scope: string, fiber: string): Json {
  return { [NURSERY_SCOPE_FIELD]: scope, [NURSERY_FIBER_FIELD]: fiber };
}
