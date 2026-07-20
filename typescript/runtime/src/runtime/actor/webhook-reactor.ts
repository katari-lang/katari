// WebhookReactor: the `webhook` reactor — dynamically generated inbound HTTP endpoints as a call reactor
// (see `ExternalCallReactor` for the shared callee-call lifecycle). A `webhook.inbound` call reaches it as
// a `delegate` (an external leaf marked `reactor: "webhook"`); it mints an unguessable token (the public
// URL's capability), dispatches the SUBSCRIBER once as an inner delegation carrying that URL, and then
// converts every `POST /inbound/<token>` into an inner delegation of the CALLBACK — resolved through
// the shared dynamic dispatch (`dispatchCallable`), so an agent / closure is delegated directly (the
// delegation boundary validates against the callee's own schema — the callee validates) and a `tool`
// callback validates against its runtime schema before the engine is touched. A mismatch either way
// surfaces as `reflection.call_error` → HTTP 400 without ever failing the run.
//
// It inverts the ffi / http direction — the outside world calls the program — which also inverts the
// recovery story: there is no external process to reconcile with, so a webhook call survives a restart
// COMPLETELY. The token + callback are persisted in its extension document and re-registered on load (the
// token also projects into `capability_routes`, so a cold inbound POST finds the project); the
// subscriber's inner delegation is durable core work that resumes on its own. Only a delivery whose HTTP
// waiter died with the process is lost — its response has no one to go to, and the webhook provider's
// retry redelivers.
//
// The call settles when the SUBSCRIBER settles: its result becomes the call's `delegateAck` (so `inbound`
// returns the subscriber's value), its throw / panic escalate like any callee failure, and a `terminate`
// from above cancels it (its FFI cleanup — deleting the external registration — runs) before the token is
// released. Either way the endpoint deactivates atomically with the call.

import { randomBytes } from "node:crypto";
import type { Json } from "@katari-lang/types";
import { CALL_ERROR, dispatchCallable } from "../engine/dynamic-dispatch.js";
import { errorData } from "../engine/throw-signal.js";
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

/** The transport data a webhook call holds. `token` and `callback` are persisted (the endpoint and its
 *  deliveries survive a restart); `subscriber` is consumed by the one-time dispatch and never stored. */
interface WebhookPayload {
  token: string;
  /** The snapshot the call was dispatched against — persisted as the extension's version pin (the
   *  callback stays resolvable against it). */
  snapshot: SnapshotId;
  callback: Value;
  subscriber: Value | null;
}

/** The webhook extension document: everything a reload re-registers — the capability `token` (the public
 *  URL), the `callback` each delivery dispatches (may capture private values, so the sealed subtree sits
 *  inside this document), the version pin, and the inner-delegation bridges. The subscriber is absent:
 *  dispatched exactly once, its inner delegation is durable core work. */
export interface WebhookExtension {
  snapshotId: SnapshotId;
  token: string;
  callback: Value;
  relays: EscalationRelayRow[];
  innerCalls: InnerCallRow[];
}

/** Encode a webhook call's extension document (pure — the persistence port seals it as a whole). */
export function encodeWebhookExtension(extension: WebhookExtension): Json {
  return {
    snapshotId: extension.snapshotId,
    token: extension.token,
    callback: asJson(extension.callback),
    relays: encodeRelays(extension.relays),
    innerCalls: encodeInnerCalls(extension.innerCalls),
  };
}

/** Decode a webhook call's extension document (pure). */
export function decodeWebhookExtension(extension: Json): WebhookExtension {
  const document = documentOf(extension);
  return {
    snapshotId: stringFieldOf(document, "snapshotId") as SnapshotId,
    token: stringFieldOf(document, "token"),
    callback: warmFieldOf<Value>(document, "callback"),
    relays: relaysOf(document),
    innerCalls: innerCallsOf(document),
  };
}

/** How one inbound delivery ended, resolved to the waiting HTTP request (values still engine `Value`s —
 *  the service lowers them at the user-facing boundary, redacting private content). */
export type WebhookDeliveryOutcome =
  /** No live endpoint holds this token. */
  | { kind: "unknown" }
  /** The endpoint exists but is winding down (cancelling, or its subscriber already settled). */
  | { kind: "gone" }
  /** The callback returned; its result is the response body. */
  | { kind: "result"; value: Value }
  /** The callback (or the dispatch boundary) threw a typed error — a schema violation is a
   *  `reflection.call_error`, the anticipated bad-request case. */
  | { kind: "throw"; value: Value }
  /** The callback panicked (or its process failed) — the internal-error case. */
  | { kind: "error"; message: string };

/** The subscriber's reserved inner-call token; deliveries use fresh `delivery:` tokens. */
const SUBSCRIBER_CALL = "subscriber";

export class WebhookReactor extends ExternalCallReactor<WebhookPayload> {
  readonly name: ReactorName = "webhook";

  /** The live endpoints: a URL token to the call serving it. Registered at dispatch / reload, released at
   *  drop — so a POST resolves its call in O(1) without scanning `calls`. */
  private readonly tokens = new Map<string, DelegationId>();
  /** The HTTP requests awaiting a delivery's outcome, by inner-call token. In-memory only: a waiter that
   *  dies with the process simply never answers (the provider retries); the delivery itself is durable. */
  private readonly waiters = new Map<string, (outcome: WebhookDeliveryOutcome) => void>();
  private deliverySequence = 0;

  constructor(
    /** The public base the minted URLs are formed under (`<baseUrl>/inbound/<token>`). */
    private readonly baseUrl: string,
    /** Schedule a fresh reactor turn (the substrate's serial mailbox) — how post-commit work (the
     *  subscriber dispatch, a synthesised completion) re-enters the transactional loop. */
    private readonly schedule: (work: () => void) => void,
    pool: ResourcePool,
  ) {
    super(pool);
  }

  // ─── the inbound delivery entry (called on a scheduled reactor turn) ────────────────────────────

  /** Convert one `POST /inbound/<token>` into an inner delegation of the endpoint's callback. `resolve` is
   *  called exactly once — synchronously for a dead token, post-commit with the callback's outcome
   *  otherwise. Runs inside a reactor turn, so the opened delegation commits with it. */
  deliver(
    token: string,
    argument: Value,
    resolve: (outcome: WebhookDeliveryOutcome) => void,
  ): void {
    const delegation = this.tokens.get(token);
    const payload = delegation === undefined ? undefined : this.payloadOf(delegation);
    if (delegation === undefined || payload === undefined) {
      this.tokens.delete(token);
      resolve({ kind: "unknown" });
      return;
    }
    // Resolve the callback value through the shared dynamic dispatch: an agent / closure is delegated
    // directly (the delegation boundary then validates against the callee's own schema — the callee
    // validates); a `tool` callback validates against its runtime schema right here, so a violating
    // delivery is answered 400 without ever entering the engine.
    const dispatched = dispatchCallable(payload.callback, argument);
    if ("error" in dispatched) {
      resolve({ kind: "throw", value: errorData(CALL_ERROR, dispatched.error) });
      return;
    }
    this.deliverySequence += 1;
    const call = `delivery:${this.deliverySequence}`;
    const opened = this.openInnerDelegation(
      delegation,
      dispatched.target,
      dispatched.to,
      dispatched.argument,
      call,
      dispatched.generics,
    );
    if (opened === null) {
      resolve({ kind: "gone" });
      return;
    }
    this.waiters.set(call, resolve);
  }

  /** The callback value this endpoint dispatches each delivery through — the seam the actor's delivery
   *  pre-validation resolves the declared input schema from. `undefined` once the endpoint is gone. */
  callbackFor(token: string): Value | undefined {
    const delegation = this.tokens.get(token);
    const payload = delegation === undefined ? undefined : this.payloadOf(delegation);
    return payload?.callback;
  }

  // ─── the ExternalCallReactor hooks ───────────────────────────────────────────────────────────────

  protected openPayload(target: ExternalTarget, argument: Value | null): WebhookPayload {
    const fields = argument !== null && argument.kind === "record" ? argument.fields : {};
    return {
      // 24 random bytes, base64url — the URL is the capability, so the token must be unguessable.
      token: randomBytes(24).toString("base64url"),
      snapshot: target.snapshot,
      callback: fields.callback ?? { kind: "null" },
      subscriber: fields.subscriber ?? null,
    };
  }

  /** Post-commit: activate the endpoint and hand the one-time subscriber dispatch back to the serial loop
   *  (a dispatch is a side-effect slot — the inner delegation itself must open inside a turn). */
  protected dispatch(delegation: DelegationId, payload: WebhookPayload): void {
    this.tokens.set(payload.token, delegation);
    const subscriber = payload.subscriber;
    payload.subscriber = null;
    this.schedule(() => this.startSubscriber(delegation, subscriber));
  }

  /** The one-time subscriber dispatch (a reactor turn): delegate the subscriber value with the minted URL.
   *  Its settlement is the whole call's settlement (see `deliverInnerOutcome`). */
  private startSubscriber(delegation: DelegationId, subscriber: Value | null): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined) return; // resolved / cancelled between the commit and this turn
    if (subscriber === null) {
      this.complete({
        delegation,
        outcome: { kind: "error", message: "webhook.inbound: the subscriber is missing" },
      });
      return;
    }
    const url: Value = {
      kind: "record",
      fields: { url: { kind: "string", value: `${this.baseUrl}/inbound/${payload.token}` } },
    };
    const dispatched = dispatchCallable(subscriber, url);
    if ("error" in dispatched) {
      this.complete({
        delegation,
        outcome: {
          kind: "error",
          message: `webhook.inbound: the subscriber is ${dispatched.error}`,
        },
      });
      return;
    }
    const opened = this.openInnerDelegation(
      delegation,
      dispatched.target,
      dispatched.to,
      dispatched.argument,
      SUBSCRIBER_CALL,
      dispatched.generics,
    );
    if (opened === null) {
      this.complete({
        delegation,
        outcome: { kind: "error", message: "webhook.inbound: the call cannot accept work" },
      });
    }
  }

  /** A settled inner delegation. The subscriber's outcome IS the call's outcome — feed it back as the
   *  transport completion (a fresh turn; values lower to the completion's wire Json and decode back at the
   *  base, `reveal` so content survives the internal round-trip). A delivery's outcome resolves its waiting
   *  HTTP request; a waiter lost to a restart just drops it (the provider's retry redelivers). */
  protected override deliverInnerOutcome(delivery: InnerDelivery): void {
    if (delivery.call === SUBSCRIBER_CALL) {
      this.schedule(() =>
        this.complete({
          delegation: delivery.delegation,
          outcome: innerOutcomeAsCompletion(delivery.outcome),
        }),
      );
      return;
    }
    const waiter = this.waiters.get(delivery.call);
    if (waiter === undefined) return;
    this.waiters.delete(delivery.call);
    switch (delivery.outcome.kind) {
      case "result":
        waiter({ kind: "result", value: delivery.outcome.value });
        return;
      case "error":
        waiter({ kind: "error", message: delivery.outcome.message });
        return;
      case "cancelled":
        waiter({ kind: "gone" });
        return;
    }
  }

  /** Reactivation: re-register the reloaded endpoint. Nothing to reconcile beyond that — the subscriber's
   *  inner delegation is durable core work resuming on its own, so the endpoint survives the restart. */
  protected recover(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload !== undefined) this.tokens.set(payload.token, delegation);
  }

  /** A cancel's transport half: deactivate the endpoint and confirm on a fresh turn (the children — the
   *  subscriber, in-flight deliveries — drain through the base's cancel cascade). */
  protected abort(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload !== undefined) this.tokens.delete(payload.token);
    this.schedule(() => this.complete({ delegation, outcome: { kind: "cancelled" } }));
  }

  /** The call resolved: release its token (the drop hook covers every resolution path at once). */
  protected override onDropCall(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload !== undefined) this.tokens.delete(payload.token);
  }

  protected encodeCallExtension(row: CallRow<WebhookPayload>): Json {
    return encodeWebhookExtension({
      snapshotId: row.payload.snapshot,
      token: row.payload.token,
      callback: row.payload.callback,
      relays: row.relays,
      innerCalls: row.innerCalls,
    });
  }

  protected decodeCallExtension(extension: Json): DecodedCallExtension<WebhookPayload> {
    const decoded = decodeWebhookExtension(extension);
    return {
      payload: {
        token: decoded.token,
        snapshot: decoded.snapshotId,
        callback: decoded.callback,
        // The subscriber was dispatched exactly once at the original open; never re-dispatched.
        subscriber: null,
      },
      relays: decoded.relays,
      innerCalls: decoded.innerCalls,
    };
  }

  /** The minted URL token — the base commits its `capability_routes` row alongside the call row, so a
   *  cold `POST /inbound/<token>` resolves this project before any actor is warm. */
  protected override capabilityTokenOf(payload: WebhookPayload): string {
    return payload.token;
  }

  override reset(): void {
    super.reset();
    this.tokens.clear();
    // Waiters are in-process HTTP requests; a reset (poisoned commit) makes their deliveries unresolvable.
    for (const waiter of this.waiters.values()) waiter({ kind: "gone" });
    this.waiters.clear();
  }
}
