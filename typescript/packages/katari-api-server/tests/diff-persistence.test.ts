// Phase G: verifies that engine `Diff[]` is appended to the storage
// diff log alongside snapshot.upsert during applyEvent transactions.
//
// We don't yet replay diffs on recovery — that's a future revision.
// This test only confirms the persistence pipeline is wired.

import { describe, expect, it } from "vitest";
import { noopLogger } from "katari-runtime";
import {
  AgentService,
  buildApp,
  InMemoryStorage,
  MachineRegistry,
  ModuleService,
} from "../src/index.js";
import { literalReturnIR, trivialSchemaBundle } from "./helpers.js";

describe("Phase G: diff persistence", () => {
  it("appends Diff[] to storage.diffs.list when an agent runs", async () => {
    const storage = new InMemoryStorage();
    const logger = noopLogger;
    const registry = new MachineRegistry(storage, logger);
    const modules = new ModuleService(storage, logger);
    const agents = new AgentService(storage, registry, logger);
    const app = buildApp({ modules, agents, apiKey: null, rateLimit: null });

    const upload = await app.fetch(
      new Request("http://test/module", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          irModule: literalReturnIR("hello"),
          schemaBundle: trivialSchemaBundle(),
        }),
      }),
    );
    const { versionId } = (await upload.json()) as { versionId: string };

    await app.fetch(
      new Request("http://test/agent", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ versionId, qualifiedName: "main", args: {} }),
      }),
    );

    const diffs = await storage.diffs.list(versionId as never);
    expect(diffs.length).toBeGreaterThan(0);
    // Diff op kinds we expect to see for a trivial agent: thread.create
    // (root user thread), scope.set (literal load), thread.delete (root
    // completion).
    const ops = new Set(diffs.map((d) => d.op));
    expect(ops.has("thread.create")).toBe(true);
  });

  it("delete clears the diff log", async () => {
    const storage = new InMemoryStorage();
    await storage.diffs.append(
      "v" as never,
      [{ op: "thread.delete", threadId: "t" as never }],
    );
    expect(await storage.diffs.list("v" as never)).toHaveLength(1);
    await storage.diffs.delete("v" as never);
    expect(await storage.diffs.list("v" as never)).toHaveLength(0);
  });
});
