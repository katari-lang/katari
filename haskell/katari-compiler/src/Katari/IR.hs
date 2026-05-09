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
--   * Variable は 'VarId' のみ。scope は runtime 側で 'BlockAgent' /
--     'BlockHandler' を見て管理する。'BlockUser' は常に inline (parent
--     scope inherit) として扱う。
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
    RequestId (..),
    ConstructorId (..),
    QualifiedName (..),
    renderQualifiedName,
    ExternalName (..),

    -- * Module
    IRModule (..),
    IRMetadata (..),
    currentIRMetadata,
    NameTable (..),
    emptyNameTable,

    -- * Block
    Block (..),
    UserBlock (..),
    AgentBlock (..),
    MatchBlock (..),
    ForBlock (..),
    HandleBlock (..),
    TupleBlock (..),
    ArrayBlock (..),
    Param (..),
    Handler (..),
    MatchArm (..),
    MatchPattern (..),

    -- * Statement
    Statement (..),
    CallData (..),
    AgentCallData (..),
    AgentCallClosureData (..),
    MakeClosureData (..),
    ExitData (..),
    ContData (..),
    LoadLiteralData (..),
    LiteralValue (..),
    CallTarget (..),
    Arg (..),
    BindPatternData (..),
    ExitKind (..),
    ContKind (..),
  )
where

import Data.Aeson
  ( FromJSON (..),
    FromJSONKey (..),
    Options (..),
    SumEncoding (..),
    ToJSON (..),
    ToJSONKey (..),
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
import Katari.Common (LiteralValue (..), QualifiedName (..), parseQualifiedName, renderQualifiedName)

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
-- of the Identifier-pass 'Katari.Id.RequestId' (Lowering re-allocates
-- these so the IR can be re-indexed without touching upstream phases).
-- Currently 1:1 with the corresponding 'BlockRequest'\'s 'BlockId', but
-- kept as a separate id space to preserve flexibility (the runtime
-- dispatches handlers by id equality, which is faster than walking the
-- block table).
--
-- Use a qualified import (e.g. @import Katari.IR qualified as IR@) when
-- both this and the AST-side 'Katari.Id.RequestId' are in scope.
newtype RequestId = RequestId Word32
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON, ToJSONKey, FromJSONKey)

-- | IR-level constructor identifier carried by a 'BlockConstructor' and
-- stored inside every tagged value the runtime constructs. Independent of
-- the Identifier-pass 'Katari.Id.ConstructorId' for the same reason as
-- the IR 'RequestId'.
newtype ConstructorId = ConstructorId Word32
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON, ToJSONKey, FromJSONKey)

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

-- | Version metadata for runtime / compiler skew detection.
newtype IRMetadata = IRMetadata
  { -- | IR shape version. Increment when the IR JSON schema changes in a
    -- backwards-incompatible way so the runtime can detect mismatches.
    schemaVersion :: Int
  }
  deriving (Eq, Show, Generic)

instance ToJSON IRMetadata where
  toJSON = genericToJSON irOptions

instance FromJSON IRMetadata where
  parseJSON = genericParseJSON irOptions

currentIRMetadata :: IRMetadata
currentIRMetadata = IRMetadata {schemaVersion = 1}

-- | The output of one compilation. The runtime loads this value from JSON
-- and uses 'entries' to resolve named callables.
--
-- JSON encoding example (fields abbreviated):
--
-- @
-- import Data.Aeson (encode)
-- import Katari.Compile (compile, CompileInput (..))
-- import Katari.IR ()           -- ToJSON instance
--
-- let result = compile input
-- case irModule result of
--   Just ir -> encode ir  -- → {"metadata":{"schemaVersion":1},
--                         --    "name":"main","blocks":{...},
--                         --    "entries":{...},"nameTable":{...}}
--   Nothing -> error "compilation failed"
-- @
data IRModule = IRModule
  { metadata :: IRMetadata,
    name :: Text,
    blocks :: Map BlockId Block,
    -- | FFI inbound name resolution: @\<modulePath\>.\<bareName\>@ →
    -- 'BlockId'. Covers every top-level callable (agent / req / ext /
    -- ctor) so external callers (JS sidecars, LSP, tooling) can address
    -- them by name. The IR's internal id allocations ('BlockId',
    -- 'RequestId', 'ConstructorId') are intentionally not exposed; the runtime
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

-- | All callable units. Each variant carries exactly one payload,
-- serialised as the JSON @body@ field via 'sumOptions'
-- (@contentsFieldName = \"body\"@). GHC forbids GADT constructors that
-- share a record-syntax field with different types, so the data type is
-- positional; pattern-match to extract the payload.
data Block where
  -- | Regular user-defined block.
  BlockUser :: UserBlock -> Block
  -- | Built-in primitive. The runtime resolves the carried name against
  -- its prim registry. Prims are system-provided and have no module of
  -- origin (they never appear in 'IRModule.entries').
  BlockPrim :: Text -> Block
  -- | Request declaration. Handlers match the carried 'RequestId' on
  -- 'SCall'. The public qualified name lives in 'IRModule.entries'.
  BlockRequest :: RequestId -> Block
  -- | External agent stub. The runtime looks up the 'ExternalName' in a
  -- JS sidecar bundle.
  BlockExternal :: ExternalName -> Block
  -- | Data constructor. The carried 'ConstructorId' is what
  -- 'MatchPatternConstructor' compares against in match arms; values
  -- built by this block carry @{__ctor: <constructorId>, ...}@ at
  -- runtime.
  BlockConstructor :: ConstructorId -> Block
  -- | Match block. The runtime creates a management thread, evaluates
  -- the subject from the inherited parent scope, walks arms in order,
  -- and executes the first matching arm's body. Called via
  -- 'StatementCall'.
  BlockMatch :: MatchBlock -> Block
  -- | For-loop block. The runtime creates a management thread, reads
  -- source arrays and init values from the inherited parent scope,
  -- manages iteration / state-var updates, and runs the body per
  -- element. Called via 'StatementCall'.
  BlockFor :: ForBlock -> Block
  -- | Handle block. The runtime creates a management thread, initialises
  -- state vars from the inherited parent scope, runs the body, and
  -- dispatches requests to handlers. Called via 'StatementCall'.
  BlockHandle :: HandleBlock -> Block
  -- | Tuple construction. Each element is an independent block whose
  -- trailing value becomes one component of the resulting tuple.
  -- When @parallel = True@, element blocks run concurrently.
  BlockTuple :: TupleBlock -> Block
  -- | Array construction. Each element is an independent block whose
  -- trailing value becomes one item in the resulting array.
  -- When @parallel = True@, element blocks run concurrently.
  BlockArray :: ArrayBlock -> Block
  -- | Agent boundary. The runtime spawns an 'AgentThread' that catches
  -- 'return' and isolates the scope, then runs 'entryBody' inside it.
  -- Top-level agent declarations lower to this. Inline blocks (match arm
  -- bodies, for bodies, handle bodies) lower to 'BlockUser' and do NOT
  -- create an agent boundary.
  BlockAgent :: AgentBlock -> Block
  deriving (Eq, Show, Generic)

instance ToJSON Block where
  toJSON = genericToJSON sumOptions

instance FromJSON Block where
  parseJSON = genericParseJSON sumOptions

-- | The body of an agent block. Carried by 'BlockAgent' to mark the
-- agent boundary (return catch + scope isolation) at the IR level.
data AgentBlock = AgentBlock
  { -- | Public name. For top-level agents this is the same value that
    -- appears in 'IRModule.entries'; for local / closure agents it is a
    -- compiler-synthesized fresh name.
    qualifiedName :: QualifiedName,
    -- | Labeled parameters. Caller binds args here.
    parameters :: [Param],
    -- | The 'BlockId' of the agent body. Typically a 'BlockUser'
    -- (inline) or 'BlockHandle' for @where { handlers }@ agents.
    entryBody :: BlockId
  }
  deriving (Eq, Show, Generic)

instance ToJSON AgentBlock where
  toJSON = genericToJSON irOptions

instance FromJSON AgentBlock where
  parseJSON = genericParseJSON irOptions

-- | The body of a regular user-defined block. Always inline
-- (inherits parent scope, catches nothing). Agent boundaries are
-- represented by 'BlockAgent' instead.
data UserBlock = UserBlock
  { -- | Labeled parameters. Meaningful for handler / then-clause blocks
    -- (req args / break value); empty for plain inline blocks.
    parameters :: [Param],
    statements :: [Statement],
    -- | Tail value when the block completes normally (Rust-style trailing
    -- expression). 'Nothing' means the block has no value.
    trailing :: Maybe VarId
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

-- | A request handler inside a 'HandleData'. Handler dispatch compares the
-- raised request's 'RequestId' against this 'request' field; on equality the
-- runtime invokes 'handlerBody'.
data Handler = Handler
  { -- | The 'RequestId' of the 'BlockRequest' being handled.
    request :: RequestId,
    -- | The handler body block ('BlockUser'). Inherits the handle scope
    -- (state vars are directly accessible). Its 'parameters' carry the req args.
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
--
-- Each variant wraps a payload record (e.g. 'CallData') so that field-name
-- conflicts (output \/ value across constructors with different field types)
-- don't collide at the Haskell level. JSON-wise this nests the payload
-- under a @"contents"@ key alongside the @"kind"@ tag.
data Statement where
  StatementCall :: CallData -> Statement
  StatementMakeClosure :: MakeClosureData -> Statement
  StatementLoadLiteral :: LoadLiteralData -> Statement
  StatementExit :: ExitData -> Statement
  StatementCont :: ContData -> Statement
  -- | Bind the value of @source@ by walking @pattern@ recursively. The
  -- runtime walks @pattern@ exactly like the arm-pattern walker of
  -- 'BlockMatch', binding each 'MatchPatternVariable' position. Unlike
  -- 'BlockMatch' there is no @defaultArm@; the pattern is irrefutable
  -- (guaranteed by the exhaustiveness checker — K0291 / Phase 16).
  StatementBindPattern :: BindPatternData -> Statement
  -- | Cross-agent call by 'QualifiedName'. Lowering emits this for
  -- top-level agent invocations (replacing inline 'StatementCall' with
  -- 'CallTargetBlock'). At runtime the engine emits a @core→core@
  -- delegate event that spawns an 'AgentThread' for the resolved entry,
  -- then feeds the result back as a delegateAck.
  --
  -- Phase 3.1 (additive): the variant exists but Lowering does not emit
  -- it yet. Phase 3.7 enables emission.
  StatementAgentCall :: AgentCallData -> Statement
  -- | Cross-agent call via a closure value. The 'target' 'VarId' holds a
  -- closure value whose @ClosureId@ identifies which 'AgentBlock' to
  -- start. Same @core→core@ delegate event mechanics as
  -- 'StatementAgentCall'.
  StatementAgentCallClosure :: AgentCallClosureData -> Statement
  deriving (Eq, Show, Generic)

instance ToJSON Statement where
  toJSON = genericToJSON sumOptions

instance FromJSON Statement where
  parseJSON = genericParseJSON sumOptions

-- | Payload for 'SCall'.
data CallData = CallData
  { target :: CallTarget,
    arguments :: [Arg],
    -- | Output var receives the callee's trailing value. 'Nothing' = drop.
    output :: Maybe VarId
  }
  deriving (Eq, Show, Generic)

instance ToJSON CallData where
  toJSON = genericToJSON irOptions

instance FromJSON CallData where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'StatementAgentCall'. Cross-agent dispatch by qualified
-- name. The runtime resolves the name through 'IRModule.entries' (or
-- through cross-module dispatch in a future round), allocates a fresh
-- delegationId, and sends a @core→core@ delegate event.
data AgentCallData = AgentCallData
  { target :: QualifiedName,
    arguments :: [Arg],
    output :: Maybe VarId
  }
  deriving (Eq, Show, Generic)

instance ToJSON AgentCallData where
  toJSON = genericToJSON irOptions

instance FromJSON AgentCallData where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'StatementAgentCallClosure'. The 'target' 'VarId' holds
-- a closure value; the runtime resolves its @ClosureId@ through the
-- machine-local closures table to find the underlying 'AgentBlock'.
data AgentCallClosureData = AgentCallClosureData
  { target :: VarId,
    arguments :: [Arg],
    output :: Maybe VarId
  }
  deriving (Eq, Show, Generic)

instance ToJSON AgentCallClosureData where
  toJSON = genericToJSON irOptions

instance FromJSON AgentCallClosureData where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'SMakeClosure'. The closure captures its lexical scope at
-- creation time; the runtime supplies the captured scope automatically when
-- the closure is invoked.
data MakeClosureData = MakeClosureData
  { output :: VarId,
    block :: BlockId
  }
  deriving (Eq, Show, Generic)

instance ToJSON MakeClosureData where
  toJSON = genericToJSON irOptions

instance FromJSON MakeClosureData where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'BlockMatch'. The runtime creates a management thread,
-- reads 'subject' from the inherited parent scope, walks arms in order,
-- and executes the first matching arm's body. Called via 'StatementCall'.
data MatchBlock = MatchBlock
  { subject :: VarId,
    arms :: [MatchArm],
    defaultArm :: Maybe BlockId
  }
  deriving (Eq, Show, Generic)

instance ToJSON MatchBlock where
  toJSON = genericToJSON irOptions

instance FromJSON MatchBlock where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'BlockFor'. The runtime creates a management thread,
-- reads source arrays and init values from the inherited parent scope,
-- manages iteration / state-var updates, and runs the body per element.
-- Called via 'StatementCall'.
--
-- When @parallel = True@, all iterations run concurrently; @stateInits@
-- must be empty (enforced by the typechecker). The first @for_break@
-- cancels all sibling iterations.
data ForBlock = ForBlock
  { -- | Whether iterations run in parallel.
    parallel :: !Bool,
    -- | (element var inside body, source array var in this scope)
    iters :: [(VarId, VarId)],
    -- | (bodyVar in for scope, init value var in this scope). Empty if parallel.
    stateInits :: [(VarId, VarId)],
    bodyBlock :: BlockId,
    -- | Optional then-block (BlockUser) run on normal completion.
    thenBlock :: Maybe BlockId
  }
  deriving (Eq, Show, Generic)

instance ToJSON ForBlock where
  toJSON = genericToJSON irOptions

instance FromJSON ForBlock where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'BlockHandle'. The runtime creates a management thread,
-- initialises state vars from the inherited parent scope, runs the body,
-- and dispatches requests to handlers. Called via 'StatementCall'.
--
-- When @parallel = True@, handlers run concurrently; @stateInits@ must be
-- empty (enforced by the typechecker). The first @break@ cancels all
-- sibling handlers.
data HandleBlock = HandleBlock
  { -- | Whether handlers run in parallel.
    parallel :: !Bool,
    -- | (bodyVar allocated in handle scope, initVar computed in caller)
    stateInits :: [(VarId, VarId)],
    -- | Body block ('BlockUser'). Inherits the handle scope.
    body :: BlockId,
    -- | Request handlers dispatched by 'RequestId'.
    handlers :: [Handler],
    -- | Optional then-block ('BlockUser') run when body completes.
    -- Its single parameter (label @\"value\"@) receives the body's trailing value.
    thenBlock :: Maybe BlockId
  }
  deriving (Eq, Show, Generic)

instance ToJSON HandleBlock where
  toJSON = genericToJSON irOptions

instance FromJSON HandleBlock where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'BlockTuple'. Each element is a 'BlockId' whose trailing
-- value becomes one component of the tuple. When @parallel = True@,
-- element blocks are evaluated concurrently; results are collected in order.
data TupleBlock = TupleBlock
  { parallel :: !Bool,
    elements :: [BlockId]
  }
  deriving (Eq, Show, Generic)

instance ToJSON TupleBlock where
  toJSON = genericToJSON irOptions

instance FromJSON TupleBlock where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'BlockArray'. Each element is a 'BlockId' whose trailing
-- value becomes one item in the array. When @parallel = True@,
-- element blocks are evaluated concurrently; results are collected in order.
data ArrayBlock = ArrayBlock
  { parallel :: !Bool,
    elements :: [BlockId]
  }
  deriving (Eq, Show, Generic)

instance ToJSON ArrayBlock where
  toJSON = genericToJSON irOptions

instance FromJSON ArrayBlock where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'SExit'.
data ExitData = ExitData
  { exitKind :: ExitKind,
    value :: VarId
  }
  deriving (Eq, Show, Generic)

instance ToJSON ExitData where
  toJSON = genericToJSON irOptions

instance FromJSON ExitData where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'StatementCont'.
data ContData = ContData
  { contKind :: ContKind,
    value :: Maybe VarId,
    -- | (targetVar in loop/handle scope, new value var in this scope)
    modifiers :: [(VarId, VarId)]
  }
  deriving (Eq, Show, Generic)

instance ToJSON ContData where
  toJSON = genericToJSON irOptions

instance FromJSON ContData where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'SLoadLiteral'. Kept inline (not via 'BlockPrim') so the
-- value travels with the statement.
data LoadLiteralData = LoadLiteralData
  { output :: VarId,
    value :: LiteralValue
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
  { source :: VarId,
    pattern :: MatchPattern
  }
  deriving (Eq, Show, Generic)

instance ToJSON BindPatternData where
  toJSON = genericToJSON irOptions

instance FromJSON BindPatternData where
  parseJSON = genericParseJSON irOptions

-- | Resolution of an 'SCall' target.
data CallTarget where
  -- | Statically known target (top-level agent / req / ext / ctor / prim).
  CallTargetBlock :: {block :: BlockId} -> CallTarget
  -- | Dynamic target via a closure value.
  CallTargetValue :: {var :: VarId} -> CallTarget
  deriving (Eq, Show, Generic)

instance ToJSON CallTarget where
  toJSON = genericToJSON sumOptions

instance FromJSON CallTarget where
  parseJSON = genericParseJSON sumOptions

data Arg = Arg
  { label :: Text,
    var :: VarId
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
data MatchPattern where
  -- | Wildcard / unconditional match. No binding.
  MatchPatternAny :: MatchPattern
  -- | Bind the matched subject to this 'VarId'. Always matches.
  MatchPatternVariable :: VarId -> MatchPattern
  -- | Match if the subject equals this literal value.
  MatchPatternLiteral :: LiteralValue -> MatchPattern
  -- | Match if the subject is a tagged value with this constructor
  -- id; recursively match each named field's sub-pattern.
  MatchPatternConstructor :: ConstructorId -> [(Text, MatchPattern)] -> MatchPattern
  -- | Match a tuple positionally; recurse into each element.
  MatchPatternTuple :: [MatchPattern] -> MatchPattern
  deriving (Eq, Show, Generic)

instance ToJSON MatchPattern where
  toJSON = genericToJSON sumOptions

instance FromJSON MatchPattern where
  parseJSON = genericParseJSON sumOptions

-- | One arm of an 'SMatch'. The runtime evaluates 'pattern' against the
-- subject; on a successful match it enters 'body' with whatever
-- bindings the pattern's 'MPVariable' positions introduced.
data MatchArm = MatchArm
  { pattern :: MatchPattern,
    body :: BlockId
  }
  deriving (Eq, Show, Generic)

instance ToJSON MatchArm where
  toJSON = genericToJSON irOptions

instance FromJSON MatchArm where
  parseJSON = genericParseJSON irOptions

data ExitKind where
  ExitKindReturn :: ExitKind
  ExitKindBreak :: ExitKind
  ExitKindForBreak :: ExitKind
  deriving (Eq, Show, Generic)

instance ToJSON ExitKind where
  toJSON = genericToJSON enumOptions

instance FromJSON ExitKind where
  parseJSON = genericParseJSON enumOptions

data ContKind where
  ContKindNext :: ContKind
  ContKindForNext :: ContKind
  deriving (Eq, Show, Generic)

instance ToJSON ContKind where
  toJSON = genericToJSON enumOptions

instance FromJSON ContKind where
  parseJSON = genericParseJSON enumOptions

-- ===========================================================================
-- Aeson option helpers
-- ===========================================================================

-- | Common record options: fields as-is, omit
-- @Nothing@ from output.
irOptions :: Options
irOptions =
  defaultOptions
    { fieldLabelModifier = id,
      omitNothingFields = True
    }

-- | Lower the first character of a string (PascalCase → camelCase).
lowerHead :: String -> String
lowerHead [] = []
lowerHead (c : cs) = toLower c : cs

-- | TaggedObject options for record-style sums. Constructor names are
-- lowercased at the head (camelCase), e.g. @"statementCall"@, @"matchPatternAny"@.
sumOptions :: Options
sumOptions =
  defaultOptions
    { sumEncoding = TaggedObject "kind" "body",
      fieldLabelModifier = id,
      constructorTagModifier = lowerHead,
      omitNothingFields = True
    }

-- | Enum (no fields) options: encode as bare camelCase strings,
-- e.g. @"exitKindReturn"@, @"contKindNext"@.
enumOptions :: Options
enumOptions =
  defaultOptions
    { sumEncoding = UntaggedValue,
      allNullaryToStringTag = True,
      constructorTagModifier = lowerHead
    }
