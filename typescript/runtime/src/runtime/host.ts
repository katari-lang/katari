// RuntimeHost: the in-memory core's composition root. It holds the warm `Map<projectId, ProjectActor>`
// (a project's actor is created lazily on its first run and stays warm), the shared snapshot IR
// registry, and the cross-cutting dependencies (blob store, prim runner, persistence). The external
// runner is per-actor (each registers its own completion sink), so it comes from a factory. This is the
// single object the HTTP service layer drives once it lands (facade.startRun -> host.startRun); deploy
// registers a snapshot's IR via `registerSnapshot`. v0.1.0 wires it to the in-memory seams by default.

import type { IRModule, QualifiedName } from "@katari-lang/types";
import { InMemoryPersistence, type Persistence } from "./actor/persistence.js";
import { type OpenEscalation, ProjectActor } from "./actor/project-actor.js";
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
  /** A live run's engine handle (its run delegation), keyed by the durable run id — so a later cancel /
   *  status call routes to the right actor + delegation. Cleared when the run settles. */
  private readonly runs = new Map<string, { projectId: ProjectId; run: DelegationId }>();

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

  /** Start a run on a project and resolve with its result value. `runId` is the caller's durable handle
   *  (the `runs` row id); the host remembers it so `cancelRun` can later reach the run's engine delegation. */
  startRun(
    projectId: ProjectId,
    runId: string,
    qualifiedName: QualifiedName,
    snapshot: SnapshotId,
    argument: Value | null,
  ): Promise<Value> {
    const { run, result } = this.actorFor(projectId).startRun(qualifiedName, snapshot, argument);
    this.runs.set(runId, { projectId, run });
    const forget = (): void => {
      this.runs.delete(runId);
    };
    void result.then(forget, forget); // drop the handle once the run settles (resolved, failed, cancelled)
    return result;
  }

  /** Request a run's cancellation (a no-op if it already settled, is unknown to this warm host, or belongs
   *  to a different project). */
  cancelRun(projectId: ProjectId, runId: string, reason?: string): void {
    const entry = this.runs.get(runId);
    if (entry === undefined || entry.projectId !== projectId) return;
    this.actorFor(projectId).cancelRun(entry.run, reason);
  }

  /** Answer an open run-root escalation on a project, resuming the suspended run. */
  answerEscalation(projectId: ProjectId, escalation: EscalationId, value: Value): void {
    this.actorFor(projectId).answerEscalation(escalation, value);
  }

  /** The run-root escalations on a project awaiting an answer. */
  listOpenEscalations(projectId: ProjectId): OpenEscalation[] {
    return this.actorFor(projectId).listOpenEscalations();
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
