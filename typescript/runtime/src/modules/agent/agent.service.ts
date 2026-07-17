// The agent resource: callable schemas read from a snapshot's IR (see agent.reader.ts for why the IR
// is the source of truth). `list` serves every PUBLIC entry — including data constructors, requests and
// the stdlib's `prelude.*`; further presentation choices (e.g. hiding primitives from an interactive
// picker) belong to clients. A private agent is excluded here: the runtime refuses to start it (see
// `conformRunArgument`), so it must not appear on the operator surface that starts runs — excluding it
// server-side keeps every client (admin console, CLI `ls agents`) consistent without a per-client
// filter.

import { NotFoundError } from "../../lib/errors.js";
import { collectEntries, loadSnapshotModules } from "./agent.reader.js";

export const agentService = {
  async list(projectId: string, snapshotId?: string) {
    const { snapshotId: resolvedSnapshotId, modules } = await loadSnapshotModules(
      projectId,
      snapshotId,
    );
    const agents = [...collectEntries(modules)]
      // A private agent is not startable from the runtime boundary, so it never appears in the listing.
      .filter(([, entry]) => !entry.private)
      .map(([qualifiedName, entry]) => ({
        qualifiedName,
        input: entry.block.schema.input,
        output: entry.block.schema.output,
        description: entry.block.description ?? "",
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
    const entry = collectEntries(modules).get(qualifiedName);
    // A private agent stays resolvable by direct name (its schema is not secret — handle privacy is
    // about run-time escalation flow, refused at the run-start boundary); only the listing hides it.
    if (entry === undefined) {
      throw new NotFoundError(`No callable "${qualifiedName}" in snapshot ${resolvedSnapshotId}.`);
    }
    return {
      snapshotId: resolvedSnapshotId,
      qualifiedName,
      input: entry.block.schema.input,
      output: entry.block.schema.output,
      description: entry.block.description ?? "",
    };
  },
};
