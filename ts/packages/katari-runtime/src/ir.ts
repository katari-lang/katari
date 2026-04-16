// ===========================================================================
// IR types
// ===========================================================================

export type VarId = number;
export type ConstId = number;
export type AgentDefId = number;
export type RequestDefId = number;
export type ThreadDefId = number;
export type HandleDefId = number;
export type ForDefId = number;

export type ConstVal =
  | { tag: "Null" }
  | { tag: "Bool"; value: boolean }
  | { tag: "Int"; value: number }
  | { tag: "Num"; value: number }
  | { tag: "Str"; value: string };

export type ThreadKind =
  | "FnBody"
  | "Block"
  | "HandlerTarget"
  | "RequestHandler"
  | "HandleThen"
  | "ForBody"
  | "ForThen";

export interface IRThread {
  id: number;
  kind: ThreadKind;
  params: VarId[];
  body: Instruction[];
}

export interface IRHandleDef {
  id: number;
  stateVars: VarId[];
  stateInits: VarId[];
  body: ThreadDefId;
  reqCases: [RequestDefId, ThreadDefId][];
  then: ThreadDefId | null;
}

export interface IRForDef {
  id: number;
  iterVars: VarId[];
  arrays: VarId[];
  stateVars: VarId[];
  stateInits: VarId[];
  body: ThreadDefId;
  then: ThreadDefId | null;
}

export interface IRAgentDef {
  id: number;
  name: string;
  entry: ThreadDefId;
  paramNames: string[];
}

export interface IRRequestDef {
  id: number;
  name: string;
  from: string | null;
  paramNames: string[];
}

export interface IRModule {
  name: string;
  nameTable: Map<string, number>;
  consts: ConstVal[];
  requests: Map<number, IRRequestDef>;
  threads: Map<number, IRThread>;
  handles: Map<number, IRHandleDef>;
  fors: Map<number, IRForDef>;
  agents: Map<number, IRAgentDef>;
  // Secondary indexes
  agentsByName: Map<string, IRAgentDef>;
  requestsByName: Map<string, IRRequestDef>;
}

// ===========================================================================
// Instruction (46 variants)
// ===========================================================================

export type Instruction =
  // Constants & Movement
  | { op: "LoadConst"; dst: VarId; cid: ConstId }
  | { op: "LoadNull"; dst: VarId }
  | { op: "Move"; dst: VarId; src: VarId }
  // Object
  | { op: "NewObject"; dst: VarId; fields: [ConstId, VarId][] }
  | { op: "GetField"; dst: VarId; obj: VarId; field: ConstId }
  | { op: "SetField"; dst: VarId; obj: VarId; field: ConstId; val: VarId }
  | { op: "HasField"; dst: VarId; obj: VarId; field: ConstId }
  // Array
  | { op: "NewArray"; dst: VarId; elems: VarId[] }
  | { op: "ArrGet"; dst: VarId; arr: VarId; idx: VarId }
  | { op: "ArrLen"; dst: VarId; arr: VarId }
  | { op: "ArrPush"; dst: VarId; arr: VarId; elem: VarId }
  | { op: "ArrSlice"; dst: VarId; arr: VarId; start: VarId; end: VarId }
  // Arithmetic
  | { op: "Add"; dst: VarId; lhs: VarId; rhs: VarId }
  | { op: "Sub"; dst: VarId; lhs: VarId; rhs: VarId }
  | { op: "Mul"; dst: VarId; lhs: VarId; rhs: VarId }
  | { op: "Div"; dst: VarId; lhs: VarId; rhs: VarId }
  | { op: "Mod"; dst: VarId; lhs: VarId; rhs: VarId }
  | { op: "Neg"; dst: VarId; src: VarId }
  // Comparison
  | { op: "CmpEq"; dst: VarId; lhs: VarId; rhs: VarId }
  | { op: "CmpNe"; dst: VarId; lhs: VarId; rhs: VarId }
  | { op: "CmpLt"; dst: VarId; lhs: VarId; rhs: VarId }
  | { op: "CmpLe"; dst: VarId; lhs: VarId; rhs: VarId }
  | { op: "CmpGt"; dst: VarId; lhs: VarId; rhs: VarId }
  | { op: "CmpGe"; dst: VarId; lhs: VarId; rhs: VarId }
  // Logical
  | { op: "And"; dst: VarId; lhs: VarId; rhs: VarId }
  | { op: "Or"; dst: VarId; lhs: VarId; rhs: VarId }
  | { op: "Not"; dst: VarId; src: VarId }
  // String/Type
  | { op: "Concat"; dst: VarId; lhs: VarId; rhs: VarId }
  | { op: "ToString"; dst: VarId; src: VarId }
  | { op: "TypeOf"; dst: VarId; src: VarId }
  // Control flow
  | { op: "Jump"; target: number }
  | { op: "Branch"; cond: VarId; thenPc: number; elsePc: number }
  | { op: "Switch"; val: VarId; cases: [ConstId, number][]; defaultPc: number }
  | { op: "Complete"; val: VarId }
  | { op: "Return"; val: VarId }
  // Agent operations
  | { op: "Call"; dst: VarId; agentDefId: AgentDefId; args: [string, VarId][] }
  | { op: "Par"; dst: VarId; threads: ThreadDefId[] }
  | { op: "Request"; dst: VarId; reqDefId: RequestDefId; args: [string, VarId][] }
  // Handle
  | { op: "Handle"; dst: VarId; handleId: HandleDefId }
  | { op: "Continue"; val: VarId; mutations: [VarId, VarId][] }
  | { op: "HandleBreak"; val: VarId }
  // For
  | { op: "For"; dst: VarId; forId: ForDefId }
  | { op: "ForContinue"; mutations: [VarId, VarId][] }
  | { op: "ForBreak"; val: VarId };

// ===========================================================================
// KTRI bytecode decoder
// ===========================================================================

const MAGIC = [0x4b, 0x54, 0x52, 0x49]; // "KTRI"
const VERSION = [0x00, 0x03];

class ByteReader {
  private pos = 0;
  private view: DataView;
  constructor(private buf: Uint8Array) {
    this.view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  }

  readByte(): number {
    if (this.pos >= this.buf.length) throw new Error("unexpected EOF");
    return this.buf[this.pos++]!;
  }

  readBytes(n: number): Uint8Array {
    if (this.pos + n > this.buf.length) throw new Error("unexpected EOF");
    const slice = this.buf.subarray(this.pos, this.pos + n);
    this.pos += n;
    return slice;
  }

  readU32(): number {
    let result = 0;
    let shift = 0;
    for (;;) {
      const byte = this.readByte();
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) === 0) return result >>> 0;
      shift += 7;
      if (shift >= 35) throw new Error("LEB128 u32 overflow");
    }
  }

  readSigned(): number {
    let result = 0;
    let shift = 0;
    let byte: number;
    for (;;) {
      byte = this.readByte();
      result |= (byte & 0x7f) << shift;
      shift += 7;
      if ((byte & 0x80) === 0) break;
      if (shift >= 70) throw new Error("signed LEB128 overflow");
    }
    if (shift < 64 && (byte! & 0x40) !== 0) {
      result |= ~0 << shift;
    }
    return result;
  }

  readF64(): number {
    const offset = this.pos;
    this.pos += 8;
    if (this.pos > this.buf.length) throw new Error("unexpected EOF");
    return this.view.getFloat64(offset, true); // little-endian
  }

  readText(): string {
    const len = this.readU32();
    const bytes = this.readBytes(len);
    return new TextDecoder().decode(bytes);
  }

  readVec<T>(readItem: () => T): T[] {
    const count = this.readU32();
    const items: T[] = [];
    for (let i = 0; i < count; i++) items.push(readItem());
    return items;
  }

  readMaybe<T>(readItem: () => T): T | null {
    const tag = this.readByte();
    if (tag === 0) return null;
    if (tag === 1) return readItem();
    throw new Error(`invalid maybe tag: ${tag}`);
  }
}

export function decodeModule(data: Uint8Array): IRModule {
  const r = new ByteReader(data);

  // Header
  for (let i = 0; i < 4; i++) {
    if (r.readByte() !== MAGIC[i]) throw new Error("invalid magic bytes");
  }
  for (let i = 0; i < 2; i++) {
    if (r.readByte() !== VERSION[i]) throw new Error("unsupported version");
  }

  const name = r.readText();
  const consts = r.readVec(() => readConst(r));
  const requestsArr = r.readVec(() => readRequestDef(r));
  const threadsArr = r.readVec(() => readThread(r));
  const handlesArr = r.readVec(() => readHandleDef(r));
  const forsArr = r.readVec(() => readForDef(r));
  const agentsArr = r.readVec(() => readAgentDef(r));

  return {
    name,
    nameTable: new Map(),
    consts,
    requests: new Map(requestsArr.map(r => [r.id, r])),
    threads: new Map(threadsArr.map(t => [t.id, t])),
    handles: new Map(handlesArr.map(h => [h.id, h])),
    fors: new Map(forsArr.map(f => [f.id, f])),
    agents: new Map(agentsArr.map(a => [a.id, a])),
    agentsByName: new Map(agentsArr.map(a => [a.name, a])),
    requestsByName: new Map(requestsArr.map(r => [r.name, r])),
  };
}

function readConst(r: ByteReader): ConstVal {
  const tag = r.readByte();
  switch (tag) {
    case 0x00: return { tag: "Null" };
    case 0x01: return { tag: "Bool", value: r.readByte() !== 0 };
    case 0x02: return { tag: "Int", value: r.readSigned() };
    case 0x03: return { tag: "Num", value: r.readF64() };
    case 0x04: return { tag: "Str", value: r.readText() };
    default: throw new Error(`unknown const tag: 0x${tag.toString(16)}`);
  }
}

function readRequestDef(r: ByteReader): IRRequestDef {
  return { id: r.readU32(), name: r.readText(), from: r.readMaybe(() => r.readText()), paramNames: r.readVec(() => r.readText()) };
}

function readThread(r: ByteReader): IRThread {
  const id = r.readU32();
  const kindByte = r.readByte();
  const kinds: ThreadKind[] = [
    "FnBody", "Block", "HandlerTarget", "RequestHandler", "HandleThen", "ForBody", "ForThen"
  ];
  if (kindByte >= kinds.length) throw new Error(`unknown thread kind: ${kindByte}`);
  return {
    id,
    kind: kinds[kindByte]!,
    params: r.readVec(() => r.readU32()),
    body: r.readVec(() => readInstruction(r)),
  };
}

function readHandleDef(r: ByteReader): IRHandleDef {
  return {
    id: r.readU32(),
    stateVars: r.readVec(() => r.readU32()),
    stateInits: r.readVec(() => r.readU32()),
    body: r.readU32(),
    reqCases: r.readVec(() => [r.readU32(), r.readU32()]),
    then: r.readMaybe(() => r.readU32()),
  };
}

function readForDef(r: ByteReader): IRForDef {
  return {
    id: r.readU32(),
    iterVars: r.readVec(() => r.readU32()),
    arrays: r.readVec(() => r.readU32()),
    stateVars: r.readVec(() => r.readU32()),
    stateInits: r.readVec(() => r.readU32()),
    body: r.readU32(),
    then: r.readMaybe(() => r.readU32()),
  };
}

function readAgentDef(r: ByteReader): IRAgentDef {
  return { id: r.readU32(), name: r.readText(), entry: r.readU32(), paramNames: r.readVec(() => r.readText()) };
}

function readInstruction(r: ByteReader): Instruction {
  const op = r.readByte();
  switch (op) {
    case 0x01: return { op: "LoadConst", dst: r.readU32(), cid: r.readU32() };
    case 0x02: return { op: "LoadNull", dst: r.readU32() };
    case 0x03: return { op: "Move", dst: r.readU32(), src: r.readU32() };

    case 0x10: return { op: "NewObject", dst: r.readU32(), fields: r.readVec(() => [r.readU32(), r.readU32()]) };
    case 0x11: return { op: "GetField", dst: r.readU32(), obj: r.readU32(), field: r.readU32() };
    case 0x12: return { op: "SetField", dst: r.readU32(), obj: r.readU32(), field: r.readU32(), val: r.readU32() };
    case 0x13: return { op: "HasField", dst: r.readU32(), obj: r.readU32(), field: r.readU32() };

    case 0x20: return { op: "NewArray", dst: r.readU32(), elems: r.readVec(() => r.readU32()) };
    case 0x21: return { op: "ArrGet", dst: r.readU32(), arr: r.readU32(), idx: r.readU32() };
    case 0x22: return { op: "ArrLen", dst: r.readU32(), arr: r.readU32() };
    case 0x23: return { op: "ArrPush", dst: r.readU32(), arr: r.readU32(), elem: r.readU32() };
    case 0x25: return { op: "ArrSlice", dst: r.readU32(), arr: r.readU32(), start: r.readU32(), end: r.readU32() };

    case 0x30: return { op: "Add", dst: r.readU32(), lhs: r.readU32(), rhs: r.readU32() };
    case 0x31: return { op: "Sub", dst: r.readU32(), lhs: r.readU32(), rhs: r.readU32() };
    case 0x32: return { op: "Mul", dst: r.readU32(), lhs: r.readU32(), rhs: r.readU32() };
    case 0x33: return { op: "Div", dst: r.readU32(), lhs: r.readU32(), rhs: r.readU32() };
    case 0x34: return { op: "Mod", dst: r.readU32(), lhs: r.readU32(), rhs: r.readU32() };
    case 0x35: return { op: "Neg", dst: r.readU32(), src: r.readU32() };

    case 0x50: return { op: "CmpEq", dst: r.readU32(), lhs: r.readU32(), rhs: r.readU32() };
    case 0x51: return { op: "CmpNe", dst: r.readU32(), lhs: r.readU32(), rhs: r.readU32() };
    case 0x52: return { op: "CmpLt", dst: r.readU32(), lhs: r.readU32(), rhs: r.readU32() };
    case 0x53: return { op: "CmpLe", dst: r.readU32(), lhs: r.readU32(), rhs: r.readU32() };
    case 0x54: return { op: "CmpGt", dst: r.readU32(), lhs: r.readU32(), rhs: r.readU32() };
    case 0x55: return { op: "CmpGe", dst: r.readU32(), lhs: r.readU32(), rhs: r.readU32() };

    case 0x60: return { op: "And", dst: r.readU32(), lhs: r.readU32(), rhs: r.readU32() };
    case 0x61: return { op: "Or", dst: r.readU32(), lhs: r.readU32(), rhs: r.readU32() };
    case 0x62: return { op: "Not", dst: r.readU32(), src: r.readU32() };

    case 0x70: return { op: "Concat", dst: r.readU32(), lhs: r.readU32(), rhs: r.readU32() };
    case 0x71: return { op: "ToString", dst: r.readU32(), src: r.readU32() };
    case 0x73: return { op: "TypeOf", dst: r.readU32(), src: r.readU32() };

    case 0x80: return { op: "Jump", target: r.readU32() };
    case 0x81: return { op: "Branch", cond: r.readU32(), thenPc: r.readU32(), elsePc: r.readU32() };
    case 0x82: return { op: "Switch", val: r.readU32(), cases: r.readVec(() => [r.readU32(), r.readU32()]), defaultPc: r.readU32() };
    case 0x83: return { op: "Return", val: r.readU32() };
    case 0x84: return { op: "Complete", val: r.readU32() };

    case 0x90: return { op: "Call", dst: r.readU32(), agentDefId: r.readU32(), args: r.readVec((): [string, number] => [r.readText(), r.readU32()]) };
    case 0x91: return { op: "Par", dst: r.readU32(), threads: r.readVec(() => r.readU32()) };
    case 0x92: return { op: "Request", dst: r.readU32(), reqDefId: r.readU32(), args: r.readVec((): [string, number] => [r.readText(), r.readU32()]) };

    case 0xa0: return { op: "Handle", dst: r.readU32(), handleId: r.readU32() };
    case 0xa2: return { op: "Continue", val: r.readU32(), mutations: r.readVec(() => [r.readU32(), r.readU32()]) };
    case 0xa3: return { op: "HandleBreak", val: r.readU32() };

    case 0xb0: return { op: "ForContinue", mutations: r.readVec(() => [r.readU32(), r.readU32()]) };
    case 0xb1: return { op: "ForBreak", val: r.readU32() };
    case 0xb2: return { op: "For", dst: r.readU32(), forId: r.readU32() };

    default: throw new Error(`unknown opcode: 0x${op.toString(16)}`);
  }
}
