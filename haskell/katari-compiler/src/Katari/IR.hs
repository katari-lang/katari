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
--   * Variable は 'VarId' のみ。scope は runtime 側で 'BlockProps.inheritScope'
--     を見て管理する。
--   * 型情報は IR に含まれない。
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
    BlockProps (..),
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
    Value (..),
    defaultOptions,
    genericParseJSON,
    genericToJSON,
    object,
    withObject,
    (.:),
    (.:?),
    (.=),
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseFail)
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
data Block where
  BlockUser ::
    {body :: UserBlock} ->
    Block
  BlockPrim ::
    {name :: Text} ->
    Block
  BlockRequest ::
    {name :: Text} ->
    Block
  BlockExternal ::
    {server :: Text, name :: Text} ->
    Block
  BlockCtor ::
    {name :: Text} ->
    Block

deriving instance Eq Block

deriving instance Show Block

instance ToJSON Block where
  toJSON = \case
    BlockUser {body} -> withTag "user" (toJSON body)
    BlockPrim {name} -> object ["kind" .= ("prim" :: Text), "name" .= name]
    BlockRequest {name} -> object ["kind" .= ("request" :: Text), "name" .= name]
    BlockExternal {server, name} ->
      object ["kind" .= ("external" :: Text), "server" .= server, "name" .= name]
    BlockCtor {name} -> object ["kind" .= ("ctor" :: Text), "name" .= name]

instance FromJSON Block where
  parseJSON = withObject "Block" $ \o -> do
    kind <- o .: "kind" :: Parser Text
    case kind of
      "user" -> BlockUser <$> parseJSON (Object o)
      "prim" -> BlockPrim <$> o .: "name"
      "request" -> BlockRequest <$> o .: "name"
      "external" -> BlockExternal <$> o .: "server" <*> o .: "name"
      "ctor" -> BlockCtor <$> o .: "name"
      other -> parseFail ("Block: unknown kind " <> show other)

-- | The body of a regular user-defined block.
data UserBlock = UserBlock
  { -- | Regular labeled parameters (call args bind by label).
    params :: [Param],
    -- | Mutable state vars introduced by @where (var ...)@ or @for (var ...)@.
    -- Listed separately so the runtime can apply the parallel/versioning
    -- semantics for state mutation.
    stateVars :: [Param],
    statements :: [Statement],
    -- | Tail value when the block completes normally (Rust-style trailing
    -- expression). 'Nothing' means the block has no value.
    trailing :: Maybe VarId,
    -- | Optional then-block applied to the body's tail. Receives 1 param
    -- whose label is conventionally @"value"@ (set by Lowering).
    thenBlock :: Maybe BlockId,
    -- | Request handlers attached to this block. Only meaningful when
    -- @props.catchesBreak@ is True (handle scope).
    handlers :: [Handler],
    props :: BlockProps
  }
  deriving (Eq, Show, Generic)

instance ToJSON UserBlock where
  toJSON = genericToJSON irOptions

instance FromJSON UserBlock where
  parseJSON = genericParseJSON irOptions

-- | A label-bound param. The @label@ is what callers use in 'Arg'.
data Param = Param
  { label :: Text,
    var :: VarId
  }
  deriving (Eq, Show, Generic)

instance ToJSON Param where
  toJSON = genericToJSON irOptions

instance FromJSON Param where
  parseJSON = genericParseJSON irOptions

-- | Static properties that determine how exits / scope work.
data BlockProps = BlockProps
  { -- | Agent entry: 'SExit' 'ExitReturn' stops here.
    catchesReturn :: Bool,
    -- | Handle scope: 'SExit' 'ExitBreak' stops here, and 'SCont' 'ContNext'
    -- targets this block for resume.
    catchesBreak :: Bool,
    -- | When True, child block calls share the parent scope (inline blocks,
    -- branch arms, for-body, then-blocks, handlers reading state).
    inheritScope :: Bool
  }
  deriving (Eq, Show, Generic)

instance ToJSON BlockProps where
  toJSON = genericToJSON irOptions

instance FromJSON BlockProps where
  parseJSON = genericParseJSON irOptions

-- | A request handler attached to a handle-scope block.
data Handler = Handler
  { -- | Target request id (a 'BlockRequest' in the block table).
    request :: BlockId,
    -- | The handler body block. Its params are @[req args... , state vars...]@
    -- by label.
    handlerBody :: BlockId
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
data Statement where
  -- | Call any block (static or via closure).
  SCall :: !CallData -> Statement
  -- | Materialize a closure value from a block id. Captures the current scope.
  SMakeClosure :: !MakeClosureData -> Statement
  -- | Load a constant literal into a fresh IR var. Literals are first-class
  -- IR statements (rather than calls to a load_xxx prim) so the value can be
  -- carried directly without a separate constant pool.
  SLoadLiteral :: !LoadLiteralData -> Statement
  -- | Single-level pattern match. Nested patterns are decomposed by Lowering;
  -- shared default arms are referenced via shared 'BlockId'.
  SMatch :: !MatchData -> Statement
  -- | For loop. Body is invoked iteratively; state vars threaded by label.
  SFor :: !ForData -> Statement
  -- | Non-local exit that traverses upward applying then-blocks until reaching
  -- the matching boundary.
  SExit :: !ExitData -> Statement
  -- | Continuation signal that resumes the enclosing for-loop frame or paused
  -- handler-scope body. Does not apply then-blocks; does not terminate the
  -- block in the value-producing sense.
  SCont :: !ContData -> Statement

deriving instance Eq Statement

deriving instance Show Statement

instance ToJSON Statement where
  toJSON = \case
    SCall d -> withTag "call" (toJSON d)
    SMakeClosure d -> withTag "makeClosure" (toJSON d)
    SLoadLiteral d -> withTag "loadLiteral" (toJSON d)
    SMatch d -> withTag "match" (toJSON d)
    SFor d -> withTag "for" (toJSON d)
    SExit d -> withTag "exit" (toJSON d)
    SCont d -> withTag "cont" (toJSON d)

instance FromJSON Statement where
  parseJSON = withObject "Statement" $ \o -> do
    kind <- o .: "kind" :: Parser Text
    let v = Object o
    case kind of
      "call" -> SCall <$> parseJSON v
      "makeClosure" -> SMakeClosure <$> parseJSON v
      "loadLiteral" -> SLoadLiteral <$> parseJSON v
      "match" -> SMatch <$> parseJSON v
      "for" -> SFor <$> parseJSON v
      "exit" -> SExit <$> parseJSON v
      "cont" -> SCont <$> parseJSON v
      other -> parseFail ("Statement: unknown kind " <> show other)

data CallData = CallData
  { target :: CallTarget,
    args :: [Arg],
    -- | Output var receives the callee's trailing value. 'Nothing' = drop.
    output :: Maybe VarId
  }
  deriving (Eq, Show, Generic)

instance ToJSON CallData where
  toJSON = genericToJSON irOptions

instance FromJSON CallData where
  parseJSON = genericParseJSON irOptions

data MakeClosureData = MakeClosureData
  { output :: VarId,
    block :: BlockId
  }
  deriving (Eq, Show, Generic)

instance ToJSON MakeClosureData where
  toJSON = genericToJSON irOptions

instance FromJSON MakeClosureData where
  parseJSON = genericParseJSON irOptions

data MatchData = MatchData
  { subject :: VarId,
    arms :: [MatchArm],
    defaultArm :: Maybe BlockId,
    output :: Maybe VarId
  }
  deriving (Eq, Show, Generic)

instance ToJSON MatchData where
  toJSON = genericToJSON irOptions

instance FromJSON MatchData where
  parseJSON = genericParseJSON irOptions

data ForData = ForData
  { -- | (element var inside body's params, source array var in this scope)
    iters :: [(VarId, VarId)],
    -- | (state var label, init value var in this scope)
    stateInits :: [(Text, VarId)],
    bodyBlock :: BlockId,
    -- | Optional then-block applied to the for's final value.
    thenBlock :: Maybe BlockId,
    output :: Maybe VarId
  }
  deriving (Eq, Show, Generic)

instance ToJSON ForData where
  toJSON = genericToJSON irOptions

instance FromJSON ForData where
  parseJSON = genericParseJSON irOptions

data ExitData = ExitData
  { exitKind :: ExitKind,
    value :: VarId
  }
  deriving (Eq, Show, Generic)

instance ToJSON ExitData where
  toJSON = genericToJSON irOptions

instance FromJSON ExitData where
  parseJSON = genericParseJSON irOptions

data ContData = ContData
  { contKind :: ContKind,
    value :: Maybe VarId,
    -- | (state var label, new value var in this scope)
    mods :: [(Text, VarId)]
  }
  deriving (Eq, Show, Generic)

instance ToJSON ContData where
  toJSON = genericToJSON irOptions

instance FromJSON ContData where
  parseJSON = genericParseJSON irOptions

-- | Constant literal load. Stored in IR directly (not via 'BlockPrim') so the
-- value can travel with the statement.
data LoadLiteralData = LoadLiteralData
  { output :: VarId,
    value :: LiteralValue
  }
  deriving (Eq, Show, Generic)

instance ToJSON LoadLiteralData where
  toJSON = genericToJSON irOptions

instance FromJSON LoadLiteralData where
  parseJSON = genericParseJSON irOptions

-- | IR-level literal values. Mirrors 'AST.LiteralValue' but lives in the IR
-- namespace so the IR is self-contained (the runtime needs only IR types).
data LiteralValue where
  LVInteger :: !Integer -> LiteralValue
  LVNumber :: !Double -> LiteralValue
  LVString :: !Text -> LiteralValue
  LVBoolean :: !Bool -> LiteralValue
  LVNull :: LiteralValue

deriving instance Eq LiteralValue

deriving instance Show LiteralValue

instance ToJSON LiteralValue where
  toJSON = \case
    LVInteger n -> object ["kind" .= ("integer" :: Text), "value" .= n]
    LVNumber n -> object ["kind" .= ("number" :: Text), "value" .= n]
    LVString s -> object ["kind" .= ("string" :: Text), "value" .= s]
    LVBoolean b -> object ["kind" .= ("boolean" :: Text), "value" .= b]
    LVNull -> object ["kind" .= ("null" :: Text)]

instance FromJSON LiteralValue where
  parseJSON = withObject "LiteralValue" $ \o -> do
    kind <- o .: "kind" :: Parser Text
    case kind of
      "integer" -> LVInteger <$> o .: "value"
      "number" -> LVNumber <$> o .: "value"
      "string" -> LVString <$> o .: "value"
      "boolean" -> LVBoolean <$> o .: "value"
      "null" -> pure LVNull
      other -> parseFail ("LiteralValue: unknown kind " <> show other)

-- | Resolution of an 'SCall' target.
data CallTarget where
  -- | Statically known target (top-level agent / req / ext / ctor / prim).
  CTBlock :: {block :: BlockId} -> CallTarget
  -- | Dynamic target via a closure value.
  CTValue :: {var :: VarId} -> CallTarget

deriving instance Eq CallTarget

deriving instance Show CallTarget

instance ToJSON CallTarget where
  toJSON = \case
    CTBlock {block} -> object ["kind" .= ("block" :: Text), "block" .= block]
    CTValue {var} -> object ["kind" .= ("value" :: Text), "var" .= var]

instance FromJSON CallTarget where
  parseJSON = withObject "CallTarget" $ \o -> do
    kind <- o .: "kind" :: Parser Text
    case kind of
      "block" -> CTBlock <$> o .: "block"
      "value" -> CTValue <$> o .: "var"
      other -> parseFail ("CallTarget: unknown kind " <> show other)

data Arg = Arg
  { label :: Text,
    var :: VarId
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
    tag :: Maybe Text,
    -- | (field/index label, IR var the arm body uses to receive that value).
    bindings :: [(Text, VarId)],
    body :: BlockId
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

-- | Common record options: camelCase fields, omit @Nothing@ from output.
irOptions :: Options
irOptions =
  defaultOptions
    { fieldLabelModifier = id, -- record fields are already camelCase in source
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

stripExitPrefix :: String -> String
stripExitPrefix = lowerHead . drop (length ("Exit" :: String))

stripContPrefix :: String -> String
stripContPrefix = lowerHead . drop (length ("Cont" :: String))

lowerHead :: String -> String
lowerHead = \case
  [] -> []
  c : rest -> toLower c : rest

-- | Insert @{"kind": tag}@ into an existing JSON object (must be an object).
-- Used to flatten record-payload sum constructors.
withTag :: Text -> Value -> Value
withTag tag = \case
  Object o -> Object (KeyMap.insert (Key.fromText "kind") (String tag) o)
  v -> object ["kind" .= tag, "value" .= v]
