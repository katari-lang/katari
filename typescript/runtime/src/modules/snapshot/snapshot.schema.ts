// HTTP contract for the snapshot resource (see docs/2026-06-19-per-module-snapshot.md §3).
//
// A deploy sends the *complete* desired manifest: one entry per module name, each carrying its
// content `hash`. `ir` is inlined only for modules the runtime does not already hold — the CLI
// diffs against `GET .../snapshots/head` first and omits unchanged modules' bytes.

import type { IRModule } from "@katari-lang/types";
import { z } from "zod";
import { projectIdParamSchema } from "../../lib/params.js";

export { projectIdParamSchema };

// An `IRModule` is a JSON object. Its full shape is not validated here (it is content-addressed and
// stored verbatim — only the CLI computes the hash), but a non-object or an array can never be a
// module IR, so we reject those at the boundary instead of persisting garbage into the store.
const isModuleObject = (value: unknown): value is IRModule =>
  typeof value === "object" && value !== null && !Array.isArray(value);

// Postgres `jsonb`/`text` cannot store a U+0000 codepoint: an INSERT carrying one aborts the whole
// deploy transaction with a driver error (a 500). Reject it at the boundary so a bad upload is a
// clean 422 instead.
const containsNullByte = (value: unknown): boolean => {
  if (typeof value === "string") return value.includes("\u0000");
  if (Array.isArray(value)) return value.some(containsNullByte);
  if (value !== null && typeof value === "object")
    return Object.values(value).some(containsNullByte);
  return false;
};
const noNullByte = (value: unknown): boolean => !containsNullByte(value);
const NULL_BYTE_MESSAGE = "must not contain a NUL character (U+0000)";

export const moduleUploadSchema = z.object({
  hash: z.string().min(1),
  /** The lowered IR, present only when the runtime lacks this hash. Stored verbatim, not re-checked. */
  ir: z.custom<IRModule>(isModuleObject).refine(noNullByte, NULL_BYTE_MESSAGE).optional(),
});

// A reserved object key (`__proto__` especially) used as a module name is silently dropped while
// parsing the body, so it can never reach this schema — it is rejected earlier, on the raw body, by
// the `rejectReservedModuleNames` middleware (see snapshot.middleware.ts).
export const deploySnapshotSchema = z.object({
  message: z.string().min(1).refine(noNullByte, NULL_BYTE_MESSAGE),
  sidecarBundle: z.unknown().refine(noNullByte, NULL_BYTE_MESSAGE).optional(),
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
