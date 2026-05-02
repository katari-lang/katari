import type { AgentState } from "./types.js";
import { getVar, setVar, constAsString } from "./types.js";
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
// Pure computation — no side effects beyond mutating agent.scopes.
// Returns what stopped execution, or null if the thread is missing.
// ===========================================================================

export function executeThread(
  agent: AgentState,
  threadId: number
): StepResult | null {
  const thread = agent.threads.get(threadId);
  if (!thread) return null;

  const irThread = agent.module.threads.get(thread.blockId);
  if (!irThread) return { tag: "completed", value: null };

  const s = thread.scopeId;

  for (;;) {
    if (thread.pc >= irThread.body.length) {
      return { tag: "completed", value: null };
    }

    const instr = irThread.body[thread.pc]!;
    thread.pc++;

    switch (instr.op) {
      // --- Terminal ---
      case "Complete":
        return { tag: "completed", value: getVar(agent, s, instr.val) };
      case "Return":
        return { tag: "returned", value: getVar(agent, s, instr.val) };
      case "HandleBreak":
        return { tag: "broken", value: getVar(agent, s, instr.val) };
      case "Continue":
        return {
          tag: "continued",
          value: getVar(agent, s, instr.val),
          mutations: instr.mutations,
        };
      case "ForBreak":
        return { tag: "for_broken", value: getVar(agent, s, instr.val) };
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
        for (const [name, vid] of instr.args) args[name] = getVar(agent, s, vid);
        return { tag: "call", dst: instr.dst, agentDefId: instr.agentDefId, args };
      }
      case "Request": {
        const args: Record<string, Value> = {};
        for (const [name, vid] of instr.args) args[name] = getVar(agent, s, vid);
        return { tag: "request", dst: instr.dst, reqDefId: instr.reqDefId, args };
      }

      // --- Control flow ---
      case "Jump":
        thread.pc = instr.target;
        break;
      case "Branch":
        thread.pc = isTruthy(getVar(agent, s, instr.cond))
          ? instr.thenPc
          : instr.elsePc;
        break;
      case "Switch": {
        const val = getVar(agent, s, instr.val);
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
          s,
          instr.dst,
          constToValue(agent.module.consts[instr.cid]!)
        );
        break;
      case "LoadNull":
        setVar(agent, s, instr.dst, null);
        break;
      case "Move":
        setVar(agent, s, instr.dst, getVar(agent, s, instr.src));
        break;

      // --- Object ---
      case "NewObject": {
        const obj: Record<string, Value> = {};
        for (const [cid, vid] of instr.fields) {
          obj[constAsString(agent.module.consts, cid)] = getVar(agent, s, vid);
        }
        setVar(agent, s, instr.dst, obj);
        break;
      }
      case "GetField": {
        const o = getVar(agent, s, instr.obj);
        const key = constAsString(agent.module.consts, instr.field);
        setVar(
          agent,
          s,
          instr.dst,
          o && typeof o === "object" && !Array.isArray(o)
            ? (o[key] ?? null)
            : null
        );
        break;
      }
      case "SetField": {
        const o = getVar(agent, s, instr.obj);
        const key = constAsString(agent.module.consts, instr.field);
        const val = getVar(agent, s, instr.val);
        const base =
          o && typeof o === "object" && !Array.isArray(o) ? { ...o } : {};
        base[key] = val;
        setVar(agent, s, instr.dst, base);
        break;
      }
      case "HasField": {
        const o = getVar(agent, s, instr.obj);
        const key = constAsString(agent.module.consts, instr.field);
        setVar(
          agent,
          s,
          instr.dst,
          !!(o && typeof o === "object" && !Array.isArray(o) && key in o)
        );
        break;
      }

      // --- Array ---
      case "NewArray":
        setVar(
          agent,
          s,
          instr.dst,
          instr.elems.map((v) => getVar(agent, s, v))
        );
        break;
      case "ArrGet": {
        const arr = getVar(agent, s, instr.arr);
        const idx = getVar(agent, s, instr.idx);
        if (Array.isArray(arr) && typeof idx === "number") {
          const i = idx < 0 ? arr.length + idx : idx;
          setVar(agent, s, instr.dst, arr[i] ?? null);
        } else {
          setVar(agent, s, instr.dst, null);
        }
        break;
      }
      case "ArrLen": {
        const arr = getVar(agent, s, instr.arr);
        setVar(agent, s, instr.dst, Array.isArray(arr) ? arr.length : 0);
        break;
      }
      case "ArrPush": {
        const arr = getVar(agent, s, instr.arr);
        const elem = getVar(agent, s, instr.elem);
        setVar(
          agent,
          s,
          instr.dst,
          Array.isArray(arr) ? [...arr, elem] : [elem]
        );
        break;
      }
      case "ArrSlice": {
        const arr = getVar(agent, s, instr.arr);
        const start = getVar(agent, s, instr.start);
        const end = getVar(agent, s, instr.end);
        if (
          Array.isArray(arr) &&
          typeof start === "number" &&
          typeof end === "number"
        ) {
          const sl = Math.min(Math.max(0, start), arr.length);
          const e = Math.min(Math.max(0, end), arr.length);
          setVar(agent, s, instr.dst, sl <= e ? arr.slice(sl, e) : []);
        } else {
          setVar(agent, s, instr.dst, []);
        }
        break;
      }

      // --- Arithmetic ---
      case "Add":
        setVar(agent, s, instr.dst, valueAdd(getVar(agent, s, instr.lhs), getVar(agent, s, instr.rhs)));
        break;
      case "Sub":
        setVar(agent, s, instr.dst, valueSub(getVar(agent, s, instr.lhs), getVar(agent, s, instr.rhs)));
        break;
      case "Mul":
        setVar(agent, s, instr.dst, valueMul(getVar(agent, s, instr.lhs), getVar(agent, s, instr.rhs)));
        break;
      case "Div":
        setVar(agent, s, instr.dst, valueDiv(getVar(agent, s, instr.lhs), getVar(agent, s, instr.rhs)));
        break;
      case "Mod":
        setVar(agent, s, instr.dst, valueMod(getVar(agent, s, instr.lhs), getVar(agent, s, instr.rhs)));
        break;
      case "Neg":
        setVar(agent, s, instr.dst, valueNeg(getVar(agent, s, instr.src)));
        break;

      // --- Comparison ---
      case "CmpEq":
        setVar(agent, s, instr.dst, valueEq(getVar(agent, s, instr.lhs), getVar(agent, s, instr.rhs)));
        break;
      case "CmpNe":
        setVar(agent, s, instr.dst, !valueEq(getVar(agent, s, instr.lhs), getVar(agent, s, instr.rhs)));
        break;
      case "CmpLt":
        setVar(agent, s, instr.dst, valueLt(getVar(agent, s, instr.lhs), getVar(agent, s, instr.rhs)));
        break;
      case "CmpLe":
        setVar(agent, s, instr.dst, !valueLt(getVar(agent, s, instr.rhs), getVar(agent, s, instr.lhs)));
        break;
      case "CmpGt":
        setVar(agent, s, instr.dst, valueLt(getVar(agent, s, instr.rhs), getVar(agent, s, instr.lhs)));
        break;
      case "CmpGe":
        setVar(agent, s, instr.dst, !valueLt(getVar(agent, s, instr.lhs), getVar(agent, s, instr.rhs)));
        break;

      // --- Logical ---
      case "And":
        setVar(agent, s, instr.dst, isTruthy(getVar(agent, s, instr.lhs)) && isTruthy(getVar(agent, s, instr.rhs)));
        break;
      case "Or":
        setVar(agent, s, instr.dst, isTruthy(getVar(agent, s, instr.lhs)) || isTruthy(getVar(agent, s, instr.rhs)));
        break;
      case "Not":
        setVar(agent, s, instr.dst, !isTruthy(getVar(agent, s, instr.src)));
        break;

      // --- String/Type ---
      case "Concat":
        setVar(agent, s, instr.dst, valueConcat(getVar(agent, s, instr.lhs), getVar(agent, s, instr.rhs)));
        break;
      case "ToString":
        setVar(agent, s, instr.dst, toDisplayString(getVar(agent, s, instr.src)));
        break;
      case "TypeOf":
        setVar(agent, s, instr.dst, typeName(getVar(agent, s, instr.src)));
        break;
    }
  }
}
