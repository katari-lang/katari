import type { NotFoundHandler } from "hono";
import type { ErrorBody } from "../lib/response.js";

export const notFound: NotFoundHandler = (c) => {
  const body: ErrorBody = {
    ok: false,
    error: {
      code: "not_found",
      message: `Cannot ${c.req.method} ${c.req.path}`,
    },
  };
  return c.json(body, 404);
};
