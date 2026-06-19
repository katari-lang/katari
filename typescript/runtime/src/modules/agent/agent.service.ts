import { NotImplementedError } from "../../lib/errors.js";

export const agentService = {
  async list(_projectId: string, _snapshotId?: string) {
    throw new NotImplementedError("Listing agents is not implemented yet.");
  },

  async getByName(_projectId: string, _qualifiedName: string, _snapshotId?: string) {
    throw new NotImplementedError("Fetching an agent schema is not implemented yet.");
  },
};
