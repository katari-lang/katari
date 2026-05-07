// Engine error taxonomy.
//
// The runtime mutates `MachineState` in-place during `processQueue`, so a
// throw mid-queue leaves the machine in an inconsistent state — there is no
// safe way to keep using the same handle. The api-server reacts by
// reconstructing the handle from the most recent snapshot (rollback) and
// flipping the offending agent to `error`, OR by poisoning every running
// agent on the version (in case the underlying state damage is not
// localizable). Which response is appropriate depends on the cause.
//
// We split the engine throws into two classes:
//
// - **RecoverableEngineError**: the user (or upstream tooling) gave the
//   engine a bad input that affects only one agent in flight — a typo'd
//   qualifiedName, a prim arg with the wrong kind, a literal pattern in a
//   match block that was supposed to be exhaustive, etc. The api-server
//   should rollback to the previous snapshot, mark the offending agent as
//   `error`, and let the rest of the version's agents continue.
//
// - **IrrecoverableEngineError** (or *anything else* that escapes the
//   engine): the in-place state damage may have crossed agent boundaries
//   (corrupted snapshot, missing IR block referenced by multiple threads,
//   internal invariant violation). The api-server poisons the version: all
//   running/cancelling agents go to `error` and the snapshot is dropped.
//
// Code outside the runtime should `instanceof RecoverableEngineError` and
// fall through to a poison path on anything else (including a plain
// `Error`).
//
// Stage A11 establishes the types but only routes a handful of throw sites
// (the obvious "user input is bad" paths). Subsequent stages will reroute
// further sites as we audit them; anything not yet reclassified stays as a
// plain `Error`, which the api-server will continue to poison on. That is
// the safe default during the migration.

import type { DelegationId } from "../machine/id.js";

/**
 * A single agent's input is bad. The api-server should mark *just that
 * agent* as `error` and roll the machine back to the snapshot taken before
 * the failed `applyEvent`.
 *
 * `delegationId` lets the api-server identify which agent to mark when the
 * runtime knows it. When the runtime cannot pinpoint the agent (e.g. a
 * shared invariant tripped during processQueue dispatch unrelated to a
 * specific delegation), `delegationId` is left undefined and the api-server
 * falls back to "mark the triggering agent" — same as the poison path's
 * scoped behavior, just without the bulk error.
 */
export class RecoverableEngineError extends Error {
  readonly delegationId?: DelegationId;
  constructor(message: string, delegationId?: DelegationId) {
    super(message);
    this.name = "RecoverableEngineError";
    this.delegationId = delegationId;
  }
}

/**
 * Specific subtype for "qualifiedName not in IRModule.entries". Lets the
 * api-server return 400 (bad request) instead of 500 when a client invokes
 * a non-existent agent definition.
 */
export class EntryNotFoundError extends RecoverableEngineError {
  readonly qualifiedName: string;
  constructor(qualifiedName: string, delegationId?: DelegationId) {
    super(
      `agent entry "${qualifiedName}" not found in IR module`,
      delegationId,
    );
    this.name = "EntryNotFoundError";
    this.qualifiedName = qualifiedName;
  }
}

/**
 * Engine invariant violation. The api-server poisons the version. Use
 * sparingly; most user-facing failures should be {@link RecoverableEngineError}.
 *
 * Existing throw sites that haven't been migrated yet just throw `Error`,
 * which the api-server already treats as irrecoverable; this class exists
 * so call sites that have been audited can be explicit about the
 * classification.
 */
export class IrrecoverableEngineError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "IrrecoverableEngineError";
  }
}
