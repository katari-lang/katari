import { NotImplementedError } from "../../lib/errors.js";
import type { SetEnvBody } from "./env.schema.js";

export const envService = {
  async list(_projectId: string) {
    throw new NotImplementedError("Listing env entries is not implemented yet.");
  },

  async get(_projectId: string, _key: string) {
    throw new NotImplementedError("Reading an env entry is not implemented yet.");
  },

  async set(_projectId: string, _key: string, _body: SetEnvBody) {
    throw new NotImplementedError(
      "Setting an env entry is not implemented yet (secret encryption pending).",
    );
  },

  async delete(_projectId: string, _key: string) {
    throw new NotImplementedError("Deleting an env entry is not implemented yet.");
  },
};
