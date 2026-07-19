// The http transport: the `http` reactor's outbound side — an in-runtime `fetch` (no sidecar). An http call
// reaches the reactor as a `delegate` (an external leaf marked `reactor: "http"`); the reactor `dispatch`es
// it here and suspends, and a later `HttpCompletion` (delivered to the registered sink, which feeds the
// reactor's `complete`) resumes it.
//
// `dispatch` is fire-and-forget: the outcome is asynchronous and arrives via the sink. The in-flight call is
// durable as the reactor's external-call row, so recovery knows it existed. There is no safe re-send (an
// http request is not idempotent / dedup-able), so `recover` never fetches: a request this transport still
// holds is left to complete (a warm reset), a gone one reports an `error` straight away (a mid-flight
// restart is a failure), which the reactor turns into a `panic` the caller can handle locally. This
// at-most-once guarantee is why http is a reactor, not a core-inline prim.

import type { Json } from "@katari-lang/types";
import type { DelegationId } from "../ids.js";
import { type HttpBlobResolver, materializeBody } from "./http-body.js";

/** One http request to perform. `argument` is the call's argument as plain Json — `{ url, method, headers,
 *  body }`, with any secret header value or secret body already revealed at the reactor boundary (the
 *  submission surfaces toward the destination server; the `url` is public by type). */
export interface HttpCall {
  delegation: DelegationId;
  argument: Json | null;
}

/** The outcome of one dispatched http call, fed back to the reactor: a `result` (any HTTP response —
 *  `{ status, headers, body }`, 2xx or not — → a delegateAck), an `error` (the request produced no response: DNS /
 *  connection / timeout / a refused recovery → a panic the reactor escalates), or a `cancelled`
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
  /** Wire the resolver the transport materialises a `file` request body through — it reads a blob's bytes +
   *  content type from the project's blob store at SEND time (so the value plane / DB / trace only ever hold
   *  the handle). Called once at wiring, like `onComplete`; a transport that never sends a real request (the
   *  stub) or records handles without materialising (a test double) ignores it. */
  useBlobResolver(resolve: HttpBlobResolver): void;
  /** Perform one request — always means "send it" (fire-and-forget; the outcome arrives via the sink). */
  dispatch(call: HttpCall): void;
  /** Reconcile a reloaded in-flight call (at-most-once; never re-sends): a request this transport still has
   *  running is left alone — its completion will come (a warm reset); one whose process is gone reports an
   *  `error`, so the caller decides whether to retry. */
  recover(delegation: DelegationId): void;
  /** Abort an in-flight request; its `cancelled` (or a racing real) completion confirms the teardown. */
  abort(delegation: DelegationId): void;
  /** Tear the transport down (host cleanup on actor disposal — the project was deleted): abort every
   *  in-flight request and deliver nothing after. */
  close(): void;
}

/** The seam default: no http client configured, so dispatching one is an error (fails loudly, like the FFI
 *  stub — so a test that does http by accident is caught rather than hitting the real network). */
export class StubHttpTransport implements HttpTransport {
  onComplete(): void {}
  useBlobResolver(): void {}
  dispatch(call: HttpCall): void {
    throw new Error(`http transport not configured (call ${call.delegation})`);
  }
  recover(delegation: DelegationId): void {
    throw new Error(`http transport not configured (recovering call ${delegation})`);
  }
  abort(): void {}
  close(): void {}
}

/** The methods that carry no request body — sending one to `fetch` for them throws. */
const BODYLESS_METHODS = new Set(["GET", "HEAD"]);

/** The production transport: an in-runtime `fetch`. The result (any HTTP response) or an error (no response)
 *  is delivered to the sink off the dispatching turn. */
export class FetchHttpTransport implements HttpTransport {
  private sink: ((completion: HttpCompletion) => void) | null = null;
  private readonly controllers = new Map<DelegationId, AbortController>();
  /** The blob resolver a `file` body materialises through, wired by the actor. `null` until wired — a bare
   *  transport (a test that sends no file body) never needs it; a file body then fails loudly. It may also
   *  be supplied at construction, for a standalone transport. */
  private resolve: HttpBlobResolver | null;

  constructor(resolve: HttpBlobResolver | null = null) {
    this.resolve = resolve;
  }

  onComplete(sink: (completion: HttpCompletion) => void): void {
    this.sink = sink;
  }

  useBlobResolver(resolve: HttpBlobResolver): void {
    this.resolve = resolve;
  }

  dispatch(call: HttpCall): void {
    const controller = new AbortController();
    this.controllers.set(call.delegation, controller);
    void this.perform(call, controller.signal)
      .then((outcome) => this.emit({ delegation: call.delegation, outcome }))
      .finally(() => this.controllers.delete(call.delegation));
  }

  recover(delegation: DelegationId): void {
    // Never re-send (at-most-once). A request this transport still has in flight survived a warm reset —
    // leave it alone, its completion will come; one it does not know is gone with its process — report an
    // error so the call fails deterministically.
    if (!this.controllers.has(delegation)) {
      this.emit({
        delegation,
        outcome: { kind: "error", message: "http request interrupted by a runtime restart" },
      });
    }
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

  close(): void {
    // Abort whatever is still in flight and unhook the sink, so a late completion delivers nowhere.
    for (const controller of this.controllers.values()) controller.abort();
    this.controllers.clear();
    this.sink = null;
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
      // A body-less method (GET / HEAD) must not carry a body; every other method materialises the request
      // body sum HERE, at the send boundary — a `file` leaf's bytes are read from the blob store now, never
      // earlier, so the value plane / DB / trace only ever held the handle. An explicit empty text body
      // (Content-Length: 0) still goes out, which some APIs distinguish from a bodyless request.
      if (!BODYLESS_METHODS.has(request.method.toUpperCase())) {
        const materialised = await materializeBody(request.body, this.resolve);
        if (materialised.body !== undefined) init.body = materialised.body;
        const contentType = materialised.contentType;
        // The body's implied Content-Type: multipart's (with its boundary) overrides a caller header;
        // binary / json apply only as a default, so a caller's own Content-Type wins.
        if (
          contentType !== undefined &&
          (contentType.authoritative || !headers.has("content-type"))
        ) {
          headers.set("content-type", contentType.value);
        }
      }
      const response = await fetch(request.url, init);
      const body = await response.text();
      // Response headers ride along (names lowercased by the platform; repeated headers arrive joined
      // with ", ") — how a program reads a session token, a rate-limit hint, a redirect location.
      const responseHeaders: { [name: string]: Json } = {};
      response.headers.forEach((value, name) => {
        responseHeaders[name] = value;
      });
      return {
        kind: "result",
        value: { status: response.status, headers: responseHeaders, body },
      };
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
  /** The raw `body` argument — a body sum (a `{ $katari_constructor, $katari_value }` data value) or a bare string; the
   *  transport materialises it at send time (`materializeBody`). Metadata (a file's bytes) is NOT here. */
  body: Json | undefined;
}

/** Read the `{ url, method, headers, body }` shape `http.fetch` lowers its argument to out of plain Json.
 *  `body` is kept as raw Json (the request-body sum) — materialised at the send boundary, not here. */
function parseRequest(argument: Json | null): ParsedRequest {
  if (argument === null || typeof argument !== "object" || Array.isArray(argument)) {
    throw new Error("http.fetch: argument is not a request object");
  }
  const url = stringField(argument, "url");
  const method = stringField(argument, "method");
  const body = argument.body ?? undefined;
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
