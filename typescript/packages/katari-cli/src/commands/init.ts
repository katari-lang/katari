// `katari init` — scaffold a new project: katari.toml + src/main.ktr
// (with an optional co-located src/main.ts ext-agent skeleton).

import * as p from "@clack/prompts";
import pc from "picocolors";
import { existsSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const KATARI_TOML_TEMPLATE = (project: string): string =>
  `project = "${project}"

[compile]
src = "src/"

[api]
url = "http://localhost:8080"
# auth = "\${KATARI_API_KEY}"   # set via env var
`;

const MAIN_KTR_TEMPLATE = `@"Returns the canonical greeting."
agent main() -> string {
  "hello, world"
}
`;

const MAIN_KTR_WITH_EXT_TEMPLATE = `@"Fetch the body at \`url\`."
ext agent fetchUrl(url: string) -> string

@"Returns the body fetched from example.com."
agent main() -> string {
  fetchUrl("https://example.com")
}
`;

const MAIN_TS_TEMPLATE = `// Ext-agent implementations co-located with main.ktr.
// Bundled by \`katari apply\` (esbuild) alongside katari-port.

import katari from "katari-port";

katari.agent("fetchUrl", async ({ args, signal }) => {
  const url = args["url"] as string;
  const resp = await fetch(url, { signal });
  return await resp.text();
});
`;

const PACKAGE_JSON_TEMPLATE = `{
  "name": "katari-app",
  "version": "0.1.0",
  "type": "module",
  "private": true,
  "dependencies": {
    "katari-port": "^0.1.0"
  }
}
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
    message: "Add ext-agent (FFI) skeleton?",
    initialValue: false,
  });
  if (p.isCancel(withSidecar)) {
    p.cancel("cancelled");
    process.exit(130);
  }

  await writeFile(tomlPath, KATARI_TOML_TEMPLATE(projectName));
  await mkdir(resolve(cwd, "src"), { recursive: true });
  const ktrPath = resolve(cwd, "src", "main.ktr");
  if (!existsSync(ktrPath)) {
    await writeFile(
      ktrPath,
      withSidecar ? MAIN_KTR_WITH_EXT_TEMPLATE : MAIN_KTR_TEMPLATE,
    );
  }
  if (withSidecar) {
    const tsPath = resolve(cwd, "src", "main.ts");
    if (!existsSync(tsPath)) {
      await writeFile(tsPath, MAIN_TS_TEMPLATE);
    }
    const pkgPath = resolve(cwd, "package.json");
    if (!existsSync(pkgPath)) {
      await writeFile(pkgPath, PACKAGE_JSON_TEMPLATE);
    }
    p.note(
      `Next: ${pc.cyan("npm install")} (or pnpm / yarn) to fetch katari-port.`,
    );
  }
  p.outro(
    `Initialized project ${pc.cyan(projectName)} — try ${pc.cyan("katari typecheck")}`,
  );
}
