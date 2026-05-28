// Orchestrator — thin re-export layer.
//
// The Orchestrator class now lives in `@katari-lang/runtime`. This module
// re-exports it alongside the api-server-specific adapter that wires
// concrete Storage + adapters. Route handlers should use
// `ApiServerOrchestrator` so `ctx.api` is typed as the concrete `ApiModule`.

export type { TickContext } from "@katari-lang/runtime";
export {
  NoSnapshotForProject,
  Orchestrator,
  SnapshotNotFound,
} from "@katari-lang/runtime";
export type { ApiServerTickContext } from "./orchestrator-adapter.js";
export {
  ApiServerOrchestrator,
  createApiServerOrchestrator,
} from "./orchestrator-adapter.js";
