import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["tests/**/*.test.ts"],
    // The suite drives a real server, a real compiler, and docker: whole-run setup (compose up, an
    // isolated database, the sidecar bundler build, a server boot) lives in `beforeAll`, and single
    // tests spawn the CLI (which compiles the whole playground on `apply`).
    testTimeout: 180_000,
    hookTimeout: 600_000,
  },
});
