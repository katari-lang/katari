// Zod-backed request validators.

import { z } from "zod";
import type {
  AgentId,
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

export const EscalationIdSchema = z.string().min(1);

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

export const PaginationQuerySchema = z.object({
  limit: z.coerce.number().int().positive().optional(),
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

export const UploadSnapshotSchema = z.object({
  irModule: z.unknown().refine((v) => typeof v === "object" && v !== null, {
    message: "irModule must be an object",
  }),
  sidecarBundle: SidecarBundleSchema.nullable().optional().default(null),
  schemaBundle: z.unknown().refine((v) => typeof v === "object" && v !== null, {
    message: "schemaBundle must be an object",
  }),
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
