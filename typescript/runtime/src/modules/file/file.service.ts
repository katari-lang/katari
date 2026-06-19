import { NotImplementedError } from "../../lib/errors.js";

export const fileService = {
  async upload(_projectId: string) {
    throw new NotImplementedError("File upload is not implemented yet (blob store pending).");
  },

  async list(_projectId: string) {
    throw new NotImplementedError("Listing files is not implemented yet.");
  },

  async download(_projectId: string, _fileId: string) {
    throw new NotImplementedError("File download is not implemented yet (blob store pending).");
  },

  async delete(_projectId: string, _fileId: string) {
    throw new NotImplementedError("Deleting a file is not implemented yet.");
  },
};
