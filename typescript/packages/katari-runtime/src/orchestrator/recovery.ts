// Boot recovery wrapper.
//
// Most of this is done by `Orchestrator.recoverOnBoot()`: enumerate the
// snapshots that have running runs, re-spawn subprocesses, and notify
// in-flight delegationIds via `restored` IPC.
//
// The `recoverOnBoot` function adds host-specific recovery on top:
// re-inject terminate for runs that were stopped in the `cancelling`
// state. This makes the Orchestrator invoke the same behaviour as
// ApiModule.cancelRun again so the cancel cascade resumes even across
// a process restart.
//
// Host-specific recovery (e.g. re-issuing cancelling runs) is injected
// via the `extraRecovery` callback.

import type { Logger } from "../engine/logger.js";

/** Duck-typed orchestrator for recovery -- only needs `recoverOnBoot()`. */
export type RecoverableOrchestrator = {
  recoverOnBoot(): Promise<void>;
};

export type RecoveryOptions = {
  orchestrator: RecoverableOrchestrator;
  logger: Logger;
  /**
   * Host-specific recovery step run after the Orchestrator's own
   * `recoverOnBoot()`. For api-server this re-issues cancelling runs.
   * Omit or return void for hosts that don't need extra recovery.
   */
  extraRecovery?: () => Promise<void>;
};

export async function recoverOnBoot(options: RecoveryOptions): Promise<void> {
  await options.orchestrator.recoverOnBoot();
  if (options.extraRecovery !== undefined) {
    await options.extraRecovery();
  }
}
