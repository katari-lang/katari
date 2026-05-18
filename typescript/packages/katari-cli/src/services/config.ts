// `katari.toml` loader. Walks up from CWD until it finds the config (Node /
// cargo / git ergonomics), parses TOML, and interpolates `${VAR}` env refs.

import { readFile } from "node:fs/promises";
import { resolve, dirname, isAbsolute, join } from "node:path";
import { existsSync } from "node:fs";
import { parse as parseToml } from "smol-toml";
import type { KatariConfig } from "../types.js";

export const CONFIG_FILENAME = "katari.toml";

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigError";
  }
}

/** Find `katari.toml` walking up from `start` (default: cwd). */
export function findConfigPath(start: string = process.cwd()): string | null {
  let dir = resolve(start);
  while (true) {
    const candidate = join(dir, CONFIG_FILENAME);
    if (existsSync(candidate)) return candidate;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

/** Load + parse + interpolate `${VAR}` env refs. */
export async function loadConfig(
  start: string = process.cwd(),
): Promise<{ config: KatariConfig; configDir: string }> {
  const path = findConfigPath(start);
  if (path === null) {
    throw new ConfigError(
      `${CONFIG_FILENAME} not found (searched up from ${resolve(start)})`,
    );
  }
  const raw = await readFile(path, "utf8");
  const interpolated = interpolateEnv(raw);
  const parsed = parseToml(interpolated);
  return {
    config: validateConfig(parsed, path),
    configDir: dirname(path),
  };
}

/**
 * `${VAR}` を `process.env[VAR]` に置換。未設定 env var は空文字に。
 * `\${VAR}` でエスケープ可能。
 */
export function interpolateEnv(input: string): string {
  return input.replace(/\\?\$\{([A-Z_][A-Z0-9_]*)\}/gi, (match, name) => {
    if (match.startsWith("\\")) return match.slice(1);
    return process.env[name] ?? "";
  });
}

function validateConfig(raw: unknown, path: string): KatariConfig {
  if (!isObject(raw)) {
    throw new ConfigError(`${path}: top-level must be a TOML table`);
  }
  const project = raw.project;
  if (typeof project !== "string" || project.length === 0) {
    throw new ConfigError(`${path}: required field 'project' (string)`);
  }
  const compile = isObject(raw.compile) ? raw.compile : {};
  const compileSrc =
    typeof compile.src === "string" && compile.src.length > 0
      ? compile.src
      : "src/";
  const sidecar = isObject(raw.sidecar) ? raw.sidecar : undefined;
  const sidecarSourceRoots = (() => {
    if (sidecar === undefined) return undefined;
    const v = sidecar.sourceRoots;
    if (v === undefined) return undefined;
    if (!Array.isArray(v) || !v.every((x) => typeof x === "string")) {
      throw new ConfigError(
        `${path}: 'sidecar.sourceRoots' must be an array of strings`,
      );
    }
    return v as string[];
  })();
  const api = isObject(raw.api) ? raw.api : {};
  const apiUrl =
    typeof api.url === "string" && api.url.length > 0
      ? api.url
      : "http://localhost:8080";
  const apiAuth =
    typeof api.auth === "string" && api.auth.length > 0 ? api.auth : undefined;

  return {
    project,
    compile: { src: compileSrc },
    sidecar:
      sidecarSourceRoots !== undefined
        ? { sourceRoots: sidecarSourceRoots }
        : undefined,
    api: { url: apiUrl, auth: apiAuth },
  };
}

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** Resolve a config-relative path against the directory containing katari.toml. */
export function resolveConfigPath(configDir: string, p: string): string {
  return isAbsolute(p) ? p : resolve(configDir, p);
}
