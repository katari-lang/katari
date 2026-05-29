// SubprocessSidecar — production `Sidecar` implementation.
//
// Spawns `node <bundle.mjs>` and speaks the 11-message IPC over stdio:
//
//   - stdin  : Parent → Child (one JSON ParentToChild per line)
//   - stdout : Child → Parent (one JSON ChildToParent per line)
//   - stderr : passed through to the parent's stderr (logs, console.*)
//
// The bundle is built by the Katari CLI and links katari-port, which
// owns the child-side end of the protocol.

import { type ChildProcess, spawn } from "node:child_process";
import { createInterface, type Interface as ReadlineInterface } from "node:readline";
import type { Logger } from "../engine/logger.js";
import { childToParentSchema } from "./child-to-parent-schema.js";
import type { Sidecar } from "./sidecar.js";
import type { ChildToParent, ParentToChild } from "./types.js";

export interface SubprocessSidecarOptions {
  /** Absolute path to the bundled ESM entry written to disk. */
  bundlePath: string;
  logger: Logger;
  /** `node` binary to invoke (defaults to `process.execPath`). */
  nodeBin?: string;
  /** Extra env vars to pass to the child (merged onto process.env). */
  env?: Record<string, string>;
  /** Called when shutdown() completes; useful for cleaning temp files. */
  onShutdown?: () => Promise<void> | void;
  /**
   * Called when the child exits at any time (= unexpectedly mid-flight,
   * or as part of an orderly shutdown). The SidecarManager uses this
   * to evict the entry so the next ensureStarted() spawns a fresh child
   * instead of trying to talk to an EPIPE'd stdin.
   */
  onExit?: (code: number | null, signal: NodeJS.Signals | null) => Promise<void> | void;
  /** Max ms to wait for `ready` before rejecting `start()` (default 10000). */
  startupTimeoutMs?: number;
  /** Max ms to wait for graceful exit on shutdown before SIGKILL (default 1000). */
  shutdownGraceMs?: number;
}

/** Env vars that must never leak to sidecar child processes. */
const FILTERED_ENV_KEYS = new Set([
  "DATABASE_URL",
  "KATARI_SECRET_KEY",
  "KATARI_API_KEY",
  "KATARI_DB_URL",
]);

export class SubprocessSidecar implements Sidecar {
  private child: ChildProcess | null = null;
  private rl: ReadlineInterface | null = null;
  private cb: ((msg: ChildToParent) => void) | null = null;

  constructor(private readonly opts: SubprocessSidecarOptions) {}

  async start(): Promise<void> {
    if (this.child !== null) return;
    const nodeBin = this.opts.nodeBin ?? process.execPath;
    const baseEnv = Object.fromEntries(
      Object.entries(process.env).filter(([k]) => !FILTERED_ENV_KEYS.has(k)),
    );
    const child = spawn(nodeBin, [this.opts.bundlePath], {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...baseEnv, ...this.opts.env },
    });
    this.child = child;

    // Pipe child's stderr verbatim to the parent's logger.
    child.stderr?.on("data", (chunk: Buffer) => {
      const text = chunk.toString("utf8").replace(/\n$/, "");
      if (text.length > 0) {
        this.opts.logger.log("info", `sidecar.stderr: ${text}`);
      }
    });

    const stdout = child.stdout;
    if (stdout === null) {
      throw new Error("subprocess sidecar: spawned child has no stdout");
    }
    this.rl = createInterface({ input: stdout });

    const startupTimeoutMs = this.opts.startupTimeoutMs ?? 10_000;
    await new Promise<void>((resolve, reject) => {
      let settled = false;
      const settle = (action: () => void): void => {
        if (settled) return;
        settled = true;
        action();
      };
      const timer = setTimeout(() => {
        settle(() => reject(new Error("subprocess sidecar: ready timeout")));
      }, startupTimeoutMs);
      timer.unref();
      const onLine = (line: string): void => {
        const msg = parseChildLine(line, this.opts.logger);
        if (msg === null) return;
        if (msg.type === "ipcReady") {
          clearTimeout(timer);
          this.rl?.off("line", onLine);
          this.rl?.on("line", (l) => this.handleLine(l));
          settle(() => resolve());
        } else {
          clearTimeout(timer);
          settle(() => reject(new Error(`subprocess sidecar: expected "ready", got ${msg.type}`)));
        }
      };
      this.rl?.on("line", onLine);
      // `child.once` so we don't leave a permanent listener that
      // would still try to reject the already-settled start() promise
      // on the eventual real exit (the `settled` guard inside `settle`
      // handles that, but `once` is cleaner).
      const onExit = (code: number | null): void => {
        clearTimeout(timer);
        settle(() =>
          reject(new Error(`subprocess sidecar: child exited during start (code=${code})`)),
        );
      };
      child.once("exit", onExit);
    });

    child.on("exit", (code, signal) => {
      this.opts.logger.log("info", "sidecar child exited", { code, signal });
      // Clear the reference so subsequent send()s fail fast with a
      // clear "not started" error rather than racing against an EPIPE
      // on a half-dead stdin. The SidecarManager's onExit hook (if
      // configured) then has a chance to evict the entry and respawn
      // on next use.
      this.child = null;
      try {
        this.rl?.close();
      } catch {
        /* already closed */
      }
      this.rl = null;
      void this.opts.onExit?.(code, signal);
    });
  }

  async send(msg: ParentToChild): Promise<void> {
    const stdin = this.child?.stdin;
    if (stdin === null || stdin === undefined) {
      throw new Error("subprocess sidecar: child not started or stdin closed");
    }
    const payload = `${JSON.stringify(msg)}\n`;
    // `send` is awaited end-to-end through the orchestrator, so each
    // write blocks the next; the write callback already accounts for
    // OS-level flushing of THIS write. If the high-water mark was hit,
    // also wait for `drain` so a large payload behind a stalled
    // sidecar doesn't sit half-buffered while the next send queues.
    const canContinue = await new Promise<boolean>((resolve, reject) => {
      const flushed = stdin.write(payload, (err) => {
        if (err !== undefined && err !== null) reject(err);
        else resolve(flushed);
      });
    });
    if (!canContinue) {
      await new Promise<void>((resolve) => stdin.once("drain", () => resolve()));
    }
  }

  onMessage(cb: (msg: ChildToParent) => void): void {
    this.cb = cb;
  }

  async shutdown(): Promise<void> {
    const child = this.child;
    if (child === null) {
      await this.opts.onShutdown?.();
      return;
    }
    const graceMs = this.opts.shutdownGraceMs ?? 1000;
    // Best-effort graceful shutdown: close stdin, SIGTERM, then SIGKILL.
    try {
      child.stdin?.end();
    } catch {
      /* already closed */
    }
    if (!child.killed) child.kill("SIGTERM");
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        if (!child.killed) child.kill("SIGKILL");
        resolve();
      }, graceMs);
      timer.unref();
      child.once("exit", () => {
        clearTimeout(timer);
        resolve();
      });
    });
    this.rl?.close();
    this.rl = null;
    this.child = null;
    await this.opts.onShutdown?.();
  }

  private handleLine(line: string): void {
    const msg = parseChildLine(line, this.opts.logger);
    if (msg === null) return;
    if (msg.type === "ipcReady") {
      // Extra ready after start() resolves — log and ignore.
      this.opts.logger.log("debug", "sidecar: spurious ready after start");
      return;
    }
    this.cb?.(msg);
  }
}

function parseChildLine(line: string, logger: Logger): ChildToParent | null {
  if (line.length === 0) return null;
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch {
    logger.log("error", `sidecar: bad JSON from child: ${line}`);
    return null;
  }
  const result = childToParentSchema.safeParse(raw);
  if (!result.success) {
    logger.log("error", `sidecar: invalid IPC message from child: ${result.error.message}`);
    return null;
  }
  return result.data;
}
