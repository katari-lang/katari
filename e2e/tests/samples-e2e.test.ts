// Real end-to-end: each samples/ project is compiled via the actual
// katari-compiler binary (= subprocess) and then run against an
// in-memory api-server harness. The result of `main()` is asserted.
//
// Skipped when the katari-compiler binary is not available on PATH /
// KATARI_COMPILER_BIN — local test runs need `stack install
// katari-compiler` first; CI will set the env var explicitly.

import { describe, expect, it, afterEach } from "vitest";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { ApiClient } from "katari-cli/services/api-client";
import { compile } from "katari-cli/services/compile";
import {
  buildTestHarness,
  noOpSidecarBundle,
  trivialSchemaBundle,
  type TestHarness,
} from "katari-api-server/tests/helpers.js";
import type { Hono } from "hono";
import type { MockAgentHandler, RawValue, SidecarBundle } from "katari-runtime";

const SAMPLES_ROOT = resolve(__dirname, "../samples");

let active: TestHarness | null = null;
afterEach(async () => {
  if (active !== null) {
    await active.shutdown();
    active = null;
  }
});

function clientFor(app: Hono): ApiClient {
  const shim = async (input: Request | URL | string, init?: RequestInit) => {
    const req = input instanceof Request ? input : new Request(input, init);
    return await app.fetch(req);
  };
  return new ApiClient({ baseUrl: "http://test" }).withFetch(shim);
}

function findCompilerBinary(): string | null {
  // 1. Explicit env override.
  const explicit = process.env.KATARI_COMPILER_BIN;
  if (explicit !== undefined && explicit.length > 0) {
    const r = spawnSync(explicit, ["--help"], { stdio: "ignore" });
    if (r.status === 0 || r.status === 1) return explicit;
  }
  // 2. Bare `katari-compiler` on PATH.
  const onPath = spawnSync("katari-compiler", ["--help"], { stdio: "ignore" });
  if (onPath.status === 0 || onPath.status === 1) return "katari-compiler";
  // 3. Auto-resolve via `stack path --local-install-root`.
  const stackPath = spawnSync("stack", ["path", "--local-install-root"], {
    encoding: "utf8",
    cwd: resolve(__dirname, "../.."),
  });
  if (stackPath.status === 0) {
    const root = stackPath.stdout.trim();
    const candidate = `${root}/bin/katari-compiler`;
    const probe = spawnSync(candidate, ["--help"], { stdio: "ignore" });
    if (probe.status === 0 || probe.status === 1) return candidate;
  }
  return null;
}

const RESOLVED_COMPILER = findCompilerBinary();
if (RESOLVED_COMPILER !== null) {
  process.env.KATARI_COMPILER_BIN = RESOLVED_COMPILER;
}
const RUN_E2E = RESOLVED_COMPILER !== null;
const itE2E = RUN_E2E ? it : it.skip;

async function applyAndRun(
  projectName: string,
  sampleDir: string,
  opts?: {
    sidecarBundle?: SidecarBundle | null;
    handlers?: Record<string, MockAgentHandler>;
  },
): Promise<RawValue> {
  const harness = buildTestHarness();
  active = harness;
  for (const [qname, fn] of Object.entries(opts?.handlers ?? {})) {
    harness.setHandler(qname, fn);
  }
  const api = clientFor(harness.app);

  const project = await api.upsertProject(projectName);
  const { irModule, schemaBundle } = await compile({
    srcPath: resolve(SAMPLES_ROOT, sampleDir, "src"),
  });
  const { snapshotId } = await api.uploadSnapshot({
    projectId: project.id,
    irModule,
    sidecarBundle: opts?.sidecarBundle ?? null,
    schemaBundle: schemaBundle ?? trivialSchemaBundle(),
  });

  const { agentId } = await api.startAgent({
    projectId: project.id,
    snapshotId,
    qualifiedName: "main.main",
    args: {},
  });

  // Most samples finalize within startAgent's tick; ext-agent samples
  // resume in a follow-up tick once the sidecar acks. Poll briefly.
  const deadline = Date.now() + 5000;
  let row = await api.getAgent(agentId);
  while (row.state === "running" && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 10));
    row = await api.getAgent(agentId);
  }
  if (row.state !== "succeeded") {
    throw new Error(
      `agent state was '${row.state}' (errorMessage: ${row.errorMessage ?? "<none>"})`,
    );
  }
  if (row.result === undefined) {
    throw new Error("agent succeeded but produced no result");
  }
  return row.result;
}

describe("samples/ end-to-end (compile → upload → run → verify)", () => {
  if (!RUN_E2E) {
    it.skip("katari-compiler binary not available — set KATARI_COMPILER_BIN or run `stack install katari-compiler`", () => {});
    return;
  }

  // API server returns the agent result in raw form
  // (`valueToRaw`-encoded), so primitives land as bare JSON values.

  itE2E("01-hello: main() returns 'hello, world'", async () => {
    const result = await applyAndRun("hello", "01-hello");
    expect(result).toBe("hello, world");
  });

  itE2E("02-arithmetic: main() returns 5", async () => {
    const result = await applyAndRun("arithmetic", "02-arithmetic");
    expect(result).toBe(5);
  });

  itE2E("03-data-and-match: main() returns 7", async () => {
    const result = await applyAndRun("data-and-match", "03-data-and-match");
    expect(result).toBe(7);
  });

  itE2E("04-agent-value: main() returns 42 (exercises agentLiteral)", async () => {
    const result = await applyAndRun("agent-value", "04-agent-value");
    expect(result).toBe(42);
  });

  itE2E("05-control-flow: main() returns 'positive'", async () => {
    const result = await applyAndRun("control-flow", "05-control-flow");
    expect(result).toBe("positive");
  });

  itE2E("06-for-and-fstring: main() returns 'sum = 6'", async () => {
    const result = await applyAndRun("for-and-fstring", "06-for-and-fstring");
    expect(result).toBe("sum = 6");
  });

  itE2E("07-abs-and-mod: manhattan with negative literals + mod = 11", async () => {
    const result = await applyAndRun("abs-and-mod", "07-abs-and-mod");
    expect(result).toBe(11);
  });

  itE2E(
    "08-metadata: get_metadata on top-level agent + local closure yields 'add_them|main.add_them|local_bar|closure:0'",
    async () => {
      const result = await applyAndRun("metadata", "08-metadata");
      expect(result).toBe("add_them|main.add_them|local_bar|closure:0");
    },
  );

  itE2E(
    "09-req-handler: three ticks under a stateful handler sum to 6",
    async () => {
      const result = await applyAndRun("req-handler", "09-req-handler");
      expect(result).toBe(6);
    },
  );

  itE2E(
    "10-tuple-pattern: (integer, string) tuple destructured via match returns '42 with hello'",
    async () => {
      const result = await applyAndRun("tuple-pattern", "10-tuple-pattern");
      expect(result).toBe("42 with hello");
    },
  );

  itE2E(
    "11-ext-agent: extGreet returns 'hello, ext' via the MockSidecar registry",
    async () => {
      const result = await applyAndRun("ext-agent", "11-ext-agent", {
        // Non-null bundle so the orchestrator wires up the sidecar
        // factory; MockSidecar ignores `entry` content and looks up
        // handlers by qname via setHandler.
        sidecarBundle: noOpSidecarBundle(),
        handlers: {
          "main.extGreet": async ({ args }) => {
            const name = args["name"] as string;
            return `hello, ${name}`;
          },
        },
      });
      expect(result).toBe("hello, ext");
    },
  );

  itE2E(
    "13-throw-catch: explicit throw caught by handle scope returns 'caught: kaboom!'",
    async () => {
      const result = await applyAndRun("throw-catch", "13-throw-catch");
      expect(result).toBe("caught: kaboom!");
    },
  );

  itE2E(
    "14-runtime-error: prim div-by-zero caught by handle scope returns 'engine threw: prim div: division by zero'",
    async () => {
      const result = await applyAndRun("runtime-error", "14-runtime-error");
      expect(result).toBe("engine threw: prim div: division by zero");
    },
  );

  itE2E(
    "15-ext-throw-catch: ext handler throw caught by handle scope returns 'ext threw: kaboom from JS'",
    async () => {
      const result = await applyAndRun("ext-throw-catch", "15-ext-throw-catch", {
        sidecarBundle: noOpSidecarBundle(),
        handlers: {
          "main.boomExt": async () => {
            throw new Error("kaboom from JS");
          },
        },
      });
      expect(result).toBe("ext threw: kaboom from JS");
    },
  );
});
