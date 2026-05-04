import type { BlockId, BlockKind, Statement, VarId } from "../../ir/types.js";
import type { ThreadBase } from "./types.js";

/**
 * Executes a BlockUser (agent or inline).
 * Processes statements sequentially via a program counter.
 *
 * - BlockKindAgent: creates a fresh scope, catches return.
 * - BlockKindInline: inherits parent scope, propagates return to parent.
 */
export type UserThread = ThreadBase & {
  kind: "user";
  blockId: BlockId;
  blockKind: BlockKind;
  /** Cached statements from UserBlock. */
  statements: Statement[];
  /** Tail value VarId (Rust-style trailing expression). */
  trailing: VarId | undefined;
  /** Index of the next statement to execute. */
  pc: number;
};
