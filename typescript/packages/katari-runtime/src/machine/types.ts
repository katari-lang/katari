import type { BlockId, IRModule, ReqId, VarId } from "../ir/types.js";
import type { ClosureId, Value } from "./value.js";

// ─── Identifiers ─────────────────────────────────────────────────────────────

export type IrModuleId = string;
export type ThreadId = string;
export type ScopeId = string;

// ─── BlockRef ────────────────────────────────────────────────────────────────

/**
 * Runtime-global reference to a block.
 * BlockId is unique only within an IRModule, so IrModuleId is required.
 */
export type BlockRef = {
  irModuleId: IrModuleId;
  blockId: BlockId;
};

// ─── MemoryCell ──────────────────────────────────────────────────────────────

/**
 * Key for a memory cell: (scope, variable, version).
 * Version is 0 for normal let-bindings, and incremented for
 * `var` state in where-blocks (per req-handler firing) and
 * for-loops (per iteration index).
 */
export type MemoryKey = {
  scopeId: ScopeId;
  varId: VarId;
  version: number;
};

/** Serialize a MemoryKey to a string for use as a Map key. */
export function memoryKeyToString(key: MemoryKey): string {
  return `${key.scopeId}:${key.varId}:${key.version}`;
}

/**
 * A memory cell is either waiting for a value to be filled,
 * or already filled (immutable once filled).
 */
export type MemoryCell =
  | { key: MemoryKey; status: "wait"; waiters: Set<ThreadId> }
  | { key: MemoryKey; status: "filled"; value: Value };

// ─── Scope ───────────────────────────────────────────────────────────────────

/**
 * Variable binding environment. Thin concept — actual values live in
 * MemoryCell keyed by (ScopeId, VarId, Version).
 */
export type Scope = {
  id: ScopeId;
  parentId: ScopeId | null;
};

// ─── HandlerEntry ─────────────────────────────────────────────────────────────

/**
 * A resolved handler entry.
 * scopeId is the scope of the where-block that registered this handler,
 * NOT the scope of the thread that triggered the request.
 * This allows the handler body to access the where-block's `var` state.
 */
export type HandlerEntry = {
  block: BlockRef;
  scopeId: ScopeId;
};

// ─── Thread ──────────────────────────────────────────────────────────────────

export type ThreadStatus =
  | { kind: "running" }
  | { kind: "waitingFor"; keys: MemoryKey[] }
  | { kind: "done" }
  | { kind: "cancelled" };

export type Thread = {
  id: ThreadId;
  block: BlockRef;
  /**
   * Lexical scope (variable lookup origin).
   * Usually matches the parent thread's scope, but diverges for closures:
   * a closure body thread's scopeId parent is the captured scope,
   * not the caller's scope.
   */
  scopeId: ScopeId;
  /** Execution tree parent (dynamic). */
  parentThreadId: ThreadId | null;
  /**
   * Visible handlers, keyed by ReqId.
   * Inherited from parent at thread creation time and merged with
   * any handlers registered by this block. Each entry retains the
   * scopeId of the where-block that registered it.
   */
  handlers: Map<ReqId, HandlerEntry>;
  /**
   * Maps statement index → the child Thread it spawned.
   *
   * Only statements that create exactly one child Thread appear here:
   *   StatementCall (user block / closure / req / ctor / ext target)
   *   StatementMatch (the arm body Thread)
   *
   * StatementFor spawns N child Threads (one per element); those children
   * are tracked via their parentThreadId instead of this map.
   *
   * Synchronous statements (LoadLiteral, MakeClosure, prim calls,
   * BindPattern) never appear here — their "launched" status is inferred
   * from their output cell being filled.
   *
   * Absence from map = not yet launched (inputs not ready).
   */
  launchedStatements: Map<number, ThreadId>;
  status: ThreadStatus;
};

// ─── Closure ─────────────────────────────────────────────────────────────────

/**
 * A closure value: a block paired with its captured lexical scope.
 * When invoked, a new Thread is created whose scopeId parent is
 * a new scope derived from capturedScopeId.
 */
export type Closure = {
  id: ClosureId;
  block: BlockRef;
  capturedScopeId: ScopeId;
};

// ─── MachineState ────────────────────────────────────────────────────────────

export type MachineState = {
  /** Loaded IR modules. Read-only after LoadIrModule. */
  irModules: ReadonlyMap<IrModuleId, IRModule>;
  threads: Map<ThreadId, Thread>;
  scopes: Map<ScopeId, Scope>;
  /** Keys are memoryKeyToString(MemoryKey). */
  cells: Map<string, MemoryCell>;
  closures: Map<ClosureId, Closure>;
};
