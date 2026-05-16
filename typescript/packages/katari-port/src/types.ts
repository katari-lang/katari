// Public types for user code that imports katari-port.

import type { RawValue } from "katari-runtime";

/** Context handed to a user-provided agent handler at delegate time. */
export interface AgentContext {
  /** Argument map sent by the Katari runtime. Keys match the `ext agent` parameter labels. */
  args: Record<string, RawValue>;
  /**
   * Stable delegation id assigned by the runtime. Useful as a logger
   * context or an idempotency key. Different deliveries of the same
   * call (e.g. after a parent restart) reuse the same id.
   */
  delegationId: string;
  /**
   * Aborts when the runtime sends a `terminate` IPC for this delegation.
   * Forward this to `fetch`, `setTimeout`, etc. to participate in
   * cooperative cancellation. Ignoring the signal leaves the handler
   * running until it naturally finishes; the runtime treats whatever
   * outcome (resolve/reject) as the response to the terminate.
   */
  signal: AbortSignal;
  /**
   * `true` when the runtime re-issued this delegation after a parent
   * restart (= `delegateRestored` IPC). Non-idempotent handlers should
   * inspect this and throw to fail safely; idempotent handlers can
   * simply re-run.
   */
  isRestored: boolean;
}

/** Async function that implements an `ext agent`. */
export type AgentHandler = (ctx: AgentContext) => Promise<RawValue>;

/** Public surface of the singleton imported as `import katari from "katari-port"`. */
export interface KatariPort {
  /**
   * Register a handler for an `ext agent <name>` declared in the
   * sibling `.ktr` file. Calling this twice with the same name throws.
   * The module qname prefix is injected by the bundler; users pass
   * only the local agent name.
   */
  agent(name: string, handler: AgentHandler): void;
}

export type { RawValue };
