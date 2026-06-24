// StepContext: the per-turn handle every thread op writes through. One turn drives exactly one instance
// (the one an inbound external event routed to); the context binds that instance, the project's shared
// scope store, the IR for the instance's snapshot, the prim runner, and the blob store, plus the three
// end-of-turn buffers. Ops mutate the instance / scopes in place and `enqueue` internal events (drained
// this same turn) or `emit` external events (buffered, flushed by the actor only after the turn's DB
// persist). Nothing here touches the DB — persistence is the actor's, applied once the internal queue
// drains (domain-model §5: "DB reflection after the internal queue is empty").

import type { BlockId, BlockInformation } from "@katari-lang/types";
import type { ExternalEvent, InternalEvent } from "../event/types.js";
import type { ExternalRunner } from "../external/runner.js";
import type { ProjectId, SnapshotId } from "../ids.js";
import type { BlobStore } from "../value/blob-store.js";
import type { Value } from "../value/types.js";
import type { CoreInstance, ProjectStore } from "./types.js";

/**
 * Read access to the IR the running instance needs, bound to that instance's (snapshot, module). Block
 * ids are module-local, so `block` reads this module's blocks; a cross-module callable is reached by a
 * named delegate whose target the actor resolves against the snapshot (the named callable's snapshot is
 * always this `snapshot`, so the engine reads it directly rather than re-resolving).
 */
export interface IrAccess {
  /** The snapshot this access reads (the running instance's version). */
  readonly snapshot: SnapshotId;
  /** The module this access reads (the running instance's agent's module). */
  readonly module: string;
  /** Resolve a block by id within this module (with the parameter map its scope is seeded from). */
  block(blockId: BlockId): BlockInformation;
}

/**
 * Runs a built-in primitive. The implementation bakes in everything a prim needs (the project's blob
 * store, the env / secret store for `get_env` / `set_env`); the engine only hands it the name and
 * argument. A prim may be async (a bounded env / blob fetch), which the internal consumer awaits inline.
 */
export interface PrimRunner {
  run(name: string, argument: Value): Promise<Value>;
}

export type LogLevel = "debug" | "info" | "warn" | "error";
export interface LogEntry {
  level: LogLevel;
  message: string;
}

/** The three things a turn accumulates and hands back to the actor at quiescence. */
export interface StepBuffers {
  /** The internal event queue, drained to empty within the turn. */
  internalQueue: InternalEvent[];
  /** External events produced this turn, flushed to the actor mailbox after the DB persist. */
  outbound: ExternalEvent[];
  /** Structured log lines emitted this turn. */
  logs: LogEntry[];
}

export interface StepContext {
  readonly projectId: ProjectId;
  readonly store: ProjectStore;
  /** The single instance this turn drives. */
  readonly instance: CoreInstance;
  readonly ir: IrAccess;
  readonly prims: PrimRunner;
  readonly blobs: BlobStore;
  /** The FFI abstraction an external leaf dispatches through (its completion re-enters via the actor). */
  readonly external: ExternalRunner;
  readonly buffers: StepBuffers;
  /** Push an internal event onto this turn's queue (processed before the turn ends). */
  enqueue(event: InternalEvent): void;
  /** Buffer an outbound external event (flushed by the actor after persist). */
  emit(event: ExternalEvent): void;
  log(level: LogLevel, message: string): void;
}

/** Build a fresh `StepContext` for one instance's turn over empty buffers. */
export function makeStepContext(args: {
  projectId: ProjectId;
  store: ProjectStore;
  instance: CoreInstance;
  ir: IrAccess;
  prims: PrimRunner;
  blobs: BlobStore;
  external: ExternalRunner;
}): StepContext {
  const buffers: StepBuffers = { internalQueue: [], outbound: [], logs: [] };
  return {
    projectId: args.projectId,
    store: args.store,
    instance: args.instance,
    ir: args.ir,
    prims: args.prims,
    blobs: args.blobs,
    external: args.external,
    buffers,
    enqueue(event) {
      buffers.internalQueue.push(event);
    },
    emit(event) {
      buffers.outbound.push(event);
    },
    log(level, message) {
      buffers.logs.push({ level, message });
    },
  };
}
