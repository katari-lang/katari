// HTTP contract for the snapshot resource (see docs/2026-06-19-per-module-snapshot.md §3).
//
// A deploy sends the *complete* desired manifest: one entry per module name, each carrying its
// content `hash`. `ir` is inlined only for modules the runtime does not already hold — the CLI
// diffs against `GET .../snapshots/head` first and omits unchanged modules' bytes.
//
// Two boundary hazards (a reserved object key used as a module name, and a NUL codepoint Postgres
// cannot store) are caught earlier, on the raw body, by the `screenRawDeployBody` middleware — they
// cannot be expressed here, since the parsed body the validator sees has already lost a stripped
// `__proto__` key. See snapshot.middleware.ts.

import type { IRModule, SidecarBundle } from "@katari-lang/types";
import { z } from "zod";
import { projectIdParamSchema } from "../../lib/params.js";

// An `IRModule` is a JSON object. Its full shape is not validated here (it is content-addressed and
// stored verbatim — only the CLI computes the hash), but a non-object or an array can never be a
// module IR, so we reject those at the boundary instead of persisting garbage into the store.
const isModuleObject = (value: unknown): value is IRModule =>
  typeof value === "object" && value !== null && !Array.isArray(value);

export const moduleUploadSchema = z.object({
  hash: z.string().min(1),
  /** The lowered IR, present only when the runtime lacks this hash. Stored verbatim, not re-checked. */
  ir: z.custom<IRModule>(isModuleObject).optional(),
});

// The compiled FFI sidecar bundle, as produced by `@katari-lang/bundle` and uploaded with the deploy.
// Stored verbatim and only ever handed back to a `node` sidecar process, so the bytes are not validated
// beyond their shape — `entry` is opaque JavaScript the runtime never parses.
const sidecarBundleSchema = z.object({
  entry: z.string(),
  runtime: z.literal("node"),
}) satisfies z.ZodType<SidecarBundle>;

export const deploySnapshotSchema = z.object({
  message: z.string().min(1),
  /** Present only when the snapshot has external (FFI) handlers; absent otherwise (no sidecar runs). */
  sidecarBundle: sidecarBundleSchema.optional(),
  /** The full manifest: module name -> { hash, ir? }. A deploy describes the complete desired world,
   *  so at least one module is required — an empty manifest is rejected rather than made head. */
  modules: z
    .record(z.string(), moduleUploadSchema)
    .refine((modules) => Object.keys(modules).length > 0, {
      message: "A deploy must include at least one module.",
    }),
});
export type DeploySnapshotInput = z.infer<typeof deploySnapshotSchema>;

export const snapshotParamSchema = projectIdParamSchema.extend({ snapshotId: z.uuid() });

/** `PUT .../snapshots/head` — move the live head to an existing snapshot (a rollback / roll-forward). */
export const setHeadSchema = z.object({ snapshotId: z.uuid() });
