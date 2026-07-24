import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * The runtime's own package version, surfaced by `/health` (and the admin console's account menu) so an
 * operator can spot a CLI/runtime skew — the same diagnosis the IR schema-version gate serves at deploy.
 *
 * Read from the shipped `package.json` relative to THIS module rather than the process cwd, the way the
 * migrations folder is located (see `db/migrate.ts`): the manifest sits beside the bundled `dist/` in the
 * image and beside `src/` in dev, so ascending from the module covers both layouts without hardcoding a
 * depth. Resolved once at load — `/health` is polled and must not touch the filesystem per request. A
 * missing or malformed manifest reads as `"unknown"`, since a version banner must never fail a boot.
 */
function readRuntimeVersion(): string {
  let directory = dirname(fileURLToPath(import.meta.url));
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = resolve(directory, "package.json");
    if (existsSync(candidate)) return versionFrom(candidate);
    const parent = dirname(directory);
    if (parent === directory) break;
    directory = parent;
  }
  return "unknown";
}

/** Parse `package.json` at `path` and return its `version` string, or `"unknown"` if it is absent /
 *  malformed. The file is trusted JSON but read defensively — a version banner is not worth a crash. */
function versionFrom(path: string): string {
  try {
    const parsed: unknown = JSON.parse(readFileSync(path, "utf8"));
    if (typeof parsed === "object" && parsed !== null && "version" in parsed) {
      const version: unknown = parsed.version;
      if (typeof version === "string") return version;
    }
  } catch {
    // Fall through to the unknown sentinel below.
  }
  return "unknown";
}

export const runtimeVersion = readRuntimeVersion();
