import type { ContentfulStatusCode } from "hono/utils/http-status";

/**
 * Base class for expected, domain-level failures. Anything thrown that is an
 * `AppError` is translated into a structured HTTP response by the error
 * handler middleware; anything else becomes a 500.
 */
export class AppError extends Error {
  readonly status: ContentfulStatusCode;
  readonly code: string;
  readonly details?: unknown;

  constructor(status: ContentfulStatusCode, code: string, message: string, details?: unknown) {
    super(message);
    this.name = new.target.name;
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

export class BadRequestError extends AppError {
  constructor(message = "Bad Request", details?: unknown) {
    super(400, "bad_request", message, details);
  }
}

export class NotFoundError extends AppError {
  constructor(message = "Resource not found", details?: unknown) {
    super(404, "not_found", message, details);
  }
}

export class ConflictError extends AppError {
  constructor(message = "Conflict", details?: unknown) {
    super(409, "conflict", message, details);
  }
}

export class UnsupportedMediaTypeError extends AppError {
  constructor(message = "Unsupported Media Type", details?: unknown) {
    super(415, "unsupported_media_type", message, details);
  }
}

export class UnprocessableEntityError extends AppError {
  constructor(message = "Unprocessable Entity", details?: unknown) {
    super(422, "unprocessable_entity", message, details);
  }
}

export class NotImplementedError extends AppError {
  constructor(message = "Not Implemented", details?: unknown) {
    super(501, "not_implemented", message, details);
  }
}
