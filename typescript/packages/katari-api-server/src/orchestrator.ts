// Orchestrator — thin re-export layer.
//
// The Orchestrator class now lives in `@katari-lang/runtime`. This module
// re-exports it alongside the api-server-specific adapter that wires
// concrete Storage + adapters. Route handlers should use
// `ApiServerOrchestrator` so `ctx.api` is typed as the concrete `ApiModule`.

export {
  Orchestrator,
  SnapshotNotFound,
  NoSnapshotForProject,
} from "@katari-lang/runtime";
export type { TickContext } from "@katari-lang/runtime";

export {
  createApiServerOrchestrator,
  ApiServerOrchestrator,
} from "./orchestrator-adapter.js";
export type { ApiServerTickContext } from "./orchestrator-adapter.js";
