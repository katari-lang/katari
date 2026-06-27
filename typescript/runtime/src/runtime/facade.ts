// Engine façade: the command side of the API — the single entry from the stateless HTTP services into the
// stateful, per-project engine. It reaches each project's warm actor through the module-scope
// `ProjectRegistry`, converts the wire's raw `Json` to/from the engine's tagged `Value`, and translates each
// command into engine work: start a run (record its metadata sidecar + kick the run off), cancel a run,
// answer an escalation. Reads (run list/get, open escalations) do NOT go through here — they read Layer 1
// directly in their repositories (the run's outcome is its delegation; an open escalation is an
// `escalations` row), so a restart never makes them stale.
//
// (This is the command edge only: it forwards each command to the project's `ApiReactor` — the api root's
// issuing and reaction sides already live there — and never drives the engine directly.)

import { createHash } from "node:crypto";
import { createAgentName, type Json, type SidecarBundle } from "@katari-lang/types";
import { and, eq } from "drizzle-orm";
import { config } from "../config/index.js";
import { db } from "../db/client.js";
import { projects, snapshots } from "../db/tables/projects.js";
import { NotFoundError } from "../lib/errors.js";
import { DbIrSource } from "./actor/db-ir-source.js";
import { DbPersistence } from "./actor/db-persistence.js";
import { PrimRegistry } from "./engine/prims.js";
import { nodeSidecarMaterialize, SnapshotFfiTransport } from "./external/snapshot-transport.js";
import {
  type DelegationId,
  type EscalationId,
  newBlobId,
  type ProjectId,
  type SnapshotId,
} from "./ids.js";
import { ProjectRegistry } from "./registry.js";
import { createBlobStore } from "./value/blob-store.js";
import { jsonToValue } from "./value/codec.js";

/** Read a snapshot's compiled sidecar bundle from the store (null when it has no FFI handlers). The
 *  `SnapshotFfiTransport` spawns it as the `node` sidecar for that snapshot's external calls. */
async function loadSidecarBundle(
  projectId: ProjectId,
  snapshot: SnapshotId,
): Promise<SidecarBundle | null> {
  const [row] = await db
    .select({ bundle: snapshots.sidecarBundle })
    .from(snapshots)
    .where(and(eq(snapshots.id, snapshot), eq(snapshots.projectId, projectId)))
    .limit(1);
  return row?.bundle ?? null;
}

export interface StartRunInput {
  projectId: string;
  /** The agent to run; resolved against the chosen snapshot's manifest. */
  qualifiedName: string;
  /** The snapshot to pin the run to. Defaults to the project head when omitted. */
  snapshotId?: string;
  argument?: Json;
  /** A human label for the run record; defaults to `qualifiedName`. */
  name?: string;
}

export interface CancelRunInput {
  projectId: string;
  runId: string;
  reason?: string;
}

export interface AnswerEscalationInput {
  projectId: string;
  escalationId: string;
  value: Json;
}

// The warm registry: one per process, backed by the DB (IR module store + engine-graph persistence). A
// project's actor is created lazily and kept warm. FFI runs each snapshot's sidecar bundle as a `node`
// process (per-project transport); env is not wired yet (pure prims).
// The byte store for blobs (file uploads, future engine string-promotion). Shared with the project actors
// (the same instance the engine reads through), so a blob's bytes are one source of truth. S3 when
// `BLOB_S3_BUCKET` is configured, else the in-memory dev store.
export const blobStore = createBlobStore(config.blobS3);

const registry = new ProjectRegistry({
  ir: new DbIrSource(db),
  persistence: new DbPersistence(db),
  prims: new PrimRegistry(),
  blobs: blobStore,
  externalFactory: () => new SnapshotFfiTransport(loadSidecarBundle, nodeSidecarMaterialize),
});

/** Resolve the snapshot a run pins: the explicit one, or the project's live head. */
async function resolveSnapshot(projectId: string, snapshotId?: string): Promise<string> {
  if (snapshotId !== undefined) return snapshotId;
  const [project] = await db
    .select({ head: projects.headSnapshotId })
    .from(projects)
    .where(eq(projects.id, projectId))
    .limit(1);
  if (project?.head == null) {
    throw new NotFoundError("project has no live snapshot to run; deploy one or pass snapshotId");
  }
  return project.head;
}

/** The command side of the API — start / cancel / answer, translating the wire's `Json` to the engine's
 *  `Value` and driving the per-project actor (reached through the registry). Reads (run list/get, open
 *  escalations) go straight to Layer 1 in the repositories, not through here. */
export const facade = {
  async startRun(input: StartRunInput): Promise<{ runId: string }> {
    const snapshotId = await resolveSnapshot(input.projectId, input.snapshotId);
    const argument = input.argument !== undefined ? jsonToValue(input.argument) : null;
    // The engine mints the run delegation and kicks off the run; its id is the durable run handle and its
    // Layer 1 row is the outcome's source of truth. The run's metadata sidecar (`runs` row) is written by the
    // engine in the SAME commit as the run's `delegate` — `await started` resolves once that launch commit is
    // durable, so the run is immediately visible to the API's reads. The in-process `result` promise is
    // ignored (the API reads the outcome from the delegation, correct even after a crash + recovery).
    const { run, result, started } = registry
      .actorFor(input.projectId as ProjectId)
      .startRun(
        createAgentName(input.qualifiedName),
        snapshotId as SnapshotId,
        argument,
        input.name ?? input.qualifiedName,
      );
    void result.catch(() => {}); // swallow: the durable outcome is the delegation, not this promise
    await started;
    return { runId: run };
  },

  async cancel(input: CancelRunInput): Promise<void> {
    // Ask the engine to terminate the run's root, recording the user's reason on the `runs` row in the same
    // commit as the `terminate`. The terminate cascade moves the run delegation to `gone` — the durable
    // `cancelled` outcome the API projects.
    await registry
      .actorFor(input.projectId as ProjectId)
      .cancelRun(input.runId as DelegationId, input.reason);
  },

  async answerEscalation(input: AnswerEscalationInput): Promise<void> {
    await registry
      .actorFor(input.projectId as ProjectId)
      .answerEscalation(input.escalationId as EscalationId, jsonToValue(input.value));
  },

  /** Upload a file as an api-root-owned blob: store the bytes (content-addressed by their hash), then
   *  register the blob through the actor so its ownership row commits durably. Returns the blob handle the
   *  caller downloads / references. The bytes are put before the (small) registration command, so the actor
   *  loop never carries the payload; an orphaned put on a failed registration is a rare, harmless leak. */
  async uploadFile(input: {
    projectId: string;
    bytes: Uint8Array;
    contentType?: string;
  }): Promise<{ id: string; hash: string; size: number }> {
    const blobId = newBlobId();
    const hash = createHash("sha256").update(input.bytes).digest("hex");
    const size = input.bytes.byteLength;
    const projectId = input.projectId as ProjectId;
    await blobStore.put(projectId, blobId, input.bytes);
    await registry.actorFor(projectId).uploadBlob(blobId, {
      hash,
      size,
      semanticKind: "file",
      ...(input.contentType !== undefined ? { contentType: input.contentType } : {}),
    });
    return { id: blobId, hash, size };
  },
};
