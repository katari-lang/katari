#!/usr/bin/env node
// Bundle src/extension.ts → out/extension.js as a single CommonJS file
// for VSCode. `vscode` is provided by the host and must stay external.
//
// Also copies the language artifacts (grammar, language configuration) from
// @katari-lang/language — the single source of truth — to the paths package.json's
// `contributes` declares. The copies are gitignored build output.

import { copyFile, mkdir } from "node:fs/promises";
import { createRequire } from "node:module";

import { build } from "esbuild";

const require_ = createRequire(import.meta.url);
await mkdir("syntaxes", { recursive: true });
await copyFile(
  require_.resolve("@katari-lang/language/grammar"),
  "syntaxes/katari.tmLanguage.json",
);
await copyFile(
  require_.resolve("@katari-lang/language/language-configuration"),
  "language-configuration.json",
);

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
