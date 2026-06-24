// RuntimeHost: the in-memory core's composition root. It holds the warm `Map<projectId, ProjectActor>`
// (a project's actor is created lazily on its first run and stays warm), the shared snapshot IR
// registry, and the cross-cutting dependencies (blob store, prim runner, persistence). The external
// runner is per-actor (each registers its own completion sink), so it comes from a factory. This is the
// single object the HTTP service layer drives once it lands (facade.startRun -> host.startRun); deploy
// registers a snapshot's IR via `registerSnapshot`. v0.1.0 wires it to the in-memory seams by default.

import type { IRModule, QualifiedName } from "@katari-lang/types";
import { InMemoryPersistence, type Persistence } from "./actor/persistence.js";
import { ProjectActor } from "./actor/project-actor.js";
import type { PrimRunner } from "./engine/context.js";
import { PrimRegistry } from "./engine/prims.js";
import { type ExternalRunner, StubExternalRunner } from "./external/runner.js";
import type { DelegationId, EscalationId, ProjectId, SnapshotId } from "./ids.js";
import { type IrSource, SnapshotRegistry } from "./ir.js";
import { type BlobStore, InMemoryBlobStore } from "./value/blob-store.js";
import type { Value } from "./value/types.js";

export interface RuntimeHostDependencies {
  /** The IR source (a DB-backed `DbIrSource` in the API; defaults to an in-memory registry for tests). */
  ir?: IrSource;
  /** The blob byte store (project-keyed). Defaults to in-memory. */
  blobs?: BlobStore;
  /** Persistence at the turn boundary. Defaults to the in-memory no-op seam. */
  persistence?: Persistence;
  /** The primitive runner (the host may register env / file prims on it). Defaults to the pure built-ins. */
  prims?: PrimRunner;
  /** Builds a fresh `ExternalRunner` per project actor (each needs its own completion sink). Defaults to
   *  the stub (FFI fails loudly until a real subprocess-backed runner is injected). */
  externalFactory?: () => ExternalRunner;
}

export class RuntimeHost {
  private readonly ir: IrSource;
  private readonly actors = new Map<ProjectId, ProjectActor>();

  private readonly blobs: BlobStore;
  private readonly persistence: Persistence;
  private readonly prims: PrimRunner;
  private readonly externalFactory: () => ExternalRunner;

  constructor(dependencies: RuntimeHostDependencies = {}) {
    this.ir = dependencies.ir ?? new SnapshotRegistry();
    this.blobs = dependencies.blobs ?? new InMemoryBlobStore();
    this.persistence = dependencies.persistence ?? new InMemoryPersistence();
    this.prims = dependencies.prims ?? new PrimRegistry();
    this.externalFactory = dependencies.externalFactory ?? (() => new StubExternalRunner());
  }

  /** Register one module's IR within a snapshot — only on the default in-memory source (tests); the
   *  DB-backed source loads modules itself. */
  registerModule(snapshot: SnapshotId, module: string, ir: IRModule): void {
    if (!(this.ir instanceof SnapshotRegistry)) {
      throw new Error("registerModule is only available on the in-memory IR source");
    }
    this.ir.set(snapshot, module, ir);
  }

  /** Start a run on a project. Returns its `runId` — the run delegation id, which is the durable handle
   *  (`runs.id`, the join key to its Layer 1 outcome) — plus an in-process `result` promise that settles
   *  with the run's value (the durable outcome lives in the delegation, so the promise is a convenience for
   *  in-process callers, not the source of truth). */
  startRun(
    projectId: ProjectId,
    qualifiedName: QualifiedName,
    snapshot: SnapshotId,
    argument: Value | null,
  ): { runId: string; result: Promise<Value> } {
    const { run, result } = this.actorFor(projectId).startRun(qualifiedName, snapshot, argument);
    return { runId: run, result };
  }

  /** Request a run's cancellation. `runId` is the run delegation id; a terminate is produced for it (a
   *  no-op in the engine if the run already finished). */
  cancelRun(projectId: ProjectId, runId: string, reason?: string): void {
    this.actorFor(projectId).cancelRun(runId as DelegationId, reason);
  }

  /** Answer an open run-root escalation on a project, resuming the suspended run. */
  answerEscalation(projectId: ProjectId, escalation: EscalationId, value: Value): void {
    this.actorFor(projectId).answerEscalation(escalation, value);
  }

  /** The warm actor for a project, created (and kept) on first use. */
  private actorFor(projectId: ProjectId): ProjectActor {
    const existing = this.actors.get(projectId);
    if (existing !== undefined) return existing;
    const actor = new ProjectActor({
      projectId,
      ir: this.ir,
      prims: this.prims,
      blobs: this.blobs,
      external: this.externalFactory(),
      persistence: this.persistence,
    });
    this.actors.set(projectId, actor);
    return actor;
  }
}
