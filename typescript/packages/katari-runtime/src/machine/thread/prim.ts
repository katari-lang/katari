import type { ThreadId } from "../id.js";
import type { MachineState } from "../machine.js";
import type { Value } from "../value.js";
import {
  ChildThread,
  type ChildThreadInit,
  type SerializedChildThreadCommon,
  type Thread,
} from "./types.js";

/**
 * Executes a BlockPrim (pure primitive computation).
 * Completes immediately in `onCall` — no children.
 */
export class PrimThread extends ChildThread {
  readonly primName: string;
  readonly args: Record<string, Value>;

  constructor(init: ChildThreadInit, primName: string, args: Record<string, Value>) {
    super(init);
    this.primName = primName;
    this.args = args;
  }

  override onCall(machine: MachineState): void {
    const value = executePrim(this.primName, this.args);
    machine.queue.push({
      kind: "done",
      parent: this.parent,
      callId: this.parentCallId,
      value,
    });
  }

  // ─── Snapshot ──────────────────────────────────────────────────────────
  // PrimThread completes synchronously inside `onCall` and never survives
  // an `applyEvent` call, so in practice `serialize` is unreachable. We
  // implement it for completeness so that mid-flight snapshots remain
  // well-defined.

  override serialize(): SerializedPrimThread {
    return {
      kind: "prim",
      ...this.serializeChildCommon(),
      primName: this.primName,
      args: this.args,
    };
  }

  static restoreSkeleton(serialized: SerializedPrimThread): PrimThread {
    const thread = Object.create(PrimThread.prototype) as PrimThread;
    thread.applySnapshotChildCommon(serialized);
    const writable = thread as unknown as {
      primName: string;
      args: Record<string, Value>;
    };
    writable.primName = serialized.primName;
    writable.args = serialized.args;
    return thread;
  }

  link(
    serialized: SerializedPrimThread,
    threadsById: ReadonlyMap<ThreadId, Thread>,
  ): void {
    this.linkChildCommon(serialized, threadsById);
  }
}

export type SerializedPrimThread = SerializedChildThreadCommon & {
  kind: "prim";
  primName: string;
  args: Record<string, Value>;
};

// ─── Prim execution ─────────────────────────────────────────────────────────

function executePrim(name: string, args: Record<string, Value>): Value {
  switch (name) {
    case "add": {
      const left = args["left"];
      const right = args["right"];
      if (left?.kind === "number" && right?.kind === "number") {
        return { kind: "number", value: left.value + right.value };
      }
      throw new Error(`prim add: invalid args`);
    }
    case "sub": {
      const left = args["left"];
      const right = args["right"];
      if (left?.kind === "number" && right?.kind === "number") {
        return { kind: "number", value: left.value - right.value };
      }
      throw new Error(`prim sub: invalid args`);
    }
    case "mul": {
      const left = args["left"];
      const right = args["right"];
      if (left?.kind === "number" && right?.kind === "number") {
        return { kind: "number", value: left.value * right.value };
      }
      throw new Error(`prim mul: invalid args`);
    }
    case "div": {
      const left = args["left"];
      const right = args["right"];
      if (left?.kind === "number" && right?.kind === "number") {
        return { kind: "number", value: left.value / right.value };
      }
      throw new Error(`prim div: invalid args`);
    }
    case "mod": {
      const left = args["left"];
      const right = args["right"];
      if (left?.kind === "number" && right?.kind === "number") {
        return { kind: "number", value: left.value % right.value };
      }
      throw new Error(`prim mod: invalid args`);
    }
    case "negate": {
      const value = args["value"];
      if (value?.kind === "number") {
        return { kind: "number", value: -value.value };
      }
      throw new Error(`prim negate: invalid args`);
    }
    case "eq": {
      const left = args["left"];
      const right = args["right"];
      return { kind: "boolean", value: valueEquals(left!, right!) };
    }
    case "neq": {
      const left = args["left"];
      const right = args["right"];
      return { kind: "boolean", value: !valueEquals(left!, right!) };
    }
    case "lt": {
      const left = args["left"];
      const right = args["right"];
      if (left?.kind === "number" && right?.kind === "number") {
        return { kind: "boolean", value: left.value < right.value };
      }
      throw new Error(`prim lt: invalid args`);
    }
    case "gt": {
      const left = args["left"];
      const right = args["right"];
      if (left?.kind === "number" && right?.kind === "number") {
        return { kind: "boolean", value: left.value > right.value };
      }
      throw new Error(`prim gt: invalid args`);
    }
    case "lte": {
      const left = args["left"];
      const right = args["right"];
      if (left?.kind === "number" && right?.kind === "number") {
        return { kind: "boolean", value: left.value <= right.value };
      }
      throw new Error(`prim lte: invalid args`);
    }
    case "gte": {
      const left = args["left"];
      const right = args["right"];
      if (left?.kind === "number" && right?.kind === "number") {
        return { kind: "boolean", value: left.value >= right.value };
      }
      throw new Error(`prim gte: invalid args`);
    }
    case "not": {
      const value = args["value"];
      if (value?.kind === "boolean") {
        return { kind: "boolean", value: !value.value };
      }
      throw new Error(`prim not: invalid args`);
    }
    case "and": {
      const left = args["left"];
      const right = args["right"];
      if (left?.kind === "boolean" && right?.kind === "boolean") {
        return { kind: "boolean", value: left.value && right.value };
      }
      throw new Error(`prim and: invalid args`);
    }
    case "or": {
      const left = args["left"];
      const right = args["right"];
      if (left?.kind === "boolean" && right?.kind === "boolean") {
        return { kind: "boolean", value: left.value || right.value };
      }
      throw new Error(`prim or: invalid args`);
    }
    case "concat": {
      const left = args["left"];
      const right = args["right"];
      if (left?.kind === "string" && right?.kind === "string") {
        return { kind: "string", value: left.value + right.value };
      }
      throw new Error(`prim concat: invalid args`);
    }
    case "to_string": {
      const value = args["value"];
      return { kind: "string", value: valueToString(value!) };
    }
    case "tuple_get": {
      const tuple = args["tuple"];
      const index = args["index"];
      if (tuple?.kind === "tuple" && index?.kind === "number") {
        const elem = tuple.elements[index.value];
        if (elem === undefined) throw new Error(`prim tuple_get: index out of bounds`);
        return elem;
      }
      throw new Error(`prim tuple_get: invalid args`);
    }
    case "get_field": {
      const value = args["value"];
      const field = args["field"];
      if (value?.kind === "tagged" && field?.kind === "string") {
        const fieldValue = value.fields[field.value];
        if (fieldValue === undefined) throw new Error(`prim get_field: field ${field.value} not found`);
        return fieldValue;
      }
      throw new Error(`prim get_field: invalid args`);
    }
    default:
      throw new Error(`Unknown prim: ${name}`);
  }
}

/**
 * Structural deep equality.
 * - Primitives (number / string / boolean / null) compare by value.
 * - Tuples / arrays compare element-wise recursively (length must match).
 * - Tagged values compare by ctorId + same field set + recursive eq on each field.
 * - Closures are NEVER equal (no extensional equality on functions).
 */
function valueEquals(a: Value, b: Value): boolean {
  if (a.kind !== b.kind) return false;
  switch (a.kind) {
    case "number":
      return a.value === (b as typeof a).value;
    case "string":
      return a.value === (b as typeof a).value;
    case "boolean":
      return a.value === (b as typeof a).value;
    case "null":
      return true;
    case "tuple":
    case "array": {
      const bb = b as typeof a;
      if (a.elements.length !== bb.elements.length) return false;
      for (let i = 0; i < a.elements.length; i++) {
        if (!valueEquals(a.elements[i]!, bb.elements[i]!)) return false;
      }
      return true;
    }
    case "tagged": {
      const bb = b as typeof a;
      if (a.ctorId !== bb.ctorId) return false;
      const aKeys = Object.keys(a.fields);
      const bKeys = Object.keys(bb.fields);
      if (aKeys.length !== bKeys.length) return false;
      for (const k of aKeys) {
        if (!Object.prototype.hasOwnProperty.call(bb.fields, k)) return false;
        if (!valueEquals(a.fields[k]!, bb.fields[k]!)) return false;
      }
      return true;
    }
    case "closure":
      return false;
  }
}

function valueToString(value: Value): string {
  switch (value.kind) {
    case "number":
      return String(value.value);
    case "string":
      return value.value;
    case "boolean":
      return String(value.value);
    case "null":
      return "null";
    case "tuple":
      return `(${value.elements.map(valueToString).join(", ")})`;
    case "array":
      return `[${value.elements.map(valueToString).join(", ")}]`;
    case "tagged":
      return `${value.ctorId}{${Object.entries(value.fields).map(([k, v]) => `${k}: ${valueToString(v)}`).join(", ")}}`;
    case "closure":
      return `<closure>`;
  }
}
