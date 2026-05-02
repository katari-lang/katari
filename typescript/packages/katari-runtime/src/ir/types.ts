// TypeScript mirror of Katari.IR (Haskell).
//
// JSON encoding follows IR.hs Aeson options:
//   irOptions  : record fields as-is, omit Nothing (→ optional fields)
//   sumOptions : TaggedObject { "kind": tag, ...rest } with lowerHead tag
//     - GADT record constructors  → fields merged flat into object
//     - GADT positional ctors     → single "contents" key
//   enumOptions: bare camelCase string (UntaggedValue + lowerHead)

// ─── Identifiers ─────────────────────────────────────────────────────────────

/** IR-level block identifier. Unique within an IRModule. */
export type BlockId = number;

/** IR-level variable identifier (per-occurrence slot). */
export type VarId = number;

/** IR-level request identifier (handler dispatch key). */
export type ReqId = number;

/** IR-level data constructor identifier. */
export type CtorId = number;

/** FFI boundary public name. */
export type QualifiedName = {
  module_: string;
  name: string;
};

/**
 * ExternalName is a newtype over QualifiedName in Haskell.
 * JSON shape is identical to QualifiedName.
 */
export type ExternalName = QualifiedName;

// ─── Module ──────────────────────────────────────────────────────────────────

export type IRMetadata = {
  schemaVersion: number;
};

export type IRModule = {
  metadata: IRMetadata;
  name: string;
  /** BlockId (number) as string key → Block */
  blocks: Record<string, Block>;
  /**
   * QualifiedName encoded as JSON object key → BlockId.
   * Key format depends on Aeson's ToJSONKey instance for QualifiedName.
   */
  entries: Record<string, BlockId>;
  nameTable: NameTable;
};

export type NameTable = {
  /** VarId (number) as string key → debug name */
  varNames: Record<string, string>;
  /** BlockId (number) as string key → debug name */
  blockNames: Record<string, string>;
};

// ─── BlockKind (enumOptions → bare camelCase string) ─────────────────────────

export type BlockKind =
  | "blockAgentEntry"
  | "blockAgentEntryWithHandlers"
  | "blockHandleScope"
  | "blockInline"
  | "blockHandlerBody";

// ─── ExitKind / ContKind (enumOptions) ───────────────────────────────────────

export type ExitKind =
  | "exitKindReturn"
  | "exitKindBreak"
  | "exitKindForBreak";

export type ContKind = "contKindNext" | "contKindForNext";

// ─── Param / Handler (irOptions → flat record) ───────────────────────────────

export type Param = {
  label: string;
  var: VarId;
};

export type Handler = {
  request: ReqId;
  handlerBody: BlockId;
};

// ─── UserBlock (irOptions → flat record) ─────────────────────────────────────

export type UserBlock = {
  kind: BlockKind;
  captures: Param[];
  parameters: Param[];
  stateVars: Param[];
  statements: Statement[];
  trailing?: VarId;
  thenBlock?: BlockId;
  handlers: Handler[];
};

// ─── Block (sumOptions, GADT record ctors → flat) ────────────────────────────

export type Block =
  | { kind: "blockUser"; body: UserBlock }
  | { kind: "blockPrim"; name: string }
  | { kind: "blockRequest"; reqId: ReqId }
  | { kind: "blockExternal"; externalName: ExternalName }
  | { kind: "blockCtor"; ctorId: CtorId };

// ─── Arg (irOptions → flat record) ───────────────────────────────────────────

export type Arg = {
  label: string;
  var: VarId;
};

// ─── LiteralValue (sumOptions, GADT record ctors → flat) ─────────────────────

export type LiteralValue =
  | { kind: "literalValueInteger"; integer: number }
  | { kind: "literalValueNumber"; number: number }
  | { kind: "literalValueString"; string: string }
  | { kind: "literalValueBoolean"; boolean: boolean }
  | { kind: "literalValueNull" };

// ─── CallTarget (sumOptions, GADT record ctors → flat) ───────────────────────

export type CallTarget =
  | { kind: "callTargetBlock"; block: BlockId }
  | { kind: "callTargetValue"; var: VarId };

// ─── MatchPattern (sumOptions, GADT positional ctors → contents) ─────────────

export type MatchPattern =
  | { kind: "matchPatternAny" }
  | { kind: "matchPatternVariable"; contents: VarId }
  | { kind: "matchPatternLiteral"; contents: LiteralValue }
  | { kind: "matchPatternConstructor"; contents: [CtorId, [string, MatchPattern][]] }
  | { kind: "matchPatternTuple"; contents: MatchPattern[] };

// ─── MatchArm (irOptions → flat record) ──────────────────────────────────────

export type MatchArm = {
  pattern: MatchPattern;
  body: BlockId;
};

// ─── Statement payload types (irOptions → flat record) ───────────────────────

export type CallData = {
  target: CallTarget;
  arguments: Arg[];
  output?: VarId;
};

export type MakeClosureData = {
  output: VarId;
  block: BlockId;
  captures: Arg[];
};

export type LoadLiteralData = {
  output: VarId;
  value: LiteralValue;
};

export type MatchData = {
  subject: VarId;
  arms: MatchArm[];
  defaultArm?: BlockId;
  output?: VarId;
};

export type ForData = {
  /** [element var inside body, source array var in this scope] */
  iters: [VarId, VarId][];
  /** [state var label, init value var in this scope] */
  stateInits: [string, VarId][];
  bodyBlock: BlockId;
  thenBlock?: BlockId;
  output?: VarId;
};

export type ExitData = {
  exitKind: ExitKind;
  value: VarId;
};

export type ContData = {
  contKind: ContKind;
  value?: VarId;
  /** [state var label, new value var in this scope] */
  modifiers: [string, VarId][];
};

export type BindPatternData = {
  source: VarId;
  pattern: MatchPattern;
};

// ─── Statement (sumOptions, positional single-arg → contents) ─────────────────

export type Statement =
  | { kind: "statementCall"; contents: CallData }
  | { kind: "statementMakeClosure"; contents: MakeClosureData }
  | { kind: "statementLoadLiteral"; contents: LoadLiteralData }
  | { kind: "statementMatch"; contents: MatchData }
  | { kind: "statementFor"; contents: ForData }
  | { kind: "statementExit"; contents: ExitData }
  | { kind: "statementCont"; contents: ContData }
  | { kind: "statementBindPattern"; contents: BindPatternData };
