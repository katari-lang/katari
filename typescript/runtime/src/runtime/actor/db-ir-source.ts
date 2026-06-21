// A DB-backed IrSource: load a snapshot's modules (its manifest + each module's content-addressed IR)
// from the module store on first use, caching them in an in-memory registry the engine then reads
// synchronously. The runtime receives the stdlib (`primitive`) as a normal uploaded module, so nothing
// is special-cased here — `primitive.add` resolves like any callable.

import type { BlockId, QualifiedName } from "@katari-lang/types";
import { and, eq, inArray } from "drizzle-orm";
import type { Database } from "../../db/client.js";
import { modules, snapshots } from "../../db/tables/projects.js";
import type { IrAccess } from "../engine/context.js";
import type { SnapshotId } from "../ids.js";
import { type IrSource, SnapshotRegistry } from "../ir.js";

export class DbIrSource implements IrSource {
  private readonly registry = new SnapshotRegistry();
  private readonly loaded = new Set<SnapshotId>();

  constructor(private readonly db: Database) {}

  async preload(snapshot: SnapshotId): Promise<void> {
    if (this.loaded.has(snapshot)) return;
    const [row] = await this.db
      .select({ projectId: snapshots.projectId, modules: snapshots.modules })
      .from(snapshots)
      .where(eq(snapshots.id, snapshot))
      .limit(1);
    if (row === undefined) {
      throw new Error(`snapshot ${snapshot} not found`);
    }
    const manifest = row.modules;
    const hashes = Object.values(manifest);
    const moduleRows =
      hashes.length === 0
        ? []
        : await this.db
            .select({ hash: modules.hash, ir: modules.ir })
            .from(modules)
            .where(and(eq(modules.projectId, row.projectId), inArray(modules.hash, hashes)));
    const irByHash = new Map(moduleRows.map((moduleRow) => [moduleRow.hash, moduleRow.ir]));
    for (const [name, hash] of Object.entries(manifest)) {
      const ir = irByHash.get(hash);
      if (ir === undefined) {
        throw new Error(`module "${name}" (hash ${hash}) missing for snapshot ${snapshot}`);
      }
      this.registry.set(snapshot, name, ir);
    }
    this.loaded.add(snapshot);
  }

  access(snapshot: SnapshotId, module: string): IrAccess {
    return this.registry.access(snapshot, module);
  }

  locate(snapshot: SnapshotId, name: QualifiedName): { module: string; blockId: BlockId } {
    return this.registry.locate(snapshot, name);
  }
}
