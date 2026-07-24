// The liveness probe reports the runtime's version alongside its status, so an operator (and the admin
// console) can spot a CLI/runtime skew. Driven against the route directly — no DB, no auth.

import { describe, expect, test } from "vitest";
import { healthRoutes } from "../src/modules/health/health.routes.js";

describe("GET /health", () => {
  test("reports status, uptime, and the runtime version", async () => {
    const response = await healthRoutes.request("/health");
    expect(response.status).toBe(200);
    const body: unknown = await response.json();
    expect(body).toMatchObject({
      ok: true,
      data: {
        status: "ok",
        uptimeSeconds: expect.any(Number),
        // Resolved from the shipped package.json; a non-empty string even when the manifest is unreadable
        // (the "unknown" sentinel), so the field is always present for skew diagnosis.
        version: expect.any(String),
      },
    });
  });
});
