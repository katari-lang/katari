// MockSidecar — test `Sidecar` implementation.
//
// Mirrors the dispatcher logic inside katari-port but runs in-process,
// so tests don't have to spawn a real subprocess. Speak the same
// `Sidecar` interface as the production `SubprocessSidecar`, so test
// code goes through every byte of the FfiModule + SidecarManager glue.
//
// `setHandler(qname, handler)` registers an ext-agent implementation
// keyed by its fully-qualified name (e.g. `"main.fetchUrl"`).

import type { Logger } from "../engine/logger.js";
import type { Sidecar } from "./sidecar.js";
import {
  PROTOCOL_VERSION,
  type ChildToParent,
  type ParentToChild,
} from "./types.js";
import type { RawValue } from "../value-codec.js";

/**
 * Test handler signature. Receives the same shape as a real ext-agent
 * handler running inside katari-port, minus the bundling indirection.
 */
export type MockAgentHandler = (input: {
  args: Record<string, RawValue>;
  delegationId: string;
  signal: AbortSignal;
  isRestored: boolean;
}) => Promise<RawValue>;

export interface MockSidecarOptions {
  logger: Logger;
  /** Initial handler map. Can also be mutated later via `setHandler`. */
  handlers?: Record<string, MockAgentHandler>;
}

export class MockSidecar implements Sidecar {
  private readonly handlers = new Map<string, MockAgentHandler>();
  private readonly inflight = new Map<
    string,
    { ctrl: AbortController; terminating: boolean }
  >();
  private cb: ((msg: ChildToParent) => void) | null = null;
  private readonly logger: Logger;

  constructor(opts: MockSidecarOptions) {
    this.logger = opts.logger;
    for (const [k, v] of Object.entries(opts.handlers ?? {})) {
      this.handlers.set(k, v);
    }
  }

  setHandler(qname: string, handler: MockAgentHandler): void {
    this.handlers.set(qname, handler);
  }

  async start(): Promise<void> {
    queueMicrotask(() => {
      this.cb?.({ type: "ready", protocolVersion: PROTOCOL_VERSION });
    });
  }

  async send(msg: ParentToChild): Promise<void> {
    if (msg.protocolVersion !== PROTOCOL_VERSION) {
      this.logger.log(
        "error",
        `mock sidecar: protocol version mismatch (got ${msg.protocolVersion}, expected ${PROTOCOL_VERSION})`,
      );
      return;
    }
    switch (msg.type) {
      case "delegate":
        void this.handleDelegate(msg, false);
        return;
      case "delegateRestored":
        void this.handleDelegate(msg, true);
        return;
      case "terminate": {
        const entry = this.inflight.get(msg.delegationId);
        if (entry !== undefined) {
          entry.terminating = true;
          entry.ctrl.abort();
          return;
        }
        this.cb?.({
          type: "terminateAck",
          protocolVersion: PROTOCOL_VERSION,
          delegationId: msg.delegationId,
        });
        return;
      }
    }
  }

  onMessage(cb: (msg: ChildToParent) => void): void {
    this.cb = cb;
  }

  async shutdown(): Promise<void> {
    for (const entry of this.inflight.values()) {
      entry.terminating = true;
      entry.ctrl.abort();
    }
    this.inflight.clear();
  }

  private async handleDelegate(
    msg: Extract<ParentToChild, { type: "delegate" | "delegateRestored" }>,
    isRestored: boolean,
  ): Promise<void> {
    // AgentDefId is documented as a flat dotted-name string on the
    // wire (see agent-def-id.ts), so we use it directly as the
    // handler-registry key.
    const key = msg.agentDefId as unknown as string;
    const handler = this.handlers.get(key);
    if (handler === undefined) {
      this.cb?.({
        type: "delegateError",
        protocolVersion: PROTOCOL_VERSION,
        delegationId: msg.delegationId,
        message: `mock sidecar: no handler for ${key}`,
      });
      return;
    }
    const ctrl = new AbortController();
    const entry = { ctrl, terminating: false };
    this.inflight.set(msg.delegationId, entry);
    let value: RawValue | null = null;
    let error: unknown = null;
    try {
      value = await handler({
        args: msg.args,
        delegationId: msg.delegationId as string,
        signal: ctrl.signal,
        isRestored,
      });
    } catch (err) {
      error = err;
    } finally {
      this.inflight.delete(msg.delegationId);
    }
    if (entry.terminating) {
      this.cb?.({
        type: "terminateAck",
        protocolVersion: PROTOCOL_VERSION,
        delegationId: msg.delegationId,
      });
      return;
    }
    if (error !== null) {
      this.cb?.({
        type: "delegateError",
        protocolVersion: PROTOCOL_VERSION,
        delegationId: msg.delegationId,
        message: error instanceof Error ? error.message : String(error),
      });
      return;
    }
    this.cb?.({
      type: "delegateAck",
      protocolVersion: PROTOCOL_VERSION,
      delegationId: msg.delegationId,
      value: value as RawValue,
    });
  }
}

