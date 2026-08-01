import { createMiddleware } from "hono/factory";
import { BadRequestError, PayloadTooLargeError, UnsupportedMediaTypeError } from "../lib/errors.js";
import type { AppEnv } from "../types/app-env.js";

/**
 * Reads a `Content-Encoding: gzip` request body and hands the decoded bytes downstream, so a caller may
 * compress what it sends. A deploy is the case that wants it: a snapshot is mostly JSON schema text with
 * the same phrases repeated thousands of times, and gzip takes it to roughly a tenth.
 *
 * `maxSize` bounds what the body expands to, and is the reason this reads the whole body here rather than
 * piping a decompression stream downstream: a few compressed kilobytes can name gigabytes, so the size
 * has to be known before anything downstream buffers it. Pair it with `bodyLimit`, which bounds the bytes
 * that arrived — one cap on the wire, one on what they mean.
 */
export const decompressRequest = (options: { maxSize: number }) =>
  createMiddleware<AppEnv>(async (c, next) => {
    const encoding = c.req.header("content-encoding")?.trim().toLowerCase();
    if (encoding === undefined || encoding === "" || encoding === "identity") return next();
    if (encoding !== "gzip") {
      throw new UnsupportedMediaTypeError(
        `This runtime decodes Content-Encoding gzip, and received "${encoding}".`,
      );
    }
    const body = c.req.raw.body;
    if (body === null) return next();

    const reader = body.pipeThrough(new DecompressionStream("gzip")).getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    for (;;) {
      // A corrupt or truncated stream errors here rather than at the parse, where it would read as
      // malformed JSON and send the caller looking at the wrong thing.
      const { done, value } = await reader.read().catch((cause: unknown) => {
        throw new BadRequestError(
          `The gzip request body could not be decoded: ${cause instanceof Error ? cause.message : String(cause)}`,
        );
      });
      if (done) break;
      size += value.length;
      if (size > options.maxSize) {
        await reader.cancel();
        throw new PayloadTooLargeError(
          `The request body expands to more than ${options.maxSize} bytes.`,
        );
      }
      chunks.push(value);
    }

    const expanded = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      expanded.set(chunk, offset);
      offset += chunk.length;
    }
    const headers = new Headers(c.req.raw.headers);
    headers.delete("content-encoding");
    headers.set("content-length", String(size));
    c.req.raw = new Request(c.req.raw, { headers, body: expanded });
    await next();
  });
