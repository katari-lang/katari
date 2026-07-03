// SnapshotFfiTransport: the production `FfiTransport` for a project actor. An FFI handler lives in a
// specific snapshot's compiled sidecar bundle (the `key` is only defined there), so this multiplexes one
// `SubprocessFfiTransport` per snapshot — each a `node` process running that snapshot's bundle — and routes
// every call to the process for its `call.snapshot`. All processes report completions to the one shared
// sink (the ffi reactor's mailbox feed). The per-snapshot process inherits the subprocess transport's
// crash → fail-in-flight → respawn behaviour for free.
//
// The bundle bytes and the way a bundle becomes a running process are injected (`bundleSource` /
// `materialize`), so the routing is unit-testable without a real DB or a real `node`; production wires the
// `snapshots` table and a temp-file + `node` spawn.

import { writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { SidecarBundle } from "@katari-lang/types";
import type { DelegationId, ProjectId, SnapshotId } from "../ids.js";
import type {
  FfiCall,
  FfiCompletion,
  FfiInnerDelegate,
  FfiInnerResult,
  FfiTransport,
} from "./runner.js";
import type { SidecarSpawner } from "./subprocess-runner.js";
import { SubprocessFfiTransport, subprocessSidecar } from "./subprocess-runner.js";

/** Fetch a snapshot's compiled sidecar bundle (or null when that snapshot has no FFI handlers). */
export type BundleSource = (
  projectId: ProjectId,
  snapshot: SnapshotId,
) => Promise<SidecarBundle | null>;

/** Turn a bundle into a spawner for its sidecar process (write it out, spawn the host). Injected so the
 *  routing is testable with a fake process. `projectId` is passed through so the materialization can hand the
 *  process its project context (the blob side channel's env). */
export type Materialize = (
  bundle: SidecarBundle,
  snapshot: SnapshotId,
  projectId: ProjectId,
) => Promise<SidecarSpawner>;

export class SnapshotFfiTransport implements FfiTransport {
  private sink: ((completion: FfiCompletion) => void) | null = null;
  private delegateSink: ((request: FfiInnerDelegate) => void) | null = null;
  /** One sub-transport (one sidecar process) per snapshot, cached as the in-flight spawn promise so two
   *  concurrent dispatches for the same snapshot share a single process. */
  private readonly perSnapshot = new Map<SnapshotId, Promise<SubprocessFfiTransport>>();
  /** Which snapshot each in-flight delegation belongs to, so an `abort` / a `deliverDelegateResult`
   *  (delegation only) routes to the right process. Cleared when the call completes. */
  private readonly delegationSnapshot = new Map<DelegationId, SnapshotId>();

  constructor(
    private readonly bundleSource: BundleSource,
    private readonly materialize: Materialize,
  ) {}

  onComplete(sink: (completion: FfiCompletion) => void): void {
    this.sink = sink;
  }

  onDelegate(sink: (request: FfiInnerDelegate) => void): void {
    this.delegateSink = sink;
  }

  dispatch(call: FfiCall): void {
    this.delegationSnapshot.set(call.delegation, call.snapshot);
    // Resolving the snapshot's process is async (bundle fetch + spawn); dispatch stays fire-and-forget, and
    // a fetch / spawn failure surfaces as an `error` completion so the call never hangs.
    void this.transportFor(call.projectId, call.snapshot).then(
      (transport) => transport.dispatch(call),
      (error: unknown) => this.fail(call.delegation, error),
    );
  }

  abort(delegation: DelegationId): void {
    const snapshot = this.delegationSnapshot.get(delegation);
    if (snapshot === undefined) {
      // No in-flight call for this delegation — a recovery abort of a call whose sidecar died with the process
      // (its request is gone), so there is nothing to signal. Confirm the teardown straight away so the reactor
      // can terminateAck. (A late terminate for an already-completed call also lands here; the reactor drops
      // the call on the first completion and ignores any that follow, so a spurious confirmation is harmless.)
      this.sink?.({ delegation, outcome: { kind: "cancelled" } });
      return;
    }
    // Only abort if the process is up; if its spawn is still pending, the dispatch has not gone out yet.
    void this.perSnapshot.get(snapshot)?.then((transport) => transport.abort(delegation));
  }

  deliverDelegateResult(result: FfiInnerResult): void {
    const snapshot = this.delegationSnapshot.get(result.delegation);
    if (snapshot === undefined) return; // the parent call is gone — the result is moot, drop it
    void this.perSnapshot
      .get(snapshot)
      ?.then((transport) => transport.deliverDelegateResult(result));
  }

  /** Kill every sidecar process (host cleanup on actor disposal). */
  close(): void {
    for (const pending of this.perSnapshot.values()) {
      void pending.then((transport) => transport.close()).catch(() => {});
    }
    this.perSnapshot.clear();
  }

  private transportFor(
    projectId: ProjectId,
    snapshot: SnapshotId,
  ): Promise<SubprocessFfiTransport> {
    const existing = this.perSnapshot.get(snapshot);
    if (existing !== undefined) return existing;
    const created = (async () => {
      const bundle = await this.bundleSource(projectId, snapshot);
      if (bundle === null) {
        throw new Error(`snapshot ${snapshot} has no FFI sidecar bundle to dispatch to`);
      }
      const transport = new SubprocessFfiTransport(
        await this.materialize(bundle, snapshot, projectId),
      );
      transport.onComplete((completion) => {
        this.delegationSnapshot.delete(completion.delegation);
        this.sink?.(completion);
      });
      transport.onDelegate((request) => this.delegateSink?.(request));
      return transport;
    })();
    // Do not cache a failed spawn — a later dispatch should be able to retry rather than inherit the error.
    created.catch(() => this.perSnapshot.delete(snapshot));
    this.perSnapshot.set(snapshot, created);
    return created;
  }

  private fail(delegation: DelegationId, error: unknown): void {
    this.delegationSnapshot.delete(delegation);
    this.sink?.({
      delegation,
      outcome: { kind: "error", message: error instanceof Error ? error.message : String(error) },
    });
  }
}

/** The production materialization, parameterized by the runtime's own base URL: write the bundle's ESM to a
 *  per-snapshot temp file and spawn it with `node`, handing the process ONLY the env the blob side channel
 *  needs (the runtime URL to reach, and the project id to scope its blobs) — the sidecar does not inherit the
 *  runtime's environment. `node` is spawned by its absolute path (`process.execPath`, the runtime's own
 *  interpreter), so it resolves without an inherited `PATH` and the sidecar runs the same node version. A
 *  snapshot's bundle is immutable, so the file is written once per snapshot per process. */
export function nodeSidecarMaterialize(runtimeBaseUrl: string): Materialize {
  return async (bundle, snapshot, projectId) => {
    const path = join(tmpdir(), `katari-sidecar-${snapshot}.mjs`);
    await writeFile(path, bundle.entry);
    return subprocessSidecar(process.execPath, [path], {
      KATARI_RUNTIME_URL: runtimeBaseUrl,
      KATARI_PROJECT_ID: projectId,
    });
  };
}
