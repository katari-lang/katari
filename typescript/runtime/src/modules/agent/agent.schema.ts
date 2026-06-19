// HTTP contract for the agent resource: the callable schemas a snapshot exposes (read from the IR).
// Statelessly implementable later (it only reads the module store); the contract is frozen here.

import { z } from "zod";

export const listAgentsQuerySchema = z.object({
  /** Which snapshot's agents to list; defaults to the project head when omitted. */
  snapshotId: z.uuid().optional(),
});

export const projectIdParamSchema = z.object({ projectId: z.uuid() });
export const agentParamSchema = z.object({
  projectId: z.uuid(),
  qualifiedName: z.string().min(1),
});
