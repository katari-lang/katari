/**
 * A compiled FFI sidecar bundle: the single ESM module that hosts a snapshot's external (FFI) handlers.
 * The CLI's bundler (`@katari-lang/bundle`) produces one per deploy and uploads it with the snapshot; the
 * runtime stores it verbatim and, when a run reaches an `external` block, spawns it as the FFI sidecar
 * process. `entry` is the bundle's JavaScript source; `runtime` names the host that executes it (only Node
 * today). A snapshot with no external handlers has no bundle at all (the field is absent / null).
 */
export type SidecarBundle = {
  /** The bundled ESM source — the whole sidecar in one module, ready to run with `node`. */
  entry: string;
  /** The host that executes `entry`. Node is the only target in v0.1. */
  runtime: "node";
};
