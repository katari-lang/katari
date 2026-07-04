# syntax=docker/dockerfile:1
#
# Multi-stage image for @katari-lang/runtime. The one container serves BOTH the JSON API (/api/v1)
# and the admin console (/): the build compiles the console and bakes its static dist in, and the
# server serves it from the root (KATARI_ADMIN_WEB_DIST below).
#
# Built from the REPO ROOT as context (the packages depend on the workspace package
# @katari-lang/types), so compose sets:
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

# ---------- build: install (with dev), compile the runtime + console, deploy ----------
FROM base AS build

# 1) Manifests first so the install layer is cached until deps change. The console (admin-web) is
#    built here too, so its manifest joins the install set (its build needs vite / react / tailwind
#    from devDependencies).
COPY pnpm-lock.yaml pnpm-workspace.yaml package.json ./
COPY typescript/types/package.json ./typescript/types/
COPY typescript/runtime/package.json ./typescript/runtime/
COPY typescript/admin-web/package.json ./typescript/admin-web/
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm install --frozen-lockfile --ignore-scripts \
      --filter @katari-lang/runtime... --filter @katari-lang/admin-web...

# 2) Sources, then build types (the shared dependency) before the runtime and the console.
COPY typescript/tsconfig.base.json ./typescript/
COPY typescript/types ./typescript/types/
COPY typescript/runtime ./typescript/runtime/
COPY typescript/admin-web ./typescript/admin-web/
RUN pnpm --filter @katari-lang/types build \
 && pnpm --filter @katari-lang/runtime build \
 && pnpm --filter @katari-lang/admin-web build

# 3) Produce a self-contained prod deployment of the runtime: prod deps in a real node_modules, no
#    devDependencies. The workspace package @katari-lang/types is inlined into the runtime's own bundle
#    at build time (see tsdown.config.ts), so it is a build-only devDependency and does not appear here.
#    Output lands in /prod (package.json + dist + node_modules); the console's dist is copied below.
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm --filter @katari-lang/runtime deploy --prod --legacy /prod

# ---------- runtime: minimal, non-root ----------
FROM node:${NODE_VERSION}-slim AS runtime
ENV NODE_ENV=production \
    PORT=3000 \
    KATARI_ADMIN_WEB_DIST=/app/admin-web/dist
WORKDIR /app
COPY --from=build --chown=node:node /prod ./
# The built console — served at the server root by the runtime (see KATARI_ADMIN_WEB_DIST). Pass an
# empty KATARI_ADMIN_WEB_DIST at run time to disable the UI and serve only the JSON API.
COPY --from=build --chown=node:node /repo/typescript/admin-web/dist ./admin-web/dist
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/api/v1/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "dist/bin.mjs"]
