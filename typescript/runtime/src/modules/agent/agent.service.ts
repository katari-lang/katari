// The agent resource: callable schemas read from a snapshot's IR (see agent.reader.ts for why the IR
// is the source of truth). `list` serves every entry — including data constructors, requests and the
// stdlib's `primitive.*` — without filtering; presentation choices (e.g. hiding primitives from an
// interactive picker) belong to clients.

import { NotFoundError } from "../../lib/errors.js";
import { collectEntries, loadSnapshotModules } from "./agent.reader.js";

export const agentService = {
  async list(projectId: string, snapshotId?: string) {
    const { snapshotId: resolvedSnapshotId, modules } = await loadSnapshotModules(
      projectId,
      snapshotId,
    );
    const agents = [...collectEntries(modules)]
      .map(([qualifiedName, schema]) => ({
        qualifiedName,
        input: schema.input,
        output: schema.output,
      }))
      // Deterministic order so paging/diffing a listing is stable across requests.
      .sort((left, right) => left.qualifiedName.localeCompare(right.qualifiedName));
    return { snapshotId: resolvedSnapshotId, agents };
  },

  async getByName(projectId: string, qualifiedName: string, snapshotId?: string) {
    const { snapshotId: resolvedSnapshotId, modules } = await loadSnapshotModules(
      projectId,
      snapshotId,
    );
    const schema = collectEntries(modules).get(qualifiedName);
    if (schema === undefined) {
      throw new NotFoundError(`No callable "${qualifiedName}" in snapshot ${resolvedSnapshotId}.`);
    }
    return {
      snapshotId: resolvedSnapshotId,
      qualifiedName,
      input: schema.input,
      output: schema.output,
    };
  },
};
