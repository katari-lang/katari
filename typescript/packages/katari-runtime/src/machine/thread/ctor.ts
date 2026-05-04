import type { CtorId } from "../../ir/types.js";
import type { Value } from "../value.js";
import type { ThreadBase } from "./types.js";

/**
 * Executes a BlockCtor (data constructor application).
 * Completes in a single step: constructs a tagged value from arguments.
 */
export type CtorThread = ThreadBase & {
  kind: "ctor";
  ctorId: CtorId;
  /** Labeled arguments become the tagged value's fields. */
  arguments: Map<string, Value>;
};
