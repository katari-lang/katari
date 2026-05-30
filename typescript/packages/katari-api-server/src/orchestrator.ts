// Warm per-project actor host — thin re-export layer.
//
// The old per-snapshot Orchestrator is gone (Phase E). Route handlers use
// `ApiServerActorHost.runForProject(projectId, fn)` and call domain methods on
// `ctx.modules.api`.

export type {
  ApiServerActorContext,
  ApiServerModules,
} from "./actor-host.js";
export { ApiServerActorHost, createApiServerHost } from "./actor-host.js";
export { NoSnapshotForProject, SnapshotNotFound } from "./services/snapshot-service.js";
