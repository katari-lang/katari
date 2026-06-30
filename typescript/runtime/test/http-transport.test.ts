// The FetchHttpTransport: the in-runtime `fetch` behind the built-in `http.fetch` effect. Any HTTP response
// (2xx or not) maps to a `result`; a request that never completes maps to an `error` (→ the run fails); a
// recovery re-dispatch maps to an `error` WITHOUT fetching (at-most-once — an http request is never re-sent).

import { afterEach, describe, expect, test, vi } from "vitest";
import {
  FetchHttpTransport,
  type HttpCall,
  type HttpCompletion,
} from "../src/runtime/external/http-transport.js";

const CALL_ID = "fetch-call-1";

afterEach(() => vi.restoreAllMocks());

/** Dispatch a call and resolve with its single completion (the result arrives asynchronously via the sink). */
function dispatchAndWait(transport: FetchHttpTransport, call: HttpCall): Promise<HttpCompletion> {
  return new Promise((resolve) => {
    transport.onComplete(resolve);
    transport.dispatch(call);
  });
}

function call(argument: Record<string, unknown>, redispatch = false): HttpCall {
  return { id: CALL_ID, argument: argument as HttpCall["argument"], redispatch };
}

describe("FetchHttpTransport", () => {
  test("any response (incl. non-2xx) maps to a result { status, body }", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("server error", { status: 500 })),
    );
    const completion = await dispatchAndWait(
      new FetchHttpTransport(),
      call({ url: "https://x", method: "GET", headers: {}, body: "" }),
    );
    expect(completion.outcome).toEqual({ kind: "result", value: { status: 500, body: "server error" } });
  });

  test("a secret header and the body are sent; a GET carries no body", async () => {
    const fetchMock = vi.fn<typeof fetch>(async () => new Response("ok", { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    await dispatchAndWait(
      new FetchHttpTransport(),
      call({
        url: "https://api/x",
        method: "POST",
        headers: { Authorization: "Bearer sk-secret" },
        body: "payload",
      }),
    );
    const post = fetchMock.mock.calls[0]?.[1];
    expect(post?.body).toBe("payload");
    expect(new Headers(post?.headers).get("Authorization")).toBe("Bearer sk-secret");

    fetchMock.mockClear();
    await dispatchAndWait(
      new FetchHttpTransport(),
      call({ url: "https://api/x", method: "GET", headers: {}, body: "" }),
    );
    const get = fetchMock.mock.calls[0]?.[1];
    expect(get?.body).toBeUndefined();
  });

  test("a request that throws (no response) maps to an error", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new Error("getaddrinfo ENOTFOUND");
      }),
    );
    const completion = await dispatchAndWait(
      new FetchHttpTransport(),
      call({ url: "https://nope", method: "GET", headers: {}, body: "" }),
    );
    expect(completion.outcome.kind).toBe("error");
  });

  test("a recovery re-dispatch reports an error WITHOUT fetching (at-most-once)", async () => {
    const fetchMock = vi.fn(async () => new Response("ok", { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    const completion = await dispatchAndWait(
      new FetchHttpTransport(),
      call({ url: "https://x", method: "GET", headers: {}, body: "" }, true),
    );
    expect(completion.outcome.kind).toBe("error");
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
