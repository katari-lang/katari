// HTTP contract for the agent resource: the callable schemas a snapshot exposes (read from the IR).
// Statelessly implementable later (it only reads the module store); the contract is frozen here.

import { z } from "zod";
import { projectIdParamSchema } from "../../lib/params.js";

// Shared by both reads (list agents and fetch one): which snapshot to read from, defaulting to the
// project head when omitted, so the two endpoints are scoped identically.
export const agentSnapshotQuerySchema = z.object({
  snapshotId: z.uuid().optional(),
});

export const agentParamSchema = projectIdParamSchema.extend({
  qualifiedName: z.string().min(1),
});
