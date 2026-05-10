// Project CRUD service. Thin wrapper around `ProjectRepo` so HTTP
// routes can depend on a service rather than the storage layer.

import type { Logger } from "katari-runtime";
import type {
  ListOptions,
  Project,
  ProjectId,
  Storage,
} from "../storage/types.js";

export class ProjectNotFound extends Error {
  constructor(public readonly projectId: ProjectId) {
    super(`project ${projectId} does not exist`);
  }
}

export class ProjectService {
  constructor(
    private readonly storage: Storage,
    private readonly logger: Logger,
  ) {}

  async upsertByName(name: string): Promise<Project> {
    const project = await this.storage.projects.upsertByName(name);
    this.logger.log("info", "project upsert", {
      projectId: project.id,
      name: project.name,
    });
    return project;
  }

  list(options?: ListOptions): Promise<Project[]> {
    return this.storage.projects.list(options);
  }

  async get(id: ProjectId): Promise<Project> {
    const project = await this.storage.projects.get(id);
    if (project === null) throw new ProjectNotFound(id);
    return project;
  }

  async getByName(name: string): Promise<Project | null> {
    return this.storage.projects.getByName(name);
  }
}
