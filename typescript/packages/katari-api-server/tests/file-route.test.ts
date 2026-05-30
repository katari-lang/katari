// HTTP tests for /project/:projectId/file — upload, list (with ref
// envelope), get, delete, and per-project isolation. The `ref` field each
// response carries is the `$ref as:file` value an operator drops into a
// `file`-typed run argument, so its shape is asserted explicitly.

import { afterEach, describe, expect, it } from "vitest";
import type { ProjectId } from "../src/storage/types.js";
import { buildTestHarness, type TestHarness } from "./helpers.js";

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

type FileWire = {
  id: string;
  hash: string;
  size: number;
  contentType?: string;
  displayName?: string;
  createdAt: string;
  ref: { $ref: { module: string; id: string }; as: string; hash: string; size: number };
};

async function upload(
  harness: TestHarness,
  projectId: ProjectId,
  bytes: Uint8Array,
  opts?: { name?: string; contentType?: string },
): Promise<Response> {
  const qs = opts?.name !== undefined ? `?name=${encodeURIComponent(opts.name)}` : "";
  const headers: Record<string, string> = {};
  if (opts?.contentType !== undefined) headers["Content-Type"] = opts.contentType;
  return harness.app.fetch(
    new Request(`http://test/project/${projectId}/file${qs}`, {
      method: "POST",
      headers,
      body: bytes,
    }),
  );
}

describe("file routes", () => {
  it("upload → list → get, carrying a ready-to-use file ref", async () => {
    const harness = buildTestHarness();
    active = harness;
    const projectId = await createProject(harness, "p1");

    const res = await upload(harness, projectId, new TextEncoder().encode("hello"), {
      name: "greeting.txt",
      contentType: "text/plain",
    });
    expect(res.status).toBe(201);
    const { file } = (await res.json()) as { file: FileWire };
    expect(file.size).toBe(5);
    expect(file.displayName).toBe("greeting.txt");
    // The ref the client will hand to invoke: a file-kind value reference
    // pointing at the api module.
    expect(file.ref).toMatchObject({
      $ref: { module: "api", id: file.id },
      as: "file",
      hash: file.hash,
      size: 5,
    });

    const listRes = await harness.app.fetch(
      new Request(`http://test/project/${projectId}/file`),
    );
    const { files } = (await listRes.json()) as { files: FileWire[] };
    expect(files).toHaveLength(1);
    expect(files[0]!.id).toBe(file.id);

    const getRes = await harness.app.fetch(
      new Request(`http://test/project/${projectId}/file/${file.id}`),
    );
    expect(getRes.status).toBe(200);
    const got = (await getRes.json()) as { file: FileWire };
    expect(got.file.ref.as).toBe("file");
  });

  it("the uploaded bytes are fetchable through the data plane via the file ref", async () => {
    const harness = buildTestHarness();
    active = harness;
    const projectId = await createProject(harness, "p1");
    const res = await upload(harness, projectId, new TextEncoder().encode("payload"), {
      name: "p.bin",
    });
    const { file } = (await res.json()) as { file: FileWire };
    const bytesRes = await harness.app.fetch(
      new Request(`http://test/project/${projectId}/value/api/ref/${file.id}`),
    );
    expect(bytesRes.status).toBe(200);
    expect(await bytesRes.text()).toBe("payload");
  });

  it("rejects an empty upload body", async () => {
    const harness = buildTestHarness();
    active = harness;
    const projectId = await createProject(harness, "p1");
    const res = await upload(harness, projectId, new Uint8Array(0), { name: "empty" });
    expect(res.status).toBe(400);
  });

  it("DELETE removes a file; second delete is 404", async () => {
    const harness = buildTestHarness();
    active = harness;
    const projectId = await createProject(harness, "p1");
    const { file } = (await (
      await upload(harness, projectId, new TextEncoder().encode("x"), { name: "x" })
    ).json()) as { file: FileWire };
    const first = await harness.app.fetch(
      new Request(`http://test/project/${projectId}/file/${file.id}`, { method: "DELETE" }),
    );
    expect(first.status).toBe(200);
    const second = await harness.app.fetch(
      new Request(`http://test/project/${projectId}/file/${file.id}`, { method: "DELETE" }),
    );
    expect(second.status).toBe(404);
  });

  it("files are isolated per project", async () => {
    const harness = buildTestHarness();
    active = harness;
    const a = await createProject(harness, "alpha");
    const b = await createProject(harness, "beta");
    await upload(harness, a, new TextEncoder().encode("a-only"), { name: "a.txt" });

    const listB = (await (
      await harness.app.fetch(new Request(`http://test/project/${b}/file`))
    ).json()) as { files: FileWire[] };
    expect(listB.files).toHaveLength(0);
  });
});
