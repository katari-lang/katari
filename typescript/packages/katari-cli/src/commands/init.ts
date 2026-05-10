// `katari init` — scaffold a new project: katari.toml + src/main.ktr.

import * as p from "@clack/prompts";
import pc from "picocolors";
import { existsSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const KATARI_TOML_TEMPLATE = (project: string, withSidecar: boolean): string =>
  `project = "${project}"

[compile]
src = "src/"

${withSidecar ? "[sidecar]\nentry = \"sidecar/index.ts\"\n\n" : ""}[api]
url = "http://localhost:8080"
# auth = "\${KATARI_API_KEY}"   # set via env var
`;

const MAIN_KTR_TEMPLATE = `@"Returns the canonical greeting."
agent main() -> string {
  "hello, world"
}
`;

const SIDECAR_TEMPLATE = `// Sidecar entry. Bundled by esbuild on \`katari apply\`.
//
// User code receives \`{ agentDefId, args, escalate, signal, isRestored }\`
// and returns the result Value.

exports.invoke = async function ({ agentDefId, args }) {
  return { kind: "null" };
};
`;

export async function initCmd(): Promise<void> {
  p.intro(pc.bgCyan(pc.black(" katari init ")));
  const cwd = process.cwd();
  const tomlPath = resolve(cwd, "katari.toml");
  if (existsSync(tomlPath)) {
    p.cancel("katari.toml already exists in this directory");
    process.exit(1);
  }
  const projectName = await p.text({
    message: "Project name",
    placeholder: "my-app",
    validate: (v) => (v.length === 0 ? "required" : undefined),
  });
  if (p.isCancel(projectName)) {
    p.cancel("cancelled");
    process.exit(130);
  }
  const withSidecar = await p.confirm({
    message: "Add sidecar (FFI) skeleton?",
    initialValue: false,
  });
  if (p.isCancel(withSidecar)) {
    p.cancel("cancelled");
    process.exit(130);
  }

  await writeFile(tomlPath, KATARI_TOML_TEMPLATE(projectName, withSidecar));
  await mkdir(resolve(cwd, "src"), { recursive: true });
  const ktrPath = resolve(cwd, "src", "main.ktr");
  if (!existsSync(ktrPath)) {
    await writeFile(ktrPath, MAIN_KTR_TEMPLATE);
  }
  if (withSidecar) {
    await mkdir(resolve(cwd, "sidecar"), { recursive: true });
    const sidecarPath = resolve(cwd, "sidecar", "index.ts");
    if (!existsSync(sidecarPath)) {
      await writeFile(sidecarPath, SIDECAR_TEMPLATE);
    }
  }
  p.outro(
    `Initialized project ${pc.cyan(projectName)} — try ${pc.cyan("katari typecheck")}`,
  );
}
