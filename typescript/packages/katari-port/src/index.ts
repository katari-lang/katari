// katari-port — user-facing FFI SDK.
//
// User code imports this package's default export and calls
// `katari.agent(name, handler)` to register ext-agent implementations.
// The actual IPC machinery (stdio listener, console redirect) does
// **not** run on import — it only activates once `__startSidecar()` is
// invoked, which the Katari CLI bundler appends to the synthetic entry.
//
// Splitting "registration" from "activation" lets tooling (tests,
// linters, `tsc`) import the package safely without commandeering
// stdin / stdout. User code that runs outside a Katari host (e.g.
// `node main.ts` for hand-testing) simply never registers a listener,
// so `katari.agent(...)` calls are recorded but no IPC is performed.

import { stdin, stdout, stderr, exit } from "node:process";
import { createInterface } from "node:readline";
import {
  PROTOCOL_VERSION,
  type ChildToParent,
  type ParentToChild,
} from "./protocol.js";
import type {
  AgentContext,
  AgentHandler,
  KatariPort,
  RawValue,
} from "./types.js";

// ─── Registry + inflight state ─────────────────────────────────────────────

const registry = new Map<string, AgentHandler>();

interface InflightEntry {
  ctrl: AbortController;
  terminating: boolean;
}
const inflight = new Map<string, InflightEntry>();

// The bundler wraps each user module in `__withModule(qname, () => {...})`
// so `katari.agent(localName, handler)` resolves to a fully-qualified
// registry key. Outside any such wrapper the qname is "" — that's a
// programming error during normal use, surfaced by the registry-clash
// check inside `agent()`.
let currentModuleQname = "";

// ─── Public API singleton ──────────────────────────────────────────────────

const katari: KatariPort = {
  agent(name, handler) {
    const key =
      currentModuleQname.length === 0
        ? name
        : `${currentModuleQname}.${name}`;
    if (registry.has(key)) {
      throw new Error(`katari-port: handler already registered for ${key}`);
    }
    registry.set(key, handler);
  },
};

// ─── Module-qname threading (used by the CLI bundler) ──────────────────────

declare global {
  // eslint-disable-next-line no-var
  var __withModule: (qname: string, body: () => void) => void;
}

(globalThis as Record<string, unknown>).__withModule = (
  qname: string,
  body: () => void,
): void => {
  const prev = currentModuleQname;
  currentModuleQname = qname;
  try {
    body();
  } finally {
    currentModuleQname = prev;
  }
};

// ─── Sidecar activation (called from the bundler-generated entry) ──────────
//
// Sets up stdio IPC, redirects console.*, and emits `ready`. Idempotent.

let started = false;
let stdoutWrite: ((chunk: string) => boolean) | null = null;

const formatConsoleArgs = (args: readonly unknown[]): string =>
  args
    .map((arg) => {
      if (typeof arg === "string") return arg;
      try {
        return JSON.stringify(arg);
      } catch {
        return String(arg);
      }
    })
    .join(" ");

const redirectConsole = (tag: string): ((...args: unknown[]) => void) =>
  (...args: unknown[]) => {
    stderr.write(`[${tag}] ${formatConsoleArgs(args)}\n`);
  };

const send = (msg: ChildToParent): void => {
  if (stdoutWrite === null) return;
  stdoutWrite(`${JSON.stringify(msg)}\n`);
};

async function handleDelegate(
  msg: Extract<ParentToChild, { type: "delegate" | "delegateRestored" }>,
  isRestored: boolean,
): Promise<void> {
  const handler = registry.get(msg.agentDefId);
  if (handler === undefined) {
    send({
      type: "delegateError",
      protocolVersion: PROTOCOL_VERSION,
      delegationId: msg.delegationId,
      message: `katari-port: no handler registered for ${msg.agentDefId}`,
    });
    return;
  }
  const entry: InflightEntry = {
    ctrl: new AbortController(),
    terminating: false,
  };
  inflight.set(msg.delegationId, entry);
  const ctx: AgentContext = {
    args: msg.args,
    delegationId: msg.delegationId,
    signal: entry.ctrl.signal,
    isRestored,
  };
  let value: RawValue | null = null;
  let error: unknown = null;
  try {
    value = await handler(ctx);
  } catch (err) {
    error = err;
  } finally {
    inflight.delete(msg.delegationId);
  }
  if (entry.terminating) {
    send({
      type: "terminateAck",
      protocolVersion: PROTOCOL_VERSION,
      delegationId: msg.delegationId,
    });
    return;
  }
  if (error !== null) {
    send({
      type: "delegateError",
      protocolVersion: PROTOCOL_VERSION,
      delegationId: msg.delegationId,
      message: error instanceof Error ? error.message : String(error),
    });
    return;
  }
  send({
    type: "delegateAck",
    protocolVersion: PROTOCOL_VERSION,
    delegationId: msg.delegationId,
    value: value as RawValue,
  });
}

/**
 * Start the sidecar IPC loop. Called by the CLI-generated synthetic
 * entry after all user modules have been imported (= every
 * `katari.agent(...)` registration has run). Calling twice is a no-op.
 */
export const __startSidecar = (): void => {
  if (started) return;
  started = true;

  stdoutWrite = stdout.write.bind(stdout);

  // stdout is the IPC channel; rebind console.* to stderr so user
  // `console.log` calls don't corrupt the protocol stream.
  console.log = redirectConsole("console.log");
  console.info = redirectConsole("console.info");
  console.warn = redirectConsole("console.warn");
  console.error = redirectConsole("console.error");
  console.debug = redirectConsole("console.debug");

  const rl = createInterface({ input: stdin });
  rl.on("line", (line) => {
    if (line.length === 0) return;
    let msg: ParentToChild;
    try {
      msg = JSON.parse(line) as ParentToChild;
    } catch {
      stderr.write(`[katari-port] bad JSON from parent: ${line}\n`);
      return;
    }
    if (
      typeof msg !== "object" ||
      msg === null ||
      msg.protocolVersion !== PROTOCOL_VERSION
    ) {
      const got =
        typeof msg === "object" && msg !== null
          ? msg.protocolVersion
          : "<missing>";
      stderr.write(
        `[katari-port] protocol mismatch (got ${got}, expected ${PROTOCOL_VERSION})\n`,
      );
      exit(1);
    }
    switch (msg.type) {
      case "delegate":
        void handleDelegate(msg, false);
        return;
      case "delegateRestored":
        void handleDelegate(msg, true);
        return;
      case "terminate": {
        const entry = inflight.get(msg.delegationId);
        if (entry !== undefined) {
          entry.terminating = true;
          entry.ctrl.abort();
          // The Ack is emitted by handleDelegate once the handler
          // observes the abort (or finishes naturally).
          return;
        }
        // Either the delegation already completed or it never reached
        // us. Either way: respond idempotently.
        send({
          type: "terminateAck",
          protocolVersion: PROTOCOL_VERSION,
          delegationId: msg.delegationId,
        });
        return;
      }
      default: {
        const unknown = (msg as { type: string }).type;
        stderr.write(`[katari-port] unknown message type: ${unknown}\n`);
        exit(1);
      }
    }
  });

  send({ type: "ready", protocolVersion: PROTOCOL_VERSION });
};

export default katari;
export type {
  AgentContext,
  AgentHandler,
  KatariPort,
  RawValue,
} from "./types.js";
export { PROTOCOL_VERSION } from "./protocol.js";
export type { ParentToChild, ChildToParent } from "./protocol.js";
