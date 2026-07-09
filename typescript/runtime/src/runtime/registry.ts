// ProjectRegistry: the process-global warm registry of per-project actors. It holds the
// `Map<projectId, ProjectActor>` (a project's actor is created lazily on first use and kept warm), the
// shared snapshot IR registry, and the cross-cutting dependencies (blob store, prim runner, persistence).
// The FFI transport is per-actor (each registers its own completion sink), so it comes from a factory.
//
// It does no command translation — that is the command surface's job (`facade`, the api root's issuing
// side); the registry only does lookup + lifecycle. Both the command surface and the read repositories
// reach a project's machinery through `actorFor`.

import type { IRModule } from "@katari-lang/types";
import { InMemoryPersistence, type Persistence } from "./actor/persistence.js";
import { ProjectActor } from "./actor/project-actor.js";
import type { PrimRunner } from "./engine/context.js";
import { PrimRegistry } from "./engine/prims.js";
import { type HttpTransport, StubHttpTransport } from "./external/http-transport.js";
import { type McpTransport, StubMcpTransport } from "./external/mcp-transport.js";
import { type FfiTransport, StubFfiTransport } from "./external/runner.js";
import type { ProjectId, SnapshotId } from "./ids.js";
import { type IrSource, SnapshotRegistry } from "./ir.js";
import { type BlobStore, InMemoryBlobStore } from "./value/blob-store.js";

export interface ProjectRegistryDependencies {
  /** The IR source (a DB-backed `DbIrSource` in the API; defaults to an in-memory registry for tests). */
  ir?: IrSource;
  /** The blob byte store (project-keyed). Defaults to in-memory. */
  blobs?: BlobStore;
  /** Persistence at the turn boundary. Defaults to the in-memory no-op seam. */
  persistence?: Persistence;
  /** The primitive runner (the host may register env / file prims on it). Defaults to the pure built-ins. */
  prims?: PrimRunner;
  /** Builds a fresh `FfiTransport` per project actor (each needs its own completion sink). Defaults to
   *  the stub (FFI fails loudly until a real subprocess-backed runner is injected). */
  externalFactory?: () => FfiTransport;
  /** Builds a fresh `HttpTransport` per project actor (each needs its own completion sink). Defaults to the
   *  stub (http fails loudly until a real `fetch`-backed transport is injected). */
  httpFactory?: () => HttpTransport;
  /** Builds a fresh `McpTransport` per project actor (each needs its own completion sink). Defaults to
   *  the stub (mcp fails loudly until the SDK-backed transport is injected). */
  mcpFactory?: () => McpTransport;
  /** The public base URL webhook endpoints are minted under. Defaults to the local dev address. */
  webhookBaseUrl?: string;
}

export class ProjectRegistry {
  private readonly ir: IrSource;
  private readonly actors = new Map<ProjectId, ProjectActor>();

  private readonly blobs: BlobStore;
  private readonly persistence: Persistence;
  private readonly prims: PrimRunner;
  private readonly externalFactory: () => FfiTransport;
  private readonly httpFactory: () => HttpTransport;
  private readonly mcpFactory: () => McpTransport;
  private readonly webhookBaseUrl: string;

  constructor(dependencies: ProjectRegistryDependencies = {}) {
    this.ir = dependencies.ir ?? new SnapshotRegistry();
    this.blobs = dependencies.blobs ?? new InMemoryBlobStore();
    this.persistence = dependencies.persistence ?? new InMemoryPersistence();
    this.prims = dependencies.prims ?? new PrimRegistry();
    this.externalFactory = dependencies.externalFactory ?? (() => new StubFfiTransport());
    this.httpFactory = dependencies.httpFactory ?? (() => new StubHttpTransport());
    this.mcpFactory = dependencies.mcpFactory ?? (() => new StubMcpTransport());
    this.webhookBaseUrl = dependencies.webhookBaseUrl ?? "http://localhost:3000";
  }

  /** Register one module's IR within a snapshot — only on the default in-memory source (tests); the
   *  DB-backed source loads modules itself. */
  registerModule(snapshot: SnapshotId, module: string, ir: IRModule): void {
    if (!(this.ir instanceof SnapshotRegistry)) {
      throw new Error("registerModule is only available on the in-memory IR source");
    }
    this.ir.set(snapshot, module, ir);
  }

  /** The warm actor for a project, created (and kept) on first use. The command surface and the read
   *  repositories both reach a project's engine through this. */
  actorFor(projectId: ProjectId): ProjectActor {
    const existing = this.actors.get(projectId);
    if (existing !== undefined) return existing;
    const actor = new ProjectActor({
      projectId,
      ir: this.ir,
      prims: this.prims,
      blobs: this.blobs,
      external: this.externalFactory(),
      http: this.httpFactory(),
      mcp: this.mcpFactory(),
      webhookBaseUrl: this.webhookBaseUrl,
      persistence: this.persistence,
    });
    this.actors.set(projectId, actor);
    return actor;
  }

  /** Drop a project's warm actor and tear it down (the project is being deleted): its sidecar processes are
   *  killed and its in-process run promises rejected. A no-op when the project was never warmed. */
  evict(projectId: ProjectId): void {
    const actor = this.actors.get(projectId);
    if (actor === undefined) return;
    this.actors.delete(projectId);
    actor.dispose();
  }
}
