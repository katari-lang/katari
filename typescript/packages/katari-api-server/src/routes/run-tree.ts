// Run-tree route. Mounted at `/project/:projectId/run/:runId/tree`.
//
// Returns the live delegation tree rooted at `runId`, plus its root's
// audit state. The admin UI polls this every few seconds while the
// run is in flight to drive the tree visualization.

import { Hono } from "hono";
import { type DelegationTreeService, RunNotFound } from "../services/delegation-tree-service.js";
import { ProjectIdSchema, RunIdSchema } from "./middleware/validation.js";

export function buildRunTreeRoutes(treeService: DelegationTreeService): Hono {
  const app = new Hono();

  app.get("/", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const runId = RunIdSchema.parse(c.req.param("runId"));
    try {
      const tree = await treeService.getTree(runId, projectId);
      return c.json({ tree });
    } catch (err) {
      if (err instanceof RunNotFound) {
        return c.json({ error: err.message }, 404);
      }
      throw err;
    }
  });

  return app;
}
