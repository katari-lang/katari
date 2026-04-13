import type { OutgoingMessage } from "katari-protocol";
import type { AgentState, Event } from "./types.js";
import {
  getVar, setVar, isRunning, constAsString, findThread, finishThread,
} from "./types.js";
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
// Callbacks for suspension instructions (avoids circular deps)
// ===========================================================================

export interface ExecuteCallbacks {
  setupHandle(agent: AgentState, threadId: number, dst: number, hid: number, events: Event[]): void;
  setupFor(agent: AgentState, threadId: number, dst: number, fid: number, events: Event[]): void;
  setupPar(agent: AgentState, threadId: number, dst: number, tids: number[], events: Event[]): void;
  handleICall(agent: AgentState, threadId: number, dst: number, agentDefId: number, namedArgs: [string, number][], events: Event[], messages: OutgoingMessage[]): void;
  handleIRequest(agent: AgentState, threadId: number, dst: number, reqDefId: number, namedArgs: [string, number][], events: Event[], messages: OutgoingMessage[]): void;
}

// ===========================================================================
// VM: execute thread instructions
// ===========================================================================

export function executeThread(
  agent: AgentState,
  threadId: number,
  events: Event[],
  messages: OutgoingMessage[],
  cb: ExecuteCallbacks
): void {
  const irThread = findThread(agent.module, threadId);
  if (!irThread) {
    finishThread(agent, threadId, { tag: "Normal", value: null }, events);
    return;
  }

  for (;;) {
    const t = agent.threads.get(threadId);
    if (!t || !isRunning(t)) return;

    if (t.pc >= irThread.body.length) {
      finishThread(agent, threadId, { tag: "Normal", value: null }, events);
      return;
    }

    const instr = irThread.body[t.pc]!;
    t.pc++;

    switch (instr.op) {
      // --- Terminal ---
      case "Complete":
        finishThread(agent, threadId, { tag: "Normal", value: getVar(agent, instr.val) }, events);
        return;
      case "Return":
        finishThread(agent, threadId, { tag: "FnReturn", value: getVar(agent, instr.val) }, events);
        return;
      case "HandleBreak":
        finishThread(agent, threadId, { tag: "HandleBreak", value: getVar(agent, instr.val) }, events);
        return;
      case "Continue":
        finishThread(agent, threadId, { tag: "Continue", value: getVar(agent, instr.val), mutations: instr.mutations }, events);
        return;
      case "ForBreak":
        finishThread(agent, threadId, { tag: "ForBreak", value: getVar(agent, instr.val) }, events);
        return;
      case "ForContinue":
        finishThread(agent, threadId, { tag: "ForContinue", mutations: instr.mutations }, events);
        return;

      // --- Control flow ---
      case "Jump":
        t.pc = instr.target;
        break;
      case "Branch":
        t.pc = isTruthy(getVar(agent, instr.cond)) ? instr.thenPc : instr.elsePc;
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
        t.pc = target;
        break;
      }

      // --- Suspension ---
      case "Handle":
        cb.setupHandle(agent, threadId, instr.dst, instr.handleId, events);
        return;
      case "For":
        cb.setupFor(agent, threadId, instr.dst, instr.forId, events);
        return;
      case "Par":
        cb.setupPar(agent, threadId, instr.dst, instr.threads, events);
        return;
      case "Call":
        cb.handleICall(agent, threadId, instr.dst, instr.agentDefId, instr.args, events, messages);
        if (!isRunning(agent.threads.get(threadId)!)) return;
        break;
      case "Request":
        cb.handleIRequest(agent, threadId, instr.dst, instr.reqDefId, instr.args, events, messages);
        return;

      // --- Constants & movement ---
      case "LoadConst":
        setVar(agent, instr.dst, constToValue(agent.module.consts[instr.cid]!));
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
        setVar(agent, instr.dst, (o && typeof o === "object" && !Array.isArray(o)) ? (o[key] ?? null) : null);
        break;
      }
      case "SetField": {
        const o = getVar(agent, instr.obj);
        const key = constAsString(agent.module.consts, instr.field);
        const val = getVar(agent, instr.val);
        const base = (o && typeof o === "object" && !Array.isArray(o)) ? { ...o } : {};
        base[key] = val;
        setVar(agent, instr.dst, base);
        break;
      }
      case "HasField": {
        const o = getVar(agent, instr.obj);
        const key = constAsString(agent.module.consts, instr.field);
        setVar(agent, instr.dst, !!(o && typeof o === "object" && !Array.isArray(o) && key in o));
        break;
      }

      // --- Array ---
      case "NewArray":
        setVar(agent, instr.dst, instr.elems.map((v) => getVar(agent, v)));
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
        setVar(agent, instr.dst, Array.isArray(arr) ? [...arr, elem] : [elem]);
        break;
      }
      case "ArrSlice": {
        const arr = getVar(agent, instr.arr);
        const start = getVar(agent, instr.start);
        const end = getVar(agent, instr.end);
        if (Array.isArray(arr) && typeof start === "number" && typeof end === "number") {
          const s = Math.min(Math.max(0, start), arr.length);
          const e = Math.min(Math.max(0, end), arr.length);
          setVar(agent, instr.dst, s <= e ? arr.slice(s, e) : []);
        } else {
          setVar(agent, instr.dst, []);
        }
        break;
      }

      // --- Arithmetic ---
      case "Add": setVar(agent, instr.dst, valueAdd(getVar(agent, instr.lhs), getVar(agent, instr.rhs))); break;
      case "Sub": setVar(agent, instr.dst, valueSub(getVar(agent, instr.lhs), getVar(agent, instr.rhs))); break;
      case "Mul": setVar(agent, instr.dst, valueMul(getVar(agent, instr.lhs), getVar(agent, instr.rhs))); break;
      case "Div": setVar(agent, instr.dst, valueDiv(getVar(agent, instr.lhs), getVar(agent, instr.rhs))); break;
      case "Mod": setVar(agent, instr.dst, valueMod(getVar(agent, instr.lhs), getVar(agent, instr.rhs))); break;
      case "Neg": setVar(agent, instr.dst, valueNeg(getVar(agent, instr.src))); break;

      // --- Comparison ---
      case "CmpEq": setVar(agent, instr.dst, valueEq(getVar(agent, instr.lhs), getVar(agent, instr.rhs))); break;
      case "CmpNe": setVar(agent, instr.dst, !valueEq(getVar(agent, instr.lhs), getVar(agent, instr.rhs))); break;
      case "CmpLt": setVar(agent, instr.dst, valueLt(getVar(agent, instr.lhs), getVar(agent, instr.rhs))); break;
      case "CmpLe": setVar(agent, instr.dst, !valueLt(getVar(agent, instr.rhs), getVar(agent, instr.lhs))); break;
      case "CmpGt": setVar(agent, instr.dst, valueLt(getVar(agent, instr.rhs), getVar(agent, instr.lhs))); break;
      case "CmpGe": setVar(agent, instr.dst, !valueLt(getVar(agent, instr.lhs), getVar(agent, instr.rhs))); break;

      // --- Logical ---
      case "And": setVar(agent, instr.dst, isTruthy(getVar(agent, instr.lhs)) && isTruthy(getVar(agent, instr.rhs))); break;
      case "Or": setVar(agent, instr.dst, isTruthy(getVar(agent, instr.lhs)) || isTruthy(getVar(agent, instr.rhs))); break;
      case "Not": setVar(agent, instr.dst, !isTruthy(getVar(agent, instr.src))); break;

      // --- String/Type ---
      case "Concat": setVar(agent, instr.dst, valueConcat(getVar(agent, instr.lhs), getVar(agent, instr.rhs))); break;
      case "ToString": setVar(agent, instr.dst, toDisplayString(getVar(agent, instr.src))); break;
      case "TypeOf": setVar(agent, instr.dst, typeName(getVar(agent, instr.src))); break;
    }
  }
}
