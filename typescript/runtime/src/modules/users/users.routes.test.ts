import { randomUUID } from "node:crypto";
import { afterAll, describe, expect, it } from "vitest";
import { createApp } from "../../app.js";
import { closeDb } from "../../db/client.js";

// These tests hit a real Postgres through the repository, so they only run
// when DATABASE_URL is set (e.g. `docker compose up -d` + migrate). Without
// it they are skipped, keeping `pnpm test` green offline.
const app = createApp();

interface JsonBody {
  ok: boolean;
  data: { total: number; items: unknown[]; role: string; id: string };
  error: { code: string; message: string };
}

const readJson = async (res: Response): Promise<JsonBody> => (await res.json()) as JsonBody;

const postJson = (body: unknown) => ({
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify(body),
});

describe.skipIf(!process.env.DATABASE_URL)("users API (integration)", () => {
  afterAll(async () => {
    await closeDb();
  });

  const email = `test-${randomUUID()}@example.com`;
  let createdId = "";

  it("creates a user and defaults the role to member", async () => {
    const res = await app.request("/api/v1/users", postJson({ name: "Grace Hopper", email }));
    expect(res.status).toBe(201);
    const body = await readJson(res);
    expect(body.data.role).toBe("member");
    expect(body.data.id).toMatch(/[0-9a-f-]{36}/);
    createdId = body.data.id;
  });

  it("fetches the created user", async () => {
    const res = await app.request(`/api/v1/users/${createdId}`);
    expect(res.status).toBe(200);
    const body = await readJson(res);
    expect(body.data.id).toBe(createdId);
  });

  it("lists users including the new one", async () => {
    const res = await app.request("/api/v1/users?limit=100");
    expect(res.status).toBe(200);
    const body = await readJson(res);
    expect(body.data.total).toBeGreaterThanOrEqual(1);
  });

  it("rejects a duplicate email with 409", async () => {
    const res = await app.request("/api/v1/users", postJson({ name: "Dup", email }));
    expect(res.status).toBe(409);
    const body = await readJson(res);
    expect(body.error.code).toBe("conflict");
  });

  it("rejects an invalid payload with 400", async () => {
    const res = await app.request("/api/v1/users", postJson({ name: "", email: "not-an-email" }));
    expect(res.status).toBe(400);
  });

  it("deletes the user (and 404s afterwards)", async () => {
    const del = await app.request(`/api/v1/users/${createdId}`, { method: "DELETE" });
    expect(del.status).toBe(204);
    const after = await app.request(`/api/v1/users/${createdId}`);
    expect(after.status).toBe(404);
  });
});
