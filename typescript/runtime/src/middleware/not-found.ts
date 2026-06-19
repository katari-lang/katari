import type { NotFoundHandler } from "hono";
import type { ErrorBody } from "../lib/response.js";

// `route_not_found` (no such route), distinct from the domain `not_found` a `NotFoundError` raises
// (the route exists, the addressed resource does not), so a client can tell the two apart.
export const notFound: NotFoundHandler = (c) => {
  const body: ErrorBody = {
    ok: false,
    error: {
      code: "route_not_found",
      message: `Cannot ${c.req.method} ${c.req.path}`,
    },
  };
  return c.json(body, 404);
};
