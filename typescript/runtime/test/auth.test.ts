// The Bearer-auth middleware decision: who gets through, who gets 401, and what stays public. Mounted on a
// tiny Hono app so the routing (public-path exemptions, the Authorization parse) is exercised for real,
// without a database.

import { Hono } from "hono";
import { describe, expect, test } from "vitest";
import { bearerAuth } from "../src/middleware/auth.js";
import type { AppEnv } from "../src/types/app-env.js";

const KEY = "s3cr3t-token";

function appWithAuth() {
  const app = new Hono<AppEnv>();
  app.use("*", bearerAuth(KEY));
  app.get("/api/v1/health", (c) => c.json({ ok: true }));
  app.get("/api/v1/projects", (c) => c.json({ ok: true }));
  app.get("/", (c) => c.text("console shell"));
  app.get("/assets/app.js", (c) => c.text("//js"));
  return app;
}

const authorized = (token: string) => ({ headers: { Authorization: `Bearer ${token}` } });

describe("bearerAuth", () => {
  const app = appWithAuth();

  test("a protected API route needs a matching bearer token", async () => {
    expect((await app.request("/api/v1/projects")).status).toBe(401);
    expect((await app.request("/api/v1/projects", authorized("wrong"))).status).toBe(401);
    expect((await app.request("/api/v1/projects", authorized(KEY))).status).toBe(200);
  });

  test("a malformed Authorization header is rejected", async () => {
    const response = await app.request("/api/v1/projects", { headers: { Authorization: KEY } });
    expect(response.status).toBe(401);
    const body = await response.json();
    expect(body).toMatchObject({ ok: false, error: { code: "unauthorized" } });
  });

  test("the health probe is public (monitoring carries no credentials)", async () => {
    expect((await app.request("/api/v1/health")).status).toBe(200);
  });

  test("the console's static assets are public (the browser can't attach a bearer to them)", async () => {
    expect((await app.request("/")).status).toBe(200);
    expect((await app.request("/assets/app.js")).status).toBe(200);
  });
});
