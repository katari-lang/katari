// Project routes: upsert / list / get.
//
// `katari apply` 時の最初の HTTP コール = `POST /project { name }`。
// 同名 project があれば既存を返す (idempotent)。

import { Hono } from "hono";
import {
  CreateProjectSchema,
  PaginationQuerySchema,
  ProjectIdSchema,
} from "./middleware/validation.js";
import {
  ProjectNotFound,
  type ProjectService,
} from "../services/project-service.js";

export function buildProjectRoutes(projects: ProjectService): Hono {
  const app = new Hono();

  app.post("/", async (c) => {
    const body = CreateProjectSchema.parse(await c.req.json());
    const project = await projects.upsertByName(body.name);
    return c.json({ project }, 201);
  });

  app.get("/", async (c) => {
    const query = PaginationQuerySchema.parse(c.req.query());
    const list = await projects.list(query);
    return c.json({ projects: list });
  });

  app.get("/:projectId", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    try {
      const project = await projects.get(projectId);
      return c.json({ project });
    } catch (err) {
      if (err instanceof ProjectNotFound) {
        return c.json({ error: err.message }, 404);
      }
      throw err;
    }
  });

  app.get("/by-name/:name", async (c) => {
    const project = await projects.getByName(c.req.param("name"));
    if (project === null) {
      return c.json({ error: "project not found" }, 404);
    }
    return c.json({ project });
  });

  return app;
}
