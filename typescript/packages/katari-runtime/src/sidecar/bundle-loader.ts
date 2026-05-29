// Bundle loader — write a `SidecarBundle` to a temp file and spawn it
// as a `SubprocessSidecar`. Used by api-server's `SidecarManager`
// factory (and by anyone wanting a real subprocess sidecar).
//
// Bundles arrive as JS source strings (produced by the Katari CLI's
// esbuild step). Node can't `import` a string directly, so we drop the
// bundle to disk under `os.tmpdir()` and pass the path to `spawn`.
// Cleanup is wired to `Sidecar.shutdown()` via the `onShutdown` hook.

import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Logger } from "../engine/logger.js";
import type { Sidecar } from "./sidecar.js";
import { SubprocessSidecar } from "./subprocess-sidecar.js";
import type { SidecarBundle } from "./types.js";

export interface LoadSubprocessSidecarOptions {
  bundle: SidecarBundle;
  logger: Logger;
  /** Optional override for the `node` binary path. */
  nodeBin?: string;
  /** Extra env vars to pass to the child. */
  env?: Record<string, string>;
}

export async function loadSubprocessSidecar(opts: LoadSubprocessSidecarOptions): Promise<Sidecar> {
  const dir = await mkdtemp(join(tmpdir(), "katari-sidecar-"));
  const bundlePath = join(dir, "sidecar.mjs");
  await writeFile(bundlePath, opts.bundle.entry, "utf8");
  const sidecar = new SubprocessSidecar({
    bundlePath,
    logger: opts.logger,
    nodeBin: opts.nodeBin,
    env: opts.env,
    onShutdown: async () => {
      try {
        await rm(dir, { recursive: true, force: true });
      } catch (err) {
        opts.logger.log("warn", "bundle-loader: tmp cleanup failed", {
          dir,
          err: err instanceof Error ? err.message : String(err),
        });
      }
    },
  });
  return sidecar;
}
