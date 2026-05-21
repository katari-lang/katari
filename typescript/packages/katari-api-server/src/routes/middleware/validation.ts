// Zod-backed request validators.

import { z } from "zod";
import type {
  AgentId,
  EscalationId,
  ProjectId,
  SnapshotId,
} from "../../storage/types.js";

// ─── Branded id schemas ────────────────────────────────────────────────────

export const ProjectIdSchema = z
  .string()
  .uuid()
  .transform((s) => s as ProjectId);

export const SnapshotIdSchema = z
  .string()
  .uuid()
  .transform((s) => s as SnapshotId);

export const AgentIdSchema = z
  .string()
  .uuid()
  .transform((s) => s as AgentId);

// Escalations are runtime-generated UUIDs (see katari-runtime); the
// previous `min(1)` shape accepted arbitrary strings, which then broke
// downstream DB query type coercion when callers passed garbage.
export const EscalationIdSchema = z
  .string()
  .uuid()
  .transform((s) => s as EscalationId);

// ─── Raw value schema ──────────────────────────────────────────────────────
//
// Wire format is JSON-shaped raw with `$ctor` / `$callable` discriminators
// where structural identity matters (tagged values, callables). The
// runtime adapter (`valueFromRaw` from `katari-runtime`) decodes this
// into a `Value` before handing it to CORE.

const RawValueSchema: z.ZodType<unknown> = z.lazy(() =>
  z.union([
    z.number(),
    z.string(),
    z.boolean(),
    z.null(),
    z.array(RawValueSchema),
    z.record(z.string(), RawValueSchema),
  ]),
);

// ─── Pagination ────────────────────────────────────────────────────────────

// Pagination query: limit is bounded so a client passing `?limit=999999999`
// can't ask storage for an arbitrarily large page. Storage layers already
// clamp at MAX_LIMIT=500; mirror that here so validation rejects loudly
// rather than silently truncating.
export const PaginationQuerySchema = z.object({
  limit: z.coerce.number().int().positive().max(500).optional(),
  offset: z.coerce.number().int().nonnegative().optional(),
});

// ─── Project / Snapshot ────────────────────────────────────────────────────

export const CreateProjectSchema = z.object({
  name: z.string().min(1),
});
export type CreateProjectInput = z.infer<typeof CreateProjectSchema>;

const SidecarBundleSchema = z.object({
  entry: z.string(),
  runtime: z.literal("node"),
  schemaVersion: z.literal(1),
});

// Minimal shape check for an IR module — enough to reject obviously
// malformed payloads at upload time so a bad blob can't end up
// committed to DB only to crash every subsequent tick that loads it.
// We deliberately stop short of validating block-by-block structure
// because the engine itself does that on load and surfaces clearer
// errors.
const IRModuleShapeSchema = z
  .object({
    metadata: z.object({ schemaVersion: z.literal(1) }),
    blocks: z.record(z.string(), z.unknown()),
    entries: z.record(z.string(), z.unknown()),
    nameTable: z.unknown(),
  })
  .passthrough();

const SchemaBundleShapeSchema = z
  .object({
    schemaVersion: z.literal(1),
    agents: z.array(z.unknown()),
  })
  .passthrough();

export const UploadSnapshotSchema = z.object({
  irModule: IRModuleShapeSchema,
  sidecarBundle: SidecarBundleSchema.nullable().optional().default(null),
  schemaBundle: SchemaBundleShapeSchema,
});
export type UploadSnapshotInput = z.infer<typeof UploadSnapshotSchema>;

// ─── Agent / Escalation ────────────────────────────────────────────────────

export const StartAgentSchema = z.object({
  projectId: ProjectIdSchema,
  snapshotId: SnapshotIdSchema.optional(),
  qualifiedName: z.string().min(1),
  args: z.record(z.string(), RawValueSchema),
});
export type StartAgentInput = z.infer<typeof StartAgentSchema>;

export const AnswerEscalationSchema = z.object({
  value: RawValueSchema,
});
export type AnswerEscalationInput = z.infer<typeof AnswerEscalationSchema>;
