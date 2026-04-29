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
import Data.Word (Word32)
import GHC.Generics (Generic)

-- ===========================================================================
-- Identifiers
-- ===========================================================================

-- | Block identifier. Globally unique within an 'IRModule'.
newtype BlockId = BlockId Word32
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON, ToJSONKey, FromJSONKey)

-- | IR-level variable identifier. Distinct from AST 'VariableId'; Lowering
-- allocates a fresh 'VarId' for each occurrence that needs an IR slot.
newtype VarId = VarId Word32
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON, ToJSONKey, FromJSONKey)

-- ===========================================================================
-- Top-level module
-- ===========================================================================

data IRModule = IRModule
  { name :: Text,
    blocks :: Map BlockId Block,
    -- | Top-level agent name → entry block.
    entries :: Map Text BlockId,
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
-- metadata; user blocks own statements / handlers / then etc.
data Block
  = -- | Regular user-defined block. The body lives in a separate record so
    -- the field set can grow independently of the sum tag.
    BlockUser {body :: !UserBlock}
  | -- | Built-in primitive. The runtime resolves @name@ against its prim
    -- registry.
    BlockPrim {name :: !Text}
  | -- | Request declaration. Used as the static target of a @raise@ /
    -- @perform@ call.
    BlockRequest {name :: !Text}
  | -- | External agent stub. Identified by @(moduleName, name)@: the runtime
    -- looks up the function in a JS sidecar bundle keyed by these. The
    -- @\@"..."@ annotation on the declaration is purely documentation and
    -- does not appear in the IR.
    BlockExternal {moduleName :: !Text, name :: !Text}
  | -- | Data constructor. The runtime tags the resulting value with @name@.
    BlockCtor {name :: !Text}
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

-- | A request handler attached to a handle-scope block.
data Handler = Handler
  { -- | Target request id (a 'BlockRequest' in the block table).
    request :: !BlockId,
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

-- | Payload for 'SMakeClosure'.
data MakeClosureData = MakeClosureData
  { output :: !VarId,
    block :: !BlockId
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

-- | One arm of an 'SMatch'. Matches on the subject's tag (or wildcards if
-- 'tag' is 'Nothing') and binds field labels into the arm's body block via
-- 'bindings'.
data MatchArm = MatchArm
  { -- | Constructor tag to match. 'Nothing' matches any tag (used for tuple
    -- destructuring or trivial bind-only patterns).
    tag :: !(Maybe Text),
    -- | (field/index label, IR var the arm body uses to receive that value).
    bindings :: ![(Text, VarId)],
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

stripExitPrefix :: String -> String
stripExitPrefix = lowerHead . drop (length ("Exit" :: String))

stripContPrefix :: String -> String
stripContPrefix = lowerHead . drop (length ("Cont" :: String))

lowerHead :: String -> String
lowerHead = \case
  [] -> []
  c : rest -> toLower c : rest
