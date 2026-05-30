// Produce-route integration tests. Mounts BOTH the produce routes and the
// read-only data plane at the same prefix, so a produced ref can be fetched
// straight back (the real FFI round-trip: sidecar produces → CORE consumes).

import { Hono } from "hono";
import { beforeEach, describe, expect, it } from "vitest";
import { ZodError } from "zod";
import { buildValueProduceRoutes } from "../src/routes/value-produce.js";
import { buildValueRoutes } from "../src/routes/value.js";
import { InMemoryStorage } from "../src/storage/memory-storage.js";

const PROJECT = "proj-1";
const enc = (text: string): Uint8Array => new TextEncoder().encode(text);

function mount(storage: InMemoryStorage): Hono {
  const app = new Hono();
  // Mirror buildApp's ZodError → 400 mapping so validation rejects surface as
  // 400 here the same way they do in production.
  app.onError((err, c) => {
    if (err instanceof ZodError) return c.json({ error: "validation failed" }, 400);
    throw err;
  });
  app.route("/project/:projectId/value", buildValueRoutes(storage));
  app.route("/project/:projectId/value", buildValueProduceRoutes(storage));
  return app;
}

async function bodyText(res: Response): Promise<string> {
  return new TextDecoder().decode(new Uint8Array(await res.arrayBuffer()));
}

describe("produce routes", () => {
  let storage: InMemoryStorage;
  let app: Hono;

  beforeEach(() => {
    storage = new InMemoryStorage();
    app = mount(storage);
  });

  it("produces an ephemeral ref that the data plane can fetch back", async () => {
    const produce = await app.fetch(
      new Request(`http://x/project/${PROJECT}/value/ffi/produce`, {
        method: "POST",
        headers: { "X-Katari-Semantic-Kind": "string" },
        body: enc("produced by sidecar"),
      }),
    );
    expect(produce.status).toBe(201);
    const ref = (await produce.json()) as { module: string; id: string; hash: string; size: number };
    expect(ref.module).toBe("ffi");
    expect(ref.size).toBe(19);

    const fetched = await app.fetch(
      new Request(`http://x/project/${PROJECT}/value/ffi/ref/${ref.id}`),
    );
    expect(fetched.status).toBe(200);
    expect(await bodyText(fetched)).toBe("produced by sidecar");
  });

  it("carries semantic kind + content type to the ref state", async () => {
    const produce = await app.fetch(
      new Request(`http://x/project/${PROJECT}/value/ffi/produce`, {
        method: "POST",
        headers: { "X-Katari-Semantic-Kind": "file", "Content-Type": "image/png" },
        body: enc("\x89PNG..."),
      }),
    );
    const ref = (await produce.json()) as { id: string; contentType?: string };
    expect(ref.contentType).toBe("image/png");

    const state = await app.fetch(
      new Request(`http://x/project/${PROJECT}/value/ffi/ref/${ref.id}/state`),
    );
    expect(await state.json()).toMatchObject({ semanticKind: "file", contentType: "image/png" });
  });

  it("persists an ephemeral ref into an api file sharing the blob", async () => {
    const produce = await app.fetch(
      new Request(`http://x/project/${PROJECT}/value/ffi/produce`, {
        method: "POST",
        headers: { "X-Katari-Semantic-Kind": "file" },
        body: enc("keep this"),
      }),
    );
    const ref = (await produce.json()) as { id: string };

    const persist = await app.fetch(
      new Request(`http://x/project/${PROJECT}/value/ffi/ref/${ref.id}/persist`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ displayName: "kept.bin" }),
      }),
    );
    expect(persist.status).toBe(201);
    const file = (await persist.json()) as { module: string; id: string; displayName?: string };
    expect(file.module).toBe("api");
    expect(file.displayName).toBe("kept.bin");

    // Fetchable as an api file, and the blob is shared (one blob, two refs).
    const fetched = await app.fetch(
      new Request(`http://x/project/${PROJECT}/value/api/ref/${file.id}`),
    );
    expect(await bodyText(fetched)).toBe("keep this");
    expect(storage.values.blobs.size).toBe(1);
  });

  it("404s persist of an unknown ref", async () => {
    const res = await app.fetch(
      new Request(`http://x/project/${PROJECT}/value/ffi/ref/ghost/persist`, { method: "POST" }),
    );
    expect(res.status).toBe(404);
  });

  it("rejects produce for a non-producer owner (api)", async () => {
    const res = await app.fetch(
      new Request(`http://x/project/${PROJECT}/value/api/produce`, {
        method: "POST",
        body: enc("nope"),
      }),
    );
    expect(res.status).toBe(400);
  });
});
