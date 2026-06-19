import { NotImplementedError } from "../../lib/errors.js";
import { facade } from "../../runtime/facade.js";
import type { StartRunBody } from "./run.schema.js";

export const runService = {
  start(projectId: string, body: StartRunBody) {
    return facade.startRun({ projectId, ...body });
  },

  cancel(projectId: string, runId: string, reason?: string) {
    return facade.cancel({ projectId, runId, reason });
  },

  async list(_projectId: string) {
    throw new NotImplementedError("Listing runs is not implemented yet.");
  },

  async getById(_projectId: string, _runId: string) {
    throw new NotImplementedError("Fetching a run is not implemented yet.");
  },
};
