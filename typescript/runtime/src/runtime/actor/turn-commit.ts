// The turn-commit vocabulary: what one turn changed, expressed so a `Persistence` can write it as a
// single atomic transaction. A turn touches two durable layers — Layer 1 entities (delegations /
// escalations: the request edges, each its own state machine) and Layer 2 the engine continuation (the
// instance's threads + scopes). Committing them together is what closes the gap the design worried about:
// a `DelegateThread` (Layer 2) that references a delegation whose Layer 1 row was not yet written.

import type { CoreInstance, Scope } from "../engine/types.js";
import type { DelegateTarget, ExternalEvent } from "../event/types.js";
import type { DelegationId, EscalationId, InstanceId, OutboxSeq } from "../ids.js";
import type { Value } from "../value/types.js";

/** A Layer 1 entity state transition a turn implies. The committing turn writes these atomically with its
 *  Layer 2, so an edge's durable record never lags the engine threads that reference it. Terminal states
 *  (done / gone / answered) are retained in place as history, not deleted. */
export type EntityTransition =
  | {
      kind: "delegation-open";
      delegation: DelegationId;
      caller: InstanceId;
      target: DelegateTarget;
      argument: Value | null;
    }
  | { kind: "delegation-done"; delegation: DelegationId; result: Value }
  | { kind: "delegation-cancelling"; delegation: DelegationId }
  | { kind: "delegation-gone"; delegation: DelegationId }
  | { kind: "delegation-failed"; delegation: DelegationId; errorMessage: string }
  | {
      kind: "escalation-open";
      escalation: EscalationId;
      raiser: InstanceId;
      request: string;
      argument: Value | null;
    }
  | { kind: "escalation-answered"; escalation: EscalationId; answer: Value };

/** Where a turn's Layer 2 (engine continuation) goes: persisted through (still running), dropped (it
 *  completed / was torn down — its threads + owned scopes cascade away), or none (an api-root "turn" — it
 *  runs no engine threads, so it only carries Layer 1 transitions). */
export type Layer2Commit =
  | { kind: "persist"; instance: CoreInstance; ownedScopes: Scope[] }
  | { kind: "drop" }
  | { kind: "none" };

/** One produced external event awaiting delivery — a durable outbox row. `issuer` is the instance that
 *  produced it (the api root for an api operation); on recovery it re-establishes a replayed `delegate`'s
 *  caller, which the event itself does not carry. */
export interface OutboxMessage {
  seq: OutboxSeq;
  issuer: InstanceId;
  event: ExternalEvent;
}

/** What one reactor turn *produced*, for the substrate to commit. A reactor computes its whole turn in
 *  memory and returns this; the substrate stamps the transactional-outbox bookkeeping onto it (the inbound
 *  `consumed` seq + a fresh seq per `outbound` event, issued by `instanceId`) and writes it atomically — see
 *  `TurnCommit`. Keeping reactors at this level (no seqs, no `consumed`) is what makes them hold no DB: they
 *  describe Layer 1 + Layer 2 + the events to emit, and the bus owns the durable bookkeeping. */
export interface Reaction {
  /** The instance whose turn this is — the Layer 2 target and the issuer stamped on every `outbound` event. */
  instanceId: InstanceId;
  layer2: Layer2Commit;
  transitions: EntityTransition[];
  /** The external events this turn emits (the bus mints an outbox seq for each at commit). */
  outbound: ExternalEvent[];
}

/** Everything one turn changed, to be committed atomically: its Layer 2, the Layer 1 transitions it
 *  implies, and the transactional-outbox bookkeeping — the inbound event it consumes (delete that row) and
 *  the events it produces (insert those rows). Writing the outbox in the same tx is what lets a crash
 *  neither lose an in-flight event nor double-deliver a consumed one. */
export interface TurnCommit {
  instanceId: InstanceId;
  layer2: Layer2Commit;
  transitions: EntityTransition[];
  /** The outbox row this turn consumes (delete it). `null` for an FFI-triggered turn or an api operation,
   *  which originate an event rather than consuming a durable one. */
  consumed: OutboxSeq | null;
  /** The external events this turn produces (insert as outbox rows), delivered to the mailbox after commit. */
  produced: OutboxMessage[];
}

/** The Layer 1 transitions a turn's *outbound external events* imply (issuer = the turn's instance). The
 *  delegation a turn *issues* (`delegate`) is intentionally NOT recorded here: it is recorded by the
 *  summoned child's create turn (where it commits atomically with the child instance), so its caller is
 *  read from the actor's routing, not derived here. `terminate` is likewise recorded by the cancel turn it
 *  triggers. Everything else maps directly to a state transition. */
export function outboundTransitions(
  issuer: InstanceId,
  outbound: ExternalEvent[],
): EntityTransition[] {
  const transitions: EntityTransition[] = [];
  for (const event of outbound) {
    switch (event.kind) {
      case "delegateAck":
        transitions.push({
          kind: "delegation-done",
          delegation: event.delegation,
          result: event.value,
        });
        break;
      case "terminateAck":
        transitions.push({ kind: "delegation-gone", delegation: event.delegation });
        break;
      case "escalate":
        // A Layer 1 escalation is a capability *request* awaiting an answer. A control escape (next / break
        // / return) that crosses an instance boundary is a one-way internal unwind, not a request — it never
        // gets an `escalateAck`, so opening a durable escalation row for it would only leak / pollute the
        // audit. The typechecker's escape discipline already keeps these from reaching the run root; here we
        // simply decline to record them as escalations. (A panic is structurally a `request`, so it is still
        // recorded, then cascades away with its failing instance.)
        if (event.ask.kind === "request") {
          transitions.push({
            kind: "escalation-open",
            escalation: event.escalation,
            raiser: issuer,
            request: event.ask.request,
            argument: event.ask.argument,
          });
        }
        break;
      case "escalateAck":
        transitions.push({
          kind: "escalation-answered",
          escalation: event.escalation,
          answer: event.value,
        });
        break;
    }
  }
  return transitions;
}
