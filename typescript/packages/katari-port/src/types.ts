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
   * Aborts when the runtime sends an `ipcTerminate` for this
   * delegation. Forward this to `fetch`, `setTimeout`, etc. to
   * participate in cooperative cancellation. Ignoring the signal
   * leaves the handler running until it naturally finishes; the
   * runtime treats whatever outcome (resolve/reject) as the response
   * to the terminate.
   */
  signal: AbortSignal;
  /**
   * `true` when the runtime re-issued this delegation after a parent
   * restart (= `ipcDelegateRestarted`). Non-idempotent handlers
   * should inspect this and throw to fail safely; idempotent
   * handlers can simply re-run.
   */
  isRestored: boolean;
}

/** Async function that implements an `ext agent`. */
export type AgentHandler = (ctx: AgentContext) => Promise<RawValue>;

/**
 * Options for `katari.delegate`. The signal lets the caller cancel a
 * child agent the ext started; aborting causes katari-port to send
 * `ipcChildTerminate` and reject the returned Promise once the
 * runtime answers with `ipcChildTerminateAck`.
 */
export interface DelegateOptions {
  signal?: AbortSignal;
}

/** Public surface of the singleton imported as `import katari from "katari-port"`. */
export interface KatariPort {
  /**
   * Register a handler for an `ext agent <name>` declared in the
   * sibling `.ktr` file. Calling this twice with the same name
   * throws. The module qname prefix is injected by the bundler;
   * users pass only the local agent name.
   */
  agent(name: string, handler: AgentHandler): void;

  /**
   * Start a CORE-side child agent and await its result. `callable`
   * is a `RawValue` the ext received from Katari — either an agent
   * def's qualified name string or a `"closure:N"` string for a
   * captured local agent. `args` is the labeled argument map. The
   * returned Promise resolves with the child's return value, rejects
   * with `Error` if the child terminated abnormally, or rejects with
   * an `AbortError` when the supplied signal aborts.
   */
  delegate(
    callable: RawValue,
    args: Record<string, RawValue>,
    opts?: DelegateOptions,
  ): Promise<RawValue>;
}

export type { RawValue };
