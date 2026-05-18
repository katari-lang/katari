// `katari apply` — compile + (optional sidecar bundle) + upload snapshot.

import * as p from "@clack/prompts";
import pc from "picocolors";
import { existsSync } from "node:fs";
import { ApiClient, ApiError } from "../services/api-client.js";
import { bundleSidecar } from "../services/bundle.js";
import { compile, CompileError } from "../services/compile.js";
import { loadConfig, resolveConfigPath } from "../services/config.js";
import { shortId } from "../prompt/picker-utils.js";

export type ApplyOptions = {
  project?: string;
  src?: string;
};

export async function applyCmd(opts: ApplyOptions): Promise<void> {
  p.intro(pc.bgCyan(pc.black(" katari apply ")));

  const { config, configDir } = await loadConfig();
  const projectName = opts.project ?? config.project;
  const srcPath = resolveConfigPath(
    configDir,
    opts.src ?? config.compile.src,
  );
  // Co-location bundle source roots default to the compile source dir.
  // Future package-manager phase will append `.katari/packages/*/src`.
  const sourceRoots = (config.sidecar?.sourceRoots ?? [config.compile.src]).map(
    (root) => resolveConfigPath(configDir, root),
  );

  if (!existsSync(srcPath)) {
    p.cancel(`source path not found: ${srcPath}`);
    process.exit(1);
  }

  // 1. Compile
  const compileSpinner = p.spinner();
  compileSpinner.start("Compiling sources");
  let compiled;
  try {
    compiled = await compile({ srcPath });
    compileSpinner.stop("Compiled");
  } catch (err) {
    compileSpinner.stop(pc.red("Compile failed"), 1);
    if (err instanceof CompileError) {
      p.cancel(err.message);
    } else {
      p.cancel(err instanceof Error ? err.message : String(err));
    }
    process.exit(1);
  }

  // 2. Bundle sidecar (co-location: walk source roots for .ktr siblings)
  let sidecarBundle = null;
  const bundleSpinner = p.spinner();
  bundleSpinner.start("Bundling sidecar (co-location)");
  try {
    const result = await bundleSidecar({ sourceRoots });
    if (result === null) {
      bundleSpinner.stop("No ext-agent siblings found; sidecar-less snapshot");
    } else {
      sidecarBundle = result.bundle;
      bundleSpinner.stop(
        `Bundled sidecar (${humanSize(sidecarBundle.entry.length)}, ${result.modules.length} module${result.modules.length === 1 ? "" : "s"})`,
      );
    }
  } catch (err) {
    bundleSpinner.stop(pc.red("Bundle failed"), 1);
    p.cancel(err instanceof Error ? err.message : String(err));
    process.exit(1);
  }

  // 3. Upload to api-server
  const api = new ApiClient({ baseUrl: config.api.url, authToken: config.api.auth });

  const uploadSpinner = p.spinner();
  uploadSpinner.start(`Upserting project ${pc.cyan(projectName)}`);
  let project;
  try {
    project = await api.upsertProject(projectName);
    uploadSpinner.message(`Uploading snapshot to ${pc.cyan(projectName)}`);
    const result = await api.uploadSnapshot({
      projectId: project.id,
      irModule: compiled.irModule,
      sidecarBundle,
      schemaBundle: compiled.schemaBundle,
    });
    uploadSpinner.stop(
      `${pc.green("✓")} Applied — snapshot ${pc.cyan(`#${shortId(result.snapshotId)}`)} (${compiled.schemaBundle.agents.length} agent${compiled.schemaBundle.agents.length === 1 ? "" : "s"})`,
    );
    p.outro(`Project: ${project.name} · ${result.snapshotId}`);
  } catch (err) {
    uploadSpinner.stop(pc.red("Upload failed"), 1);
    if (err instanceof ApiError) {
      p.cancel(`${err.message} (HTTP ${err.status})`);
    } else {
      p.cancel(err instanceof Error ? err.message : String(err));
    }
    process.exit(1);
  }
}

function humanSize(bytes: number): string {
  if (bytes < 1024) return `${bytes}B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`;
  return `${(bytes / 1024 / 1024).toFixed(2)}MB`;
}
