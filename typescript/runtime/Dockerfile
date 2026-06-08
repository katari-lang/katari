# syntax=docker/dockerfile:1
#
# Multi-stage image for @katari-lang/runtime.
#
# Built from the REPO ROOT as context (the package depends on the workspace
# package @katari-lang/types), so compose sets:
#   build: { context: ., dockerfile: typescript/runtime/Dockerfile }
#
ARG NODE_VERSION=22

# ---------- base: pnpm via corepack ----------
FROM node:${NODE_VERSION}-slim AS base
ENV PNPM_HOME=/pnpm \
    PATH=/pnpm:$PATH \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable
WORKDIR /repo

# ---------- build: install (with dev), compile, deploy ----------
FROM base AS build

# 1) Manifests first so the install layer is cached until deps change.
COPY pnpm-lock.yaml pnpm-workspace.yaml package.json ./
COPY typescript/types/package.json ./typescript/types/
COPY typescript/runtime/package.json ./typescript/runtime/
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm install --frozen-lockfile --ignore-scripts

# 2) Sources, then build types (dependency) before runtime.
COPY typescript/tsconfig.base.json ./typescript/
COPY typescript/types ./typescript/types/
COPY typescript/runtime ./typescript/runtime/
RUN pnpm --filter @katari-lang/types build \
 && pnpm --filter @katari-lang/runtime build

# 3) Produce a self-contained prod deployment: flattens the workspace
#    dependency (@katari-lang/types) into a real node_modules and drops
#    devDependencies. Output lands in /prod (package.json + dist + node_modules).
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm --filter @katari-lang/runtime deploy --prod --legacy /prod

# ---------- runtime: minimal, non-root ----------
FROM node:${NODE_VERSION}-slim AS runtime
ENV NODE_ENV=production \
    PORT=3000
WORKDIR /app
COPY --from=build --chown=node:node /prod ./
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/api/v1/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "dist/bin.mjs"]
