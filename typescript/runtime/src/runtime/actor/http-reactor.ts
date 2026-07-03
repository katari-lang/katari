// HttpReactor: the `http` reactor — a built-in HTTP client as a call reactor (see 'ExternalCallReactor' for
// the shared callee-call lifecycle). An `http.fetch` call reaches it as a `delegate` (an external leaf marked
// `reactor: "http"`) routed from core's `ExternalThread` proxy, exactly like an FFI call; it performs the
// request through its transport (an in-runtime `fetch`) and the base turns the outcome into the call's
// `delegateAck` (the `{ status, body }` response), an `escalate` (a request that produced no response → a
// `throw[http.fetch_error]` that bubbles to the caller's handler), or a `terminateAck` (an abort confirmed).
//
// It owns its in-flight calls durably as `http`-kind instances (`http_instances` — the call's status + caller),
// and on recovery it does NOT re-send (an http request is not idempotent): the transport's `recover` leaves a
// surviving request alone and reports an error for a gone one, so an interrupted running call fails like any
// other no-response. This at-most-once guarantee is the whole reason http is a reactor rather than a
// core-inline primitive.
//
// A no-response error (DNS failure, refused connection, timeout, restart interruption) is a *program-
// anticipatable* failure, so it escalates as `throw[http.fetch_error]` (the stdlib `prelude/http.ktr`
// declares the effect) — a caller handles it to control retry; unhandled, it fails the run with the payload.

import { errorData } from "../engine/throw-signal.js";
import type { ReactorName } from "../event/types.js";
import type { HttpTransport } from "../external/http-transport.js";
import type { DelegationId } from "../ids.js";
import { valueToJson } from "../value/codec.js";
import type { Value } from "../value/types.js";
import {
  type CallRow,
  ExternalCallReactor,
  type ExternalTarget,
  type LoadedCall,
} from "./external-call-reactor.js";
import type { Loader, PersistenceTx } from "./persistence.js";
import type { ResourcePool } from "./resource-pool.js";

/** The transport data an http call holds. The argument is kept only to dispatch the request; recovery never
 *  re-sends (at-most-once), so it is not persisted — a reloaded call carries `null`. */
interface HttpPayload {
  argument: Value | null;
}

export class HttpReactor extends ExternalCallReactor<HttpPayload> {
  readonly name: ReactorName = "http";

  constructor(
    private readonly transport: HttpTransport,
    pool: ResourcePool,
  ) {
    super(pool);
  }

  protected openPayload(_target: ExternalTarget, argument: Value | null): HttpPayload {
    return { argument };
  }

  protected dispatch(delegation: DelegationId, payload: HttpPayload): void {
    this.transport.dispatch({
      delegation,
      // Lower the engine's Value to plain Json for the request; a secret header value is revealed here (http
      // is an allowed sink — an API key flows to its request), unlike the user-facing API which redacts.
      argument: payload.argument === null ? null : valueToJson(payload.argument, "reveal"),
    });
  }

  protected recover(delegation: DelegationId): void {
    this.transport.recover(delegation);
  }

  /** An http no-response is program-anticipatable: escalate `throw[http.fetch_error]` (not a panic), so a
   *  caller's throw handler controls retry. */
  protected override escalateError(
    delegation: DelegationId,
    message: string,
    caller: ReactorName,
  ): void {
    this.raiseThrow(delegation, errorData(FETCH_ERROR, message), caller);
  }

  protected abort(delegation: DelegationId): void {
    this.transport.abort(delegation);
  }

  protected async persistCallRow(tx: PersistenceTx, row: CallRow<HttpPayload>): Promise<void> {
    // The inner-delegation bridges (`relays` / `innerCalls`) are not persisted: an http transport surfaces
    // no inner agent calls, so both are empty by construction.
    await tx.http.putHttpInstance({
      instanceId: row.instance,
      status: row.status,
    });
  }

  protected async loadCallRows(loader: Loader): Promise<Array<LoadedCall<HttpPayload>>> {
    return (await loader.http.instances()).map((row) => ({
      delegation: row.delegation,
      instance: row.instance,
      caller: row.caller,
      status: row.status,
      // The argument is not persisted (at-most-once recovery never re-sends), so a reloaded call has none.
      payload: { argument: null },
      relays: [],
      innerCalls: [],
    }));
  }
}

/** The domain error ctor an http no-response throws (`prelude/http.ktr` declares it). */
const FETCH_ERROR = "prelude.http.fetch_error";
