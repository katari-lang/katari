import type { Value } from "../value.js";
import type { ThreadBase } from "./types.js";

/**
 * Executes a BlockPrim (pure primitive computation).
 * Completes in a single step: looks up the prim function by name,
 * applies arguments, and produces a result value.
 */
export type PrimThread = ThreadBase & {
  kind: "prim";
  primName: string;
  /** Labeled arguments resolved at call site. */
  arguments: Map<string, Value>;
};
