import type { MachineState } from "../machine.js";
import type { Value } from "../value.js";
import type { CreateThreadInit, ThreadBase } from "./types.js";

/**
 * Executes a BlockPrim (pure primitive computation).
 * Completes immediately in onCall — no children.
 */
export type PrimThread = ThreadBase & {
  kind: "prim";
  primName: string;
  args: Map<string, Value>;
};

export function createPrimThread(
  machine: MachineState,
  init: CreateThreadInit,
  primName: string,
  args: Map<string, Value>,
): PrimThread {
  const thread: PrimThread = {
    ...init,
    kind: "prim",
    scopeId: init.parent.scopeId,
    children: new Map(),
    status: "running",
    primName,
    args,
  };
  machine.threads.set(thread.id, thread);
  return thread;
}

export function onCallPrim(machine: MachineState, thread: PrimThread): void {
  const value = executePrim(thread.primName, thread.args);
  machine.queue.push({
    kind: "done",
    parent: thread.parent!,
    callId: thread.parentCallId!,
    value,
  });
}

// ─── Prim execution ─────────────────────────────────────────────────────────

function executePrim(name: string, args: Map<string, Value>): Value {
  switch (name) {
    case "add": {
      const left = args.get("left");
      const right = args.get("right");
      if (left?.kind === "number" && right?.kind === "number") {
        return { kind: "number", value: left.value + right.value };
      }
      throw new Error(`prim add: invalid args`);
    }
    case "sub": {
      const left = args.get("left");
      const right = args.get("right");
      if (left?.kind === "number" && right?.kind === "number") {
        return { kind: "number", value: left.value - right.value };
      }
      throw new Error(`prim sub: invalid args`);
    }
    case "mul": {
      const left = args.get("left");
      const right = args.get("right");
      if (left?.kind === "number" && right?.kind === "number") {
        return { kind: "number", value: left.value * right.value };
      }
      throw new Error(`prim mul: invalid args`);
    }
    case "div": {
      const left = args.get("left");
      const right = args.get("right");
      if (left?.kind === "number" && right?.kind === "number") {
        return { kind: "number", value: left.value / right.value };
      }
      throw new Error(`prim div: invalid args`);
    }
    case "mod": {
      const left = args.get("left");
      const right = args.get("right");
      if (left?.kind === "number" && right?.kind === "number") {
        return { kind: "number", value: left.value % right.value };
      }
      throw new Error(`prim mod: invalid args`);
    }
    case "negate": {
      const value = args.get("value");
      if (value?.kind === "number") {
        return { kind: "number", value: -value.value };
      }
      throw new Error(`prim negate: invalid args`);
    }
    case "eq": {
      const left = args.get("left");
      const right = args.get("right");
      return { kind: "boolean", value: valueEquals(left!, right!) };
    }
    case "neq": {
      const left = args.get("left");
      const right = args.get("right");
      return { kind: "boolean", value: !valueEquals(left!, right!) };
    }
    case "lt": {
      const left = args.get("left");
      const right = args.get("right");
      if (left?.kind === "number" && right?.kind === "number") {
        return { kind: "boolean", value: left.value < right.value };
      }
      throw new Error(`prim lt: invalid args`);
    }
    case "gt": {
      const left = args.get("left");
      const right = args.get("right");
      if (left?.kind === "number" && right?.kind === "number") {
        return { kind: "boolean", value: left.value > right.value };
      }
      throw new Error(`prim gt: invalid args`);
    }
    case "lte": {
      const left = args.get("left");
      const right = args.get("right");
      if (left?.kind === "number" && right?.kind === "number") {
        return { kind: "boolean", value: left.value <= right.value };
      }
      throw new Error(`prim lte: invalid args`);
    }
    case "gte": {
      const left = args.get("left");
      const right = args.get("right");
      if (left?.kind === "number" && right?.kind === "number") {
        return { kind: "boolean", value: left.value >= right.value };
      }
      throw new Error(`prim gte: invalid args`);
    }
    case "not": {
      const value = args.get("value");
      if (value?.kind === "boolean") {
        return { kind: "boolean", value: !value.value };
      }
      throw new Error(`prim not: invalid args`);
    }
    case "and": {
      const left = args.get("left");
      const right = args.get("right");
      if (left?.kind === "boolean" && right?.kind === "boolean") {
        return { kind: "boolean", value: left.value && right.value };
      }
      throw new Error(`prim and: invalid args`);
    }
    case "or": {
      const left = args.get("left");
      const right = args.get("right");
      if (left?.kind === "boolean" && right?.kind === "boolean") {
        return { kind: "boolean", value: left.value || right.value };
      }
      throw new Error(`prim or: invalid args`);
    }
    case "concat": {
      const left = args.get("left");
      const right = args.get("right");
      if (left?.kind === "string" && right?.kind === "string") {
        return { kind: "string", value: left.value + right.value };
      }
      throw new Error(`prim concat: invalid args`);
    }
    case "to_string": {
      const value = args.get("value");
      return { kind: "string", value: valueToString(value!) };
    }
    case "tuple_get": {
      const tuple = args.get("tuple");
      const index = args.get("index");
      if (tuple?.kind === "tuple" && index?.kind === "number") {
        const elem = tuple.elements[index.value];
        if (elem === undefined) throw new Error(`prim tuple_get: index out of bounds`);
        return elem;
      }
      throw new Error(`prim tuple_get: invalid args`);
    }
    case "get_field": {
      const value = args.get("value");
      const field = args.get("field");
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
    default:
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
