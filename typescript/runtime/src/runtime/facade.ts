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
import { and, eq, notInArray } from "drizzle-orm";
import { config } from "../config/index.js";
import { db } from "../db/client.js";
import { instances, runs, TERMINAL_RUN_STATES, webhookInstances } from "../db/tables/execution.js";
import { projects, snapshots } from "../db/tables/projects.js";
import { BadRequestError, ConflictError, NotFoundError } from "../lib/errors.js";
import type { Logger } from "../lib/logger.js";
import { envReader } from "../modules/env/env.service.js";
import { DbIrSource } from "./actor/db-ir-source.js";
import { DbPersistence } from "./actor/db-persistence.js";
import { messageOf } from "./actor/failure.js";
import { registerHostPrims } from "./engine/host-prims.js";
import { PrimRegistry } from "./engine/prims.js";
import type { BlobEntry } from "./engine/types.js";
import { FetchHttpTransport } from "./external/http-transport.js";
import { SdkMcpTransport } from "./external/mcp-transport.js";
import { nodeSidecarMaterialize, SnapshotFfiTransport } from "./external/snapshot-transport.js";
import {
  type BlobId,
  type DelegationId,
  type EscalationId,
  type InstanceId,
  newBlobId,
  type ProjectId,
  type SnapshotId,
} from "./ids.js";
import { ProjectRegistry } from "./registry.js";
import { createBlobStore } from "./value/blob-store.js";
import { jsonToValue, valueToJson } from "./value/codec.js";
import type { Value } from "./value/types.js";

/** Decode client-supplied `Json` (a run argument, an escalation answer) into an engine `Value`, mapping a
 *  malformed-input decode failure — a reserved `$`-key, a non-string `$constructor` tag, an undecodable
 *  file / agent / closure handle — to a 400 rather than letting `jsonToValue`'s plain `Error` surface as a
 *  500. These acceptance surfaces are the only unchecked entries for client `Json`, so the decode guard
 *  lives here, once. */
export function decodeClientJson(value: Json, what: string): Value {
  try {
    return jsonToValue(value);
  } catch (error) {
    throw new BadRequestError(`${what} is not a decodable value: ${messageOf(error)}`);
  }
}

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
// process (per-project transport).
// The byte store for blobs (file uploads, future engine string-promotion). Shared with the project actors
// (the same instance the engine reads through), so a blob's bytes are one source of truth. S3 when
// `BLOB_S3_BUCKET` is configured, else the in-memory dev store.
export const blobStore = createBlobStore(config.blobS3);

// The URL a sidecar uses to reach this runtime's blob side channel (download / upload). The sidecar is a child
// process on this same host, so it connects over loopback regardless of the server's bind host (which may be a
// wildcard such as `0.0.0.0`). It includes the versioned API prefix the routes mount under (see `app.ts`), so
// the blob client appends only the resource path.
const runtimeBaseUrl = `http://127.0.0.1:${config.port}/api/v1`;

// The shared prim runner: the pure built-ins (preloaded) plus the host-registered effectful ones (env
// reads the project's `env_entries` store). One registry serves every project actor; the per-call
// `PrimContext` supplies the project a given env read runs for.
const prims = new PrimRegistry();
registerHostPrims(prims, { env: envReader });

const registry = new ProjectRegistry({
  ir: new DbIrSource(db),
  persistence: new DbPersistence(db),
  prims,
  blobs: blobStore,
  externalFactory: () =>
    new SnapshotFfiTransport(
      loadSidecarBundle,
      nodeSidecarMaterialize(runtimeBaseUrl, config.apiKey),
    ),
  // The built-in http client: a fresh in-runtime `fetch` transport per project actor (its own completion
  // sink). The api root performs `http.fetch` requests through it.
  httpFactory: () => new FetchHttpTransport(),
  // The built-in MCP client: the SDK-backed transport, one per project actor (its own connections).
  // Its blob producer bridges a tool result's binary content (an image block) into a project blob owned
  // by the mcp call's instance — the exact ownership + ascent path an FFI handler's mid-call upload
  // takes (`produceFfiBlob`), just in-process. A vanished call (ConflictError) returns null, so the
  // transport degrades that block to its text placeholder instead of failing the whole result.
  mcpFactory: (projectId) =>
    new SdkMcpTransport(async (delegation, bytes, contentType) => {
      try {
        const produced = await mintAndStoreBlob(projectId, bytes, contentType, (blobId, entry) =>
          registry.actorFor(projectId).registerProducedMcpBlob(delegation, blobId, entry),
        );
        // The slim handle: identity only — the metadata just registered lives on the blob's row.
        return { $ref: produced.id, semanticKind: "file" };
      } catch {
        return null;
      }
    }),
  // The public base `webhook.inbound` mints its URLs under (KATARI_PUBLIC_URL, or the local port).
  webhookBaseUrl: config.publicUrl,
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
    const argument =
      input.argument !== undefined ? decodeClientJson(input.argument, "the run argument") : null;
    // The engine mints the run's permanent run instance and kicks the run off; that instance's id is the
    // durable run handle (`runs.id`). The run's metadata (`runs` row) is written by the engine in the SAME
    // commit as the run's `delegate` — `await started` resolves once that launch commit is durable, so the
    // run is immediately visible to the API's reads. The in-process `result` promise is ignored (the API
    // reads the outcome from the `runs` row, correct even after a crash + recovery).
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
      .cancelRun(input.runId as InstanceId, input.reason);
  },

  async answerEscalation(input: AnswerEscalationInput): Promise<void> {
    await registry
      .actorFor(input.projectId as ProjectId)
      .answerEscalation(
        input.escalationId as EscalationId,
        decodeClientJson(input.value, "the answer"),
      );
  },

  /** Upload a file as an api-root-owned blob: store the bytes (content-addressed by their hash), then
   *  register the blob through the actor so its ownership row commits durably. Returns the blob handle the
   *  caller downloads / references. */
  uploadFile(input: {
    projectId: string;
    bytes: Uint8Array;
    contentType?: string;
  }): Promise<{ id: string; hash: string; size: number }> {
    const projectId = input.projectId as ProjectId;
    return mintAndStoreBlob(projectId, input.bytes, input.contentType, async (blobId, entry) => {
      await registry.actorFor(projectId).uploadBlob(blobId, entry);
      return true; // the api root is always present, so an upload always registers.
    });
  },

  /** Delete an uploaded file: free its blob row through the actor (ownership has one SoT — the warm pool),
   *  the bytes following strictly after the commit. Resolves to whether the file existed. */
  deleteFile(input: { projectId: string; fileId: string }): Promise<boolean> {
    return registry.actorFor(input.projectId as ProjectId).deleteBlob(input.fileId as BlobId);
  },

  /** Tear down a project's warm engine (the project is being deleted): kill its sidecars, abort its
   *  in-flight http, reject its in-process run promises, and drop the actor. A no-op when never warmed. */
  evictProject(projectId: string): void {
    registry.evict(projectId as ProjectId);
  },

  /** Deliver one inbound webhook POST. The token alone locates its endpoint — the durable
   *  `webhook_instances` row resolves it to a project (waking a cold actor, whose reload re-registers the
   *  token), and the actor's webhook reactor converts the body into a delegation of the endpoint's
   *  callback. Returns the callback's outcome with its values lowered at THIS user-facing boundary
   *  (private content redacts — a webhook caller is outside the trust boundary). */
  async deliverWebhook(input: {
    token: string;
    body: Json;
  }): Promise<
    | { kind: "unknown" }
    | { kind: "gone" }
    | { kind: "result"; value: Json }
    | { kind: "rejected"; error: Json }
    | { kind: "throw"; error: Json }
    | { kind: "error" }
  > {
    const [row] = await db
      .select({ projectId: instances.projectId })
      .from(webhookInstances)
      .innerJoin(instances, eq(webhookInstances.instanceId, instances.id))
      .where(eq(webhookInstances.token, input.token))
      .limit(1);
    if (row === undefined) return { kind: "unknown" };
    const outcome = await registry
      .actorFor(row.projectId as ProjectId)
      .deliverWebhook(input.token, decodeClientJson(input.body, "the webhook body"));
    switch (outcome.kind) {
      case "unknown":
      case "gone":
        return { kind: outcome.kind };
      case "result":
        return { kind: "result", value: valueToJson(outcome.value, "redact") };
      case "throw": {
        // A schema violation at the dynamic-dispatch boundary is the caller's fault — the callback never
        // ran, so it surfaces as a distinct rejection (the route's 400) rather than as the throw variant
        // a program failing on a well-formed delivery produces (the route's 500).
        const error = valueToJson(outcome.value, "redact");
        return isCallError(outcome.value) ? { kind: "rejected", error } : { kind: "throw", error };
      }
      case "error":
        // The panic message stays server-side (it may name internals); the caller gets a bare 500.
        return { kind: "error" };
    }
  },

  /** Store the bytes an FFI handler produced mid-call (content-addressed by their hash) and register the blob
   *  as owned by that handler's ffi call instance — so the call's return ascends it to the core caller. Returns
   *  the blob handle the sidecar lifts into a `File` value; throws a `ConflictError` (so the upload fails) when
   *  the call already vanished, after deleting the orphaned bytes. */
  produceFfiBlob(input: {
    projectId: string;
    delegation: string;
    bytes: Uint8Array;
    contentType?: string;
  }): Promise<{ id: string; hash: string; size: number }> {
    const projectId = input.projectId as ProjectId;
    return mintAndStoreBlob(projectId, input.bytes, input.contentType, (blobId, entry) =>
      registry
        .actorFor(projectId)
        .registerProducedBlob(input.delegation as DelegationId, blobId, entry),
    );
  },
};

/** Whether a thrown payload is the dynamic-dispatch schema violation (`reflection.call_error`). */
function isCallError(value: Value): boolean {
  return value.kind === "record" && String(value.ctor) === "prelude.reflection.call_error";
}

/** Resume every project that still has an in-flight run — the boot half of recovery. Reactivation is
 *  otherwise lazy (a project reloads when next touched), so after a restart a long-running run would stay
 *  suspended until external traffic happens to arrive; the host calls this once at boot to touch them
 *  itself. Sequential and per-project fault-isolated: one broken project logs and must not stop the rest.
 *  Called after the server is listening — a resuming FFI call's sidecar reaches back over the blob side
 *  channel of this very server. */
export async function activateInFlightProjects(logger: Logger): Promise<void> {
  const inFlight = await db
    .selectDistinct({ projectId: runs.projectId })
    .from(runs)
    .where(notInArray(runs.state, [...TERMINAL_RUN_STATES]));
  for (const { projectId } of inFlight) {
    try {
      await registry.actorFor(projectId as ProjectId).activate();
      logger.info("resumed a project with in-flight runs", { projectId });
    } catch (error) {
      logger.error("failed to resume a project with in-flight runs", {
        projectId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }
}

/** Mint a content-addressed blob, store its bytes, then register ownership through `register`. The bytes are
 *  put before the (small) registration command so the actor loop never carries the payload. The catch is that
 *  bytes-then-register is not atomic: if registration never commits (a poisoned commit rejects it) or reports
 *  the owning call gone (`register` returns `false`), the stored bytes have NO row referencing them, so they
 *  are deleted inline — closing the orphan rather than leaving it for a (deferred) blob GC. Returns the handle
 *  on success; rethrows / raises a `ConflictError` otherwise. */
async function mintAndStoreBlob(
  projectId: ProjectId,
  bytes: Uint8Array,
  contentType: string | undefined,
  register: (blobId: BlobId, entry: Omit<BlobEntry, "owner">) => Promise<boolean>,
): Promise<{ id: string; hash: string; size: number }> {
  const blobId = newBlobId();
  const hash = createHash("sha256").update(bytes).digest("hex");
  const size = bytes.byteLength;
  await blobStore.put(projectId, blobId, bytes);
  let registered: boolean;
  try {
    registered = await register(blobId, {
      hash,
      size,
      semanticKind: "file",
      ...(contentType !== undefined ? { contentType } : {}),
    });
  } catch (error) {
    // Registration never committed, so no row references these bytes — delete them rather than orphan them.
    await blobStore.delete(projectId, blobId).catch(() => {});
    throw error;
  }
  if (!registered) {
    // The owning FFI call vanished (cancelled / completed) before its upload landed; same orphan, same fix.
    await blobStore.delete(projectId, blobId).catch(() => {});
    throw new ConflictError("the FFI call that produced this blob is no longer in flight");
  }
  return { id: blobId, hash, size };
}
