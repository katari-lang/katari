import type { AgentState } from "./types.js";
import { getVar, setVar, constAsString, findThread } from "./types.js";
import type { Value } from "../value.js";
import {
  constToValue,
  isTruthy,
  toDisplayString,
  typeName,
  valueAdd,
  valueSub,
  valueMul,
  valueDiv,
  valueMod,
  valueNeg,
  valueEq,
  valueLt,
  valueConcat,
} from "../value.js";

// ===========================================================================
// StepResult — what stopped VM execution
// ===========================================================================

export type StepResult =
  // Terminal — produces a runtime event on this thread
  | { tag: "completed"; value: Value }
  | { tag: "returned"; value: Value }
  | { tag: "broken"; value: Value }
  | { tag: "continued"; value: Value; mutations: [number, number][] }
  | { tag: "for_broken"; value: Value }
  | { tag: "for_continued"; mutations: [number, number][] }
  // Suspension — needs orchestration by dispatch
  | { tag: "handle"; dst: number; handleId: number }
  | { tag: "for"; dst: number; forId: number }
  | { tag: "par"; dst: number; threads: number[] }
  | { tag: "call"; dst: number; agentDefId: number; args: Record<string, Value> }
  | { tag: "request"; dst: number; reqDefId: number; args: Record<string, Value> };

// ===========================================================================
// VM: execute thread instructions until a stop point
//
// Pure computation — no side effects beyond mutating agent.vars.
// Returns what stopped execution, or null if the thread is missing.
// ===========================================================================

export function executeThread(
  agent: AgentState,
  threadId: number
): StepResult | null {
  const irThread = findThread(agent.module, threadId);
  if (!irThread) return { tag: "completed", value: null };

  const thread = agent.threads.get(threadId);
  if (!thread) return null;

  for (;;) {
    if (thread.pc >= irThread.body.length) {
      return { tag: "completed", value: null };
    }

    const instr = irThread.body[thread.pc]!;
    thread.pc++;

    switch (instr.op) {
      // --- Terminal ---
      case "Complete":
        return { tag: "completed", value: getVar(agent, instr.val) };
      case "Return":
        return { tag: "returned", value: getVar(agent, instr.val) };
      case "HandleBreak":
        return { tag: "broken", value: getVar(agent, instr.val) };
      case "Continue":
        return {
          tag: "continued",
          value: getVar(agent, instr.val),
          mutations: instr.mutations,
        };
      case "ForBreak":
        return { tag: "for_broken", value: getVar(agent, instr.val) };
      case "ForContinue":
        return { tag: "for_continued", mutations: instr.mutations };

      // --- Suspension ---
      case "Handle":
        return { tag: "handle", dst: instr.dst, handleId: instr.handleId };
      case "For":
        return { tag: "for", dst: instr.dst, forId: instr.forId };
      case "Par":
        return { tag: "par", dst: instr.dst, threads: instr.threads };
      case "Call": {
        const args: Record<string, Value> = {};
        for (const [name, vid] of instr.args) args[name] = getVar(agent, vid);
        return { tag: "call", dst: instr.dst, agentDefId: instr.agentDefId, args };
      }
      case "Request": {
        const args: Record<string, Value> = {};
        for (const [name, vid] of instr.args) args[name] = getVar(agent, vid);
        return { tag: "request", dst: instr.dst, reqDefId: instr.reqDefId, args };
      }

      // --- Control flow ---
      case "Jump":
        thread.pc = instr.target;
        break;
      case "Branch":
        thread.pc = isTruthy(getVar(agent, instr.cond))
          ? instr.thenPc
          : instr.elsePc;
        break;
      case "Switch": {
        const val = getVar(agent, instr.val);
        let target = instr.defaultPc;
        for (const [cid, pc] of instr.cases) {
          if (valueEq(val, constToValue(agent.module.consts[cid]!))) {
            target = pc;
            break;
          }
        }
        thread.pc = target;
        break;
      }

      // --- Constants & Movement ---
      case "LoadConst":
        setVar(
          agent,
          instr.dst,
          constToValue(agent.module.consts[instr.cid]!)
        );
        break;
      case "LoadNull":
        setVar(agent, instr.dst, null);
        break;
      case "Move":
        setVar(agent, instr.dst, getVar(agent, instr.src));
        break;

      // --- Object ---
      case "NewObject": {
        const obj: Record<string, Value> = {};
        for (const [cid, vid] of instr.fields) {
          obj[constAsString(agent.module.consts, cid)] = getVar(agent, vid);
        }
        setVar(agent, instr.dst, obj);
        break;
      }
      case "GetField": {
        const o = getVar(agent, instr.obj);
        const key = constAsString(agent.module.consts, instr.field);
        setVar(
          agent,
          instr.dst,
          o && typeof o === "object" && !Array.isArray(o)
            ? (o[key] ?? null)
            : null
        );
        break;
      }
      case "SetField": {
        const o = getVar(agent, instr.obj);
        const key = constAsString(agent.module.consts, instr.field);
        const val = getVar(agent, instr.val);
        const base =
          o && typeof o === "object" && !Array.isArray(o) ? { ...o } : {};
        base[key] = val;
        setVar(agent, instr.dst, base);
        break;
      }
      case "HasField": {
        const o = getVar(agent, instr.obj);
        const key = constAsString(agent.module.consts, instr.field);
        setVar(
          agent,
          instr.dst,
          !!(o && typeof o === "object" && !Array.isArray(o) && key in o)
        );
        break;
      }

      // --- Array ---
      case "NewArray":
        setVar(
          agent,
          instr.dst,
          instr.elems.map((v) => getVar(agent, v))
        );
        break;
      case "ArrGet": {
        const arr = getVar(agent, instr.arr);
        const idx = getVar(agent, instr.idx);
        if (Array.isArray(arr) && typeof idx === "number") {
          const i = idx < 0 ? arr.length + idx : idx;
          setVar(agent, instr.dst, arr[i] ?? null);
        } else {
          setVar(agent, instr.dst, null);
        }
        break;
      }
      case "ArrLen": {
        const arr = getVar(agent, instr.arr);
        setVar(agent, instr.dst, Array.isArray(arr) ? arr.length : 0);
        break;
      }
      case "ArrPush": {
        const arr = getVar(agent, instr.arr);
        const elem = getVar(agent, instr.elem);
        setVar(
          agent,
          instr.dst,
          Array.isArray(arr) ? [...arr, elem] : [elem]
        );
        break;
      }
      case "ArrSlice": {
        const arr = getVar(agent, instr.arr);
        const start = getVar(agent, instr.start);
        const end = getVar(agent, instr.end);
        if (
          Array.isArray(arr) &&
          typeof start === "number" &&
          typeof end === "number"
        ) {
          const s = Math.min(Math.max(0, start), arr.length);
          const e = Math.min(Math.max(0, end), arr.length);
          setVar(agent, instr.dst, s <= e ? arr.slice(s, e) : []);
        } else {
          setVar(agent, instr.dst, []);
        }
        break;
      }

      // --- Arithmetic ---
      case "Add":
        setVar(agent, instr.dst, valueAdd(getVar(agent, instr.lhs), getVar(agent, instr.rhs)));
        break;
      case "Sub":
        setVar(agent, instr.dst, valueSub(getVar(agent, instr.lhs), getVar(agent, instr.rhs)));
        break;
      case "Mul":
        setVar(agent, instr.dst, valueMul(getVar(agent, instr.lhs), getVar(agent, instr.rhs)));
        break;
      case "Div":
        setVar(agent, instr.dst, valueDiv(getVar(agent, instr.lhs), getVar(agent, instr.rhs)));
        break;
      case "Mod":
        setVar(agent, instr.dst, valueMod(getVar(agent, instr.lhs), getVar(agent, instr.rhs)));
        break;
      case "Neg":
        setVar(agent, instr.dst, valueNeg(getVar(agent, instr.src)));
        break;

      // --- Comparison ---
      case "CmpEq":
        setVar(agent, instr.dst, valueEq(getVar(agent, instr.lhs), getVar(agent, instr.rhs)));
        break;
      case "CmpNe":
        setVar(agent, instr.dst, !valueEq(getVar(agent, instr.lhs), getVar(agent, instr.rhs)));
        break;
      case "CmpLt":
        setVar(agent, instr.dst, valueLt(getVar(agent, instr.lhs), getVar(agent, instr.rhs)));
        break;
      case "CmpLe":
        setVar(agent, instr.dst, !valueLt(getVar(agent, instr.rhs), getVar(agent, instr.lhs)));
        break;
      case "CmpGt":
        setVar(agent, instr.dst, valueLt(getVar(agent, instr.rhs), getVar(agent, instr.lhs)));
        break;
      case "CmpGe":
        setVar(agent, instr.dst, !valueLt(getVar(agent, instr.lhs), getVar(agent, instr.rhs)));
        break;

      // --- Logical ---
      case "And":
        setVar(agent, instr.dst, isTruthy(getVar(agent, instr.lhs)) && isTruthy(getVar(agent, instr.rhs)));
        break;
      case "Or":
        setVar(agent, instr.dst, isTruthy(getVar(agent, instr.lhs)) || isTruthy(getVar(agent, instr.rhs)));
        break;
      case "Not":
        setVar(agent, instr.dst, !isTruthy(getVar(agent, instr.src)));
        break;

      // --- String/Type ---
      case "Concat":
        setVar(agent, instr.dst, valueConcat(getVar(agent, instr.lhs), getVar(agent, instr.rhs)));
        break;
      case "ToString":
        setVar(agent, instr.dst, toDisplayString(getVar(agent, instr.src)));
        break;
      case "TypeOf":
        setVar(agent, instr.dst, typeName(getVar(agent, instr.src)));
        break;
    }
  }
}
