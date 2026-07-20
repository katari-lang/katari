// Unit tests for the real `FetchHttpTransport` (the production http seam) — the piece the reactor tests stub
// out. Covers request building (method / headers / body pass-through, GET carries no body, an explicit empty
// body IS sent), the response mapping (any status is a `result`, a throwing fetch is an `error`), and the two
// recovery-critical guarantees: a recovery NEVER re-sends (a surviving request is left alone, a gone one
// reports an error — at-most-once), and an
// abort with no live request synthesises a `cancelled` (so a recovered cancelling call can be confirmed).

import { afterEach, describe, expect, test, vi } from "vitest";
import {
  FetchHttpTransport,
  type HttpCall,
  type HttpCompletion,
} from "../src/runtime/external/http-transport.js";
import type { BlobId, DelegationId } from "../src/runtime/ids.js";

const DELEGATION = "http-delegation-1" as DelegationId;

/** A `fetch` stub that records its calls and returns a fixed response. */
function fetchStub(response: () => Promise<Response>) {
  return vi.fn((_input: string | URL | Request, _init?: RequestInit): Promise<Response> => response());
}

/** Dispatch one call and resolve with the completion the transport feeds back to its sink. */
function dispatchOnce(transport: FetchHttpTransport, call: HttpCall): Promise<HttpCompletion> {
  return new Promise((resolve) => {
    transport.onComplete(resolve);
    transport.dispatch(call);
  });
}

function requestCall(argument: HttpCall["argument"]): HttpCall {
  return { delegation: DELEGATION, argument, responseKind: "text" };
}

/** A `fetch_file` call: the response body is captured to a blob (through the wired producer) rather than
 *  read as text. */
function fileRequestCall(argument: HttpCall["argument"]): HttpCall {
  return { delegation: DELEGATION, argument, responseKind: "file" };
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("FetchHttpTransport", () => {
  test("performs a GET (no body) and maps any response to a { status, body } result", async () => {
    const fetchMock = fetchStub(() => Promise.resolve(new Response("pong", { status: 200 })));
    vi.stubGlobal("fetch", fetchMock);
    const transport = new FetchHttpTransport();

    const completion = await dispatchOnce(
      transport,
      requestCall({ url: "https://example.test/ping", method: "GET", headers: {}, body: "" }),
    );

    expect(completion.outcome).toEqual({
      kind: "result",
      value: {
        status: 200,
        headers: { "content-type": "text/plain;charset=UTF-8" },
        body: "pong",
      },
    });
    const init = fetchMock.mock.calls[0]?.[1];
    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://example.test/ping");
    expect(init?.method).toBe("GET");
    // A GET must not carry a request body.
    expect(init?.body).toBeUndefined();
  });

  test("sends the body and headers for a POST, including an explicit empty body", async () => {
    const fetchMock = fetchStub(() => Promise.resolve(new Response("", { status: 201 })));
    vi.stubGlobal("fetch", fetchMock);
    const transport = new FetchHttpTransport();

    await dispatchOnce(
      transport,
      requestCall({
        url: "https://example.test/items",
        method: "POST",
        headers: { authorization: "Bearer sk-123" },
        body: "payload",
      }),
    );
    const postInit = fetchMock.mock.calls[0]?.[1];
    expect(postInit?.body).toBe("payload");
    expect(new Headers(postInit?.headers).get("authorization")).toBe("Bearer sk-123");

    // A POST with a deliberately empty body still sends a body (Content-Length: 0), not a bodyless request.
    const emptyTransport = new FetchHttpTransport();
    await dispatchOnce(
      emptyTransport,
      requestCall({ url: "https://example.test/items", method: "POST", headers: {}, body: "" }),
    );
    expect(fetchMock.mock.calls[1]?.[1]?.body).toBe("");
  });

  test("a non-2xx response is a result, not an error", async () => {
    vi.stubGlobal(
      "fetch",
      fetchStub(() => Promise.resolve(new Response("nope", { status: 404 }))),
    );
    const transport = new FetchHttpTransport();

    const completion = await dispatchOnce(
      transport,
      requestCall({ url: "https://example.test/missing", method: "GET", headers: {}, body: "" }),
    );
    expect(completion.outcome).toEqual({
      kind: "result",
      value: {
        status: 404,
        headers: { "content-type": "text/plain;charset=UTF-8" },
        body: "nope",
      },
    });
  });

  test("a request that produces no response is an error", async () => {
    vi.stubGlobal(
      "fetch",
      fetchStub(() => Promise.reject(new Error("getaddrinfo ENOTFOUND"))),
    );
    const transport = new FetchHttpTransport();

    const completion = await dispatchOnce(
      transport,
      requestCall({ url: "https://nope.invalid/x", method: "GET", headers: {}, body: "" }),
    );
    expect(completion.outcome).toEqual({ kind: "error", message: "getaddrinfo ENOTFOUND" });
  });

  test("a malformed request argument is an error, not an unhandled rejection", async () => {
    vi.stubGlobal(
      "fetch",
      fetchStub(() => Promise.resolve(new Response("", { status: 200 }))),
    );
    const transport = new FetchHttpTransport();

    const completion = await dispatchOnce(transport, requestCall({ url: 42, method: "GET" }));
    expect(completion.outcome.kind).toBe("error");
  });

  test("recovering an unknown call reports an error WITHOUT re-sending the request (at-most-once)", async () => {
    const fetchMock = fetchStub(() => Promise.resolve(new Response("ok", { status: 200 })));
    vi.stubGlobal("fetch", fetchMock);
    const transport = new FetchHttpTransport();

    const completion = await new Promise<HttpCompletion>((resolve) => {
      transport.onComplete(resolve);
      transport.recover(DELEGATION);
    });
    expect(completion.outcome.kind).toBe("error");
    // The whole point: the interrupted request is never re-sent.
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test("recovering a request the transport still has in flight leaves it alone (a warm reset)", async () => {
    // A fetch that resolves only when the test releases it, so the request is verifiably in flight.
    let release: (response: Response) => void = () => {};
    const fetchMock = fetchStub(() => new Promise<Response>((resolve) => (release = resolve)));
    vi.stubGlobal("fetch", fetchMock);
    const transport = new FetchHttpTransport();

    const completions: HttpCompletion[] = [];
    transport.onComplete((completion) => completions.push(completion));
    transport.dispatch(
      requestCall({ url: "https://example.test/slow", method: "GET", headers: {}, body: "" }),
    );
    transport.recover(DELEGATION);
    // No error was synthesised — the surviving request is left to complete on its own.
    expect(completions).toHaveLength(0);
    release(new Response("late", { status: 200 }));
    await vi.waitFor(() => expect(completions).toHaveLength(1));
    expect(completions[0]?.outcome).toEqual({
      kind: "result",
      value: {
        status: 200,
        headers: { "content-type": "text/plain;charset=UTF-8" },
        body: "late",
      },
    });
  });

  test("aborting a call with no live request synthesises a cancelled confirmation", async () => {
    vi.stubGlobal(
      "fetch",
      fetchStub(() => Promise.resolve(new Response("", { status: 200 }))),
    );
    const transport = new FetchHttpTransport();

    // No dispatch preceded this abort (a recovery abort of a call whose request died with the process).
    const completion = await new Promise<HttpCompletion>((resolve) => {
      transport.onComplete(resolve);
      transport.abort(DELEGATION);
    });
    expect(completion).toEqual({ delegation: DELEGATION, outcome: { kind: "cancelled" } });
  });

  test("a fetch_file captures the response bytes into a file handle through the wired producer", async () => {
    // Arbitrary non-UTF-8 bytes, so a text read would corrupt them — the whole reason to capture to a blob.
    const bytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x00, 0xff]);
    vi.stubGlobal(
      "fetch",
      fetchStub(() =>
        Promise.resolve(new Response(bytes, { status: 200, headers: { "content-type": "image/png" } })),
      ),
    );
    const produced: { delegation: DelegationId; bytes: Uint8Array; contentType: string }[] = [];
    const transport = new FetchHttpTransport();
    transport.useBlobProducer(async (delegation, given, contentType) => {
      produced.push({ delegation, bytes: given, contentType });
      return "produced-blob-1" as BlobId;
    });

    const completion = await dispatchOnce(
      transport,
      fileRequestCall({ url: "https://example.test/logo.png", method: "GET", headers: {}, body: "" }),
    );

    // The producer received the raw response bytes and the response's Content-Type.
    expect(produced).toHaveLength(1);
    expect(produced[0]?.delegation).toBe(DELEGATION);
    expect(produced[0]?.bytes).toEqual(bytes);
    expect(produced[0]?.contentType).toBe("image/png");
    // The result carries the slim `$katari_ref` handle (the reactor's decode lifts it into a `file`), never
    // the bytes — the status / headers ride alongside so a caller branches on them like a `fetch`.
    expect(completion.outcome).toEqual({
      kind: "result",
      value: {
        status: 200,
        headers: { "content-type": "image/png" },
        file: { $katari_ref: "produced-blob-1", $katari_semantic_kind: "file" },
      },
    });
  });

  test("a fetch_file with no response Content-Type stores the octet-stream fallback", async () => {
    // A Response built from raw bytes carries no Content-Type, so the transport supplies the RFC 2046 default.
    vi.stubGlobal(
      "fetch",
      fetchStub(() => Promise.resolve(new Response(new Uint8Array([1, 2, 3]), { status: 200 }))),
    );
    let seenContentType: string | undefined;
    const transport = new FetchHttpTransport();
    transport.useBlobProducer(async (_delegation, _bytes, contentType) => {
      seenContentType = contentType;
      return "produced-blob-2" as BlobId;
    });

    await dispatchOnce(
      transport,
      fileRequestCall({ url: "https://example.test/blob", method: "GET", headers: {}, body: "" }),
    );
    expect(seenContentType).toBe("application/octet-stream");
  });

  test("a fetch_file whose call already vanished is an error (the producer dropped the bytes)", async () => {
    vi.stubGlobal(
      "fetch",
      fetchStub(() => Promise.resolve(new Response(new Uint8Array([1]), { status: 200 }))),
    );
    const transport = new FetchHttpTransport();
    // A `null` producer result models the owning call having resolved / been cancelled before the download.
    transport.useBlobProducer(async () => null);

    const completion = await dispatchOnce(
      transport,
      fileRequestCall({ url: "https://example.test/gone", method: "GET", headers: {}, body: "" }),
    );
    expect(completion.outcome.kind).toBe("error");
  });

  test("a fetch_file with no wired producer fails loudly (an error, not a silent empty result)", async () => {
    vi.stubGlobal(
      "fetch",
      fetchStub(() => Promise.resolve(new Response(new Uint8Array([1]), { status: 200 }))),
    );
    const transport = new FetchHttpTransport(); // no producer wired

    const completion = await dispatchOnce(
      transport,
      fileRequestCall({ url: "https://example.test/x", method: "GET", headers: {}, body: "" }),
    );
    expect(completion.outcome.kind).toBe("error");
    if (completion.outcome.kind === "error") {
      expect(completion.outcome.message).toMatch(/blob producer/);
    }
  });
});
