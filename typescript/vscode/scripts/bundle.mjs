#!/usr/bin/env node
// Bundle src/extension.ts → out/extension.js as a single CommonJS file
// for VSCode. `vscode` is provided by the host and must stay external.

import { build } from "esbuild";

await build({
  entryPoints: ["src/extension.ts"],
  outfile: "out/extension.js",
  bundle: true,
  platform: "node",
  target: "node18",
  format: "cjs",
  external: ["vscode"],
  sourcemap: true,
  minify: process.env.NODE_ENV === "production",
  logLevel: "info",
});
