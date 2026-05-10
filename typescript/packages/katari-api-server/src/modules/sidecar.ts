// Sidecar abstraction: parent ↔ child IPC, regardless of transport.
//
//   - SubprocessSidecar: spawns a Node subprocess running the bootstrapper
//                        and exchanges JSON Lines over stdio
//   - InProcessSidecar:  in-process handler map, used by tests to avoid
//                        actual subprocess spawning
//
// Both implement the same `Sidecar` interface so the FFI Runner doesn't
// know or care which is used.

import { spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import type {
  ChildToParent,
  ParentToChild,
  SidecarBundle,
} from "katari-runtime/dist/sidecar/types.js";
import type { Logger } from "katari-runtime";

export interface Sidecar {
  send(msg: ParentToChild): Promise<void>;
  /** Replace the previous handler. */
  onMessage(cb: (msg: ChildToParent) => void): void;
  shutdown(): Promise<void>;
}

// ─── SubprocessSidecar ─────────────────────────────────────────────────────

/**
 * Resolve the bootstrapper.js path. The runtime ships it next to its
 * compiled types under `dist/sidecar/bootstrapper.js`.
 */
function resolveBootstrapperPath(): string {
  // Use a runtime-resolved path so the api-server can find the
  // bootstrapper even when installed via pnpm workspace symlinks.
  const moduleUrl = import.meta.url;
  const here = dirname(fileURLToPath(moduleUrl));
  // dist/modules → dist/../../katari-runtime/dist/sidecar/bootstrapper.js
  // works for both monorepo layout and node_modules install.
  return resolve(
    here,
    "..",
    "..",
    "..",
    "katari-runtime",
    "dist",
    "sidecar",
    "bootstrapper.js",
  );
}

export class SubprocessSidecar implements Sidecar {
  private child: ChildProcess | null = null;
  private bundleDir: string | null = null;
  private handler: ((msg: ChildToParent) => void) | null = null;
  private readyPromise: Promise<void>;
  private resolveReady: (() => void) | null = null;

  constructor(
    private readonly bundle: SidecarBundle,
    private readonly logger: Logger,
  ) {
    this.readyPromise = new Promise((resolve) => {
      this.resolveReady = resolve;
    });
  }

  async start(): Promise<void> {
    // Materialize the bundle to a temp file so node can `require()` it.
    this.bundleDir = mkdtempSync(join(tmpdir(), "katari-sidecar-"));
    const bundlePath = join(this.bundleDir, "bundle.cjs");
    writeFileSync(bundlePath, this.bundle.entry, "utf8");

    const bootstrapPath = resolveBootstrapperPath();
    this.child = spawn("node", [bootstrapPath, bundlePath], {
      stdio: ["pipe", "pipe", "pipe"],
    });

    const stdout = this.child.stdout!;
    const rl = createInterface({ input: stdout });
    rl.on("line", (line) => this.onLine(line));

    const stderr = this.child.stderr!;
    stderr.setEncoding("utf8");
    stderr.on("data", (chunk) => {
      this.logger.log("debug", "sidecar stderr", { chunk: String(chunk) });
    });

    this.child.on("exit", (code, signal) => {
      this.logger.log("info", "sidecar exited", { code, signal });
    });

    return this.readyPromise;
  }

  private onLine(line: string): void {
    if (line.trim() === "") return;
    let msg: ChildToParent;
    try {
      msg = JSON.parse(line) as ChildToParent;
    } catch {
      this.logger.log("warn", "sidecar emitted invalid JSON", { line });
      return;
    }
    if (msg.type === "ready") {
      this.resolveReady?.();
      this.resolveReady = null;
      return;
    }
    if (msg.type === "log") {
      this.logger.log(msg.level, `sidecar: ${msg.message}`, msg.context);
      return;
    }
    this.handler?.(msg);
  }

  async send(msg: ParentToChild): Promise<void> {
    if (this.child === null) throw new Error("sidecar: not started");
    return new Promise((resolve, reject) => {
      this.child!.stdin!.write(JSON.stringify(msg) + "\n", (err) => {
        if (err) reject(err);
        else resolve();
      });
    });
  }

  onMessage(cb: (msg: ChildToParent) => void): void {
    this.handler = cb;
  }

  async shutdown(): Promise<void> {
    if (this.child === null) return;
    try {
      await this.send({ type: "shutdown" });
    } catch {
      /* ignore: subprocess may already be dead */
    }
    // Give it 1s to exit cleanly, then SIGKILL.
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        try {
          this.child?.kill("SIGKILL");
        } catch {
          /* ignore */
        }
        resolve();
      }, 1000);
      this.child!.once("exit", () => {
        clearTimeout(timer);
        resolve();
      });
    });
    if (this.bundleDir !== null) {
      try {
        rmSync(this.bundleDir, { recursive: true, force: true });
      } catch {
        /* ignore */
      }
    }
    this.child = null;
  }
}

// ─── InProcessSidecar ──────────────────────────────────────────────────────

/**
 * Handler registered by tests / inproc deployments. Mirrors the user
 * bundle's `invoke` signature.
 */
export type InProcessHandler = (input: {
  agentDefId: unknown;
  args: Record<string, unknown>;
  delegationId: string;
  signal: AbortSignal;
  escalate: (
    agentDefId: unknown,
    args: Record<string, unknown>,
  ) => Promise<unknown>;
}) => Promise<unknown>;

/**
 * In-process replacement for SubprocessSidecar. All handlers live in
 * memory and get called directly. Tests bypass the subprocess spawn
 * entirely while keeping the same `Sidecar` interface.
 */
export class InProcessSidecar implements Sidecar {
  private handler: ((msg: ChildToParent) => void) | null = null;
  private readonly inflight = new Map<string, AbortController>();
  private readonly pendingEscalations = new Map<
    string,
    { resolve: (v: unknown) => void; reject: (e: Error) => void }
  >();

  constructor(
    private readonly userInvoke: InProcessHandler,
    private readonly logger: Logger,
  ) {}

  async start(): Promise<void> {
    // Emit ready synchronously so callers don't wait on transport.
    queueMicrotask(() => this.handler?.({ type: "ready" }));
  }

  async send(msg: ParentToChild): Promise<void> {
    switch (msg.type) {
      case "delegate":
        this.handleDelegate(msg).catch((err) => {
          this.logger.log("error", "inproc sidecar delegate threw", {
            err: String(err),
          });
        });
        return;
      case "terminate": {
        const ctrl = this.inflight.get(msg.delegationId);
        ctrl?.abort();
        this.inflight.delete(msg.delegationId);
        this.handler?.({
          type: "terminateAck",
          delegationId: msg.delegationId,
        });
        return;
      }
      case "escalateAck": {
        const pending = this.pendingEscalations.get(msg.escalationId);
        pending?.resolve(msg.value);
        this.pendingEscalations.delete(msg.escalationId);
        return;
      }
      case "escalateError": {
        const pending = this.pendingEscalations.get(msg.escalationId);
        pending?.reject(new Error(msg.message));
        this.pendingEscalations.delete(msg.escalationId);
        return;
      }
      case "restored":
      case "shutdown":
        return;
    }
  }

  private async handleDelegate(
    msg: Extract<ParentToChild, { type: "delegate" }>,
  ): Promise<void> {
    const ctrl = new AbortController();
    this.inflight.set(msg.delegationId, ctrl);
    let currentDelegationId = msg.delegationId;
    const escalate = (agentDefId: unknown, args: Record<string, unknown>) => {
      const escalationId = randomUuid();
      return new Promise<unknown>((resolve, reject) => {
        this.pendingEscalations.set(escalationId, { resolve, reject });
        this.handler?.({
          type: "escalate",
          delegationId: currentDelegationId as never,
          escalationId: escalationId as never,
          agentDefId: agentDefId as never,
          args: args as never,
        });
      });
    };
    try {
      const value = await this.userInvoke({
        agentDefId: msg.agentDefId,
        args: msg.args,
        delegationId: msg.delegationId,
        signal: ctrl.signal,
        escalate,
      });
      this.handler?.({
        type: "delegateAck",
        delegationId: msg.delegationId,
        value: value as never,
      });
    } catch (err) {
      this.handler?.({
        type: "delegateError",
        delegationId: msg.delegationId,
        message: err instanceof Error ? err.message : String(err),
      });
    } finally {
      this.inflight.delete(msg.delegationId);
    }
  }

  onMessage(cb: (msg: ChildToParent) => void): void {
    this.handler = cb;
  }

  async shutdown(): Promise<void> {
    for (const ctrl of this.inflight.values()) ctrl.abort();
    this.inflight.clear();
    for (const pending of this.pendingEscalations.values()) {
      pending.reject(new Error("sidecar shutdown"));
    }
    this.pendingEscalations.clear();
  }
}

function randomUuid(): string {
  // Lightweight uuid4 for in-process testing — no need to depend on
  // node:crypto in this hot path.
  return `${Math.random().toString(16).slice(2)}-${Date.now().toString(16)}`;
}
