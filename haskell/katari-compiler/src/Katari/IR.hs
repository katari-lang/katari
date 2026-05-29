-- | Intermediate Representation for the Katari runtime.
--
-- The IR is a block-centric data-flow language. Lowering produces it from
-- the Zonked AST by discarding type information; the runtime (TS) receives
-- and interprets it as JSON.
--
-- Design highlights (see doc/ir-design.md or equivalent for details):
--
--   * Every callable (agent / req / ext / data ctor / prim) lives in the
--     'Block' table and is invoked uniformly via 'SCall'. Special blocks
--     (prim / req / ext / ctor) have no statements, only metadata.
--   * Control flow keeps if / match / for as structured statements
--     'SMatch' / 'SFor'. No jumps or labels.
--   * Non-local exits come in two flavors: 'SExit' (return / break /
--     for_break) and 'SCont' (next / for_next). They differ in how
--     then-blocks are applied along the path.
--   * Variables use 'VarId' only. Scoping is handled on the runtime side
--     by inspecting 'BlockAgent' / 'BlockHandler'. 'BlockUser' is always
--     treated as inline (inheriting the parent scope).
--   * Type information is not included in the IR.
--
-- The JSON representation is fully derived via 'genericToJSON' /
-- 'genericParseJSON'. Sum types use the @{"kind": tag, ...}@ TaggedObject
-- form: record-argument constructors are flat (e.g.
-- @{"kind":"prim","name":"add"}@), while constructors with a single
-- non-record argument nest under @"contents"@ (e.g.
-- @{"kind":"call","contents":{"target":...,"args":...,"output":...}}@).
module Katari.IR
  ( -- * Identifiers
    BlockId (..),
    VarId (..),
    QualifiedName (..),
    renderQualifiedName,

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
    DelegateBlock (..),
    DelegateTarget (..),
    ExternalDispatch (..),
    MatchBlock (..),
    ForBlock (..),
    HandleBlock (..),
    TupleBlock (..),
    ArrayBlock (..),
    RecordBlock (..),
    Param (..),
    Handler (..),
    MatchArm (..),
    MatchPattern (..),
    TypePatternTag (..),

    -- * Statement
    Statement (..),
    CallData (..),
    MakeClosureData (..),
    ExitData (..),
    ContData (..),
    LoadLiteralData (..),
    LiteralValue (..),
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
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Word (Word32)
import GHC.Generics (Generic)
import Katari.Common (LiteralValue (..), QualifiedName (..), TypePatternTag (..), lowerHead, renderQualifiedName)

-- ===========================================================================
-- Identifiers
-- ===========================================================================

-- | Block identifier. Globally unique within an 'IRModule'. Used as the
-- target of 'SCall' / 'SMakeClosure' and as the key of 'IRModule.blocks'.
newtype BlockId = BlockId Word32
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON, ToJSONKey, FromJSONKey)

-- | IR-level variable identifier. Distinct from the AST's
-- 'Katari.Id.VariableResolution'; Lowering allocates a fresh 'VarId' for
-- each occurrence that needs an IR slot.
newtype VarId = VarId Word32
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON, ToJSONKey, FromJSONKey)

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

-- | The 'IRMetadata' value the compiler stamps onto every newly emitted
-- 'IRModule'. Bumped whenever the IR JSON shape changes incompatibly so
-- that the runtime can refuse stale bundles at load time.
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
--                         --    "blocks":{...},
--                         --    "entries":{...},"nameTable":{...}}
--   Nothing -> error "compilation failed"
-- @
data IRModule = IRModule
  { metadata :: IRMetadata,
    blocks :: Map BlockId Block,
    -- | FFI inbound name resolution: @\<modulePath\>.\<bareName\>@ →
    -- 'BlockId'. Covers every top-level callable (agent / req / ext /
    -- ctor) so external callers (JS sidecars, LSP, tooling) can address
    -- them by name. The runtime derives any inverse maps it needs (e.g.
    -- ReqId / CtorId qname tables) by walking 'blocks' once at load
    -- time.
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

-- | Debug-only mapping from internal 'VarId' / 'BlockId' values back to
-- their human-readable surface names. Carried alongside the IR for
-- pretty printers, stack traces, and dev tools; the runtime's hot path
-- does not consult it. Missing entries are not an error — anonymous
-- callables / synthetic slots simply have no name.
data NameTable = NameTable
  { varNames :: Map VarId Text,
    blockNames :: Map BlockId Text
  }
  deriving (Eq, Show, Generic)

instance ToJSON NameTable where
  toJSON = genericToJSON irOptions

instance FromJSON NameTable where
  parseJSON = genericParseJSON irOptions

-- | The empty 'NameTable'. Used as the Lowering starting state and as a
-- sensible default when constructing an 'IRModule' in tests where debug
-- names don't matter.
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
  -- | Request declaration. Handlers compare the carried 'QualifiedName'
  -- on 'SCall' (handler dispatch is by name). The same qualified name
  -- also lives in 'IRModule.entries'.
  BlockRequest :: QualifiedName -> Block
  -- | Data constructor. The carried 'QualifiedName' is what
  -- 'MatchPatternConstructor' compares against in match arms; values
  -- built by this block carry @{__ctor: <qualifiedName>, ...}@ at
  -- runtime.
  BlockConstructor :: QualifiedName -> Block
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
  -- | Record construction. Each entry is a (label, block) pair; the
  -- trailing value of each block becomes the entry's value. Entries
  -- are evaluated left-to-right (sequential — there's no parallel
  -- record literal at the surface).
  BlockRecord :: RecordBlock -> Block
  -- | Agent boundary. The runtime spawns an 'AgentThread' that catches
  -- 'return' and isolates the scope, then runs 'entryBody' inside it.
  -- Top-level agent declarations lower to this. Inline blocks (match arm
  -- bodies, for bodies, handle bodies) lower to 'BlockUser' and do NOT
  -- create an agent boundary.
  BlockAgent :: AgentBlock -> Block
  -- | Outbound delegation boundary. The runtime spawns a 'DelegateThread'
  -- that emits a @delegate@ event to the appropriate endpoint based on
  -- 'target' (CORE loopback for internal targets, FFI for external,
  -- runtime value resolution for value targets).
  BlockDelegate :: DelegateBlock -> Block
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
    entryBody :: BlockId,
    -- | User-facing simple name (e.g. @"local_bar"@ for a local agent
    -- declaration or @"foo"@ for a top-level one). Used as the
    -- @name@ field of 'agent_metadata' returned by @get_metadata@.
    -- Distinct from 'qualifiedName' which always carries the module
    -- prefix.
    name :: Text,
    -- | The @\@\"...\"@ annotation string attached to the declaration,
    -- if any. Surfaced as the @description@ field of
    -- 'agent_metadata'.
    description :: Maybe Text,
    -- | Aeson-encoded JSON Schema string describing the agent's input
    -- (named parameters as an @object@ schema). Pre-computed at
    -- lowering time so the runtime can return it verbatim without
    -- recomputing from semantic types.
    inputSchema :: Text,
    -- | Aeson-encoded JSON Schema string describing the agent's
    -- output (return type).
    outputSchema :: Text
  }
  deriving (Eq, Show, Generic)

instance ToJSON AgentBlock where
  toJSON = genericToJSON irOptions

instance FromJSON AgentBlock where
  parseJSON = genericParseJSON irOptions

-- | Payload for 'BlockDelegate'. Identifies the delegation target — the
-- runtime decides routing (CORE loopback / FFI / dynamic value lookup)
-- based on the 'target' variant.
newtype DelegateBlock = DelegateBlock
  { target :: DelegateTarget
  }
  deriving (Eq, Show, Generic)

instance ToJSON DelegateBlock where
  toJSON = genericToJSON irOptions

instance FromJSON DelegateBlock where
  parseJSON = genericParseJSON irOptions

-- | Discriminator for a 'BlockDelegate'.
--
--   * 'DelegateTargetInternal': statically known CORE qname; runtime
--     emits a @delegate@ event to the local self-endpoint (loopback).
--   * 'DelegateTargetExternal': statically known external dispatch. The
--     @endpoint@ field (e.g. @\"FFI\"@, @\"ENV\"@) selects the runtime
--     module that handles dispatch; @dispatchName@ is the flat opaque key
--     that module's registry expects. Both come straight from the source
--     @from \"ENDPOINT:name\"@ clause and are completely independent of
--     Katari's module path.
--   * 'DelegateTargetValue': the callee is a runtime value at the given
--     'VarId'. The runtime reads the value (@agentLiteral@ → qname
--     resolved through 'IRModule.entries' to decide internal vs external,
--     @closure@ → CORE loopback with captured scope) and routes accordingly.
data DelegateTarget where
  DelegateTargetInternal :: QualifiedName -> DelegateTarget
  DelegateTargetExternal :: ExternalDispatch -> DelegateTarget
  DelegateTargetValue :: VarId -> DelegateTarget
  deriving (Eq, Show, Generic)

-- | Payload for 'DelegateTargetExternal'. The @endpoint@ field selects
-- the runtime module (e.g. @\"FFI\"@, @\"ENV\"@); @dispatchName@ is the
-- flat opaque key looked up in that module's registry. Both come straight
-- from the source @from \"ENDPOINT:name\"@ clause.
data ExternalDispatch = ExternalDispatch
  { endpoint :: Text,
    dispatchName :: Text
  }
  deriving (Eq, Show, Generic)

instance ToJSON ExternalDispatch where
  toJSON = genericToJSON irOptions

instance FromJSON ExternalDispatch where
  parseJSON = genericParseJSON irOptions

instance ToJSON DelegateTarget where
  toJSON = genericToJSON sumOptions

instance FromJSON DelegateTarget where
  parseJSON = genericParseJSON sumOptions

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
-- raised request's 'QualifiedName' against this 'request' field; on equality
-- the runtime invokes 'handlerBody'.
data Handler = Handler
  { -- | The 'QualifiedName' of the 'BlockRequest' being handled.
    request :: QualifiedName,
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
  deriving (Eq, Show, Generic)

instance ToJSON Statement where
  toJSON = genericToJSON sumOptions

instance FromJSON Statement where
  parseJSON = genericParseJSON sumOptions

-- | Payload for 'StatementCall'. Targets any IR block: inline
-- (structural) blocks for in-thread execution (match arm body /
-- for body / handle scope / handler body / tuple / array / prim leaf),
-- or a 'BlockDelegate' for cross-callable agent invocations. The runtime
-- dispatches on the target block's kind.
data CallData = CallData
  { block :: BlockId,
    arguments :: [Arg],
    -- | Output var receives the callee's trailing value. 'Nothing' = drop.
    output :: Maybe VarId
  }
  deriving (Eq, Show, Generic)

instance ToJSON CallData where
  toJSON = genericToJSON irOptions

instance FromJSON CallData where
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
    -- | Request handlers dispatched by 'QualifiedName'.
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

-- | Payload for 'BlockRecord'. Each entry is a @(label, BlockId)@
-- whose trailing value becomes the entry's value. Entries are
-- evaluated left-to-right.
data RecordBlock = RecordBlock
  { entries :: [(Text, BlockId)]
  }
  deriving (Eq, Show, Generic)

instance ToJSON RecordBlock where
  toJSON = genericToJSON irOptions

instance FromJSON RecordBlock where
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

-- | A single labeled argument passed at a call site. Katari calls are
-- keyword-style: every argument has a surface 'label' (matched against
-- the callee's parameter name) and a 'var' carrying the IR slot whose
-- value is passed in. Order in the argument list is irrelevant for the
-- runtime; only labels matter.
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
  -- qualified name; recursively match each named field's sub-pattern.
  MatchPatternConstructor :: QualifiedName -> [(Text, MatchPattern)] -> MatchPattern
  -- | Match a tuple positionally; recurse into each element.
  MatchPatternTuple :: [MatchPattern] -> MatchPattern
  -- | Runtime-type guard. Matches if the subject's runtime tag is
  -- compatible with 'tag' (e.g. @integer@ requires @value.kind ===
  -- \"number\"@ AND the number is integral); then matches @inner@
  -- against the (narrowed) value.
  MatchPatternTypeGuard :: TypePatternTag -> MatchPattern -> MatchPattern
  -- | Match a record value (subject must be of @kind \"record\"@). Each
  -- listed entry's key must be present in the record; its value is then
  -- matched against the entry's sub-pattern. Other keys are ignored
  -- (subset match — record values are heterogeneous over keys).
  MatchPatternRecord :: [(Text, MatchPattern)] -> MatchPattern
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

-- | How an 'SExit' statement unwinds. Each kind targets a different
-- enclosing block role: 'ExitKindReturn' propagates out of an
-- agent / handler body and produces its return value, 'ExitKindBreak'
-- exits the innermost @where@ handle scope, and 'ExitKindForBreak'
-- exits the innermost @for@ loop. Lowering picks the kind statically
-- based on the parser's 'BreakContext'; the runtime never has to guess.
data ExitKind where
  ExitKindReturn :: ExitKind
  ExitKindBreak :: ExitKind
  ExitKindForBreak :: ExitKind
  deriving (Eq, Show, Generic)

instance ToJSON ExitKind where
  toJSON = genericToJSON enumOptions

instance FromJSON ExitKind where
  parseJSON = genericParseJSON enumOptions

-- | How an 'SCont' statement continues. 'ContKindNext' resumes a
-- request handler with a fresh state value (the @next(...)@ form);
-- 'ContKindForNext' advances a @for@ loop to its next iteration
-- (the bare @next@ form). The two are distinct surface keywords in
-- different 'BreakContext's and Lowering picks the kind statically.
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
