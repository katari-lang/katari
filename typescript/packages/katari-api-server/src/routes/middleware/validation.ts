// Zod-backed request validators for the HTTP layer.
//
// We define schemas in one place and let route handlers parse with them so:
//   - validation errors are rendered as a structured 400 response, not a
//     generic 500 from a downstream type cast,
//   - branded id types (VersionId / AgentId / DelegationId) become real
//     UUID-validated brands instead of blind `as VersionId` casts at the
//     route boundary.
//
// JSON parse failures (`c.req.json()` throwing on malformed input) are
// caught by the top-level `onError` handler in `routes/app.ts` and turned
// into 400, so they don't reach the schemas here.

import { z } from "zod";
import type { AgentId, VersionId } from "../../storage/types.js";

// ─── Branded id schemas ─────────────────────────────────────────────────────

/** UUID (v4 / v7) that the domain treats as a `VersionId`. */
export const VersionIdSchema = z
  .string()
  .uuid()
  .transform((s) => s as VersionId);

export const AgentIdSchema = z
  .string()
  .uuid()
  .transform((s) => s as AgentId);

// ─── Value schema ──────────────────────────────────────────────────────────
//
// Mirrors `katari-runtime`'s `Value` type. We accept the full structural
// shape but treat the contents loosely — the runtime will type-check once
// the value actually reaches a prim or pattern. Keeping the schema lax at
// the HTTP boundary means a tagged value with a custom field set still
// flows through (only the outer envelope is checked).

const ValueSchema: z.ZodType<unknown> = z.lazy(() =>
  z.union([
    z.object({ kind: z.literal("number"), value: z.number() }),
    z.object({ kind: z.literal("string"), value: z.string() }),
    z.object({ kind: z.literal("boolean"), value: z.boolean() }),
    z.object({ kind: z.literal("null") }),
    z.object({ kind: z.literal("tuple"), elements: z.array(ValueSchema) }),
    z.object({ kind: z.literal("array"), elements: z.array(ValueSchema) }),
    z.object({
      kind: z.literal("tagged"),
      ctorId: z.number(),
      fields: z.record(z.string(), ValueSchema),
    }),
    z.object({
      kind: z.literal("closure"),
      blockId: z.number(),
      scopeId: z.string(),
    }),
  ]),
);

// ─── Route input schemas ────────────────────────────────────────────────────

/**
 * Optional `?limit=` and `?offset=` query parameters for list endpoints.
 * Storage clamps further if the client picks something silly; this schema
 * just enforces shape (positive integers).
 */
export const PaginationQuerySchema = z.object({
  limit: z.coerce.number().int().positive().optional(),
  offset: z.coerce.number().int().nonnegative().optional(),
});

export const StartAgentSchema = z.object({
  versionId: VersionIdSchema,
  qualifiedName: z.string().min(1),
  args: z.record(z.string(), ValueSchema),
});
export type StartAgentInput = z.infer<typeof StartAgentSchema>;

export const UploadModuleSchema = z.object({
  // We don't deeply validate the IRModule structure here — that's the
  // compiler's contract, and re-encoding the entire IR shape in Zod would
  // create a parallel maintenance burden. The runtime will reject malformed
  // IR at first use.
  irModule: z.unknown().refine((v) => typeof v === "object" && v !== null, {
    message: "irModule must be an object",
  }),
  schemaBundle: z.unknown().refine((v) => typeof v === "object" && v !== null, {
    message: "schemaBundle must be an object",
  }),
});
export type UploadModuleInput = z.infer<typeof UploadModuleSchema>;
