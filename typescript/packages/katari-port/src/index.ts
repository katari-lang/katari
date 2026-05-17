// katari-port — user-facing FFI SDK.
//
// User code imports this package's default export and calls
// `katari.agent(name, handler)` to register ext-agent implementations,
// and `katari.delegate(callable, args, opts?)` from inside a handler
// to start a CORE-side child agent (e.g. an AI tool call, a cron
// notify callback, a discord-event router).
//
// The IPC machinery (stdio listener, console redirect) does **not** run
// on import — it only activates once `__startSidecar()` is invoked,
// which the Katari CLI bundler appends to the synthetic entry. Splitting
// "registration" from "activation" lets tooling (tests, linters, `tsc`)
// import the package safely without commandeering stdin / stdout.

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
  DelegateOptions,
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

interface PendingChild {
  resolve(value: RawValue): void;
  reject(error: Error): void;
  signal: AbortSignal | null;
  abortListener: (() => void) | null;
  /** Set to true once we send ipcChildTerminate so the next ack settles as cancel. */
  terminating: boolean;
}
const pendingChildren = new Map<string, PendingChild>();

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

  delegate(callable, args, opts) {
    return delegateChild(callable, args, opts ?? {});
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

// ─── Currently-delegating context plumbing ─────────────────────────────────
//
// When a handler calls `katari.delegate(...)`, we need to know which
// delegationId the child belongs to so the parent side can find the
// owning ext call. We thread the current delegation id through a stack
// (handlers can compose, e.g. a handler that awaits another handler's
// helper, although ext handlers don't typically nest beyond one level).

const delegationStack: string[] = [];
const currentDelegationId = (): string | null =>
  delegationStack.length === 0 ? null : delegationStack[delegationStack.length - 1]!;

function generateChildDelegationId(): string {
  // 128 bit random hex. Collisions across the whole runtime would
  // require billions of in-flight delegations, so this is fine for now.
  const a = Math.floor(Math.random() * 0xffffffff)
    .toString(16)
    .padStart(8, "0");
  const b = Math.floor(Math.random() * 0xffffffff)
    .toString(16)
    .padStart(8, "0");
  const c = Math.floor(Math.random() * 0xffffffff)
    .toString(16)
    .padStart(8, "0");
  const d = Math.floor(Math.random() * 0xffffffff)
    .toString(16)
    .padStart(8, "0");
  return `child-${a}${b}${c}${d}`;
}

async function delegateChild(
  callable: RawValue,
  args: Record<string, RawValue>,
  opts: DelegateOptions,
): Promise<RawValue> {
  if (typeof callable !== "string") {
    throw new Error(
      `katari.delegate: callable must be a flat-string RawValue (agent def id), got ${typeof callable}`,
    );
  }
  const parentDelegationId = currentDelegationId();
  if (parentDelegationId === null) {
    throw new Error(
      "katari.delegate: must be called from inside a katari.agent handler",
    );
  }
  if (!started) {
    throw new Error(
      "katari.delegate: sidecar not started — wait for __startSidecar()",
    );
  }
  const childId = generateChildDelegationId();
  return new Promise<RawValue>((resolve, reject) => {
    const entry: PendingChild = {
      resolve,
      reject,
      signal: opts.signal ?? null,
      abortListener: null,
      terminating: false,
    };
    pendingChildren.set(childId, entry);

    if (opts.signal !== undefined) {
      if (opts.signal.aborted) {
        sendChildTerminate(childId);
        entry.terminating = true;
      } else {
        const listener = (): void => {
          if (!pendingChildren.has(childId)) return;
          sendChildTerminate(childId);
          entry.terminating = true;
        };
        opts.signal.addEventListener("abort", listener, { once: true });
        entry.abortListener = listener;
      }
    }

    send({
      type: "ipcChildDelegate",
      protocolVersion: PROTOCOL_VERSION,
      parentDelegationId,
      delegationId: childId,
      agentDefId: callable,
      args,
    });
  });
}

function sendChildTerminate(childId: string): void {
  send({
    type: "ipcChildTerminate",
    protocolVersion: PROTOCOL_VERSION,
    delegationId: childId,
  });
}

function settlePendingChild(
  childId: string,
  outcome:
    | { kind: "ack"; value: RawValue }
    | { kind: "terminate" }
    | { kind: "error"; message: string },
): void {
  const entry = pendingChildren.get(childId);
  if (entry === undefined) return;
  pendingChildren.delete(childId);
  if (entry.abortListener !== null && entry.signal !== null) {
    entry.signal.removeEventListener("abort", entry.abortListener);
  }
  if (outcome.kind === "ack") {
    if (entry.terminating) {
      // Race: we sent terminate but ack arrived first. Treat as ack
      // (the value is real; the cancel races to next time).
    }
    entry.resolve(outcome.value);
    return;
  }
  if (outcome.kind === "error") {
    entry.reject(new Error(outcome.message));
    return;
  }
  // terminate
  const err = new Error("katari.delegate: child terminated");
  (err as Error & { name: string }).name = "AbortError";
  entry.reject(err);
}

async function handleDelegate(
  msg: Extract<
    ParentToChild,
    { type: "ipcDelegate" | "ipcDelegateRestarted" }
  >,
  isRestored: boolean,
): Promise<void> {
  const handler = registry.get(msg.agentDefId);
  if (handler === undefined) {
    send({
      type: "ipcDelegateError",
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
  delegationStack.push(msg.delegationId);
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
    const top = delegationStack.pop();
    if (top !== msg.delegationId) {
      // Should never happen because handlers don't nest, but log so we
      // notice if it ever does.
      stderr.write(
        `[katari-port] delegation stack drift: popped ${String(
          top,
        )} expected ${msg.delegationId}\n`,
      );
    }
  }
  if (entry.terminating) {
    send({
      type: "ipcTerminateAck",
      protocolVersion: PROTOCOL_VERSION,
      delegationId: msg.delegationId,
    });
    return;
  }
  if (error !== null) {
    send({
      type: "ipcDelegateError",
      protocolVersion: PROTOCOL_VERSION,
      delegationId: msg.delegationId,
      message: error instanceof Error ? error.message : String(error),
    });
    return;
  }
  send({
    type: "ipcDelegateAck",
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
      case "ipcDelegate":
        void handleDelegate(msg, false);
        return;
      case "ipcDelegateRestarted":
        void handleDelegate(msg, true);
        return;
      case "ipcTerminate": {
        const entry = inflight.get(msg.delegationId);
        if (entry !== undefined) {
          entry.terminating = true;
          entry.ctrl.abort();
          return;
        }
        send({
          type: "ipcTerminateAck",
          protocolVersion: PROTOCOL_VERSION,
          delegationId: msg.delegationId,
        });
        return;
      }
      case "ipcChildDelegateAck":
        settlePendingChild(msg.delegationId, {
          kind: "ack",
          value: msg.value,
        });
        return;
      case "ipcChildTerminateAck":
        settlePendingChild(msg.delegationId, { kind: "terminate" });
        return;
      default: {
        const unknown = (msg as { type: string }).type;
        stderr.write(`[katari-port] unknown message type: ${unknown}\n`);
        exit(1);
      }
    }
  });

  send({ type: "ipcReady", protocolVersion: PROTOCOL_VERSION });
};

export default katari;
export type {
  AgentContext,
  AgentHandler,
  DelegateOptions,
  KatariPort,
  RawValue,
} from "./types.js";
export { PROTOCOL_VERSION } from "./protocol.js";
export type { ParentToChild, ChildToParent } from "./protocol.js";
