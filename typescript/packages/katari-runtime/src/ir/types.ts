// TypeScript mirror of Katari.IR (Haskell).
//
// JSON encoding follows IR.hs Aeson options:
//   irOptions  : record fields as-is, omit Nothing (→ optional fields)
//   sumOptions : TaggedObject { "kind": tag, ...rest } — tag = lowerHead(constructor) = camelCase
//     - GADT record constructors  → fields merged flat into object
//     - GADT positional ctors     → single "contents" key
//   enumOptions: bare camelCase string (UntaggedValue, constructorTagModifier = lowerHead)

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
  /** New scope, catches return. */
  | "blockKindAgent"
  /**
   * Inherits parent scope, catches nothing.
   * Used for inline blocks, match arms, for bodies, handle bodies,
   * req handler bodies, and then-clauses.
   */
  | "blockKindInline";

// ─── ExitKind / ContKind (enumOptions) ───────────────────────────────────────

export type ExitKind = "exitKindReturn" | "exitKindBreak" | "exitKindForBreak";

export type ContKind = "contKindNext" | "contKindForNext";

// ─── Param / Handler (irOptions → flat record) ───────────────────────────────

export type Param = {
  label: string;
  var: VarId;
};

/**
 * A request handler inside a HandleData.
 * The handlerBody block is BlockKindInline and inherits the handle scope.
 * Its parameters carry the req args; state vars are accessible directly.
 */
export type Handler = {
  request: ReqId;
  handlerBody: BlockId;
};

// ─── UserBlock (irOptions → flat record) ─────────────────────────────────────

export type UserBlock = {
  kind: BlockKind;
  /**
   * Labeled parameters. Meaningful for BlockKindAgent blocks (new scope)
   * and for BlockKindInline handler/then-clause blocks (req args / break value).
   */
  parameters: Param[];
  statements: Statement[];
  trailing?: VarId;
};

// ─── Block (sumOptions, GADT record ctors → flat) ────────────────────────────

export type Block =
  | { kind: "blockUser"; body: UserBlock }
  | { kind: "blockPrim"; name: string }
  | { kind: "blockRequest"; reqId: ReqId }
  | { kind: "blockExternal"; externalName: ExternalName }
  | { kind: "blockCtor"; ctorId: CtorId }
  | { kind: "blockMatch"; matchBlock: MatchBlock }
  | { kind: "blockFor"; forBlock: ForBlock }
  | { kind: "blockHandle"; handleBlock: HandleBlock }
  | { kind: "blockTuple"; tupleBlock: TupleBlock }
  | { kind: "blockArray"; arrayBlock: ArrayBlock };

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
  | {
      kind: "matchPatternConstructor";
      contents: [CtorId, [string, MatchPattern][]];
    }
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
};

export type LoadLiteralData = {
  output: VarId;
  value: LiteralValue;
};

// ─── Block payload types (irOptions → flat record) ──────────────────────────

/** Payload for blockMatch. */
export type MatchBlock = {
  subject: VarId;
  arms: MatchArm[];
  defaultArm?: BlockId;
};

/** Payload for blockFor. */
export type ForBlock = {
  parallel: boolean;
  /** [element var inside body, source array var in this scope] */
  iters: [VarId, VarId][];
  /** [bodyVar in for scope, init value var in this scope] */
  stateInits: [VarId, VarId][];
  bodyBlock: BlockId;
  thenBlock?: BlockId;
};

/**
 * Payload for blockHandle.
 * The outer BlockKindAgent block evaluates the init expressions,
 * then calls this block via StatementCall.
 */
export type HandleBlock = {
  parallel: boolean;
  /** [bodyVar allocated in handle scope, initVar computed in caller] */
  stateInits: [VarId, VarId][];
  /** Body block (blockKindInline). Inherits the handle scope. */
  body: BlockId;
  handlers: Handler[];
  /**
   * Optional then-block (blockKindInline) run when the body completes
   * normally (= the body's last statement returns a trailing value, no
   * `break`). Its single parameter (label "value") receives the body's
   * trailing value. `break` bypasses then-block and propagates the break
   * value as the handle's result directly.
   */
  thenBlock?: BlockId;
};

/** Payload for blockTuple. */
export type TupleBlock = {
  parallel: boolean;
  /** Each element is an inline block computing one value. */
  elements: BlockId[];
};

/** Payload for blockArray. */
export type ArrayBlock = {
  parallel: boolean;
  /** Each element is an inline block computing one value. */
  elements: BlockId[];
};

export type ExitData = {
  exitKind: ExitKind;
  value: VarId;
};

export type ContData = {
  contKind: ContKind;
  value?: VarId;
  /** [targetVar in loop/handle scope, new value var in this scope] */
  modifiers: [VarId, VarId][];
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
  | { kind: "statementExit"; contents: ExitData }
  | { kind: "statementCont"; contents: ContData }
  | { kind: "statementBindPattern"; contents: BindPatternData };
