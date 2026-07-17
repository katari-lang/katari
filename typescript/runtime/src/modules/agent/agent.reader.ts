// Reads callable schemas straight from a snapshot's stored IR. The IR is the single source of truth
// for schemas — every top-level callable (agent, data constructor, request, external, primitive) is an
// `entries` member wrapping an agent block that carries its `SchemaInfo` — so nothing is uploaded or
// stored separately; this reader materialises a snapshot's modules and projects the schemas out.
//
// This is the API's own reader rather than a reuse of the engine's `DbIrSource`: the engine caches
// snapshots in memory for its lifetime and raises infra failures as retryable `TransientError`s, while
// an API read wants plain per-request queries and HTTP-mapped errors (404 for a missing project /
// snapshot / callable).

import type { AgentBlock, IRModule, JSONSchema } from "@katari-lang/types";
import { db } from "../../db/client.js";
import { NotFoundError } from "../../lib/errors.js";
import { snapshotRepository } from "../snapshot/snapshot.repository.js";

/** A snapshot's modules keyed by module name, plus the snapshot they came from (resolved from the
 *  project head when the caller did not pin one). */
export interface SnapshotModules {
  snapshotId: string;
  modules: Map<string, IRModule>;
}

/** Load a snapshot's modules from the content-addressed store. `snapshotId` omitted means the project
 *  head; a project with no deployed head is a 404 (nothing is runnable yet). */
export async function loadSnapshotModules(
  projectId: string,
  snapshotId?: string,
): Promise<SnapshotModules> {
  const resolvedSnapshotId = snapshotId ?? (await resolveHeadSnapshotId(projectId));
  const [snapshot] = await snapshotRepository.findSnapshot(db, projectId, resolvedSnapshotId);
  if (!snapshot) {
    throw new NotFoundError(`Snapshot ${resolvedSnapshotId} not found.`);
  }
  const manifestEntries = Object.entries(snapshot.modules);
  const hashes = manifestEntries.map(([, hash]) => hash);
  const rows =
    hashes.length === 0 ? [] : await snapshotRepository.findModulesByHashes(db, projectId, hashes);
  const irByHash = new Map(rows.map((row) => [row.hash, row.ir]));
  const modules = new Map<string, IRModule>();
  for (const [moduleName, hash] of manifestEntries) {
    const ir = irByHash.get(hash);
    if (ir === undefined) {
      // A manifest hash missing from the store means the deploy invariant was violated — an internal
      // inconsistency, not a caller mistake — so let it surface as a 500 rather than a 404.
      throw new Error(
        `Module "${moduleName}" (hash ${hash}) missing for snapshot ${resolvedSnapshotId}.`,
      );
    }
    modules.set(moduleName, ir);
  }
  return { snapshotId: resolvedSnapshotId, modules };
}

async function resolveHeadSnapshotId(projectId: string): Promise<string> {
  const [project] = await snapshotRepository.findProject(db, projectId);
  if (!project) {
    throw new NotFoundError(`Project ${projectId} not found.`);
  }
  if (project.headSnapshotId === null) {
    throw new NotFoundError(`Project ${projectId} has no deployed snapshot.`);
  }
  return project.headSnapshotId;
}

/** One resolved callable entry: its agent block plus the entry's handle privacy. Privacy travels with
 *  the block so a presentation surface (the agents listing) can hide a private agent, while the schema
 *  reader below still resolves it (an escalation's answer schema comes from a public request entry, but
 *  the reader stays privacy-agnostic — it never filters). */
export interface CallableEntry {
  block: AgentBlock;
  private: boolean;
}

/** Every callable's entry across a snapshot's modules, keyed by qualified name. Entries always point at
 *  agent blocks (the sole schema-carrying wrapper); anything else is skipped defensively. The whole
 *  block is returned so callers see both its schema and its `@"..."` description, alongside the entry's
 *  `private` flag. */
export function collectEntries(modules: Map<string, IRModule>): Map<string, CallableEntry> {
  const entries = new Map<string, CallableEntry>();
  for (const ir of modules.values()) {
    for (const [qualifiedName, entry] of Object.entries(ir.entries)) {
      const information = ir.blocks[entry.block];
      if (information === undefined || information.block.kind !== "agent") continue;
      entries.set(qualifiedName, { block: information.block, private: entry.private });
    }
  }
  return entries;
}

/** The schema an answer to `request` must satisfy: the request callable's output schema. `null` when
 *  the snapshot has no such entry (the caller falls back to unvalidated input). */
export function deriveAnswerSchema(
  entries: Map<string, CallableEntry>,
  request: string,
): JSONSchema | null {
  return entries.get(request)?.block.schema.output ?? null;
}
