// In-process FFI executor: a function map keyed by `module.name`.
//
// Used in tests and for embedded deployments where the runtime + sidecar
// live in the same process. The map values are async functions taking
// the args record and returning the result Value.

import type { DelegationId, QualifiedName, Value } from "katari-runtime";
import type { FFIExecutor, InvokeArgs } from "./executor.js";
import { withTimeout } from "./executor.js";

export type InProcessHandler = (
  args: Record<string, Value>,
  signal: AbortSignal,
) => Promise<Value>;

export class InProcessFFIExecutor implements FFIExecutor {
  private readonly inFlight = new Map<DelegationId, AbortController>();

  constructor(
    private readonly handlers: Map<string, InProcessHandler>,
  ) {}

  async invoke(args: InvokeArgs): Promise<Value> {
    const key = qnKey(args.qualifiedName);
    const handler = this.handlers.get(key);
    if (handler === undefined) {
      throw new Error(`InProcessFFIExecutor: no handler for ${key}`);
    }
    const controller = new AbortController();
    this.inFlight.set(args.delegationId, controller);

    try {
      const promise = handler(args.args, controller.signal);
      return await withTimeout(promise, args.timeoutMs ?? 0);
    } finally {
      this.inFlight.delete(args.delegationId);
    }
  }

  async terminate(delegationId: DelegationId): Promise<void> {
    const controller = this.inFlight.get(delegationId);
    if (controller === undefined) return;
    controller.abort();
    this.inFlight.delete(delegationId);
  }

  /**
   * Convenience builder: from a plain Record<string, InProcessHandler>.
   * Keys are `module.name` (or bare `name` for module_ === "").
   */
  static of(handlers: Record<string, InProcessHandler>): InProcessFFIExecutor {
    return new InProcessFFIExecutor(new Map(Object.entries(handlers)));
  }
}

function qnKey(qn: QualifiedName): string {
  return qn.module_ === "" ? qn.name : `${qn.module_}.${qn.name}`;
}
