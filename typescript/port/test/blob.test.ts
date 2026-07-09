// The blob side channel client: a handler downloads a blob's bytes over HTTP to the runtime's file endpoint,
// addressed by the env the runtime hands a hosted sidecar (`KATARI_RUNTIME_URL` / `KATARI_PROJECT_ID` /
// `KATARI_API_KEY`). The blob routes are under the runtime's authenticated `/api`, so every call carries the
// bearer. Run outside such a sidecar (missing env), a blob op throws a clear error rather than guessing.

import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { downloadBlob, uploadBlob } from "../src/blob.js";

describe("downloadBlob (blob side channel)", () => {
  beforeEach(() => {
    process.env.KATARI_RUNTIME_URL = "http://127.0.0.1:9999";
    process.env.KATARI_PROJECT_ID = "proj-1";
    process.env.KATARI_API_KEY = "test-key";
  });
  afterEach(() => {
    delete process.env.KATARI_RUNTIME_URL;
    delete process.env.KATARI_PROJECT_ID;
    delete process.env.KATARI_API_KEY;
    vi.unstubAllGlobals();
  });

  test("GETs the file endpoint by handle or bare id, with the bearer, and returns the bytes", async () => {
    const bytes = new Uint8Array([1, 2, 3]);
    const urls: string[] = [];
    const auths: (string | null)[] = [];
    vi.stubGlobal("fetch", (url: string | URL, init?: RequestInit) => {
      urls.push(String(url));
      auths.push(new Headers(init?.headers).get("authorization"));
      return Promise.resolve(new Response(bytes));
    });

    const fromHandle = await downloadBlob({ $ref: "blob-1" });
    const fromId = await downloadBlob("blob-2");

    expect(Array.from(fromHandle.bytes)).toEqual([1, 2, 3]);
    expect(fromHandle.size).toBe(3);
    expect(Array.from(fromId.bytes)).toEqual([1, 2, 3]);
    expect(urls).toEqual([
      "http://127.0.0.1:9999/projects/proj-1/files/blob-1",
      "http://127.0.0.1:9999/projects/proj-1/files/blob-2",
    ]);
    expect(auths).toEqual(["Bearer test-key", "Bearer test-key"]);
  });

  test("surfaces the served Content-Type verbatim, and its absence as absence", async () => {
    const bytes = new Uint8Array([1]);
    vi.stubGlobal("fetch", (url: string | URL) =>
      Promise.resolve(
        String(url).endsWith("/recorded")
          ? // The runtime sends the header only when the blob row records a type — even the generic
            // octet-stream is a genuine recording, not a sentinel to strip.
            new Response(bytes, { headers: { "content-type": "application/octet-stream" } })
          : new Response(bytes),
      ),
    );

    const recorded = await downloadBlob("recorded");
    const unrecorded = await downloadBlob("unrecorded");

    expect(recorded.contentType).toBe("application/octet-stream");
    expect(unrecorded.contentType).toBeUndefined();
  });

  test("throws on a non-ok response", async () => {
    vi.stubGlobal("fetch", () =>
      Promise.resolve(new Response("nope", { status: 404, statusText: "Not Found" })),
    );
    await expect(downloadBlob("missing")).rejects.toThrow(/download failed \(404/);
  });

  test("throws when run outside a runtime-hosted sidecar (env unset)", async () => {
    delete process.env.KATARI_RUNTIME_URL;
    await expect(downloadBlob("blob-1")).rejects.toThrow(/runtime-hosted sidecar/);
  });

  test("throws when the bearer token is unset (a blob op cannot authenticate)", async () => {
    delete process.env.KATARI_API_KEY;
    await expect(downloadBlob("blob-1")).rejects.toThrow(/runtime-hosted sidecar/);
  });
});

describe("uploadBlob (blob side channel)", () => {
  beforeEach(() => {
    process.env.KATARI_RUNTIME_URL = "http://127.0.0.1:9999";
    process.env.KATARI_PROJECT_ID = "proj-1";
    process.env.KATARI_API_KEY = "test-key";
  });
  afterEach(() => {
    delete process.env.KATARI_RUNTIME_URL;
    delete process.env.KATARI_PROJECT_ID;
    delete process.env.KATARI_API_KEY;
    vi.unstubAllGlobals();
  });

  test("POSTs the bytes to the ffi blob endpoint, with the bearer, and assembles the handle", async () => {
    const seen: {
      url: string;
      method?: string;
      contentType?: string;
      authorization?: string;
      body: unknown;
    }[] = [];
    vi.stubGlobal("fetch", (url: string | URL, init?: RequestInit) => {
      const headers = new Headers(init?.headers);
      seen.push({
        url: String(url),
        method: init?.method,
        contentType: headers.get("content-type") ?? undefined,
        authorization: headers.get("authorization") ?? undefined,
        body: init?.body,
      });
      return Promise.resolve(
        new Response(JSON.stringify({ ok: true, data: { id: "blob-9", hash: "abc", size: 3 } })),
      );
    });

    const bytes = new Uint8Array([7, 8, 9]);
    const handle = await uploadBlob("deleg-1", bytes, { contentType: "image/png" });

    // The slim handle: identity only (the metadata just registered lives on the blob's runtime row).
    expect(handle).toEqual({ $ref: "blob-9", semanticKind: "file" });
    expect(seen).toHaveLength(1);
    expect(seen[0]?.url).toBe("http://127.0.0.1:9999/projects/proj-1/ffi/deleg-1/blobs");
    expect(seen[0]?.method).toBe("POST");
    expect(seen[0]?.contentType).toBe("image/png");
    expect(seen[0]?.authorization).toBe("Bearer test-key");
    expect(seen[0]?.body).toBe(bytes);
  });

  test("throws on a non-ok response", async () => {
    vi.stubGlobal("fetch", () => Promise.resolve(new Response("no", { status: 500 })));
    await expect(uploadBlob("deleg-1", new Uint8Array([1]))).rejects.toThrow(/upload failed \(500/);
  });

  test("throws a clear shape error when the reply omits size (rather than a NaN-size handle)", async () => {
    vi.stubGlobal("fetch", () =>
      Promise.resolve(new Response(JSON.stringify({ ok: true, data: { id: "blob-9", hash: "abc" } }))),
    );
    await expect(uploadBlob("deleg-1", new Uint8Array([1]))).rejects.toThrow(
      /unexpected response shape/,
    );
  });

  test("throws a clear shape error on a non-JSON 2xx body (not a raw SyntaxError)", async () => {
    vi.stubGlobal("fetch", () => Promise.resolve(new Response("not json", { status: 201 })));
    await expect(uploadBlob("deleg-1", new Uint8Array([1]))).rejects.toThrow(
      /unexpected response shape/,
    );
  });
});
