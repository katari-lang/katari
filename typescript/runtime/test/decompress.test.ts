// The request-decompression middleware: a caller may gzip what it sends (a deploy's snapshot is mostly
// repeated schema text), and the cap that bounds the wire bytes has to bound what they expand to as well.
// Mounted on a tiny Hono app so the header handling and the rebuilt request are exercised for real.

import { gzipSync } from "node:zlib";
import { Hono } from "hono";
import { describe, expect, test } from "vitest";
import { createApp } from "../src/app.js";
import { errorHandler } from "../src/middleware/error-handler.js";
import { decompressRequest } from "../src/middleware/decompress.js";
import type { AppEnv } from "../src/types/app-env.js";

function appWith(maxSize: number) {
  const app = new Hono<AppEnv>();
  app.onError(errorHandler);
  app.use("*", decompressRequest({ maxSize }));
  app.post("/echo", async (c) => c.json({ received: await c.req.json() }));
  return app;
}

const gzipped = (body: unknown) => ({
  method: "POST",
  headers: { "Content-Type": "application/json", "Content-Encoding": "gzip" },
  body: gzipSync(Buffer.from(JSON.stringify(body))),
});

describe("decompressRequest", () => {
  test("a gzip body reaches the route as the JSON it encodes", async () => {
    const payload = { modules: { hello: "a".repeat(10_000) } };
    const response = await appWith(1024 * 1024).request("/echo", gzipped(payload));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ received: payload });
  });

  test("an uncompressed body is passed through untouched", async () => {
    const response = await appWith(1024 * 1024).request("/echo", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ plain: true }),
    });
    expect(await response.json()).toEqual({ received: { plain: true } });
  });

  test("the cap counts what the body expands to, not what arrived", async () => {
    // ~1 MiB of one repeated character: a few hundred compressed bytes naming far more than the cap.
    const payload = { blob: "a".repeat(1024 * 1024) };
    const request = gzipped(payload);
    expect(request.body.length).toBeLessThan(8 * 1024);
    const response = await appWith(64 * 1024).request("/echo", request);
    expect(response.status).toBe(413);
    expect(await response.json()).toMatchObject({ error: { code: "payload_too_large" } });
  });

  test("an encoding the runtime does not decode is refused, not guessed at", async () => {
    const response = await appWith(1024 * 1024).request("/echo", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Content-Encoding": "br" },
      body: "whatever",
    });
    expect(response.status).toBe(415);
  });

  test("a body that is not gzip fails as a bad request rather than as bad JSON", async () => {
    const response = await appWith(1024 * 1024).request("/echo", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Content-Encoding": "gzip" },
      body: "not actually gzip",
    });
    expect(response.status).toBe(400);
  });

  // Expanding a body is work a caller has to authenticate to ask for. `bearerAuth` exempts the health
  // probe, so mounting the decompressor on all of `/api/*` would let anyone who can reach the port turn
  // 32 KiB into whatever the cap allows, once per request and with no rate limiter on that path.
  test("it is mounted on the authenticated subtree, not on the public probe", async () => {
    const app = createApp();
    // A body that is not gzip at all: were the decompressor on this path, it would read it and answer
    // 400. The 404 says the request reached routing with its body untouched — nothing expanded it for
    // a caller that presented no credential.
    const response = await app.request("/api/v1/health", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Content-Encoding": "gzip" },
      body: "not actually gzip",
    });
    expect(response.status).toBe(404);
  });
});
