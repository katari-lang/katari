// IR resolution for the engine. A snapshot pins one IR version as a manifest of modules (module name ->
// IRModule). Block ids are module-local, so the engine reads through an `IrAccess` bound to a
// (snapshot, module); a cross-module callable is reached by a named delegate the actor resolves with
// `locate`. The module a qualified name belongs to is its name minus the final segment (the compiler's
// module = path, qname = module + "." + declaration). Loading from the DB is async, so the source is
// `preload`ed (caching all of a snapshot's modules) before the engine reads it synchronously.

import type { BlockId, BlockInformation, IRModule, QualifiedName } from "@katari-lang/types";
import type { IrAccess } from "./engine/context.js";
import type { SnapshotId } from "./ids.js";

/** The module a qualified name belongs to: everything before its final segment (`"primitive.add"` ->
 *  `"primitive"`, `"foo.bar.baz"` -> `"foo.bar"`). A bare name (no dot) belongs to the empty module. */
export function moduleOfName(name: QualifiedName): string {
  const segments = String(name).split(".");
  return segments.slice(0, -1).join(".");
}

export interface IrSource {
  /** Ensure all of a snapshot's modules are loaded (async for a DB source); idempotent. */
  preload(snapshot: SnapshotId): Promise<void>;
  /** A snapshot+module-bound access for the engine (must have been `preload`ed). */
  access(snapshot: SnapshotId, module: string): IrAccess;
  /** Resolve a named callable to its module + agent block (the actor's delegate-target resolution). */
  locate(snapshot: SnapshotId, name: QualifiedName): { module: string; blockId: BlockId };
}

/** An in-memory `IrSource`: modules registered directly (deploy / tests). `preload` is a no-op. */
export class SnapshotRegistry implements IrSource {
  private readonly modules = new Map<SnapshotId, Map<string, IRModule>>();

  /** Register one module's IR within a snapshot. */
  set(snapshot: SnapshotId, module: string, ir: IRModule): void {
    const byModule = this.modules.get(snapshot) ?? new Map<string, IRModule>();
    byModule.set(module, ir);
    this.modules.set(snapshot, byModule);
  }

  async preload(): Promise<void> {
    // Already in memory.
  }

  private moduleIr(snapshot: SnapshotId, module: string): IRModule {
    const ir = this.modules.get(snapshot)?.get(module);
    if (ir === undefined) {
      throw new Error(`no IR for module "${module}" in snapshot ${snapshot}`);
    }
    return ir;
  }

  access(snapshot: SnapshotId, module: string): IrAccess {
    const ir = this.moduleIr(snapshot, module);
    return {
      snapshot,
      module,
      block: (blockId: BlockId): BlockInformation => {
        const information = ir.blocks[blockId];
        if (information === undefined) {
          throw new Error(`block ${blockId} not found in ${module}@${snapshot}`);
        }
        return information;
      },
    };
  }

  locate(snapshot: SnapshotId, name: QualifiedName): { module: string; blockId: BlockId } {
    const module = moduleOfName(name);
    const blockId = this.moduleIr(snapshot, module).entries[name];
    if (blockId === undefined) {
      throw new Error(`callable "${name}" not found in snapshot ${snapshot}`);
    }
    return { module, blockId };
  }
}
