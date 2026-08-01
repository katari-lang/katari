// Which body cap applies where. Every middleware whose path matches runs, so the caps cannot be layered:
// an upload path carrying both the upload cap and the general one would be decided by whichever is
// smaller, which is not what either number means. One middleware picks, and this suite says which — with
// two different numbers, since the shipped defaults are equal and would hide the distinction.

import { Hono } from "hono";
import { describe, expect, test } from "vitest";
import { requestBodyLimit } from "../src/middleware/body-caps.js";
import type { AppEnv } from "../src/types/app-env.js";

const ORDINARY = 1_000;
const UPLOAD = 100_000;

function app() {
  const app = new Hono<AppEnv>();
  app.use("/api/*", requestBodyLimit({ maxRequestBytes: ORDINARY, maxUploadBytes: UPLOAD }));
  app.post("/api/*", (c) => c.json({ ok: true }));
  return app;
}

const send = (path: string, size: number) =>
  app().request(path, { method: "POST", body: "x".repeat(size) });

describe("requestBodyLimit", () => {
  test("an upload is measured against the upload cap, not the smaller general one", async () => {
    expect((await send("/api/v1/projects/p1/files", ORDINARY * 10)).status).toBe(200);
    expect((await send("/api/v1/projects/p1/ffi/d1/blobs", ORDINARY * 10)).status).toBe(200);
  });

  test("an upload past the upload cap is still refused", async () => {
    const response = await send("/api/v1/projects/p1/files", UPLOAD + 1);
    expect(response.status).toBe(413);
    expect(await response.json()).toMatchObject({ error: "the uploaded file is too large" });
  });

  test("an ordinary API body is measured against the general cap", async () => {
    expect((await send("/api/v1/projects/p1/snapshots", ORDINARY - 1)).status).toBe(200);
    const response = await send("/api/v1/projects/p1/snapshots", ORDINARY + 1);
    expect(response.status).toBe(413);
    expect(await response.json()).toMatchObject({ error: "the request body is too large" });
  });

  test("a path that merely looks like an upload does not get the upload cap", async () => {
    // The pattern is anchored: nothing may append a segment to it and inherit the larger allowance.
    expect((await send("/api/v1/projects/p1/files/extra", ORDINARY * 10)).status).toBe(413);
  });
});
