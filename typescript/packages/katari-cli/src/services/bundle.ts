// esbuild ラッパ: sidecar entry を 1 つの CommonJS string に bundle する。
// 出力は SidecarBundle { entry, runtime: "node", schemaVersion: 1 } として
// snapshot に乗る。

import { build } from "esbuild";
import type { SidecarBundle } from "../types.js";

export class BundleError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BundleError";
  }
}

/**
 * Bundle a sidecar entry file into a single CommonJS source string.
 * The bootstrapper / katari-port loads this via `require` from a temp file.
 */
export async function bundleSidecar(opts: {
  entry: string;
}): Promise<SidecarBundle> {
  let result;
  try {
    result = await build({
      entryPoints: [opts.entry],
      bundle: true,
      format: "cjs",
      platform: "node",
      target: "node20",
      write: false,
      // Emit a single file. esbuild defaults to ".js"; we ignore the extension.
      sourcemap: false,
      treeShaking: true,
    });
  } catch (err) {
    throw new BundleError(
      `failed to bundle sidecar at ${opts.entry}: ${
        err instanceof Error ? err.message : String(err)
      }`,
    );
  }
  if (result.outputFiles === undefined || result.outputFiles.length === 0) {
    throw new BundleError(
      `esbuild produced no output for ${opts.entry}`,
    );
  }
  const entry = result.outputFiles[0]!.text;
  return {
    entry,
    runtime: "node",
    schemaVersion: 1,
  };
}
