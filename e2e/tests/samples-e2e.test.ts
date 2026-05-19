// Real end-to-end: each samples/ project is applied + run through the
// Haskell `katari` CLI. The runtime is the api-server test harness
// bound to an ephemeral port; the binary speaks HTTP to it just like
// it would in production.
//
// Skipped when the katari binary is not available — local runs need
// `stack install katari` first. CI sets KATARI_BIN explicitly.

import { describe, expect, it, afterEach } from "vitest";
import { resolve } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { startHttpHarness } from "katari-api-server/tests/helpers.js";
import type { MockAgentHandler, RawValue } from "katari-runtime";

const SAMPLES_ROOT = resolve(__dirname, "../samples");

type HttpHarness = Awaited<ReturnType<typeof startHttpHarness>>;

let active: HttpHarness | null = null;
afterEach(async () => {
  if (active !== null) {
    await active.shutdown();
    active = null;
  }
});

function findKatariBinary(): string | null {
  const explicit = process.env.KATARI_BIN;
  if (explicit !== undefined && explicit.length > 0) {
    const r = spawnSync(explicit, ["--help"], { stdio: "ignore" });
    if (r.status === 0 || r.status === 1) return explicit;
  }
  const onPath = spawnSync("katari", ["--help"], { stdio: "ignore" });
  if (onPath.status === 0 || onPath.status === 1) return "katari";
  const stackPath = spawnSync("stack", ["path", "--local-install-root"], {
    encoding: "utf8",
    cwd: resolve(__dirname, "../.."),
  });
  if (stackPath.status === 0) {
    const root = stackPath.stdout.trim();
    const candidate = `${root}/bin/katari`;
    const probe = spawnSync(candidate, ["--help"], { stdio: "ignore" });
    if (probe.status === 0 || probe.status === 1) return candidate;
  }
  return null;
}

function findBundleScript(): string {
  // The bundler script lives alongside katari-bundle's compiled output.
  return resolve(__dirname, "../../typescript/packages/katari-bundle/dist/cli.js");
}

const RESOLVED_KATARI = findKatariBinary();
const RUN_E2E = RESOLVED_KATARI !== null;
const itE2E = RUN_E2E ? it : it.skip;

// Convention: every sample lives at `e2e/samples/<NN>-<name>` and its
// Katari package name is `<name>` with hyphens turned into underscores.
function packageNameFromSampleDir(sampleDir: string): string {
  return sampleDir.replace(/^\d+-/, "").replace(/-/g, "_");
}

interface SpawnResult {
  status: number | null;
  stdout: string;
  stderr: string;
}

function runKatari(args: string[], cwd: string): Promise<SpawnResult> {
  // Async spawn (not spawnSync) so the in-process Hono harness on the
  // same event loop can answer the binary's HTTP requests while we
  // wait for it to exit.
  return new Promise((resolveP, rejectP) => {
    const child = spawn(RESOLVED_KATARI!, args, {
      cwd,
      env: {
        ...process.env,
        KATARI_BUNDLE_BIN: findBundleScript(),
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString("utf8");
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", rejectP);
    child.on("close", (status) => resolveP({ status, stdout, stderr }));
  });
}

async function applyAndRun(
  _projectName: string,
  sampleDir: string,
  opts?: {
    handlers?: Record<string, MockAgentHandler>;
  },
): Promise<RawValue> {
  const harness = await startHttpHarness();
  active = harness;
  for (const [qname, fn] of Object.entries(opts?.handlers ?? {})) {
    harness.setHandler(qname, fn);
  }
  const sampleRoot = resolve(SAMPLES_ROOT, sampleDir);
  const pkg = packageNameFromSampleDir(sampleDir);

  // 1. katari apply
  const applyR = await runKatari(["apply", "--api-url", harness.url], sampleRoot);
  if (applyR.status !== 0) {
    throw new Error(
      `katari apply failed (status=${applyR.status})\nstdout:\n${applyR.stdout}\nstderr:\n${applyR.stderr}`,
    );
  }

  // 2. katari run --wait
  const runR = await runKatari(
    [
      "run",
      `${pkg}.main`,
      "--api-url",
      harness.url,
      "--project",
      pkg,
      "--wait",
    ],
    sampleRoot,
  );
  if (runR.status !== 0) {
    throw new Error(
      `katari run failed (status=${runR.status})\nstdout:\n${runR.stdout}\nstderr:\n${runR.stderr}`,
    );
  }
  const trimmed = runR.stdout.trim();
  if (trimmed === "") {
    throw new Error(`katari run produced no result stdout (stderr: ${runR.stderr})`);
  }
  return JSON.parse(trimmed) as RawValue;
}

describe("samples/ end-to-end (apply → run → verify)", () => {
  if (!RUN_E2E) {
    it.skip("katari binary not available — set KATARI_BIN or run `stack install katari`", () => {});
    return;
  }

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
    "08-metadata: get_metadata on top-level agent + local closure yields 'add_them|metadata.add_them|local_bar|closure:0'",
    async () => {
      const result = await applyAndRun("metadata", "08-metadata");
      expect(result).toBe("add_them|metadata.add_them|local_bar|closure:0");
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

  itE2E("11-ext-agent: extGreet returns 'hello, ext' via the MockSidecar registry", async () => {
    const result = await applyAndRun("ext-agent", "11-ext-agent", {
      handlers: {
        "ext_agent.extGreet": async ({ args }) => `hello, ${args.name as string}`,
      },
    });
    expect(result).toBe("hello, ext");
  });

  // 12-ext-cron exercises ipcChildDelegate which the MockSidecar
  // intentionally does not route. The full round-trip is exercised in
  // subprocess-sidecar.integration.test.ts against a real bundle.

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
        handlers: {
          "ext_throw_catch.boomExt": async () => {
            throw new Error("kaboom from JS");
          },
        },
      });
      expect(result).toBe("ext threw: kaboom from JS");
    },
  );

  itE2E(
    "16-multi-package: dep `list_utils` doubles 6 to 12 across packages",
    async () => {
      const result = await applyAndRun("multi-package", "16-multi-package");
      expect(result).toBe(12);
    },
  );
});
