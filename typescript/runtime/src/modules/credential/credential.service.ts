// The credential resource as the admin API presents it: metadata listing and deletion. Depositing is
// NOT here — a credential only ever enters the store through the runtime-hosted OAuth flow's completion
// (see runtime/external/authorization-flow.ts), so no write endpoint exists to put token material on
// the wire.

import { db } from "../../db/client.js";
import { NotFoundError } from "../../lib/errors.js";
import { credentialRepository } from "./credential.repository.js";

export const credentialService = {
  /** The stored credentials as metadata — name, the acquisition-profile discriminant (mcp | configured;
   *  what a re-authorization needs to know, never token material), and the update instant. The wire
   *  shape nests under `credentials` (not a bare array) so the resource can grow siblings without a
   *  breaking change. */
  async list(projectId: string): Promise<{
    credentials: Array<{ name: string; profile: "mcp" | "configured"; updatedAt: Date }>;
  }> {
    return { credentials: await credentialRepository.list(db, projectId) };
  },

  /** Forget a credential — the operator's forced re-authorization (e.g. to switch accounts). The next
   *  use of the name escalates `prelude.oauth.authorize` again. 404 when nothing is stored under it. */
  async delete(projectId: string, name: string): Promise<void> {
    const deleted = await credentialRepository.delete(db, projectId, name);
    if (!deleted) {
      throw new NotFoundError(`no credential named "${name}" is stored for this project`);
    }
  },
};
