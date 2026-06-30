// The http transport: the outbound side of the built-in `http.fetch` effect — an in-runtime `fetch` (no
// sidecar). A `fetch` request bubbles unhandled to the run's api root, which `dispatch`es it here and keeps
// the escalation open; a later `HttpCompletion` (delivered to the registered sink, which feeds the api
// root's `completeFetch`) answers the escalation with the `{ status, body }` response.
//
// `dispatch` is fire-and-forget: the outcome is asynchronous and arrives via the sink. The in-flight call is
// durable as the run-root escalation row (the api root performs it), so recovery knows it existed. There is
// no safe re-send (an http request is not idempotent / dedup-able), so a recovery re-dispatch does NOT fetch
// — it reports an `error` straight away, and the run fails (at-most-once). The correlation `id` is opaque to
// the transport (the api root keys it by the fetch's escalation id).

import type { Json } from "@katari-lang/types";

/** One http request to perform. `id` is the caller's opaque correlation key (the fetch's escalation id);
 *  `argument` is the request as plain Json — `{ url, method, headers, body }`, with any secret header value
 *  already revealed at the boundary. */
export interface HttpCall {
  id: string;
  argument: Json | null;
  /** True when this is a recovery re-dispatch of a call that was in flight when the process went down. The
   *  transport must NOT re-send it (at-most-once) — it reports an `error` so the call fails deterministically. */
  redispatch?: boolean;
}

/** The outcome of one dispatched http call, fed back to the api root: a `result` (any HTTP response —
 *  `{ status, body }`, 2xx or not — → the escalation's answer), an `error` (the request produced no response:
 *  DNS / connection / timeout / a recovery re-dispatch → the run fails), or a `cancelled` confirmation (after
 *  an `abort`). A late completion for an aborted call is harmless — the caller ignores an unknown `id`. */
export interface HttpCompletion {
  id: string;
  outcome:
    | { kind: "result"; value: Json }
    | { kind: "error"; message: string }
    | { kind: "cancelled" };
}

export interface HttpTransport {
  /** Register the sink completions are delivered through (called once at wiring). */
  onComplete(sink: (completion: HttpCompletion) => void): void;
  /** Perform one request (fire-and-forget; the outcome arrives via the sink). */
  dispatch(call: HttpCall): void;
  /** Abort an in-flight request; its `cancelled` (or a racing real) completion confirms the teardown. */
  abort(id: string): void;
}

/** The seam default: no http client configured, so dispatching one is an error. The facade swaps in the
 *  real `FetchHttpTransport`; a test injects an in-process stub. */
export class StubHttpTransport implements HttpTransport {
  onComplete(): void {}
  dispatch(call: HttpCall): void {
    throw new Error(`http transport not configured (call ${call.id})`);
  }
  abort(): void {}
}

/** The methods that carry no request body — sending one to `fetch` for them throws. */
const BODYLESS_METHODS = new Set(["GET", "HEAD"]);

/** The production transport: an in-runtime `fetch`. The result (any HTTP response) or an error (no response)
 *  is delivered to the sink off the dispatching turn. */
export class FetchHttpTransport implements HttpTransport {
  private sink: ((completion: HttpCompletion) => void) | null = null;
  private readonly controllers = new Map<string, AbortController>();

  onComplete(sink: (completion: HttpCompletion) => void): void {
    this.sink = sink;
  }

  dispatch(call: HttpCall): void {
    // A recovery re-dispatch must not re-send: report an error so the call fails at-most-once.
    if (call.redispatch === true) {
      this.emit({
        id: call.id,
        outcome: { kind: "error", message: "http request interrupted by a runtime restart" },
      });
      return;
    }
    const controller = new AbortController();
    this.controllers.set(call.id, controller);
    void this.perform(call, controller.signal)
      .then((outcome) => this.emit({ id: call.id, outcome }))
      .finally(() => this.controllers.delete(call.id));
  }

  abort(id: string): void {
    this.controllers.get(id)?.abort();
  }

  private emit(completion: HttpCompletion): void {
    this.sink?.(completion);
  }

  /** Perform the request, mapping any response to a `result` and a non-completing request to an `error`. */
  private async perform(call: HttpCall, signal: AbortSignal): Promise<HttpCompletion["outcome"]> {
    const request = parseRequest(call.argument);
    try {
      const headers = new Headers(request.headers);
      const init: RequestInit = { method: request.method, headers, signal };
      // A body-less method must not carry a body; otherwise send it only when non-empty.
      if (!BODYLESS_METHODS.has(request.method.toUpperCase()) && request.body !== "") {
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
