// HTTP contract for the snapshot resource (see docs/2026-06-19-per-module-snapshot.md §3).
//
// A deploy sends the *complete* desired manifest: one entry per module name, each carrying its
// content `hash`. `ir` is inlined only for modules the runtime does not already hold — the CLI
// diffs against `GET .../snapshots/head` first and omits unchanged modules' bytes.

import type { IRModule } from "@katari-lang/types";
import { z } from "zod";

const isObject = (value: unknown): boolean => typeof value === "object" && value !== null;

export const moduleUploadSchema = z.object({
  hash: z.string().min(1),
  /** The lowered IR, present only when the runtime lacks this hash. Stored verbatim, not re-checked. */
  ir: z.custom<IRModule>(isObject).optional(),
});

export const deploySnapshotSchema = z.object({
  message: z.string().min(1),
  sidecarBundle: z.unknown().optional(),
  /** The full manifest: module name -> { hash, ir? }. */
  modules: z.record(z.string(), moduleUploadSchema),
});
export type DeploySnapshotInput = z.infer<typeof deploySnapshotSchema>;

export const projectIdParamSchema = z.object({ projectId: z.uuid() });
export const snapshotParamSchema = z.object({ projectId: z.uuid(), snapshotId: z.uuid() });
