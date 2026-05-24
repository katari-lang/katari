# syntax=docker/dockerfile:1.7
#
# Build context expected at repo root (so the whole pnpm workspace is
# visible). Build with:
#
#   docker build -f typescript/packages/katari-api-server/Dockerfile -t katari .
#
# At runtime the container reads:
#   DATABASE_URL              (required)  Postgres connection string
#   KATARI_API_KEY            (required)  Bearer token; "disabled" turns auth off (dev only)
#   KATARI_SECRET_KEY         (required)  32-byte hex; AES-GCM key for env secret encryption
#   PORT                      (default 8000)
#   LOG_LEVEL                 (default "info")
#   KATARI_ADMIN_WEB_DIST     (default /app/admin-web/dist; set to "" to disable the UI)
#
# Apply schema.sql (shipped at /app/share/schema.sql) to your Postgres
# instance before first launch — or set KATARI_AUTO_MIGRATE=true (default).

# ---------------------------------------------------------------------------
# Stage 1: build the TS workspace with pnpm. Produces a self-contained deploy
# dir for katari-api-server plus a static dist/ for katari-admin-web.
# ---------------------------------------------------------------------------
FROM node:24-alpine AS builder

ENV PNPM_HOME=/pnpm
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable && corepack prepare pnpm@11.1.3 --activate

WORKDIR /work

# Copy workspace manifests first so dependency installs cache well.
COPY pnpm-workspace.yaml package.json pnpm-lock.yaml ./
COPY typescript/package.json typescript/
COPY typescript/tsconfig.base.json typescript/
COPY typescript/packages/katari-runtime/package.json typescript/packages/katari-runtime/
COPY typescript/packages/katari-api-server/package.json typescript/packages/katari-api-server/
COPY typescript/packages/katari-admin-web/package.json typescript/packages/katari-admin-web/

# Install transitive deps for both api-server and admin-web.
# admin-web's build needs its devDeps (vite / tailwind / monaco / react), so we
# install the full set here; only the api-server slice gets shipped in stage 2.
RUN pnpm install --frozen-lockfile \
      --filter "@katari-lang/api-server..." \
      --filter "@katari-lang/admin-web..."

# Copy sources and build.
COPY typescript/packages/katari-runtime/ typescript/packages/katari-runtime/
COPY typescript/packages/katari-api-server/ typescript/packages/katari-api-server/
COPY typescript/packages/katari-admin-web/ typescript/packages/katari-admin-web/
RUN pnpm --filter @katari-lang/runtime build \
 && pnpm --filter @katari-lang/api-server build \
 && pnpm --filter @katari-lang/admin-web build

# Produce a self-contained deploy dir with prod deps inlined for api-server.
# `--legacy` is required since pnpm 10: the new default deploy behavior
# expects `inject-workspace-packages=true`, which we don't use. Legacy
# deploy resolves workspace deps directly from node_modules.
RUN pnpm --filter @katari-lang/api-server deploy --legacy --prod /deploy

# ---------------------------------------------------------------------------
# Stage 2: minimal runtime image.
# ---------------------------------------------------------------------------
FROM node:24-alpine

RUN apk add --no-cache tini

WORKDIR /app

COPY --from=builder /deploy/ ./
COPY --from=builder /work/typescript/packages/katari-api-server/src/storage/schema.sql /app/share/schema.sql
# Admin SPA static assets. Served at /admin/* by the api-server when
# KATARI_ADMIN_WEB_DIST is set (= the ENV below). To disable the UI in a
# deployment, pass `KATARI_ADMIN_WEB_DIST=""`.
COPY --from=builder /work/typescript/packages/katari-admin-web/dist/ /app/admin-web/dist/

ENV NODE_ENV=production
ENV PORT=8000
ENV LOG_LEVEL=info
ENV KATARI_ADMIN_WEB_DIST=/app/admin-web/dist

EXPOSE 8000

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "dist/bin.js"]
