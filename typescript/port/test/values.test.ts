// The handler value layer: wire JSON decodes into the ergonomic wrappers (files / strings / data /
// callables, unescaped record keys) and encodes back to the exact wire form, so a handler never touches a
// raw `$ref` or an escaped key.

import type { Json } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import {
  decodeWireValue,
  encodeWireValue,
  KatariAgent,
  KatariData,
  KatariFile,
  KatariString,
  text,
  type ValueBinding,
} from "../src/values.js";

/** A binding whose download / call are recorded, for observing wrapper behaviour without a runtime. */
function makeBinding(bytesByRef: Record<string, string> = {}) {
  const calls: Array<{ target: Json; argument: unknown }> = [];
  const binding: ValueBinding = {
    download: (ref) => {
      const content = bytesByRef[ref];
      if (content === undefined) return Promise.reject(new Error(`no bytes for ${ref}`));
      const bytes = new TextEncoder().encode(content);
      return Promise.resolve({ bytes, size: bytes.byteLength, contentType: "text/plain" });
    },
    callCallable: (target, argument) => {
      calls.push({ target, argument });
      return Promise.resolve("called");
    },
  };
  return { binding, calls };
}

const fileHandle: Json = { $ref: "blob-1", semanticKind: "file" };

describe("decodeWireValue", () => {
  test("scalars and arrays pass through; record keys are unescaped", () => {
    const { binding } = makeBinding();
    expect(decodeWireValue({ $$ref: [1, "two", null, true] }, binding)).toEqual({
      $ref: [1, "two", null, true],
    });
  });

  test("a file handle becomes a downloadable KatariFile (no raw $ref exposed)", async () => {
    const { binding } = makeBinding({ "blob-1": "hello" });
    const decoded = decodeWireValue({ content: fileHandle }, binding);
    if (
      decoded === null ||
      typeof decoded !== "object" ||
      Array.isArray(decoded) ||
      decoded instanceof KatariFile ||
      decoded instanceof KatariString ||
      decoded instanceof KatariData ||
      decoded instanceof KatariAgent
    ) {
      throw new Error("expected a record");
    }
    const content = decoded.content;
    expect(content).toBeInstanceOf(KatariFile);
    if (!(content instanceof KatariFile)) throw new Error("unreachable");
    // Metadata is async now — the slim handle carries none; it comes with the download.
    await expect(content.size()).resolves.toBe(5);
    await expect(content.contentType()).resolves.toBe("text/plain");
    await expect(content.text()).resolves.toBe("hello");
  });

  test("a blob-backed string becomes a KatariString, read uniformly via text()", async () => {
    const { binding } = makeBinding({ "blob-2": "big text" });
    const decoded = decodeWireValue({ $ref: "blob-2", semanticKind: "string" }, binding);
    expect(decoded).toBeInstanceOf(KatariString);
    if (!(decoded instanceof KatariString)) throw new Error("unreachable");
    await expect(text(decoded)).resolves.toBe("big text");
    await expect(text("inline")).resolves.toBe("inline");
  });

  test("a data value becomes KatariData with decoded fields", () => {
    const { binding } = makeBinding();
    const decoded = decodeWireValue(
      { $constructor: "adt.Some", value: { value: 42 } },
      binding,
    );
    expect(decoded).toBeInstanceOf(KatariData);
    if (!(decoded instanceof KatariData)) throw new Error("unreachable");
    expect(decoded.name).toBe("adt.Some");
    expect(decoded.value).toEqual({ value: 42 });
  });

  test("an agent reference becomes a KatariAgent whose call rides the raw reference verbatim", async () => {
    const { binding, calls } = makeBinding();
    const raw: Json = { $agent: "main.helper", snapshot: "snap-1" };
    const decoded = decodeWireValue(raw, binding);
    expect(decoded).toBeInstanceOf(KatariAgent);
    if (!(decoded instanceof KatariAgent)) throw new Error("unreachable");
    expect(decoded.name).toBe("main.helper");
    await expect(decoded.call({ n: 1 })).resolves.toBe("called");
    expect(calls).toEqual([{ target: raw, argument: { n: 1 } }]);
  });

  test("a redacted marker fails loudly (it cannot appear in well-formed revealed input)", () => {
    const { binding } = makeBinding();
    expect(() => decodeWireValue({ $redacted: true }, binding)).toThrow(/redacted/);
  });
});

describe("encodeWireValue", () => {
  test("wrappers collapse to their wire forms and record keys re-escape", () => {
    const { binding } = makeBinding();
    const file = decodeWireValue(fileHandle, binding);
    const agentRaw: Json = { $agent: "main.helper", snapshot: "snap-1" };
    const agent = decodeWireValue(agentRaw, binding);
    expect(
      encodeWireValue({
        $key: "escaped",
        file,
        callable: agent,
        data: new KatariData("adt.Ok", { value: 1 }),
      }),
    ).toEqual({
      $$key: "escaped",
      file: fileHandle,
      callable: agentRaw,
      data: { $constructor: "adt.Ok", value: { value: 1 } },
    });
  });

  test("undefined becomes null at the top and is dropped inside records", () => {
    expect(encodeWireValue(undefined)).toBe(null);
    expect(encodeWireValue({ kept: 1, dropped: undefined })).toEqual({ kept: 1 });
  });

  test("values with no wire form fail with a clear error", () => {
    expect(() => encodeWireValue(10n)).toThrow(/bigint/);
    expect(() => encodeWireValue(new Uint8Array([1]))).toThrow(/context\.file/);
    expect(() => encodeWireValue(Number.NaN)).toThrow(/non-finite/);
    const cyclic: { self?: unknown } = {};
    cyclic.self = cyclic;
    expect(() => encodeWireValue(cyclic)).toThrow(/cyclic/);
  });

  test("a shared (non-cyclic) subtree is not mistaken for a cycle", () => {
    const shared = { n: 1 };
    expect(encodeWireValue({ a: shared, b: shared })).toEqual({ a: { n: 1 }, b: { n: 1 } });
  });
});
