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

type Call = { url: string; headers?: Record<string, string> };

function stubFetch(body: string, status = 200): { fetchImpl: FetchLike; calls: Call[] } {
  const calls: Call[] = [];
  const fetchImpl: FetchLike = async (url, init) => {
    calls.push({ url, headers: init?.headers });
    return {
      ok: status >= 200 && status < 300,
      status,
      arrayBuffer: async () => new TextEncoder().encode(body).buffer as ArrayBuffer,
      text: async () => body,
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
