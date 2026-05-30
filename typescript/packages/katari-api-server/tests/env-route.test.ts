// HTTP CRUD tests for /project/:projectId/env. Verifies redaction on read,
// opaque encryption at rest, idempotent upsert, 404 semantics, and
// per-project isolation.

import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { randomBytes } from "node:crypto";
import { resetKeyCacheForTesting } from "@katari-lang/runtime";
import type { ProjectId } from "../src/storage/types.js";
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

async function createProject(harness: TestHarness, name: string): Promise<ProjectId> {
  const res = await harness.app.fetch(
    new Request("http://test/project", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name }),
    }),
  );
  const body = (await res.json()) as { project: { id: string } };
  return body.project.id as ProjectId;
}

async function putEnv(
  harness: TestHarness,
  projectId: ProjectId,
  body: { key: string; value: string; isSecret: boolean },
): Promise<Response> {
  return harness.app.fetch(
    new Request(`http://test/project/${projectId}/env`, {
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
    const projectId = await createProject(harness, "p1");
    const put = await putEnv(harness, projectId, {
      key: "ENDPOINT_URL",
      value: "https://example.com",
      isSecret: false,
    });
    expect(put.status).toBe(200);
    const got = await harness.app.fetch(
      new Request(`http://test/project/${projectId}/env/ENDPOINT_URL`),
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
    const projectId = await createProject(harness, "p1");
    await putEnv(harness, projectId, {
      key: "API_KEY",
      value: "sk-live-XXXXXXXX",
      isSecret: true,
    });
    // Direct storage inspection: plaintext must NOT appear on disk.
    const row = await harness.storage.envEntries.get(projectId, "API_KEY");
    expect(row).not.toBeNull();
    expect(row!.value).not.toEqual("sk-live-XXXXXXXX");
    expect(row!.value).toMatch(/^[^:]+:/); // IV-prefixed wire form
    // HTTP read returns the redaction placeholder, never the cipher.
    const got = await harness.app.fetch(
      new Request(`http://test/project/${projectId}/env/API_KEY`),
    );
    const body = (await got.json()) as { value: string; isSecret: boolean };
    expect(body.value).toEqual("<redacted>");
    expect(body.isSecret).toBe(true);
  });

  it("GET list redacts every secret entry's value", async () => {
    const harness = buildTestHarness();
    active = harness;
    const projectId = await createProject(harness, "p1");
    await putEnv(harness, projectId, { key: "PUBLIC_URL", value: "ok", isSecret: false });
    await putEnv(harness, projectId, { key: "SECRET_A", value: "a", isSecret: true });
    await putEnv(harness, projectId, { key: "SECRET_B", value: "b", isSecret: true });
    const res = await harness.app.fetch(
      new Request(`http://test/project/${projectId}/env`),
    );
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
    const projectId = await createProject(harness, "p1");
    await putEnv(harness, projectId, { key: "K", value: "first", isSecret: false });
    await putEnv(harness, projectId, { key: "K", value: "second", isSecret: false });
    const row = await harness.storage.envEntries.get(projectId, "K");
    expect(row!.value).toEqual("second");
  });

  it("env is isolated per project — one project's keys don't leak into another", async () => {
    const harness = buildTestHarness();
    active = harness;
    const a = await createProject(harness, "alpha");
    const b = await createProject(harness, "beta");
    await putEnv(harness, a, { key: "SHARED", value: "from-a", isSecret: false });
    await putEnv(harness, b, { key: "SHARED", value: "from-b", isSecret: false });

    const fromA = (await (
      await harness.app.fetch(new Request(`http://test/project/${a}/env/SHARED`))
    ).json()) as { value: string };
    const fromB = (await (
      await harness.app.fetch(new Request(`http://test/project/${b}/env/SHARED`))
    ).json()) as { value: string };
    expect(fromA.value).toEqual("from-a");
    expect(fromB.value).toEqual("from-b");

    const listA = (await (
      await harness.app.fetch(new Request(`http://test/project/${a}/env`))
    ).json()) as { entries: { key: string }[] };
    expect(listA.entries).toHaveLength(1);
  });

  it("DELETE removes an entry and returns 404 when it's already gone", async () => {
    const harness = buildTestHarness();
    active = harness;
    const projectId = await createProject(harness, "p1");
    await putEnv(harness, projectId, { key: "TMP", value: "x", isSecret: false });
    const first = await harness.app.fetch(
      new Request(`http://test/project/${projectId}/env/TMP`, { method: "DELETE" }),
    );
    expect(first.status).toBe(200);
    const second = await harness.app.fetch(
      new Request(`http://test/project/${projectId}/env/TMP`, { method: "DELETE" }),
    );
    expect(second.status).toBe(404);
  });

  it("GET on a missing key is 404", async () => {
    const harness = buildTestHarness();
    active = harness;
    const projectId = await createProject(harness, "p1");
    const res = await harness.app.fetch(
      new Request(`http://test/project/${projectId}/env/MISSING`),
    );
    expect(res.status).toBe(404);
  });

  it("rejects keys with disallowed characters", async () => {
    const harness = buildTestHarness();
    active = harness;
    const projectId = await createProject(harness, "p1");
    const res = await putEnv(harness, projectId, {
      key: "has space",
      value: "x",
      isSecret: false,
    });
    expect(res.status).toBe(400);
  });
});
