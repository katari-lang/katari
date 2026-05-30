// ProjectActorHost — the thin proxy that owns the warm per-project actors.
//
// A process holds one host; the host holds one {@link ProjectActor} per
// project, created on first touch and kept warm thereafter. The host's only
// jobs are (1) get-or-create the actor for a project and (2) run a quantum on
// it. It holds no transaction, no lock, and knows nothing about snapshots,
// sidecars, or storage — those are module-private concerns wired by the
// concrete host package (api-server) via the `buildModules` factory and its own
// sidecar message routing.

import type { Logger } from "../engine/logger.js";
import {
  ProjectActor,
  type ProjectActorContext,
  type ProjectActorModules,
} from "./project-actor.js";

export class ProjectActorHost<M extends ProjectActorModules = ProjectActorModules> {
  private readonly actors = new Map<string, ProjectActor<M>>();

  /**
   * @param buildModules constructs the warm module bundle for a project. Called
   *        once per project (the modules then live as long as the host). Module
   *        state loads lazily inside the first `feed`, so this is synchronous.
   */
  constructor(
    private readonly buildModules: (projectId: string) => M,
    private readonly logger: Logger,
  ) {}

  /** Get-or-create the warm actor for `projectId`. */
  forProject(projectId: string): ProjectActor<M> {
    let actor = this.actors.get(projectId);
    if (actor === undefined) {
      actor = new ProjectActor<M>(this.logger, this.buildModules(projectId));
      this.actors.set(projectId, actor);
    }
    return actor;
  }

  /** Convenience: get-or-create the actor and run one serialized quantum on it. */
  run<T>(projectId: string, fn: (ctx: ProjectActorContext<M>) => Promise<T>): Promise<T> {
    return this.forProject(projectId).run(fn);
  }

  /** Project ids with a resident actor (for diagnostics / shutdown). */
  activeProjects(): string[] {
    return [...this.actors.keys()];
  }
}
