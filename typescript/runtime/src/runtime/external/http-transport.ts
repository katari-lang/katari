// The http transport: the `http` reactor's outbound side — an in-runtime `fetch` (no sidecar). An http call
// reaches the reactor as a `delegate` (an external leaf marked `reactor: "http"`); the reactor `dispatch`es
// it here and suspends, and a later `HttpCompletion` (delivered to the registered sink, which feeds the
// reactor's `complete`) resumes it.
//
// `dispatch` is fire-and-forget: the outcome is asynchronous and arrives via the sink. The in-flight call is
// durable as the reactor's `http_instances` row, so recovery knows it existed. There is no safe re-send (an
// http request is not idempotent / dedup-able), so a recovery re-dispatch does NOT fetch — it reports an
// `error` straight away (a mid-flight restart is a failure), which the reactor turns into a `panic` the
// caller can handle locally. This at-most-once guarantee is why http is a reactor, not a core-inline prim.

import type { Json } from "@katari-lang/types";
import type { DelegationId } from "../ids.js";

/** One http request to perform. `argument` is the call's argument as plain Json — `{ url, method, headers,
 *  body }`, with any secret header value already revealed at the reactor boundary. */
export interface HttpCall {
  delegation: DelegationId;
  argument: Json | null;
  /** True when this is a recovery re-dispatch of a call that was in flight when the process went down. The
   *  transport must NOT re-send it (at-most-once) — it reports an `error` so the call fails deterministically. */
  redispatch?: boolean;
}

/** The outcome of one dispatched http call, fed back to the reactor: a `result` (any HTTP response —
 *  `{ status, body }`, 2xx or not — → a delegateAck), an `error` (the request produced no response: DNS /
 *  connection / timeout / a recovery re-dispatch → a panic the reactor escalates), or a `cancelled`
 *  confirmation (→ terminateAck, after an `abort`). A late completion for an aborted call is harmless. */
export interface HttpCompletion {
  delegation: DelegationId;
  outcome:
    | { kind: "result"; value: Json }
    | { kind: "error"; message: string }
    | { kind: "cancelled" };
}

export interface HttpTransport {
  /** Register the sink the reactor consumes completions through (called once at wiring). */
  onComplete(sink: (completion: HttpCompletion) => void): void;
  /** Perform one request (fire-and-forget; the outcome arrives via the sink). */
  dispatch(call: HttpCall): void;
  /** Abort an in-flight request; its `cancelled` (or a racing real) completion confirms the teardown. */
  abort(delegation: DelegationId): void;
}

/** The seam default: no http client configured, so dispatching one is an error (fails loudly, like the FFI
 *  stub — so a test that does http by accident is caught rather than hitting the real network). */
export class StubHttpTransport implements HttpTransport {
  onComplete(): void {}
  dispatch(call: HttpCall): void {
    throw new Error(`http transport not configured (call ${call.delegation})`);
  }
  abort(): void {}
}

/** The methods that carry no request body — sending one to `fetch` for them throws. */
const BODYLESS_METHODS = new Set(["GET", "HEAD"]);

/** The production transport: an in-runtime `fetch`. The result (any HTTP response) or an error (no response)
 *  is delivered to the sink off the dispatching turn. */
export class FetchHttpTransport implements HttpTransport {
  private sink: ((completion: HttpCompletion) => void) | null = null;
  private readonly controllers = new Map<DelegationId, AbortController>();

  onComplete(sink: (completion: HttpCompletion) => void): void {
    this.sink = sink;
  }

  dispatch(call: HttpCall): void {
    // A recovery re-dispatch must not re-send: report an error so the call fails at-most-once.
    if (call.redispatch === true) {
      this.emit({
        delegation: call.delegation,
        outcome: { kind: "error", message: "http request interrupted by a runtime restart" },
      });
      return;
    }
    const controller = new AbortController();
    this.controllers.set(call.delegation, controller);
    void this.perform(call, controller.signal)
      .then((outcome) => this.emit({ delegation: call.delegation, outcome }))
      .finally(() => this.controllers.delete(call.delegation));
  }

  abort(delegation: DelegationId): void {
    const controller = this.controllers.get(delegation);
    if (controller !== undefined) {
      // An in-flight request: aborting the signal makes `perform` throw AbortError → a `cancelled` outcome.
      controller.abort();
      return;
    }
    // No live request to abort — the request already finished, or this is a recovery abort of a call whose
    // request died with the process. Confirm the teardown straight away so the reactor can `terminateAck`.
    // (Harmless if a real completion also lands: the reactor drops the call on the first, ignores the rest.)
    this.emit({ delegation, outcome: { kind: "cancelled" } });
  }

  private emit(completion: HttpCompletion): void {
    this.sink?.(completion);
  }

  /** Perform the request, mapping any response to a `result` and a non-completing request to an `error`. The
   *  argument parse is inside the try so a malformed request is an `error` outcome, not an unhandled rejection. */
  private async perform(call: HttpCall, signal: AbortSignal): Promise<HttpCompletion["outcome"]> {
    try {
      const request = parseRequest(call.argument);
      const headers = new Headers(request.headers);
      const init: RequestInit = { method: request.method, headers, signal };
      // A body-less method (GET / HEAD) must not carry a body; every other method sends exactly the `body`
      // string the program supplied — including an explicit empty body (Content-Length: 0), which some APIs
      // distinguish from a bodyless request.
      if (!BODYLESS_METHODS.has(request.method.toUpperCase())) {
        init.body = request.body;
      }
      const response = await fetch(request.url, init);
      const body = await response.text();
      return { kind: "result", value: { status: response.status, body } };
    } catch (error) {
      if (error instanceof Error && error.name === "AbortError") {
        return { kind: "cancelled" };
      }
      return { kind: "error", message: error instanceof Error ? error.message : String(error) };
    }
  }
}

interface ParsedRequest {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: string;
}

/** Read the `{ url, method, headers, body }` shape `http.fetch` lowers its argument to out of plain Json. */
function parseRequest(argument: Json | null): ParsedRequest {
  if (argument === null || typeof argument !== "object" || Array.isArray(argument)) {
    throw new Error("http.fetch: argument is not a request object");
  }
  const url = stringField(argument, "url");
  const method = stringField(argument, "method");
  const body = stringField(argument, "body");
  const headers: Record<string, string> = {};
  const rawHeaders = argument.headers;
  if (
    rawHeaders !== undefined &&
    rawHeaders !== null &&
    typeof rawHeaders === "object" &&
    !Array.isArray(rawHeaders)
  ) {
    for (const [name, value] of Object.entries(rawHeaders)) {
      if (typeof value === "string") headers[name] = value;
    }
  }
  return { url, method, headers, body };
}

function stringField(object: { [key: string]: Json | undefined }, name: string): string {
  const value = object[name];
  if (typeof value !== "string") {
    throw new Error(`http.fetch: "${name}" must be a string`);
  }
  return value;
}
