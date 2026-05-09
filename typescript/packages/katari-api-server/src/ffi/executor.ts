// FFIExecutor: the host's adapter for resolving CORE→FFI delegate /
// terminate events. The engine emits these as outbound events; the
// `OutboundEventDispatcher` hands them to an `FFIExecutor` which calls
// out to the actual sidecar (HTTP, in-process function, etc).
//
// `invoke` returns a Promise that resolves with the FFI's return value
// or rejects with an error (timeout, network failure, etc). The
// AgentService is responsible for feeding the resulting `delegateAck` /
// `terminateAck` back into the engine.

import type { DelegationId, QualifiedName, Value } from "katari-runtime";

export type InvokeArgs = {
  qualifiedName: QualifiedName;
  args: Record<string, Value>;
  delegationId: DelegationId;
  /** Timeout in milliseconds; 0 / undefined disables the host-side timeout. */
  timeoutMs?: number;
};

export interface FFIExecutor {
  /**
   * Invoke a sidecar function. Resolves with the returned Value on
   * success; rejects on timeout / connection failure / sidecar error.
   *
   * Implementations should respect `terminate` (called when the host
   * decides to abort the in-flight call) — it's a hint that the
   * promise's resolution will be ignored.
   */
  invoke(args: InvokeArgs): Promise<Value>;

  /**
   * Cancel an in-flight invocation. Idempotent — terminating an unknown
   * delegationId is a no-op. Implementations should make a best-effort
   * attempt to abort the underlying call (e.g. AbortController for HTTP).
   */
  terminate(delegationId: DelegationId): Promise<void>;
}

/**
 * Wrap an FFIExecutor invocation in a `Promise.race` against a timeout.
 * Returns a fresh promise that rejects with `Error("FFI timeout after Nms")`
 * if `timeoutMs` elapses before the underlying call resolves. Callers
 * are responsible for calling `executor.terminate` after a timeout.
 */
export function withTimeout<T>(
  promise: Promise<T>,
  timeoutMs: number,
): Promise<T> {
  if (timeoutMs <= 0) return promise;
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`FFI timeout after ${timeoutMs}ms`));
    }, timeoutMs);
    timer.unref?.();
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (err) => {
        clearTimeout(timer);
        reject(err);
      },
    );
  });
}
