// Shared types for the CLI.

import type { IRModule, SchemaBundle, SidecarBundle, Value } from "katari-runtime";

export type KatariConfig = {
  /** project の論理名 (api-server で upsertByName される)。 */
  project: string;
  compile: {
    src: string;
    root?: string;
  };
  sidecar?: {
    entry: string;
  };
  api: {
    url: string;
    auth?: string;
  };
};

export type CompileOutput = {
  irModule: IRModule;
  schemaBundle: SchemaBundle;
};

export type AppliedSnapshot = {
  projectId: string;
  snapshotId: string;
};

export type { Value, SidecarBundle, IRModule, SchemaBundle };
