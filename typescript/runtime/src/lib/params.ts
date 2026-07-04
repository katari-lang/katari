// Shared path-param schemas. Every project-scoped resource carries `:projectId`, so the base lives
// here once instead of being respelled per module; composite params (`:key`, `:runId`, …) `.extend()`
// it so the project-id rule stays identical across every route.

import { z } from "zod";

export const projectIdParamSchema = z.object({ projectId: z.uuid() });
