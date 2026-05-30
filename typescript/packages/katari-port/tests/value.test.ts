// katari.value consume client tests. A stub `FetchLike` records calls so we
// can assert the data-plane URL / auth header without a real server, plus the
// inline fast-paths that need no protocol config at all.

import { describe, expect, it } from "vitest";
import { createValueClient, type FetchLike } from "../src/value.js";

const ENV = {
  KATARI_PROTOCOL_URL: "http://host:9000",
  KATARI_PROTOCOL_TOKEN: "tok-123",
  KATARI_PROJECT_ID: "proj-1",
};

type Call = {
  url: string;
  method?: string;
  headers?: Record<string, string>;
  body?: Uint8Array | string;
};

function stubFetch(body: string, status = 200): { fetchImpl: FetchLike; calls: Call[] } {
  const calls: Call[] = [];
  const fetchImpl: FetchLike = async (url, init) => {
    calls.push({ url, method: init?.method, headers: init?.headers, body: init?.body });
    return {
      ok: status >= 200 && status < 300,
      status,
      arrayBuffer: async () => new TextEncoder().encode(body).buffer as ArrayBuffer,
      text: async () => body,
      json: async () => JSON.parse(body),
    };
  };
  return { fetchImpl, calls };
}

const ref = (module: string, id: string) => ({
  $ref: { module, id },
  as: "string" as const,
  hash: "h",
  size: 5,
});

describe("katari.value: inline fast-path", () => {
  it("text() returns an inline string without fetching", async () => {
    const { fetchImpl, calls } = stubFetch("UNUSED");
    const value = createValueClient({ env: {}, fetchImpl });
    expect(await value.text("hello")).toBe("hello");
    expect(calls).toHaveLength(0);
  });

  it("fetch() encodes an inline string to UTF-8 bytes", async () => {
    const { fetchImpl } = stubFetch("UNUSED");
    const value = createValueClient({ env: {}, fetchImpl });
    expect(new TextDecoder().decode(await value.fetch("héllo"))).toBe("héllo");
  });

  it("fetchRange() slices inline bytes locally", async () => {
    const { fetchImpl, calls } = stubFetch("UNUSED");
    const value = createValueClient({ env: {}, fetchImpl });
    expect(new TextDecoder().decode(await value.fetchRange("0123456789", 2, 4))).toBe("2345");
    expect(calls).toHaveLength(0);
  });
});

describe("katari.value: $ref via data plane", () => {
  it("text() GETs the data-plane URL with the bearer token", async () => {
    const { fetchImpl, calls } = stubFetch("fetched conversation");
    const value = createValueClient({ env: ENV, fetchImpl });
    expect(await value.text(ref("ffi", "abc"))).toBe("fetched conversation");
    expect(calls).toHaveLength(1);
    expect(calls[0]?.url).toBe("http://host:9000/project/proj-1/value/ffi/ref/abc");
    expect(calls[0]?.headers?.Authorization).toBe("Bearer tok-123");
  });

  it("fetch() returns the raw bytes", async () => {
    const { fetchImpl } = stubFetch("raw-bytes");
    const value = createValueClient({ env: ENV, fetchImpl });
    expect(new TextDecoder().decode(await value.fetch(ref("core", "xyz")))).toBe("raw-bytes");
  });

  it("fetchRange() appends ?range=offset-end", async () => {
    const { fetchImpl, calls } = stubFetch("RANGE");
    const value = createValueClient({ env: ENV, fetchImpl });
    await value.fetchRange(ref("api", "f1"), 10, 5);
    expect(calls[0]?.url).toBe("http://host:9000/project/proj-1/value/api/ref/f1?range=10-14");
  });

  it("throws a clear error when protocol env is missing", async () => {
    const { fetchImpl } = stubFetch("UNUSED");
    const value = createValueClient({ env: {}, fetchImpl });
    await expect(value.text(ref("ffi", "abc"))).rejects.toThrow(/missing sidecar env/);
  });

  it("throws on a non-2xx data-plane response", async () => {
    const { fetchImpl } = stubFetch("not found", 404);
    const value = createValueClient({ env: ENV, fetchImpl });
    await expect(value.fetch(ref("ffi", "gone"))).rejects.toThrow(/failed \(404\)/);
  });
});

describe("katari.value: type guards", () => {
  it("rejects a non-byte-sequence RawValue", async () => {
    const { fetchImpl } = stubFetch("UNUSED");
    const value = createValueClient({ env: ENV, fetchImpl });
    await expect(value.text(42)).rejects.toThrow(/not a string \/ file/);
    await expect(value.fetch({ foo: "bar" })).rejects.toThrow(/not a string \/ file/);
  });
});

const PRODUCE_ENV = { ...ENV, KATARI_SIDECAR_OWNER: "ffi" };

function isRef(v: unknown): v is { $ref: { module: string; id: string }; as: string; size: number } {
  return typeof v === "object" && v !== null && "$ref" in v;
}

describe("katari.value: produce", () => {
  it("put() POSTs to the owner's produce endpoint and returns a $ref", async () => {
    const { fetchImpl, calls } = stubFetch(
      JSON.stringify({ module: "ffi", id: "new-id", hash: "hh", size: 9, contentType: "image/png" }),
      201,
    );
    const value = createValueClient({ env: PRODUCE_ENV, fetchImpl });
    const ref = await value.put(new TextEncoder().encode("some bytes"), {
      as: "file",
      contentType: "image/png",
    });
    expect(calls[0]?.url).toBe("http://host:9000/project/proj-1/value/ffi/produce");
    expect(calls[0]?.method).toBe("POST");
    expect(calls[0]?.headers?.["X-Katari-Semantic-Kind"]).toBe("file");
    expect(calls[0]?.headers?.["Content-Type"]).toBe("image/png");
    expect(isRef(ref) && ref.$ref).toEqual({ module: "ffi", id: "new-id" });
    expect(isRef(ref) && ref.as).toBe("file");
  });

  it("put() requires KATARI_SIDECAR_OWNER", async () => {
    const { fetchImpl } = stubFetch(JSON.stringify({ module: "ffi", id: "x", hash: "h", size: 1 }));
    const value = createValueClient({ env: ENV, fetchImpl });
    await expect(value.put(new Uint8Array([1]))).rejects.toThrow(/KATARI_SIDECAR_OWNER/);
  });

  it("open() buffers chunks and produces the concatenation on close", async () => {
    const { fetchImpl, calls } = stubFetch(
      JSON.stringify({ module: "ffi", id: "streamed", hash: "h", size: 6 }),
      201,
    );
    const value = createValueClient({ env: PRODUCE_ENV, fetchImpl });
    const handle = value.open({ as: "file" });
    handle.pushChunk(new TextEncoder().encode("foo"));
    handle.pushChunk(new TextEncoder().encode("bar"));
    const ref = await handle.close();
    expect(new TextDecoder().decode(calls[0]?.body as Uint8Array)).toBe("foobar");
    expect(isRef(ref) && ref.$ref).toEqual({ module: "ffi", id: "streamed" });
  });

  it("open().abort() makes no produce call", async () => {
    const { fetchImpl, calls } = stubFetch(JSON.stringify({ module: "ffi", id: "x", hash: "h", size: 1 }));
    const value = createValueClient({ env: PRODUCE_ENV, fetchImpl });
    const handle = value.open();
    handle.pushChunk(new Uint8Array([1, 2, 3]));
    handle.abort();
    expect(calls).toHaveLength(0);
  });

  it("persist() promotes an ephemeral ref to an api file $ref", async () => {
    const { fetchImpl, calls } = stubFetch(
      JSON.stringify({ module: "api", id: "file-1", hash: "h", size: 4 }),
      201,
    );
    const value = createValueClient({ env: PRODUCE_ENV, fetchImpl });
    const result = await value.persist(ref("ffi", "eph-1"), { displayName: "kept.bin" });
    expect(calls[0]?.url).toBe("http://host:9000/project/proj-1/value/ffi/ref/eph-1/persist");
    expect(calls[0]?.body).toBe(JSON.stringify({ displayName: "kept.bin" }));
    expect(isRef(result) && result.$ref).toEqual({ module: "api", id: "file-1" });
    expect(isRef(result) && result.as).toBe("file");
  });

  it("persist() rejects a non-ephemeral / non-ref value", async () => {
    const { fetchImpl } = stubFetch("{}");
    const value = createValueClient({ env: PRODUCE_ENV, fetchImpl });
    await expect(value.persist("inline")).rejects.toThrow(/not a \$ref/);
    await expect(value.persist({ $ref: { module: "api", id: "f" }, as: "file", hash: "h", size: 1 })).rejects.toThrow(
      /only ephemeral/,
    );
  });
});
