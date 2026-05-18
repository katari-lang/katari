// Shared fixtures for api-server tests.
//
// 新設計向け: project + snapshot を upload するヘルパと、orchestrator + bus
// を含むテスト用 app を作るヘルパを提供する。

import {
  MockSidecar,
  SidecarManager,
  noopLogger,
  type IRModule,
  type MockAgentHandler,
  type SchemaBundle,
  type Sidecar,
  type SidecarBundle,
} from "katari-runtime";
import type { Block, VarId } from "katari-runtime/dist/ir/types.js";
import {
  InMemoryStorage,
  Orchestrator,
  ProjectService,
  SnapshotService,
  buildApp,
  type AppDeps,
} from "../src/index.js";
import type { SnapshotId } from "../src/storage/types.js";
import type { Hono } from "hono";

// ─── IR fixtures ───────────────────────────────────────────────────────────

export function literalReturnIR(literal: string, irName = "test"): IRModule {
  const blocks: Record<number, Block> = {
    0: {
      kind: "blockAgent",
      body: {
        qualifiedName: irName === "" ? "main" : `${irName}.main`,
        parameters: [],
        entryBody: 1,
        name: "main",
        description: undefined,
        inputSchema: "{}",
        outputSchema: '{"type":"string"}',
      },
    },
    1: {
      kind: "blockUser",
      body: {
        parameters: [],
        statements: [
          {
            kind: "statementLoadLiteral",
            body: {
              output: 0 as VarId,
              value: { kind: "literalValueString", string: literal },
            },
          },
          {
            kind: "statementExit",
            body: { exitKind: "exitKindReturn", value: 0 as VarId },
          },
        ],
      },
    },
  };
  return {
    metadata: { schemaVersion: 1 },
    blocks: Object.fromEntries(
      Object.entries(blocks).map(([k, v]) => [k, v]),
    ),
    entries: { main: 0 },
    nameTable: { varNames: {}, blockNames: {} },
  };
}

export function pausesOnExternalIR(irName = "test"): IRModule {
  const blocks: Record<number, Block> = {
    0: {
      kind: "blockAgent",
      body: {
        qualifiedName: irName === "" ? "main" : `${irName}.main`,
        parameters: [],
        entryBody: 1,
        name: "main",
        description: undefined,
        inputSchema: "{}",
        outputSchema: "{}",
      },
    },
    1: {
      kind: "blockUser",
      body: {
        parameters: [],
        statements: [
          {
            kind: "statementCall",
            body: {
              target: { kind: "callTargetBlock", block: 2 },
              arguments: [],
              output: 0 as VarId,
            },
          },
          {
            kind: "statementExit",
            body: { exitKind: "exitKindReturn", value: 0 as VarId },
          },
        ],
      },
    },
    2: {
      kind: "blockExternal",
      body: irName === "" ? "ext_call" : `${irName}.ext_call`,
    },
  };
  return {
    metadata: { schemaVersion: 1 },
    blocks: Object.fromEntries(
      Object.entries(blocks).map(([k, v]) => [k, v]),
    ),
    entries: { main: 0 },
    nameTable: { varNames: {}, blockNames: {} },
  };
}

export function trivialSchemaBundle(): SchemaBundle {
  return {
    schemaVersion: 1,
    agents: [
      {
        qualifiedName: "test.main",
        parameters: { type: "object", properties: {} },
        returns: { type: "string" },
        description: "Returns a greeting",
      },
    ],
  };
}

/** Trivially-valid sidecar bundle for snapshots that don't need FFI. */
export function noOpSidecarBundle(): SidecarBundle {
  return {
    entry: "exports.invoke = async () => ({ kind: 'null' });",
    runtime: "node",
    schemaVersion: 1,
  };
}

// ─── Test harness ──────────────────────────────────────────────────────────

export type TestHarness = {
  storage: InMemoryStorage;
  app: Hono;
  orchestrator: Orchestrator;
  shutdown: () => Promise<void>;
};

/**
 * Build a test harness wired with `InMemoryStorage` and `MockSidecar`
 * (factory-driven from a shared handler map). Use `setHandler(qname, fn)`
 * to register sidecar invokes for a specific test.
 */
export function buildTestHarness(opts?: {
  ffiHandlers?: Record<string, MockAgentHandler>;
}): TestHarness & {
  setHandler: (qname: string, handler: MockAgentHandler) => void;
} {
  const handlers = new Map<string, MockAgentHandler>(
    Object.entries(opts?.ffiHandlers ?? {}),
  );
  // Track every live MockSidecar that this harness produces so external
  // setHandler() calls reach already-running sidecars too. Practically
  // a harness owns at most one or two sidecars (one per snapshot), but
  // a Set keeps the bookkeeping uniform.
  const liveSidecars = new Set<MockSidecar>();
  const storage = new InMemoryStorage();
  const sidecarManager = new SidecarManager<SnapshotId>(
    (_key, _bundle, sidecarLogger): Sidecar | null => {
      const mock = new MockSidecar({ logger: sidecarLogger });
      for (const [k, v] of handlers.entries()) mock.setHandler(k, v);
      liveSidecars.add(mock);
      return mock;
    },
    noopLogger,
  );
  const orchestrator = new Orchestrator(storage, sidecarManager, noopLogger);
  const projects = new ProjectService(storage, noopLogger);
  const snapshots = new SnapshotService(storage, noopLogger);
  const deps: AppDeps = {
    storage,
    projects,
    snapshots,
    orchestrator,
    apiKey: null,
    rateLimit: null,
  };
  const app = buildApp(deps);
  return {
    storage,
    app,
    orchestrator,
    setHandler(qname, handler) {
      handlers.set(qname, handler);
      for (const mock of liveSidecars) mock.setHandler(qname, handler);
    },
    async shutdown() {
      await sidecarManager.shutdown();
      liveSidecars.clear();
    },
  };
}

/** Convenience: upsert project + upload snapshot, return snapshotId. */
export async function uploadSnapshot(
  harness: TestHarness,
  projectName: string,
  irModule: IRModule,
  schemaBundle: SchemaBundle,
  sidecarBundle: SidecarBundle | null = null,
): Promise<{ projectId: string; snapshotId: string }> {
  const projectResp = await harness.app.fetch(
    new Request("http://test/project", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: projectName }),
    }),
  );
  const projectBody = (await projectResp.json()) as { project: { id: string } };
  const projectId = projectBody.project.id;
  const snapResp = await harness.app.fetch(
    new Request(`http://test/project/${projectId}/snapshot`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ irModule, sidecarBundle, schemaBundle }),
    }),
  );
  const snapBody = (await snapResp.json()) as { snapshotId: string };
  return { projectId, snapshotId: snapBody.snapshotId };
}
