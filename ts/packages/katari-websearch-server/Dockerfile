FROM node:22-alpine
WORKDIR /app
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml tsconfig.base.json ./
COPY packages/ packages/
RUN corepack enable && pnpm install --frozen-lockfile
RUN pnpm -r build
WORKDIR /app/packages/katari-websearch-server
CMD ["node", "dist/index.js"]
