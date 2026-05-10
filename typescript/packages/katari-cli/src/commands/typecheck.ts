// `katari typecheck [--src <dir>]` — type-check sources without uploading.

import * as p from "@clack/prompts";
import pc from "picocolors";
import { existsSync } from "node:fs";
import { typecheck, CompileError } from "../services/compile.js";
import { loadConfig, resolveConfigPath } from "../services/config.js";

export type TypecheckOptions = {
  src?: string;
};

export async function typecheckCmd(opts: TypecheckOptions): Promise<void> {
  p.intro(pc.bgCyan(pc.black(" katari typecheck ")));
  const { config, configDir } = await loadConfig();
  const srcPath = resolveConfigPath(
    configDir,
    opts.src ?? config.compile.src,
  );
  if (!existsSync(srcPath)) {
    p.cancel(`source path not found: ${srcPath}`);
    process.exit(1);
  }
  const spinner = p.spinner();
  spinner.start("Type-checking");
  try {
    await typecheck({ srcPath, rootModule: config.compile.root });
    spinner.stop(pc.green("✓ no errors"));
    p.outro("done");
  } catch (err) {
    spinner.stop(pc.red("type-check failed"), 1);
    if (err instanceof CompileError) {
      p.cancel(err.message);
    } else {
      p.cancel(err instanceof Error ? err.message : String(err));
    }
    process.exit(1);
  }
}
