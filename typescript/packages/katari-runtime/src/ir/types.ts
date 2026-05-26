// TypeScript mirror of Katari.IR (Haskell).
//
// JSON encoding follows IR.hs Aeson options:
//   irOptions  : record fields as-is, omit Nothing (→ optional fields)
//   sumOptions : TaggedObject { "kind": tag, "body": payload } — tag = lowerHead(constructor) = camelCase
//     - GADT record constructors  → fields merged flat into object
//     - GADT positional ctors (single-arg) → single "body" key
//     - GADT positional ctors (multi-arg)  → "body" is a JSON array
//   enumOptions: bare camelCase string (UntaggedValue, constructorTagModifier = lowerHead)
//
// **Important**: the sum-payload field name is `body`, *not* `contents` (the
// Haskell side overrides it via `TaggedObject "kind" "body"` in `sumOptions`).
// Older mirrors of this file used `contents` / individual field names like
// `name`/`matchBlock`/`forBlock`; that was wrong and prevented compiler-output
// IR from being executed by the runtime. All payload fields below are
// uniformly `body` for sum types.

// ─── Identifiers ─────────────────────────────────────────────────────────────

/** IR-level block identifier. Unique within an IRModule. */
export type BlockId = number;

/** IR-level variable identifier (per-occurrence slot). */
export type VarId = number;

/**
 * FFI boundary public name. Flat dotted string `"module.name"` (or
 * `"name"` when the module is empty). Used to identify every top-level
 * callable (agent / request / external / data constructor / prim) plus
 * the dispatch key for handlers and tagged values' ctor identity.
 *
 * Helpers below decompose the string when individual segments are
 * needed (rarely; mostly internal naming / FFI cosmetics).
 */
export type QualifiedName = string;

/** Decompose a 'QualifiedName' into (moduleName, bareName). */
export function splitQualifiedName(qn: QualifiedName): { module_: string; name: string } {
  const lastDot = qn.lastIndexOf(".");
  if (lastDot < 0) return { module_: "", name: qn };
  return { module_: qn.slice(0, lastDot), name: qn.slice(lastDot + 1) };
}

/** Build a flat 'QualifiedName' from segments. Empty module → bare name. */
export function joinQualifiedName(module_: string, name: string): QualifiedName {
  return module_ === "" ? name : `${module_}.${name}`;
}

// ─── Module ──────────────────────────────────────────────────────────────────

export type IRMetadata = {
  schemaVersion: number;
};

export type IRModule = {
  metadata: IRMetadata;
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
 * The handlerBody block is a BlockUser inheriting the handle scope.
 * Its parameters carry the req args; state vars are accessible directly.
 */
export type Handler = {
  request: QualifiedName;
  handlerBody: BlockId;
};

// ─── UserBlock (irOptions → flat record) ─────────────────────────────────────
//
// UserBlock is always inline: inherits the parent scope and catches nothing.
// Agent boundaries (new scope, return catch) are represented by `BlockAgent`
// instead.

export type UserBlock = {
  /**
   * Labeled parameters. Meaningful for handler / then-clause blocks
   * (req args / break value); empty for plain inline blocks.
   */
  parameters: Param[];
  statements: Statement[];
  trailing?: VarId;
};

// ─── AgentBlock (irOptions → flat record) ────────────────────────────────────

/**
 * Payload for `blockAgent`. Marks an agent boundary at the IR level —
 * the runtime spawns an `AgentThread` that catches `return` and isolates
 * the scope, then runs `entryBody` as a child UserThread.
 */
export type AgentBlock = {
  /**
   * Public name. Top-level agent decls use the same value that appears in
   * `IRModule.entries`; closure / local agents will use a synthesized
   * fresh name once Phase 3.7 lands.
   */
  qualifiedName: QualifiedName;
  parameters: Param[];
  /** BlockId of the body. Typically a `blockUser` (inline) or `blockHandle`. */
  entryBody: BlockId;
  /**
   * The human-readable name as it appears in the surface declaration
   * (`agent foo() ...` → `"foo"`). Distinct from `qualifiedName.name` so
   * local agents can carry their bare source-side name even though
   * their qualified name is a synthetic `<local>.foo`.
   */
  name: string;
  /** `@"..."` annotation text, when present on the declaration. */
  description?: string;
  /** Aeson-encoded JSON Schema string for the agent's parameter object. */
  inputSchema: string;
  /** Aeson-encoded JSON Schema string for the agent's return type. */
  outputSchema: string;
};

// ─── Block (sumOptions, "body" payload key) ────────────────────────────────

export type Block =
  | { kind: "blockUser"; body: UserBlock }
  | { kind: "blockPrim"; body: string }
  | { kind: "blockRequest"; body: QualifiedName }
  /**
   * Constructor block. Note the kind is `blockConstructor` (matching
   * Haskell's `BlockConstructor` ctor name); earlier drafts of this
   * mirror used `blockCtor`, which the Aeson-generated JSON never
   * actually produced.
   */
  | { kind: "blockConstructor"; body: QualifiedName }
  | { kind: "blockMatch"; body: MatchBlock }
  | { kind: "blockFor"; body: ForBlock }
  | { kind: "blockHandle"; body: HandleBlock }
  | { kind: "blockTuple"; body: TupleBlock }
  | { kind: "blockArray"; body: ArrayBlock }
  | { kind: "blockRecord"; body: RecordBlock }
  | { kind: "blockAgent"; body: AgentBlock }
  | { kind: "blockDelegate"; body: DelegateBlock };

/**
 * Payload for `blockDelegate`. Identifies the delegation target; runtime
 * picks the endpoint (CORE loopback / FFI / dynamic value resolution)
 * based on the `target` variant.
 */
export type DelegateBlock = {
  target: DelegateTarget;
};

/**
 * Discriminator for `BlockDelegate`.
 *
 *   - `delegateTargetInternal`: statically known CORE qname; runtime emits
 *     `delegate` to the local self-endpoint.
 *   - `delegateTargetExternal`: statically known external dispatch. The
 *     `endpoint` field (e.g. `"FFI"`, `"ENV"`) selects which runtime module
 *     handles dispatch; `dispatchName` is the flat opaque key that module's
 *     registry expects. Both come from the source `from "ENDPOINT:name"`
 *     clause and are independent of Katari's module path.
 *   - `delegateTargetValue`: runtime value at the given VarId
 *     (agentLiteral → qname resolved via entries to decide internal vs
 *     external; closure → CORE loopback with captured scope).
 */
export type DelegateTarget =
  | { kind: "delegateTargetInternal"; body: QualifiedName }
  | { kind: "delegateTargetExternal"; body: ExternalDispatch }
  | { kind: "delegateTargetValue"; body: VarId };

/** Payload for `delegateTargetExternal`. */
export type ExternalDispatch = {
  endpoint: string;
  dispatchName: string;
};

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
  | { kind: "literalValueNull" }
  // Reference to a top-level callable (agent / prim / ctor / external).
  // The runtime resolves `qualifiedName` through `IRModule.entries` to
  // a `BlockId` on dispatch; the value carries no captured scope.
  | { kind: "literalValueAgent"; qualifiedName: QualifiedName };

// ─── MatchPattern (sumOptions, "body" payload key) ─────────────────────────

export type MatchPattern =
  | { kind: "matchPatternAny" }
  | { kind: "matchPatternVariable"; body: VarId }
  | { kind: "matchPatternLiteral"; body: LiteralValue }
  | {
      kind: "matchPatternConstructor";
      // Multi-arg GADT positional ctor → JSON array under `body`.
      body: [QualifiedName, [string, MatchPattern][]];
    }
  | { kind: "matchPatternTuple"; body: MatchPattern[] }
  | {
      kind: "matchPatternTypeGuard";
      // [tag, inner]: tag picks the runtime-type check (integer / record /
      // ...); after the guard succeeds the inner pattern runs against the
      // narrowed value.
      body: [TypePatternTag, MatchPattern];
    }
  | {
      // Subset match: each listed key must exist in the subject record,
      // and its value must match the sub-pattern. Other entries are
      // ignored.
      kind: "matchPatternRecord";
      body: [string, MatchPattern][];
    };

// Runtime-checkable type tag. Encoded as a bare camelCase string on the
// wire (Haskell `enumOptions` — same convention as `ExitKind`). Record
// values have no tag here; record patterns (`{ label = pat, ... }`)
// cover both the type-check and field extraction in one form.
export type TypePatternTag =
  | "typePatternTagInteger"
  | "typePatternTagNumber"
  | "typePatternTagString"
  | "typePatternTagBoolean"
  | "typePatternTagAgent";

// ─── MatchArm (irOptions → flat record) ──────────────────────────────────────

export type MatchArm = {
  pattern: MatchPattern;
  body: BlockId;
};

// ─── Statement payload types (irOptions → flat record) ───────────────────────

/**
 * Payload for `statementCall` — targets any IR block. For inline
 * (structural) blocks (match arm body / for body / handle scope / tuple
 * / array / prim leaf) the runtime runs them in-thread inheriting the
 * caller's lexical scope. For a `blockDelegate` block the runtime spawns
 * a `DelegateThread` that crosses the delegation boundary.
 */
export type CallData = {
  block: BlockId;
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
 * The caller evaluates the init expressions, then calls this block via
 * StatementCall.
 */
export type HandleBlock = {
  parallel: boolean;
  /** [bodyVar allocated in handle scope, initVar computed in caller] */
  stateInits: [VarId, VarId][];
  /** Body block (BlockUser). Inherits the handle scope. */
  body: BlockId;
  handlers: Handler[];
  /**
   * Optional then-block (BlockUser) run when the body completes
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

/** Payload for blockRecord. Entries are evaluated left-to-right
 * (no parallel record literal at the surface). */
export type RecordBlock = {
  /** Ordered (label, block) pairs. Each block's trailing value
   * becomes the entry's value in the constructed record. */
  entries: [string, BlockId][];
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

// ─── Statement (sumOptions, "body" payload key) ────────────────────────────

export type Statement =
  | { kind: "statementCall"; body: CallData }
  | { kind: "statementMakeClosure"; body: MakeClosureData }
  | { kind: "statementLoadLiteral"; body: LoadLiteralData }
  | { kind: "statementExit"; body: ExitData }
  | { kind: "statementCont"; body: ContData }
  | { kind: "statementBindPattern"; body: BindPatternData };
