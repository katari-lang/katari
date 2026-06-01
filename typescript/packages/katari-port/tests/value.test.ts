// Tests for the internal data plane + value-shape guards. A stub `FetchLike`
// records calls so we can assert the data-plane URL / auth header / produce
// headers without a real server.

import { describe, expect, it } from "vitest";
import type { KatariFile, KatariRef } from "../src/types.js";
import {
  asRef,
  createDataPlane,
  type FetchLike,
  isKatariAgent,
  isKatariFile,
  isKatariString,
} from "../src/value.js";

const ENV = {
  KATARI_PROTOCOL_URL: "http://host:9000",
  KATARI_PROTOCOL_TOKEN: "tok-123",
  KATARI_PROJECT_ID: "proj-1",
};
const PRODUCE_ENV = { ...ENV, KATARI_SIDECAR_OWNER: "ffi" };

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

const stringRef = (module: string, id: string): KatariRef<"string"> => ({
  $ref: { module: module as "core" | "ffi" | "api", id },
  as: "string",
  hash: "h",
  size: 5,
});
const fileRef = (module: string, id: string): KatariFile => ({
  $ref: { module: module as "core" | "ffi" | "api", id },
  as: "file",
  hash: "h",
  size: 5,
});

describe("value guards", () => {
  it("asRef recognises a $ref envelope, rejects others", () => {
    expect(asRef(stringRef("ffi", "a"))?.$ref.id).toBe("a");
    expect(asRef(fileRef("api", "f"))?.as).toBe("file");
    expect(asRef("inline")).toBeNull();
    expect(asRef(42)).toBeNull();
    expect(asRef({ foo: "bar" })).toBeNull();
    expect(asRef({ $agent: "x.y@s" })).toBeNull();
  });

  it("isKatariFile / isKatariString / isKatariAgent", () => {
    expect(isKatariFile(fileRef("ffi", "f"))).toBe(true);
    expect(isKatariFile(stringRef("ffi", "s"))).toBe(false);
    expect(isKatariFile("inline")).toBe(false);

    expect(isKatariString("inline")).toBe(true);
    expect(isKatariString(stringRef("core", "s"))).toBe(true);
    expect(isKatariString(fileRef("core", "f"))).toBe(false);

    expect(isKatariAgent({ $agent: "tools.search@snap" })).toBe(true);
    expect(isKatariAgent({ $agent: "closureref:abc" })).toBe(true);
    expect(isKatariAgent(stringRef("ffi", "s"))).toBe(false);
    expect(isKatariAgent("x.y")).toBe(false);
  });
});

describe("data plane: fetchBytes", () => {
  it("GETs the data-plane URL with the bearer token", async () => {
    const { fetchImpl, calls } = stubFetch("fetched conversation");
    const dp = createDataPlane({ env: ENV, fetchImpl });
    const bytes = await dp.fetchBytes(stringRef("ffi", "abc"));
    expect(new TextDecoder().decode(bytes)).toBe("fetched conversation");
    expect(calls).toHaveLength(1);
    expect(calls[0]?.url).toBe("http://host:9000/project/proj-1/value/ffi/ref/abc");
    expect(calls[0]?.headers?.Authorization).toBe("Bearer tok-123");
  });

  it("throws a clear error when protocol env is missing", async () => {
    const { fetchImpl } = stubFetch("UNUSED");
    const dp = createDataPlane({ env: {}, fetchImpl });
    await expect(dp.fetchBytes(stringRef("ffi", "abc"))).rejects.toThrow(/missing sidecar env/);
  });

  it("throws on a non-2xx data-plane response", async () => {
    const { fetchImpl } = stubFetch("not found", 404);
    const dp = createDataPlane({ env: ENV, fetchImpl });
    await expect(dp.fetchBytes(fileRef("ffi", "gone"))).rejects.toThrow(/failed \(404\)/);
  });
});

describe("data plane: produce", () => {
  it("POSTs to the owner's produce endpoint with semantic-kind / content-type / display-name", async () => {
    const { fetchImpl, calls } = stubFetch(
      JSON.stringify({ module: "ffi", id: "new-id", hash: "hh", size: 9, contentType: "image/png" }),
      201,
    );
    const dp = createDataPlane({ env: PRODUCE_ENV, fetchImpl });
    const ref = await dp.produce(new TextEncoder().encode("some bytes"), {
      as: "file",
      contentType: "image/png",
      displayName: "pic.png",
    });
    expect(calls[0]?.url).toBe("http://host:9000/project/proj-1/value/ffi/produce");
    expect(calls[0]?.method).toBe("POST");
    expect(calls[0]?.headers?.["X-Katari-Semantic-Kind"]).toBe("file");
    expect(calls[0]?.headers?.["Content-Type"]).toBe("image/png");
    expect(calls[0]?.headers?.["X-Katari-Display-Name"]).toBe("pic.png");
    expect(ref.$ref).toEqual({ module: "ffi", id: "new-id" });
    expect(ref.as).toBe("file");
  });

  it("stamps the owning delegation when ownerDelegationId is given", async () => {
    const { fetchImpl, calls } = stubFetch(
      JSON.stringify({ module: "ffi", id: "x", hash: "h", size: 1 }),
      201,
    );
    const dp = createDataPlane({ env: PRODUCE_ENV, fetchImpl });
    await dp.produce(new Uint8Array([1]), { as: "string", ownerDelegationId: "deleg-9" });
    expect(calls[0]?.headers?.["X-Katari-Owner-Delegation"]).toBe("deleg-9");
  });

  it("requires KATARI_SIDECAR_OWNER", async () => {
    const { fetchImpl } = stubFetch(JSON.stringify({ module: "ffi", id: "x", hash: "h", size: 1 }));
    const dp = createDataPlane({ env: ENV, fetchImpl });
    await expect(dp.produce(new Uint8Array([1]), { as: "string" })).rejects.toThrow(
      /KATARI_SIDECAR_OWNER/,
    );
  });
});

describe("data plane: persist", () => {
  it("promotes an ephemeral ref to an api file $ref", async () => {
    const { fetchImpl, calls } = stubFetch(
      JSON.stringify({ module: "api", id: "file-1", hash: "h", size: 4 }),
      201,
    );
    const dp = createDataPlane({ env: PRODUCE_ENV, fetchImpl });
    const result = await dp.persist(fileRef("ffi", "eph-1"), { displayName: "kept.bin" });
    expect(calls[0]?.url).toBe("http://host:9000/project/proj-1/value/ffi/ref/eph-1/persist");
    expect(calls[0]?.body).toBe(JSON.stringify({ displayName: "kept.bin" }));
    expect(result.$ref).toEqual({ module: "api", id: "file-1" });
    expect(result.as).toBe("file");
  });

  it("rejects a non-ephemeral (api) ref", async () => {
    const { fetchImpl } = stubFetch("{}");
    const dp = createDataPlane({ env: PRODUCE_ENV, fetchImpl });
    await expect(dp.persist(fileRef("api", "f"))).rejects.toThrow(/only ephemeral/);
  });
});
