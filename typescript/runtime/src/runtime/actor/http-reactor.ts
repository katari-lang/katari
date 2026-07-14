// HttpReactor: the `http` reactor — a built-in HTTP client as a call reactor (see 'ExternalCallReactor' for
// the shared callee-call lifecycle). An `http.fetch` call reaches it as a `delegate` (an external leaf marked
// `reactor: "http"`) routed from core's `ExternalThread` proxy, exactly like an FFI call; it performs the
// request through its transport (an in-runtime `fetch`) and the base turns the outcome into the call's
// `delegateAck` (the `{ status, headers, body }` response), an `escalate` (a request that produced no response → a
// `throw[http.fetch_error]` that bubbles to the caller's handler), or a `terminateAck` (an abort confirmed).
//
// It owns its in-flight calls durably as `http`-kind instances (an external-call row carrying only the
// status — the extension document is empty), and on recovery it does NOT re-send (an http request is not
// idempotent): the transport's `recover` leaves a surviving request alone and reports an error for a gone
// one, so an interrupted running call fails like any other no-response. This at-most-once guarantee is the
// whole reason http is a reactor rather than a core-inline primitive.
//
// A no-response error (DNS failure, refused connection, timeout, restart interruption) is a *program-
// anticipatable* failure, so it escalates as `throw[http.fetch_error]` (the stdlib `prelude/http.ktr`
// declares the effect) — a caller handles it to control retry; unhandled, it fails the run with the payload.

import type { Json } from "@katari-lang/types";
import { errorData } from "../engine/throw-signal.js";
import type { ReactorName } from "../event/types.js";
import type { HttpTransport } from "../external/http-transport.js";
import type { DelegationId, InstanceId } from "../ids.js";
import { valueToJson } from "../value/codec.js";
import type { Value } from "../value/types.js";
import {
  type CallRow,
  type DecodedCallExtension,
  ExternalCallReactor,
  type ExternalTarget,
} from "./external-call-reactor.js";
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
      // Lower the engine's Value to plain Json for the request. This is THE single transport boundary the
      // stdlib rule names: a secret submission surface — a header value OR the body — is revealed here (http
      // is an allowed sink toward the destination server: an API key flows to its auth header, an OAuth
      // `refresh_token` to its form body), unlike the user-facing API which redacts. The `url` carries no
      // secret (the type system forbids a private URL), so revealing the whole argument reveals only what
      // was deliberately submitted.
      argument: payload.argument === null ? null : valueToJson(payload.argument, "reveal"),
    });
  }

  protected recover(delegation: DelegationId): void {
    this.transport.recover(delegation);
  }

  /** An http no-response is program-anticipatable: escalate `throw[http.fetch_error]` (not a panic), so a
   *  caller's throw handler controls retry. `raiser` (this http call's instance) owns the durable row. */
  protected override escalateError(
    delegation: DelegationId,
    message: string,
    caller: ReactorName,
    run: InstanceId,
    raiser: InstanceId,
  ): void {
    this.raiseThrow(delegation, errorData(FETCH_ERROR, message), caller, run, raiser);
  }

  protected abort(delegation: DelegationId): void {
    this.transport.abort(delegation);
  }

  /** The empty extension document: an http call's only kind-specific durable datum is its status (a row
   *  column). No request (at-most-once recovery never re-sends), and no inner-delegation bridges — an
   *  http transport surfaces no inner agent calls, so the fields do not exist rather than sit nullable. */
  protected encodeCallExtension(_row: CallRow<HttpPayload>): Json {
    return {};
  }

  protected decodeCallExtension(_extension: Json): DecodedCallExtension<HttpPayload> {
    // The argument is not persisted (at-most-once recovery never re-sends), so a reloaded call has none.
    return { payload: { argument: null }, relays: [], innerCalls: [] };
  }
}

/** The domain error ctor an http no-response throws (`prelude/http.ktr` declares it). */
const FETCH_ERROR = "prelude.http.fetch_error";
