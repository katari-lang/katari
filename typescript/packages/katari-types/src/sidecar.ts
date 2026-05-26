// Sidecar bundle type.
//
// **Sidecar**: subprocess that the FFI Runner spawns per snapshot. The
// user's bundled JS (built with the Katari CLI + `katari-port`) runs
// inside. This file contains only the bundle shape; the IPC protocol
// types remain in `katari-runtime` because they depend on runtime-
// internal id types (`DelegationId`, `AgentDefId`).

/**
 * Bundled sidecar source. v1 is a single ESM string (esbuild output)
 * that the runtime writes to a temp file and launches with `node`. The
 * bundle is expected to import `katari-port` and call
 * `__startSidecar()` at the very end of evaluation.
 */
export type SidecarBundle = {
  /** Bundled JS source. The runtime writes this to a temp file and `node` it. */
  entry: string;
  runtime: "node";
  schemaVersion: 1;
};
