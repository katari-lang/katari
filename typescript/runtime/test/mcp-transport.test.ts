// Unit tests for the mcp transport's result shaping (`resolveToolResult`): how one SDK tool result's
// content blocks become the completion's Json — text joins, structured content rides through, and
// binary (image / audio) blocks become project blobs via the injected producer, degrading to their
// text placeholder when no producer is wired or the owning call vanished mid-produce.

import type { Json } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { type McpBlobProducer, resolveToolResult } from "../src/runtime/external/mcp-transport.js";
import type { DelegationId } from "../src/runtime/ids.js";

const DELEGATION = "delegation-mcp-shape" as DelegationId;

const PNG_BASE64 = Buffer.from([0x89, 0x50, 0x4e, 0x47]).toString("base64");

/** A producer that records what it was asked to store and returns a deterministic handle. */
function recordingProducer(): {
  producer: McpBlobProducer;
  calls: Array<{ bytes: Uint8Array; contentType: string | undefined }>;
} {
  const calls: Array<{ bytes: Uint8Array; contentType: string | undefined }> = [];
  const producer: McpBlobProducer = async (_delegation, bytes, contentType) => {
    calls.push({ bytes, contentType });
    // The slim handle the real producer returns: identity only (metadata went to the blob's row).
    return { $ref: `blob-${calls.length}`, semanticKind: "file" };
  };
  return { producer, calls };
}

describe("resolveToolResult", () => {
  test("text-only content joins to a plain string (unchanged pre-bridge behaviour)", async () => {
    const value = await resolveToolResult(
      { content: [{ type: "text", text: "hello" }, { type: "text", text: "world" }] },
      undefined,
      DELEGATION,
    );
    expect(value).toBe("hello\nworld");
  });

  test("structured content rides through as the value it is", async () => {
    const structured: Json = { answer: 42 };
    const value = await resolveToolResult(
      { structuredContent: structured, content: [{ type: "text", text: "ignored" }] },
      undefined,
      DELEGATION,
    );
    expect(value).toEqual(structured);
  });

  test("an image block becomes a produced blob handle in { text, files }", async () => {
    const { producer, calls } = recordingProducer();
    const value = await resolveToolResult(
      {
        content: [
          { type: "text", text: "your screenshot" },
          { type: "image", data: PNG_BASE64, mimeType: "image/png" },
        ],
      },
      producer,
      DELEGATION,
    );
    expect(calls).toHaveLength(1);
    expect(Array.from(calls[0]?.bytes ?? [])).toEqual([0x89, 0x50, 0x4e, 0x47]);
    expect(calls[0]?.contentType).toBe("image/png");
    expect(value).toEqual({
      text: "your screenshot",
      files: [{ $ref: "blob-1", semanticKind: "file" }],
    });
  });

  test("files win over structured content when both are present", async () => {
    const { producer } = recordingProducer();
    const value = await resolveToolResult(
      {
        structuredContent: { ignored: true },
        content: [{ type: "image", data: PNG_BASE64, mimeType: "image/png" }],
      },
      producer,
      DELEGATION,
    );
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
      throw new Error("expected a { text, files } record");
    }
    expect(Array.isArray(value.files)).toBe(true);
  });

  test("a binary block with no producer degrades to its text placeholder", async () => {
    const value = await resolveToolResult(
      {
        content: [
          { type: "text", text: "see attached" },
          { type: "image", data: PNG_BASE64, mimeType: "image/png" },
        ],
      },
      undefined,
      DELEGATION,
    );
    expect(value).toBe("see attached\n(image content)");
  });

  test("a producer refusal (the call vanished) degrades that block, not the whole result", async () => {
    const refusing: McpBlobProducer = async () => null;
    const value = await resolveToolResult(
      { content: [{ type: "image", data: PNG_BASE64, mimeType: "image/png" }] },
      refusing,
      DELEGATION,
    );
    expect(value).toBe("(image content)");
  });
});
