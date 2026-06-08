# @katari-lang/runtime

Hono-based API server for Katari. Feature-modular, layered architecture.

## Layout

```
src/
  bin.ts            # process entry: loads config, serves the app, graceful shutdown
  index.ts          # public exports: app, createApp, AppType, response types
  app.ts            # app factory: global middleware + error/404 boundaries + routes
  routes.ts         # mounts feature modules under /api/v1
  config/           # env parsing/validation (zod) -> typed, immutable config
  types/            # AppEnv (Hono Variables/Bindings)
  lib/              # cross-cutting: logger, errors (AppError), response envelope
  middleware/       # request-context (id + scoped logger), error-handler, not-found
  modules/          # one folder per feature (vertical slice)
    health/
    users/
      users.routes.ts      # HTTP layer (Hono router + zod validation)
      users.service.ts     # business logic + invariants -> domain errors
      users.repository.ts  # data access (dummy in-memory store)
      users.schema.ts      # zod schemas + inferred types (single source of truth)
```

The layering per feature is **routes → service → repository**; HTTP details stay
in routes, invariants in the service, persistence in the repository. Swapping
the in-memory store for a real database only touches `*.repository.ts`.

## Responses

Every endpoint returns a uniform envelope:

- success: `{ "ok": true, "data": ... }`
- error:   `{ "ok": false, "error": { "code", "message", "details?" } }`

## Endpoints (dummy data)

| Method | Path                  | Notes                          |
| ------ | --------------------- | ------------------------------ |
| GET    | `/`                   | service info                   |
| GET    | `/api/v1/health`      | health + uptime                |
| GET    | `/api/v1/users`       | `?limit&offset&role`           |
| POST   | `/api/v1/users`       | validated; 201 / 400 / 409     |
| GET    | `/api/v1/users/:id`   | 200 / 404                      |
| PATCH  | `/api/v1/users/:id`   | partial update                 |
| DELETE | `/api/v1/users/:id`   | 204 / 404                      |

## Scripts

```
pnpm dev         # tsx watch (hot reload)
pnpm build       # tsdown -> dist (esm + d.ts)
pnpm start       # node dist/bin.mjs
pnpm test        # vitest (uses app.request, no network)
pnpm typecheck   # tsc --noEmit
```

Config via env: `PORT` (3000), `LOG_LEVEL` (info), `NODE_ENV` (development).
