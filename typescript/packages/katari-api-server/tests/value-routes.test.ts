// Data plane HTTP integration tests. Mounts `buildValueRoutes` at the same
// path the app uses (`/project/:projectId/value`) over an in-memory store and
// drives it through `app.fetch`, exercising fetch / range / state / errors.

import { Hono } from "hono";
import { beforeEach, describe, expect, it } from "vitest";
import { buildValueRoutes } from "../src/routes/value.js";
import { InMemoryStorage } from "../src/storage/memory-storage.js";

const PROJECT = "proj-1";
const enc = (text: string): Uint8Array => new TextEncoder().encode(text);

function mount(storage: InMemoryStorage): Hono {
  const app = new Hono();
  app.route("/project/:projectId/value", buildValueRoutes(storage));
  return app;
}

async function bodyText(res: Response): Promise<string> {
  return new TextDecoder().decode(new Uint8Array(await res.arrayBuffer()));
}

describe("data plane: GET value", () => {
  let storage: InMemoryStorage;
  let app: Hono;

  beforeEach(() => {
    storage = new InMemoryStorage();
    app = mount(storage);
  });

  it("fetches full bytes with metadata headers", async () => {
    const { id } = await storage.values.putComplete({
      projectId: PROJECT,
      owner: "core",
      bytes: enc("hello data plane"),
      semanticKind: "string",
    });
    const res = await app.fetch(new Request(`http://x/project/${PROJECT}/value/core/ref/${id}`));
    expect(res.status).toBe(200);
    expect(res.headers.get("Accept-Ranges")).toBe("bytes");
    expect(res.headers.get("Content-Length")).toBe("16");
    expect(await bodyText(res)).toBe("hello data plane");
  });

  it("serves a byte range via ?range=N-M (206 + Content-Range)", async () => {
    const { id } = await storage.values.putComplete({
      projectId: PROJECT,
      owner: "core",
      bytes: enc("0123456789"),
      semanticKind: "string",
    });
    const res = await app.fetch(
      new Request(`http://x/project/${PROJECT}/value/core/ref/${id}?range=2-5`),
    );
    expect(res.status).toBe(206);
    expect(res.headers.get("Content-Range")).toBe("bytes 2-5/10");
    expect(await bodyText(res)).toBe("2345");
  });

  it("honours a standard Range header", async () => {
    const { id } = await storage.values.putComplete({
      projectId: PROJECT,
      owner: "core",
      bytes: enc("0123456789"),
      semanticKind: "string",
    });
    const res = await app.fetch(
      new Request(`http://x/project/${PROJECT}/value/core/ref/${id}`, {
        headers: { Range: "bytes=7-" },
      }),
    );
    expect(res.status).toBe(206);
    expect(res.headers.get("Content-Range")).toBe("bytes 7-9/10");
    expect(await bodyText(res)).toBe("789");
  });

  it("returns metadata at /state", async () => {
    const { id, hash } = await storage.values.putComplete({
      projectId: PROJECT,
      owner: "ffi",
      bytes: enc("meta"),
      semanticKind: "file",
      contentType: "application/octet-stream",
    });
    const res = await app.fetch(
      new Request(`http://x/project/${PROJECT}/value/ffi/ref/${id}/state`),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({
      module: "ffi",
      state: "complete",
      semanticKind: "file",
      hash,
      size: 4,
      contentType: "application/octet-stream",
    });
  });

  it("serves an api file (module=api) with its contentType", async () => {
    const file = await storage.values.createFile({
      projectId: PROJECT,
      bytes: enc("file body"),
      contentType: "text/markdown",
    });
    const res = await app.fetch(
      new Request(`http://x/project/${PROJECT}/value/api/ref/${file.id}`),
    );
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("text/markdown");
    expect(await bodyText(res)).toBe("file body");
  });

  it("404s an unknown ref", async () => {
    const res = await app.fetch(
      new Request(`http://x/project/${PROJECT}/value/core/ref/missing`),
    );
    expect(res.status).toBe(404);
  });

  it("409s an errored ref", async () => {
    const handle = await storage.values.open({
      projectId: PROJECT,
      owner: "ffi",
      semanticKind: "string",
    });
    await handle.abort("producer crashed");
    const res = await app.fetch(
      new Request(`http://x/project/${PROJECT}/value/ffi/ref/${handle.id}`),
    );
    expect(res.status).toBe(409);
    expect(await res.json()).toMatchObject({ message: "producer crashed" });
  });
});
