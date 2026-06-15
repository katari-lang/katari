-- | The intermediate representation handed to the runtime, one 'IRModule' per source module (the
-- runtime uploads modules individually — there is no whole-program link step).
--
-- Shape (see the design discussion / docs for the rationale):
--
--   * Every block runs as its own thread (the unit the engine schedules and checkpoints). A
--     'Callable' is value-addressable and carries the calling convention (a single argument,
--     defaults, and a schema in 'IRModule.schemas'); the other blocks are structural nodes that
--     inherit the caller's scope.
--   * Invocation is split by what it summons, not by two verbs at the call site:
--       - 'OpCall' runs a local structural node (by 'BlockId', no argument, in the same scope);
--       - 'OpDelegate' invokes a callable (by 'QualifiedName' — cross-module-safe — or by value,
--         with the single argument). Whether a delegation commits the transaction is a property of
--         the resolved callee (agent / external / effectful prim commit; pure prim / ctor stay
--         in-transaction), so it is derived at run time and not encoded in the op.
--   * Non-local control ('OpExit' / 'OpCont') names the enclosing block it unwinds to / resumes; the
--     kind (return / break / for-break, next / for-next) is implied by that block's role.
--   * No type information. The public schema of each callable lives in 'IRModule.schemas'.
--
-- The JSON encoding (consumed by the TS runtime) is intentionally not derived yet — it is co-designed
-- with the runtime once that exists. 'Katari.Data.JSONSchema' already serialises (schemas are needed
-- independently of the IR's own wire format).
module Katari.Data.IR where

import Data.Map (Map)
import Data.Text (Text)
import Data.Word (Word32)
import GHC.List (List)
import Katari.Data.Id (GenericId)
import Katari.Data.JSONSchema (JSONSchema)
import Katari.Data.QualifiedName (QualifiedName)

---------------------------------------------------------------------------------------------------
-- Identifiers
---------------------------------------------------------------------------------------------------

-- | Block identifier, unique within an 'IRModule'. The key of 'IRModule.blocks' / 'IRModule.schemas'
-- and the target of an 'OpCall' / 'OpMakeClosure'. Module-local: a cross-module callee is addressed
-- by 'QualifiedName', never by a foreign 'BlockId'.
newtype BlockId = BlockId Word32
  deriving stock (Eq, Ord, Show)

-- | IR-level variable. Lowering allocates one per value slot within a block's scope.
newtype VarId = VarId Word32
  deriving stock (Eq, Ord, Show)

---------------------------------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------------------------------

newtype Metadata = Metadata
  { -- | Bumped on backward-incompatible changes to the IR JSON shape, so the runtime can reject
    -- stale bundles.
    schemaVersion :: Int
  }
  deriving stock (Eq, Show)

-- | The metadata the compiler stamps on every emitted 'IRModule'.
currentMetadata :: Metadata
currentMetadata = Metadata {schemaVersion = 1}

-- | One module's lowered output. The runtime loads it and resolves callables by 'QualifiedName'
-- through 'entries' (cross-module names resolve against the defining module's entries the same way).
data IRModule = IRModule
  { metadata :: Metadata,
    -- | Every block (callable or structural node), keyed by id.
    blocks :: Map BlockId Block,
    -- | The schema of every callable block. Structural nodes have none. A callable value resolves to
    -- its block, so a closure's schema is reachable here too (by 'BlockId'), not only top-level names.
    schemas :: Map BlockId SchemaInfo,
    -- | Top-level callable name -> block, for resolving an 'OpDelegate' 'CalleeName' at run time.
    entries :: Map QualifiedName BlockId,
    -- | Debug-only block names (pretty printer / traces). The runtime's hot path ignores it.
    names :: Map BlockId Text
  }
  deriving stock (Eq, Show)

---------------------------------------------------------------------------------------------------
-- Blocks (each runs as its own thread)
---------------------------------------------------------------------------------------------------

-- | A schedulable unit. 'BlockCallable' is value-addressable and carries a signature; the rest are
-- structural nodes invoked by 'OpCall' that read the inherited scope directly.
data Block where
  BlockCallable :: Callable -> Block
  BlockSequence :: Sequence -> Block
  BlockMatch :: Match -> Block
  BlockFor :: For -> Block
  BlockHandle :: Handle -> Block
  -- | A parallel sequence literal (@par [e1, ...]@): its elements run concurrently.
  BlockParallel :: ParallelBlock -> Block
  deriving stock (Eq, Show)

-- | A top-level agent / external / primitive / data-constructor, or a closure. The single calling
-- convention lives here: the incoming argument binds to 'parameter' in the new scope, omitted
-- optionals are filled from 'defaults', and 'implementation' says what running it means. Its schema
-- is in 'IRModule.schemas', keyed by this block's id.
data Callable = Callable
  { scope :: ScopeMode,
    parameter :: Maybe VarId,
    defaults :: Map Text Literal,
    implementation :: Implementation
  }
  deriving stock (Eq, Show)

data ScopeMode where
  -- | A fresh scope cut off from the caller — a top-level agent boundary; catches @return@.
  ScopeIsolated :: ScopeMode
  -- | A fresh scope whose parent is the closure's captured scope.
  ScopeCaptured :: ScopeMode
  deriving stock (Eq, Show)

-- | What invoking a 'Callable' does. The runtime derives the transaction behaviour from this (and,
-- for 'ImplPrim', the prim registry): pure leaves run in-transaction; agents, externals and
-- I/O prims suspend (and effectful ones commit).
data Implementation where
  -- | Run the body block (a 'Sequence', or a 'Handle' for @where { handlers }@) in the new scope.
  ImplBody :: BlockId -> Implementation
  -- | A built-in primitive, by name (resolved against the runtime's prim registry).
  ImplPrim :: Text -> Implementation
  -- | A data constructor: build the tagged value from the argument record.
  ImplConstruct :: QualifiedName -> Implementation
  -- | A request: raise it as an escalation to the enclosing handler.
  ImplRaise :: QualifiedName -> Implementation
  -- | An external agent: the external thread dispatches it directly (no endpoint / module routing).
  -- The carried text is the opaque dispatch key the external handler interprets.
  ImplExternal :: Text -> Implementation
  deriving stock (Eq, Show)

-- | A block body: a list of operations plus the variable holding its value (if any).
data Sequence = Sequence
  { operations :: List Operation,
    result :: Maybe VarId
  }
  deriving stock (Eq, Show)

---------------------------------------------------------------------------------------------------
-- Structural node blocks
---------------------------------------------------------------------------------------------------

-- | @match subject { ... }@. The runtime reads 'subject' from the inherited scope, tries 'arms' in
-- order, and runs the first matching arm's body (or 'fallback').
data Match = Match
  { subject :: VarId,
    arms :: List MatchArm,
    fallback :: Maybe BlockId
  }
  deriving stock (Eq, Show)

data MatchArm = MatchArm
  { pattern :: Pattern,
    body :: BlockId
  }
  deriving stock (Eq, Show)

-- | @[par] for (pattern in source; var s = init) { body } [then (p) { ... }]@. Each iteration's
-- @next@ value is collected, in source order, into the mapped output array.
data For = For
  { parallel :: Bool,
    -- | (element var bound in the body scope, source-array var in the caller scope), one per iterator.
    iterators :: List (VarId, VarId),
    -- | (state var in the body scope, initial-value var in the caller scope). Empty when parallel.
    states :: List (VarId, VarId),
    body :: BlockId,
    thenClause :: Maybe ThenClause
  }
  deriving stock (Eq, Show)

-- | A @handle@ scope: runs 'body', dispatches escalations to 'handlers', and on completion runs
-- 'thenClause'. State vars are seeded from the caller's scope.
data Handle = Handle
  { parallel :: Bool,
    states :: List (VarId, VarId),
    body :: BlockId,
    handlers :: List Handler,
    thenClause :: Maybe ThenClause
  }
  deriving stock (Eq, Show)

-- | One request handler. On a matching escalation the runtime binds the request arguments to
-- 'parameter' (in the handler body's scope) and runs 'body'.
data Handler = Handler
  { request :: QualifiedName,
    parameter :: Maybe VarId,
    body :: BlockId
  }
  deriving stock (Eq, Show)

-- | A @then (pattern) { body }@ clause: 'parameter' receives the produced value (the for-mapping
-- array / the handle body's result), bound in the clause body's scope.
data ThenClause = ThenClause
  { parameter :: Maybe VarId,
    body :: BlockId
  }
  deriving stock (Eq, Show)

-- | @par [e1, ...]@: each element is its own block, evaluated concurrently, results collected in
-- order. A sequential @[e1, ...]@ lowers to 'OpMakeTuple' instead (no concurrency, no own thread).
newtype ParallelBlock = ParallelBlock
  { elements :: List BlockId
  }
  deriving stock (Eq, Show)

---------------------------------------------------------------------------------------------------
-- Operations (each runs within the enclosing block's thread)
---------------------------------------------------------------------------------------------------

data Operation where
  -- | Run a local structural node ('Match' / 'For' / 'Handle' / 'BlockParallel') in the current
  -- scope. No argument (the node reads the scope directly); synchronous (in-transaction).
  OpCall :: CallOp -> Operation
  -- | Invoke a callable with the single argument value. Target is a 'QualifiedName' (resolved via
  -- 'IRModule.entries', cross-module-safe) or a runtime value (a dynamically-supplied agent /
  -- closure). The commit boundary, if any, is the callee's property (see 'Implementation').
  OpDelegate :: DelegateOp -> Operation
  OpLoadLiteral :: LoadLiteralOp -> Operation
  -- | Make a closure value capturing the current scope; it resolves to the given 'Callable' block.
  OpMakeClosure :: MakeClosureOp -> Operation
  -- | Build a record value from in-scope vars (a named-args record / a record literal).
  OpMakeRecord :: MakeRecordOp -> Operation
  -- | Build a sequential array value from in-scope vars. (@par [...]@ uses 'BlockParallel' instead.)
  OpMakeTuple :: MakeTupleOp -> Operation
  -- | Read one field of a record value (@obj.field@ / a parameter binding); @null@ when absent.
  OpGetField :: GetFieldOp -> Operation
  -- | Irrefutably destructure a value (a @let@ pattern; exhaustiveness guaranteed by the checker).
  OpBindPattern :: BindPatternOp -> Operation
  -- | Attach a generic substitution to a callable value (for @get_metadata@ schema specialisation).
  OpApplyGenerics :: ApplyGenericsOp -> Operation
  -- | A non-local exit (return / break / for-break). 'target' is the enclosing block it unwinds to;
  -- the kind is implied by that block (callable = return, handle = break, for = for-break).
  OpExit :: ExitOp -> Operation
  -- | A non-local continue (next / for-next). 'target' is the enclosing handle / for it resumes.
  OpCont :: ContOp -> Operation
  deriving stock (Eq, Show)

data CallOp = CallOp
  { target :: BlockId,
    output :: Maybe VarId
  }
  deriving stock (Eq, Show)

data DelegateOp = DelegateOp
  { target :: CalleeReference,
    argument :: VarId,
    output :: Maybe VarId
  }
  deriving stock (Eq, Show)

data LoadLiteralOp = LoadLiteralOp
  { output :: VarId,
    value :: Literal
  }
  deriving stock (Eq, Show)

data MakeClosureOp = MakeClosureOp
  { output :: VarId,
    callable :: BlockId
  }
  deriving stock (Eq, Show)

data MakeRecordOp = MakeRecordOp
  { entries :: List (Text, VarId),
    output :: VarId
  }
  deriving stock (Eq, Show)

data MakeTupleOp = MakeTupleOp
  { elements :: List VarId,
    output :: VarId
  }
  deriving stock (Eq, Show)

data GetFieldOp = GetFieldOp
  { source :: VarId,
    field :: Text,
    output :: VarId
  }
  deriving stock (Eq, Show)

data BindPatternOp = BindPatternOp
  { source :: VarId,
    pattern :: Pattern
  }
  deriving stock (Eq, Show)

data ApplyGenericsOp = ApplyGenericsOp
  { source :: VarId,
    generics :: List (GenericId, GenericArgumentSchema),
    output :: VarId
  }
  deriving stock (Eq, Show)

data ExitOp = ExitOp
  { target :: BlockId,
    value :: VarId
  }
  deriving stock (Eq, Show)

data ContOp = ContOp
  { target :: BlockId,
    value :: Maybe VarId,
    -- | @with (name = e, ...)@ state updates: (state var in the target's scope, new-value var here).
    modifiers :: List (VarId, VarId)
  }
  deriving stock (Eq, Show)

-- | A callable-invocation target: a name (resolved through 'IRModule.entries', cross-module-safe) or
-- a runtime value (a dynamically-supplied agent / closure).
data CalleeReference where
  CalleeName :: QualifiedName -> CalleeReference
  CalleeValue :: VarId -> CalleeReference
  deriving stock (Eq, Show)

---------------------------------------------------------------------------------------------------
-- Literals and patterns
---------------------------------------------------------------------------------------------------

data Literal where
  LiteralNull :: Literal
  LiteralBoolean :: Bool -> Literal
  LiteralInteger :: Integer -> Literal
  LiteralNumber :: Double -> Literal
  LiteralString :: Text -> Literal
  deriving stock (Eq, Show)

-- | A runtime match pattern. The runtime walks it against a value, binding each 'PatternVariable'
-- position; the whole nested pattern is kept (no compilation to a tag cascade).
data Pattern where
  -- | Matches anything; binds nothing.
  PatternAny :: Pattern
  -- | Binds the value to a var; always matches.
  PatternVariable :: VarId -> Pattern
  -- | Matches when the value equals this literal.
  PatternLiteral :: Literal -> Pattern
  -- | Matches a tagged value of this constructor; recurses into the named fields.
  PatternConstructor :: QualifiedName -> List (Text, Pattern) -> Pattern
  -- | Matches a tuple positionally.
  PatternTuple :: List Pattern -> Pattern
  -- | Matches a record by the listed keys (subset match); other keys are ignored.
  PatternRecord :: List (Text, Pattern) -> Pattern
  -- | A runtime type guard (@T(pattern)@): matches when the value's runtime tag is 'TypeTag', then
  -- matches the inner pattern against it.
  PatternTypeGuard :: TypeTag -> Pattern -> Pattern
  deriving stock (Eq, Show)

-- | The runtime-checkable tag a @T(pattern)@ type filter narrows on.
data TypeTag where
  TagNull :: TypeTag
  TagBoolean :: TypeTag
  TagInteger :: TypeTag
  TagNumber :: TypeTag
  TagString :: TypeTag
  TagFile :: TypeTag
  TagArray :: TypeTag
  TagRecord :: TypeTag
  TagAgent :: TypeTag
  deriving stock (Eq, Show)

---------------------------------------------------------------------------------------------------
-- Schemas carried per callable
--
-- The shapes the (deferred) SemanticType -> JSONSchema converter fills; see "Katari.Data.JSONSchema".
---------------------------------------------------------------------------------------------------

-- | The public schema of one callable: its input, output, and the requests it may raise.
data SchemaInfo = SchemaInfo
  { input :: JSONSchema,
    output :: JSONSchema,
    requests :: List RequestSchema
  }
  deriving stock (Eq, Show)

-- | One entry of a callable's requests schema: a concrete request, or a placeholder for an
-- effect-generic parameter (filled at an instantiation site from the substituted effect).
data RequestSchema where
  RequestConcrete :: RequestDescriptor -> RequestSchema
  RequestGeneric :: GenericId -> RequestSchema
  deriving stock (Eq, Show)

data RequestDescriptor = RequestDescriptor
  { name :: QualifiedName,
    input :: JSONSchema,
    output :: JSONSchema
  }
  deriving stock (Eq, Show)

-- | The schema of one generic argument supplied at an 'OpApplyGenerics' site: a type's schema, or an
-- effect's requests. (Attribute generics carry no runtime schema.)
data GenericArgumentSchema where
  GenericArgumentType :: JSONSchema -> GenericArgumentSchema
  GenericArgumentRequests :: List RequestSchema -> GenericArgumentSchema
  deriving stock (Eq, Show)
