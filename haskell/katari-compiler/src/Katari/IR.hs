-- | Intermediate Representation for the Katari runtime.
--
-- IR は block 中心の data-flow 言語。Lowering が Zonked AST から型情報を捨てて
-- 生成し、ランタイム (TS) は JSON 形式で受け取りインタプリトする。
--
-- 設計の核 (詳細は doc/ir-design.md 相当を参照):
--
--   * 全ての callable (agent / req / ext / data ctor / prim) を 'Block' 表に
--     乗せ、'SCall' で統一的に呼ぶ。Special block (prim / req / ext / ctor) は
--     statements を持たず metadata のみ。
--   * 制御フローは if / match / for を 'SMatch' / 'SFor' という structured
--     statement として残す。jump / label は使わない。
--   * 大域脱出は 'SExit' (return / break / for_break) と 'SCont' (next /
--     for_next) の 2 系統。経路上 then-block の適用ルールが異なる。
--   * Variable は 'VarId' のみ。scope は runtime 側で 'UserBlock.kind'
--     を見て管理する。
--   * 型情報は IR に含まれない。
--
-- JSON 表現は全て 'genericToJSON' / 'genericParseJSON' で導出する。
-- Sum 型は @{"kind": tag, ...}@ の TaggedObject 形式: record 引数の
-- constructor は flat (例: @{"kind":"prim","name":"add"}@)、
-- 単一 non-record 引数の constructor は @"contents"@ にネスト
-- (例: @{"kind":"call","contents":{"target":...,"args":...,"output":...}}@)。
module Katari.IR
  ( -- * Identifiers
    BlockId (..),
    VarId (..),
    ReqId (..),
    CtorId (..),
    QualifiedName (..),
    renderQualifiedName,
    ExternalName (..),

    -- * Module
    IRModule (..),
    NameTable (..),
    emptyNameTable,

    -- * Block
    Block (..),
    UserBlock (..),
    BlockKind (..),
    Param (..),
    Handler (..),

    -- * Statement
    Statement (..),
    CallData (..),
    MakeClosureData (..),
    MatchData (..),
    ForData (..),
    ExitData (..),
    ContData (..),
    LoadLiteralData (..),
    LiteralValue (..),
    CallTarget (..),
    Arg (..),
    MatchArm (..),
    MatchPattern (..),
    BindPatternData (..),
    ExitKind (..),
    ContKind (..),
  )
where

import Data.Aeson
  ( FromJSON (..),
    FromJSONKey,
    Options (..),
    SumEncoding (..),
    ToJSON (..),
    ToJSONKey,
    defaultOptions,
    genericParseJSON,
    genericToJSON,
  )
import Data.Char (toLower)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32)
import GHC.Generics (Generic)

-- ===========================================================================
-- Identifiers
-- ===========================================================================

-- | Block identifier. Globally unique within an 'IRModule'. Used as the
-- target of 'SCall' / 'SMakeClosure' and as the key of 'IRModule.blocks'.
newtype BlockId = BlockId Word32
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON, ToJSONKey, FromJSONKey)

-- | IR-level variable identifier. Distinct from AST 'VariableId'; Lowering
-- allocates a fresh 'VarId' for each occurrence that needs an IR slot.
newtype VarId = VarId Word32
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON, ToJSONKey, FromJSONKey)

-- | IR-level request identifier carried by a 'BlockRequest'. Independent
-- of the Identifier-pass 'RequestId' (Lowering re-allocates these so the
-- IR can be re-indexed without touching upstream phases). Currently 1:1
-- with the corresponding 'BlockRequest'\'s 'BlockId', but kept as a
-- separate id space to preserve flexibility (the runtime dispatches
-- handlers by 'ReqId' equality, which is faster than walking the block
-- table).
newtype ReqId = ReqId Word32
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON, ToJSONKey, FromJSONKey)

-- | IR-level constructor identifier carried by a 'BlockCtor' and stored
-- inside every tagged value the runtime constructs. Independent of the
-- Identifier-pass 'ConstructorId' for the same reason as 'ReqId'.
newtype CtorId = CtorId Word32
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON, ToJSONKey, FromJSONKey)

-- | A top-level declaration's qualified name (@\<modulePath\>.\<bareName\>@
-- as the canonical pair). Used as the FFI-boundary identifier in
-- 'IRModule.entries' so that JS / external callers can address a
-- callable without depending on the IR's internal 'BlockId' /
-- 'ReqId' / 'CtorId' allocation.
data QualifiedName = QualifiedName
  { module_ :: !Text,
    name :: !Text
  }
  deriving (Eq, Ord, Show, Generic)

instance ToJSON QualifiedName where
  toJSON = genericToJSON irOptions

instance FromJSON QualifiedName where
  parseJSON = genericParseJSON irOptions

instance ToJSONKey QualifiedName

instance FromJSONKey QualifiedName

renderQualifiedName :: QualifiedName -> Text
renderQualifiedName q
  | T.null q.module_ = q.name
  | otherwise = q.module_ <> "." <> q.name

-- | Identifier of an external (sidecar) callable. Wraps a 'QualifiedName'
-- under a distinct type so the runtime layer can evolve its lookup
-- protocol independently (e.g. switching to per-sidecar namespaces)
-- without churning every 'BlockExternal' use site.
newtype ExternalName = ExternalName QualifiedName
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

-- ===========================================================================
-- Top-level module
-- ===========================================================================

data IRModule = IRModule
  { name :: Text,
    blocks :: Map BlockId Block,
    -- | FFI inbound name resolution: @\<modulePath\>.\<bareName\>@ →
    -- 'BlockId'. Covers every top-level callable (agent / req / ext /
    -- ctor) so external callers (JS sidecars, LSP, tooling) can address
    -- them by name. The IR's internal id allocations ('BlockId',
    -- 'ReqId', 'CtorId') are intentionally not exposed; the runtime
    -- derives any inverse maps it needs by walking 'blocks' once at
    -- load time.
    entries :: Map QualifiedName BlockId,
    -- | Debug-only var/block names. Runtime ignores; pretty printer / dev
    -- tools consume.
    nameTable :: NameTable
  }
  deriving (Eq, Show, Generic)

instance ToJSON IRModule where
  toJSON = genericToJSON irOptions

instance FromJSON IRModule where
  parseJSON = genericParseJSON irOptions

data NameTable = NameTable
  { varNames :: Map VarId Text,
    blockNames :: Map BlockId Text
  }
  deriving (Eq, Show, Generic)

instance ToJSON NameTable where
  toJSON = genericToJSON irOptions

instance FromJSON NameTable where
  parseJSON = genericParseJSON irOptions

emptyNameTable :: NameTable
emptyNameTable = NameTable {varNames = Map.empty, blockNames = Map.empty}

-- ===========================================================================
-- Block
-- ===========================================================================

-- | All callable units. Special blocks (prim / req / ext / ctor) carry only
-- the metadata the runtime needs to dispatch them; the public,
-- FFI-visible name lives at the 'IRModule' level instead, so each block
-- variant only stores its dispatch-axis identifier.
data Block
  = -- | Regular user-defined block. The body lives in a separate record so
    -- the field set can grow independently of the sum tag.
    BlockUser {body :: !UserBlock}
  | -- | Built-in primitive. The runtime resolves @name@ against its prim
    -- registry. Prims are system-provided and have no module of origin,
    -- so they keep a plain 'Text' identifier (and never appear in
    -- 'IRModule.entries').
    BlockPrim {name :: !Text}
  | -- | Request declaration. The 'reqId' is what handlers match against
    -- ('Handler.request') when a request is raised via 'SCall'. The
    -- public qualified name lives in 'IRModule.entries'.
    BlockRequest {reqId :: !ReqId}
  | -- | External agent stub. The runtime looks up @externalName@ in a
    -- JS sidecar bundle.
    BlockExternal {externalName :: !ExternalName}
  | -- | Data constructor. The 'ctorId' is what 'MatchTagConstructor'
    -- compares against in match arms; values built by this block carry
    -- @{__ctor: <ctorId>, ...}@ at runtime.
    BlockCtor {ctorId :: !CtorId}
  deriving (Eq, Show, Generic)

instance ToJSON Block where
  toJSON = genericToJSON (sumOptions stripBlockPrefix)

instance FromJSON Block where
  parseJSON = genericParseJSON (sumOptions stripBlockPrefix)

-- | Static structural role of a 'UserBlock'. Replaces the older
-- 'BlockProps' triple of booleans, making invalid combinations
-- unrepresentable.
--
-- The 5 valid roles correspond to:
--
--   * 'BlockAgentEntry' — agent body without handlers; catches @return@ only.
--   * 'BlockAgentEntryWithHandlers' — agent body with a where-clause that
--     attaches handlers; catches both @return@ and @break@.
--   * 'BlockHandleScope' — inner scope of a @where { state vars; handlers }@
--     construct; catches @break@ and inherits the parent scope.
--   * 'BlockInline' — an inline block / arm body / for-body / then-clause;
--     inherits the parent scope, catches nothing.
--   * 'BlockHandlerBody' — the body of a request handler; runs in its own
--     scope and catches nothing.
--
-- Mapping to the runtime\'s old triple:
--
-- @
--                                 catchesReturn  catchesBreak  inheritScope
-- BlockAgentEntry                 True           False         False
-- BlockAgentEntryWithHandlers     True           True          False
-- BlockHandleScope                False          True          True
-- BlockInline                     False          False         True
-- BlockHandlerBody                False          False         False
-- @
data BlockKind
  = BlockAgentEntry
  | BlockAgentEntryWithHandlers
  | BlockHandleScope
  | BlockInline
  | BlockHandlerBody
  deriving (Eq, Show, Generic)

instance ToJSON BlockKind where
  toJSON = genericToJSON (enumOptions stripBlockPrefix)

instance FromJSON BlockKind where
  parseJSON = genericParseJSON (enumOptions stripBlockPrefix)

-- | The body of a regular user-defined block.
data UserBlock = UserBlock
  { -- | Structural role of the block. Determines exit semantics and scope
    -- inheritance at runtime.
    kind :: !BlockKind,
    -- | Closure-captured parameters. Empty for top-level callables; for
    -- closures produced by 'SMakeClosure', these are the values trapped
    -- from the enclosing scope at closure-build time. The runtime
    -- supplies them automatically when the closure is invoked, on top
    -- of the call-time 'params'.
    captures :: ![Param],
    -- | Regular labeled parameters (call args bind by label).
    params :: ![Param],
    -- | Mutable state vars introduced by @where (var ...)@ or @for (var ...)@.
    -- Listed separately so the runtime can apply the parallel/versioning
    -- semantics for state mutation.
    stateVars :: ![Param],
    statements :: ![Statement],
    -- | Tail value when the block completes normally (Rust-style trailing
    -- expression). 'Nothing' means the block has no value.
    trailing :: !(Maybe VarId),
    -- | Optional then-block applied to the body's tail. Receives 1 param
    -- whose label is conventionally @"value"@ (set by Lowering).
    thenBlock :: !(Maybe BlockId),
    -- | Request handlers attached to this block. Only meaningful when
    -- 'kind' is 'BlockAgentEntryWithHandlers' or 'BlockHandleScope'.
    handlers :: ![Handler]
  }
  deriving (Eq, Show, Generic)

instance ToJSON UserBlock where
  toJSON = genericToJSON irOptions

instance FromJSON UserBlock where
  parseJSON = genericParseJSON irOptions

-- | A label-bound param. The @label@ is what callers use in 'Arg'.
data Param = Param
  { label :: !Text,
    var :: !VarId
  }
  deriving (Eq, Show, Generic)

instance ToJSON Param where
  toJSON = genericToJSON irOptions

instance FromJSON Param where
  parseJSON = genericParseJSON irOptions

-- | A request handler attached to a handle-scope block. Handler dispatch
-- compares the raised request's 'ReqId' against this 'request' field;
-- on equality the runtime invokes 'handlerBody'.
data Handler = Handler
  { -- | The 'ReqId' of the 'BlockRequest' being handled.
    request :: !ReqId,
    -- | The handler body block. Its params are @[req args... , state vars...]@
    -- by label.
    handlerBody :: !BlockId
  }
  deriving (Eq, Show, Generic)

instance ToJSON Handler where
  toJSON = genericToJSON irOptions

instance FromJSON Handler where
  parseJSON = genericParseJSON irOptions

-- ===========================================================================
-- Statements
-- ===========================================================================

-- | All actions a block can take. Statement order is irrelevant: the runtime
-- is dataflow-based and fires statements when their input vars are ready.
--
-- Each variant wraps a payload record (e.g. 'CallData') so that field-name
-- conflicts (output \/ value across constructors with different field types)
-- don't collide at the Haskell level. JSON-wise this nests the payload
-- under a @"contents"@ key alongside the @"kind"@ tag.
data Statement
  = SCall !CallData
  | SMakeClosure !MakeClosureData
  | SLoadLiteral !LoadLiteralData
  | SMatch !MatchData
  | SFor !ForData
  | SExit !ExitData
  | SCont !ContData
  | -- | Bind the value of @source@ by walking @pattern@ recursively. The
    -- runtime walks @pattern@ exactly like the arm-pattern walker of
    -- 'SMatch', binding each 'MPVariable' position. Unlike 'SMatch' there
    -- is no @defaultArm@; the pattern is irrefutable (guaranteed by the
    -- exhaustiveness checker — K0291 / Phase 16).
    SBindPattern !BindPatternData
  deriving (Eq, Show, Generic)

instance ToJSON Statement where
  toJSON = genericToJSON (sumOptions stripStmtPrefix)

instance FromJSON Statement where
  parseJSON = genericParseJSON (sumOptions stripStmtPrefix)

-- | Payload for 'SCall'.
data CallData = CallData
  { target :: !CallTarget,
    args :: ![Arg],
    -- | Output var receives the callee's trailing value. 'Nothing' = drop.
    output :: !(Maybe VarId)
  }
  deriving (Eq, Show, Generic)

instance ToJSON CallData where
  toJSON = genericToJSON irOptions

instance FromJSON CallData where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'SMakeClosure'. The 'captures' list pairs each capture
-- param's label (which must match a 'Param' in the target block's
-- @captures@ field) with the outer-scope 'VarId' whose value the
-- closure should trap.
data MakeClosureData = MakeClosureData
  { output :: !VarId,
    block :: !BlockId,
    captures :: ![Arg]
  }
  deriving (Eq, Show, Generic)

instance ToJSON MakeClosureData where
  toJSON = genericToJSON irOptions

instance FromJSON MakeClosureData where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'SMatch'.
data MatchData = MatchData
  { subject :: !VarId,
    arms :: ![MatchArm],
    defaultArm :: !(Maybe BlockId),
    output :: !(Maybe VarId)
  }
  deriving (Eq, Show, Generic)

instance ToJSON MatchData where
  toJSON = genericToJSON irOptions

instance FromJSON MatchData where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'SFor'.
data ForData = ForData
  { -- | (element var inside body's params, source array var in this scope)
    iters :: ![(VarId, VarId)],
    -- | (state var label, init value var in this scope)
    stateInits :: ![(Text, VarId)],
    bodyBlock :: !BlockId,
    -- | Optional then-block applied to the for's final value.
    thenBlock :: !(Maybe BlockId),
    output :: !(Maybe VarId)
  }
  deriving (Eq, Show, Generic)

instance ToJSON ForData where
  toJSON = genericToJSON irOptions

instance FromJSON ForData where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'SExit'.
data ExitData = ExitData
  { exitKind :: !ExitKind,
    value :: !VarId
  }
  deriving (Eq, Show, Generic)

instance ToJSON ExitData where
  toJSON = genericToJSON irOptions

instance FromJSON ExitData where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'SCont'.
data ContData = ContData
  { contKind :: !ContKind,
    value :: !(Maybe VarId),
    -- | (state var label, new value var in this scope)
    mods :: ![(Text, VarId)]
  }
  deriving (Eq, Show, Generic)

instance ToJSON ContData where
  toJSON = genericToJSON irOptions

instance FromJSON ContData where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'SLoadLiteral'. Kept inline (not via 'BlockPrim') so the
-- value travels with the statement.
data LoadLiteralData = LoadLiteralData
  { output :: !VarId,
    value :: !LiteralValue
  }
  deriving (Eq, Show, Generic)

instance ToJSON LoadLiteralData where
  toJSON = genericToJSON irOptions

instance FromJSON LoadLiteralData where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'SBindPattern'. The runtime walks @pattern@ against
-- @source@, binding each 'MPVariable' position. The pattern is guaranteed
-- irrefutable (K0291); runtime may treat a mismatch as an internal error.
data BindPatternData = BindPatternData
  { source :: !VarId,
    pattern :: !MatchPattern
  }
  deriving (Eq, Show, Generic)

instance ToJSON BindPatternData where
  toJSON = genericToJSON irOptions

instance FromJSON BindPatternData where
  parseJSON = genericParseJSON irOptions

-- | IR-level literal values. Mirrors 'AST.LiteralValue' but lives in the IR
-- namespace so the IR is self-contained (the runtime needs only IR types).
data LiteralValue
  = LVInteger {integer :: !Integer}
  | LVNumber {number :: !Double}
  | LVString {string :: !Text}
  | LVBoolean {boolean :: !Bool}
  | LVNull
  deriving (Eq, Show, Generic)

instance ToJSON LiteralValue where
  toJSON = genericToJSON (sumOptions stripLVPrefix)

instance FromJSON LiteralValue where
  parseJSON = genericParseJSON (sumOptions stripLVPrefix)

-- | Resolution of an 'SCall' target.
data CallTarget
  = -- | Statically known target (top-level agent / req / ext / ctor / prim).
    CTBlock {block :: !BlockId}
  | -- | Dynamic target via a closure value.
    CTValue {var :: !VarId}
  deriving (Eq, Show, Generic)

instance ToJSON CallTarget where
  toJSON = genericToJSON (sumOptions stripCTPrefix)

instance FromJSON CallTarget where
  parseJSON = genericParseJSON (sumOptions stripCTPrefix)

data Arg = Arg
  { label :: !Text,
    var :: !VarId
  }
  deriving (Eq, Show, Generic)

instance ToJSON Arg where
  toJSON = genericToJSON irOptions

instance FromJSON Arg where
  parseJSON = genericParseJSON irOptions

-- | What an 'SMatch' arm matches against. The runtime walks the
-- pattern tree against the subject, binding matched sub-values to the
-- 'VarId's introduced by 'MPVariable' along the way; on success it
-- jumps into the arm's 'body' with those bindings in scope.
--
-- Carrying the full nested pattern in the IR (rather than compiling
-- it down to a cascade of single-tag SMatchs) keeps a 1:1 shape with
-- the source @match@ and pushes the search-and-bind logic to the
-- runtime — which it has to do anyway for tagged-value introspection.
data MatchPattern
  = -- | Wildcard / unconditional match. No binding.
    MPAny
  | -- | Bind the matched subject to this 'VarId'. Always matches.
    MPVariable !VarId
  | -- | Match if the subject equals this literal value.
    MPLiteral !LiteralValue
  | -- | Match if the subject is a tagged value with this constructor
    -- id; recursively match each named field's sub-pattern.
    MPConstructor !CtorId ![(Text, MatchPattern)]
  | -- | Match a tuple positionally; recurse into each element.
    MPTuple ![MatchPattern]
  deriving (Eq, Show, Generic)

instance ToJSON MatchPattern where
  toJSON = genericToJSON (sumOptions stripMPPrefix)

instance FromJSON MatchPattern where
  parseJSON = genericParseJSON (sumOptions stripMPPrefix)

-- | One arm of an 'SMatch'. The runtime evaluates 'pattern' against the
-- subject; on a successful match it enters 'body' with whatever
-- bindings the pattern's 'MPVariable' positions introduced.
data MatchArm = MatchArm
  { pattern :: !MatchPattern,
    body :: !BlockId
  }
  deriving (Eq, Show, Generic)

instance ToJSON MatchArm where
  toJSON = genericToJSON irOptions

instance FromJSON MatchArm where
  parseJSON = genericParseJSON irOptions

data ExitKind
  = ExitReturn
  | ExitBreak
  | ExitForBreak
  deriving (Eq, Show, Generic)

instance ToJSON ExitKind where
  toJSON = genericToJSON (enumOptions stripExitPrefix)

instance FromJSON ExitKind where
  parseJSON = genericParseJSON (enumOptions stripExitPrefix)

data ContKind
  = ContNext
  | ContForNext
  deriving (Eq, Show, Generic)

instance ToJSON ContKind where
  toJSON = genericToJSON (enumOptions stripContPrefix)

instance FromJSON ContKind where
  parseJSON = genericParseJSON (enumOptions stripContPrefix)

-- ===========================================================================
-- Aeson option helpers
-- ===========================================================================

-- | Common record options: camelCase fields (already in source), omit
-- @Nothing@ from output.
irOptions :: Options
irOptions =
  defaultOptions
    { fieldLabelModifier = id,
      omitNothingFields = True
    }

-- | TaggedObject options for record-style sums. Constructor tags are
-- transformed by the supplied modifier.
sumOptions :: (String -> String) -> Options
sumOptions tagMod =
  defaultOptions
    { sumEncoding = TaggedObject "kind" "contents",
      constructorTagModifier = tagMod,
      fieldLabelModifier = id,
      omitNothingFields = True
    }

-- | Enum (no fields) options: encode as bare strings.
enumOptions :: (String -> String) -> Options
enumOptions tagMod =
  defaultOptions
    { sumEncoding = UntaggedValue,
      constructorTagModifier = tagMod,
      allNullaryToStringTag = True
    }

stripBlockPrefix :: String -> String
stripBlockPrefix = lowerHead . drop (length ("Block" :: String))

stripStmtPrefix :: String -> String
stripStmtPrefix = lowerHead . drop (length ("S" :: String))

stripLVPrefix :: String -> String
stripLVPrefix = lowerHead . drop (length ("LV" :: String))

stripCTPrefix :: String -> String
stripCTPrefix = lowerHead . drop (length ("CT" :: String))

stripMPPrefix :: String -> String
stripMPPrefix = lowerHead . drop (length ("MP" :: String))

stripExitPrefix :: String -> String
stripExitPrefix = lowerHead . drop (length ("Exit" :: String))

stripContPrefix :: String -> String
stripContPrefix = lowerHead . drop (length ("Cont" :: String))

lowerHead :: String -> String
lowerHead = \case
  [] -> []
  c : rest -> toLower c : rest
