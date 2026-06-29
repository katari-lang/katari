// The blob side channel client: a handler downloads a blob's bytes over HTTP to the runtime's file endpoint,
// addressed by the env the runtime hands a hosted sidecar (`KATARI_RUNTIME_URL` / `KATARI_PROJECT_ID`). Run
// outside such a sidecar (no env), a blob op throws a clear error rather than guessing an endpoint.

import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { downloadBlob, uploadBlob } from "../src/blob.js";

describe("downloadBlob (blob side channel)", () => {
  beforeEach(() => {
    process.env.KATARI_RUNTIME_URL = "http://127.0.0.1:9999";
    process.env.KATARI_PROJECT_ID = "proj-1";
  });
  afterEach(() => {
    delete process.env.KATARI_RUNTIME_URL;
    delete process.env.KATARI_PROJECT_ID;
    vi.unstubAllGlobals();
  });

  test("GETs the file endpoint by handle or bare id and returns the bytes", async () => {
    const bytes = new Uint8Array([1, 2, 3]);
    const urls: string[] = [];
    vi.stubGlobal("fetch", (url: string | URL) => {
      urls.push(String(url));
      return Promise.resolve(new Response(bytes));
    });

    const fromHandle = await downloadBlob({ $ref: "blob-1", size: 3, hash: "h" });
    const fromId = await downloadBlob("blob-2");

    expect(Array.from(fromHandle)).toEqual([1, 2, 3]);
    expect(Array.from(fromId)).toEqual([1, 2, 3]);
    expect(urls).toEqual([
      "http://127.0.0.1:9999/projects/proj-1/files/blob-1",
      "http://127.0.0.1:9999/projects/proj-1/files/blob-2",
    ]);
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
});

describe("uploadBlob (blob side channel)", () => {
  beforeEach(() => {
    process.env.KATARI_RUNTIME_URL = "http://127.0.0.1:9999";
    process.env.KATARI_PROJECT_ID = "proj-1";
  });
  afterEach(() => {
    delete process.env.KATARI_RUNTIME_URL;
    delete process.env.KATARI_PROJECT_ID;
    vi.unstubAllGlobals();
  });

  test("POSTs the bytes to the ffi blob endpoint and assembles the handle from the reply", async () => {
    const seen: { url: string; method?: string; contentType?: string; body: unknown }[] = [];
    vi.stubGlobal("fetch", (url: string | URL, init?: RequestInit) => {
      const headers = new Headers(init?.headers);
      seen.push({
        url: String(url),
        method: init?.method,
        contentType: headers.get("content-type") ?? undefined,
        body: init?.body,
      });
      return Promise.resolve(
        new Response(JSON.stringify({ ok: true, data: { id: "blob-9", hash: "abc", size: 3 } })),
      );
    });

    const bytes = new Uint8Array([7, 8, 9]);
    const handle = await uploadBlob("deleg-1", bytes, { contentType: "image/png" });

    expect(handle).toEqual({
      $ref: "blob-9",
      size: 3,
      hash: "abc",
      semanticKind: "file",
      contentType: "image/png",
    });
    expect(seen).toHaveLength(1);
    expect(seen[0]?.url).toBe("http://127.0.0.1:9999/projects/proj-1/ffi/deleg-1/blobs");
    expect(seen[0]?.method).toBe("POST");
    expect(seen[0]?.contentType).toBe("image/png");
    expect(seen[0]?.body).toBe(bytes);
  });

  test("throws on a non-ok response", async () => {
    vi.stubGlobal("fetch", () => Promise.resolve(new Response("no", { status: 500 })));
    await expect(uploadBlob("deleg-1", new Uint8Array([1]))).rejects.toThrow(/upload failed \(500/);
  });
});
