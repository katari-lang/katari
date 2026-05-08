// Engine error taxonomy. Lives inside the engine layer (no upward ref to
// the runtime facade).
//
// - RecoverableEngineError: the engine encountered a single-agent input
//   problem (typo'd qualifiedName, prim arg of wrong kind, refutable
//   pattern that should have been caught by the compiler, ...). The host
//   layer should mark just that agent as `error` and roll the machine
//   state back from the pre-call snapshot.
//
// - IrrecoverableEngineError: an internal invariant tripped. The host
//   should poison the version (mark every running/cancelling agent as
//   error and drop the snapshot).
//
// `EntryNotFoundError` is a thin specialization of Recoverable for the
// "qualifiedName not found in IRModule.entries" case so the HTTP layer
// can return 400.

import type { DelegationId } from "./id.js";

export class RecoverableEngineError extends Error {
  readonly delegationId?: DelegationId;
  constructor(message: string, delegationId?: DelegationId) {
    super(message);
    this.name = "RecoverableEngineError";
    this.delegationId = delegationId;
  }
}

export class EntryNotFoundError extends RecoverableEngineError {
  readonly qualifiedName: string;
  constructor(qualifiedName: string, delegationId?: DelegationId) {
    super(`agent entry "${qualifiedName}" not found in IR module`, delegationId);
    this.name = "EntryNotFoundError";
    this.qualifiedName = qualifiedName;
  }
}

export class IrrecoverableEngineError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "IrrecoverableEngineError";
  }
}

export type EngineError = RecoverableEngineError | IrrecoverableEngineError;
