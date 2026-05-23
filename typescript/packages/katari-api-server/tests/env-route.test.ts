// HTTP CRUD tests for /env. Verifies redaction on read, opaque
// encryption at rest, idempotent upsert, and 404 semantics.

import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { randomBytes } from "node:crypto";
import { resetKeyCacheForTesting } from "@katari-lang/runtime";
import { buildTestHarness, type TestHarness } from "./helpers.js";

beforeAll(() => {
  if (
    process.env.KATARI_SECRET_KEY === undefined
    || process.env.KATARI_SECRET_KEY === ""
  ) {
    process.env.KATARI_SECRET_KEY = randomBytes(32).toString("hex");
  }
  resetKeyCacheForTesting();
});

let active: TestHarness | null = null;
afterEach(async () => {
  if (active !== null) {
    await active.shutdown();
    active = null;
  }
});

async function putEnv(
  harness: TestHarness,
  body: { key: string; value: string; isSecret: boolean },
): Promise<Response> {
  return harness.app.fetch(
    new Request("http://test/env", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    }),
  );
}

describe("env routes", () => {
  it("PUT then GET (non-secret) round-trips the value verbatim", async () => {
    const harness = buildTestHarness();
    active = harness;
    const put = await putEnv(harness, {
      key: "ENDPOINT_URL",
      value: "https://example.com",
      isSecret: false,
    });
    expect(put.status).toBe(200);
    const got = await harness.app.fetch(
      new Request("http://test/env/ENDPOINT_URL"),
    );
    expect(got.status).toBe(200);
    const body = (await got.json()) as {
      key: string;
      value: string;
      isSecret: boolean;
    };
    expect(body).toMatchObject({
      key: "ENDPOINT_URL",
      value: "https://example.com",
      isSecret: false,
    });
  });

  it("PUT a secret stores ciphertext at rest; GET returns redaction", async () => {
    const harness = buildTestHarness();
    active = harness;
    await putEnv(harness, {
      key: "API_KEY",
      value: "sk-live-XXXXXXXX",
      isSecret: true,
    });
    // Direct storage inspection: plaintext must NOT appear on disk.
    const row = await harness.storage.envEntries.get("API_KEY");
    expect(row).not.toBeNull();
    expect(row!.value).not.toEqual("sk-live-XXXXXXXX");
    expect(row!.value).toMatch(/^[^:]+:/); // IV-prefixed wire form
    // HTTP read returns the redaction placeholder, never the cipher.
    const got = await harness.app.fetch(
      new Request("http://test/env/API_KEY"),
    );
    const body = (await got.json()) as { value: string; isSecret: boolean };
    expect(body.value).toEqual("<redacted>");
    expect(body.isSecret).toBe(true);
  });

  it("GET list redacts every secret entry's value", async () => {
    const harness = buildTestHarness();
    active = harness;
    await putEnv(harness, { key: "PUBLIC_URL", value: "ok", isSecret: false });
    await putEnv(harness, { key: "SECRET_A", value: "a", isSecret: true });
    await putEnv(harness, { key: "SECRET_B", value: "b", isSecret: true });
    const res = await harness.app.fetch(new Request("http://test/env"));
    const body = (await res.json()) as {
      entries: { key: string; value: string; isSecret: boolean }[];
    };
    const byKey = Object.fromEntries(body.entries.map((e) => [e.key, e]));
    expect(byKey.PUBLIC_URL!.value).toEqual("ok");
    expect(byKey.SECRET_A!.value).toEqual("<redacted>");
    expect(byKey.SECRET_B!.value).toEqual("<redacted>");
  });

  it("PUT is idempotent — re-uploading the same key replaces the entry", async () => {
    const harness = buildTestHarness();
    active = harness;
    await putEnv(harness, { key: "K", value: "first", isSecret: false });
    await putEnv(harness, { key: "K", value: "second", isSecret: false });
    const row = await harness.storage.envEntries.get("K");
    expect(row!.value).toEqual("second");
  });

  it("DELETE removes an entry and returns 404 when it's already gone", async () => {
    const harness = buildTestHarness();
    active = harness;
    await putEnv(harness, { key: "TMP", value: "x", isSecret: false });
    const first = await harness.app.fetch(
      new Request("http://test/env/TMP", { method: "DELETE" }),
    );
    expect(first.status).toBe(200);
    const second = await harness.app.fetch(
      new Request("http://test/env/TMP", { method: "DELETE" }),
    );
    expect(second.status).toBe(404);
  });

  it("GET on a missing key is 404", async () => {
    const harness = buildTestHarness();
    active = harness;
    const res = await harness.app.fetch(
      new Request("http://test/env/MISSING"),
    );
    expect(res.status).toBe(404);
  });

  it("rejects keys with disallowed characters", async () => {
    const harness = buildTestHarness();
    active = harness;
    const res = await putEnv(harness, {
      key: "has space",
      value: "x",
      isSecret: false,
    });
    expect(res.status).toBe(400);
  });
});
