# syntax=docker/dockerfile:1.7
#
# Build context expected at repo root (so the whole pnpm workspace is
# visible). Build with:
#
#   docker build -f typescript/packages/katari-api-server/Dockerfile -t katari-runtime .
#
# At runtime the container reads:
#   DATABASE_URL  (required)  Postgres connection string
#   PORT          (default 8080)
#   LOG_LEVEL     (default "info")
#
# Apply schema.sql (shipped at /app/share/schema.sql) to your Postgres
# instance before first launch.

# ---------------------------------------------------------------------------
# Stage 1: build the TS workspace with pnpm and produce a self-contained
# deploy directory for katari-api-server.
# ---------------------------------------------------------------------------
FROM node:20-alpine AS builder

ENV PNPM_HOME=/pnpm
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable && corepack prepare pnpm@9.15.9 --activate

WORKDIR /work

# Copy workspace manifests first so dependency installs cache well.
COPY pnpm-workspace.yaml package.json pnpm-lock.yaml ./
COPY typescript/package.json typescript/
COPY typescript/tsconfig.base.json typescript/
COPY typescript/packages/katari-runtime/package.json typescript/packages/katari-runtime/
COPY typescript/packages/katari-api-server/package.json typescript/packages/katari-api-server/

# Install only the deps needed for katari-api-server's transitive set.
RUN pnpm install --frozen-lockfile --filter "katari-api-server..."

# Copy sources and build.
COPY typescript/packages/katari-runtime/ typescript/packages/katari-runtime/
COPY typescript/packages/katari-api-server/ typescript/packages/katari-api-server/
RUN pnpm --filter katari-runtime build \
 && pnpm --filter katari-api-server build

# Produce a self-contained deploy dir with prod deps inlined.
RUN pnpm --filter katari-api-server deploy --prod /deploy

# ---------------------------------------------------------------------------
# Stage 2: minimal runtime image.
# ---------------------------------------------------------------------------
FROM node:20-alpine

RUN apk add --no-cache tini

WORKDIR /app

COPY --from=builder /deploy/ ./
COPY --from=builder /work/typescript/packages/katari-api-server/src/storage/schema.sql /app/share/schema.sql

ENV NODE_ENV=production
ENV PORT=8080
ENV LOG_LEVEL=info

EXPOSE 8080

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "dist/bin.js"]
