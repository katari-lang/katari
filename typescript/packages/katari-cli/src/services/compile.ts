// Spawns the Haskell `katari-compiler` binary to compile / typecheck Katari
// source files. Returns IRModule + SchemaBundle (compile) or only diagnostics
// (typecheck).
//
// Binary resolution order:
//   1. `KATARI_COMPILER_BIN` env var (= absolute path)
//   2. `katari-compiler` from PATH (= installed via `stack install`)
//
// stdout: JSON `{ irModule, schemaBundle }`
// stderr: rendered diagnostics (passthrough — already coloured by Haskell side)

import { spawn } from "node:child_process";
import type { CompileOutput } from "../types.js";

export class CompileError extends Error {
  constructor(message: string, public readonly stderr: string) {
    super(message);
    this.name = "CompileError";
  }
}

function resolveBinary(): string {
  return process.env.KATARI_COMPILER_BIN ?? "katari-compiler";
}

/**
 * Compile sources at `srcPath` (file or directory). Streams diagnostics to
 * the parent's stderr so the user sees them as the compile runs.
 */
export async function compile(opts: {
  srcPath: string;
}): Promise<CompileOutput> {
  const args = ["compile", opts.srcPath];
  const { stdout } = await runBinary(args);
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch (err) {
    throw new CompileError(
      `katari-compiler produced invalid JSON on stdout: ${
        err instanceof Error ? err.message : String(err)
      }`,
      "",
    );
  }
  if (
    typeof parsed !== "object" || parsed === null ||
    !("irModule" in parsed) || !("schemaBundle" in parsed)
  ) {
    throw new CompileError(
      "katari-compiler produced unexpected JSON shape (missing irModule / schemaBundle)",
      "",
    );
  }
  return parsed as CompileOutput;
}

export async function typecheck(opts: {
  srcPath: string;
}): Promise<void> {
  const args = ["typecheck", opts.srcPath];
  await runBinary(args);
}

function runBinary(args: string[]): Promise<{ stdout: string }> {
  const bin = resolveBinary();
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, {
      stdio: ["ignore", "pipe", "inherit"],
    });
    let stdout = "";
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk) => {
      stdout += chunk;
    });
    child.on("error", (err) => {
      reject(
        new CompileError(
          `failed to spawn ${bin}: ${err.message} ` +
            "(set KATARI_COMPILER_BIN or run `stack install katari-compiler`)",
          "",
        ),
      );
    });
    child.on("close", (code) => {
      if (code === 0) {
        resolve({ stdout });
        return;
      }
      reject(
        new CompileError(
          `katari-compiler exited with code ${code}`,
          "",
        ),
      );
    });
  });
}
