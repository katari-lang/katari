// Shared fixtures for api-server tests.
//
// 新設計向け: project + snapshot を upload するヘルパと、orchestrator + bus
// を含むテスト用 app を作るヘルパを提供する。

import {
  InProcessSidecar,
  SidecarManager,
  noopLogger,
  type IRModule,
  type InProcessHandler,
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
        qualifiedName: { module_: irName, name: "main" },
        parameters: [],
        entryBody: 1,
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
    name: irName,
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
        qualifiedName: { module_: irName, name: "main" },
        parameters: [],
        entryBody: 1,
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
      body: { module_: irName, name: "ext_call" },
    },
  };
  return {
    metadata: { schemaVersion: 1 },
    name: irName,
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
        qualifiedName: { module_: "test", name: "main" },
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
 * Build a test harness wired with `InMemoryStorage` and `InProcessSidecar`
 * (factory-driven from a shared handler map). Use `setHandler(qname, fn)`
 * to register sidecar invokes for a specific test.
 */
export function buildTestHarness(opts?: {
  ffiHandlers?: Record<string, InProcessHandler>;
}): TestHarness & {
  setHandler: (qname: string, handler: InProcessHandler) => void;
} {
  const handlers = new Map<string, InProcessHandler>(
    Object.entries(opts?.ffiHandlers ?? {}),
  );
  const storage = new InMemoryStorage();
  const sidecarManager = new SidecarManager<SnapshotId>(
    (_key, _bundle, sidecarLogger): Sidecar | null => {
      const dispatch: InProcessHandler = async (input) => {
        const decoded = input.agentDefId as {
          kind: string;
          value: { module_: string; name: string };
        };
        const key =
          decoded.value.module_ === ""
            ? decoded.value.name
            : `${decoded.value.module_}.${decoded.value.name}`;
        const handler = handlers.get(key);
        if (handler === undefined) {
          throw new Error(`no test handler registered for ${key}`);
        }
        return handler(input);
      };
      return new InProcessSidecar(dispatch, sidecarLogger);
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
    },
    async shutdown() {
      await sidecarManager.shutdown();
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
