// End-to-end test that runs IR produced by the Haskell compiler against
// the TS runtime. This is the load-bearing test for the schema contract
// between the two halves of the project — if the Aeson encoding diverges
// from the TS mirror, this test is the one that catches it.
//
// Fixtures live in `tests/fixtures/` and are copied verbatim from the
// Haskell side's golden-test outputs at
// `haskell/katari-compiler/test/golden/expected/*.ir.json`. There is no
// build-time mechanism that re-syncs them automatically yet (Plan C1
// notes a CI step as the right next move); when adding a compiler-side
// schema change, copy the new fixture in by hand and update the
// expectations below.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { noopLogger, type IRModule } from "katari-runtime";
import {
  AgentService,
  buildApp,
  InMemoryStorage,
  MachineRegistry,
  ModuleService,
} from "../src/index.js";

const FIXTURES_DIR = join(
  dirname(fileURLToPath(import.meta.url)),
  "fixtures",
);

function loadIR(filename: string): IRModule {
  const raw = readFileSync(join(FIXTURES_DIR, filename), "utf-8");
  return JSON.parse(raw) as IRModule;
}

function loadSchema(filename: string): unknown {
  const raw = readFileSync(join(FIXTURES_DIR, filename), "utf-8");
  return JSON.parse(raw);
}

describe("compiler IR round-trip (golden fixture)", () => {
  it("01-hello-agent: starting `main.main` returns 'hello, world'", async () => {
    const irModule = loadIR("01-hello-agent.ir.json");
    const schemaBundle = loadSchema("01-hello-agent.schema.json");

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
        body: JSON.stringify({ irModule, schemaBundle }),
      }),
    );
    expect(upload.status).toBe(201);
    const { versionId } = (await upload.json()) as { versionId: string };

    // The compiler emits qualifiedNames as "<module>.<name>"; the source
    // is `agent main()` inside module `main`, so the entry key is
    // "main.main".
    const start = await app.fetch(
      new Request("http://test/agent", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          versionId,
          qualifiedName: "main.main",
          args: {},
        }),
      }),
    );
    expect(start.status).toBe(201);
    const { agentId } = (await start.json()) as { agentId: string };

    const got = await app.fetch(new Request(`http://test/agent/${agentId}`));
    const row = (await got.json()) as {
      state: string;
      result?: { kind: string; value: string };
    };
    expect(row.state).toBe("succeeded");
    expect(row.result).toEqual({ kind: "string", value: "hello, world" });
  });
});
