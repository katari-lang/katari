// IR resolution for the engine. A snapshot pins one IR version; the engine reads it through an
// `IrAccess` bound to that snapshot. v0.1.0 holds one IRModule per snapshot (single-module programs);
// resolving a block id or a `QualifiedName` stays within it. Multi-module snapshots are a refinement:
// block ids are module-local, so cross-module resolution must additionally carry the module a value /
// closure belongs to — deferred until programs span modules.

import type { BlockId, BlockInformation, IRModule, QualifiedName } from "@katari-lang/types";
import type { IrAccess } from "./engine/context.js";
import type { SnapshotId } from "./ids.js";

/** A registry of the IR each snapshot pins, handing out a snapshot-bound `IrAccess` to the engine. */
export class SnapshotRegistry {
  private readonly modules = new Map<SnapshotId, IRModule>();

  /** Register the IR a snapshot resolves to (one module per snapshot in v0.1.0). */
  set(snapshot: SnapshotId, ir: IRModule): void {
    this.modules.set(snapshot, ir);
  }

  /** The IR a snapshot pins; throws if the snapshot is unknown to this registry. */
  get(snapshot: SnapshotId): IRModule {
    const ir = this.modules.get(snapshot);
    if (ir === undefined) {
      throw new Error(`no IR registered for snapshot ${snapshot}`);
    }
    return ir;
  }

  /** A snapshot-bound `IrAccess` the engine reads blocks and resolves names through. */
  access(snapshot: SnapshotId): IrAccess {
    const ir = this.get(snapshot);
    return {
      snapshot,
      block: (blockId: BlockId): BlockInformation => {
        const information = ir.blocks[blockId];
        if (information === undefined) {
          throw new Error(`block ${blockId} not found in snapshot ${snapshot}`);
        }
        return information;
      },
      resolveName: (name: QualifiedName): { blockId: BlockId; snapshot: SnapshotId } => {
        const blockId = ir.entries[name];
        if (blockId === undefined) {
          throw new Error(`callable "${name}" not found in snapshot ${snapshot}`);
        }
        return { blockId, snapshot };
      },
    };
  }
}
