-- | The intermediate representation handed to the runtime, one 'IRModule' per source module (the
-- runtime uploads modules individually — there is no whole-program link step).
--
-- Shape (see the design discussion / docs for the rationale):
--
--   * Every block runs as its own thread (the unit the engine schedules and checkpoints). A
--     'BlockAgent' is the sole value-addressable wrapper — it carries the whole calling convention (a
--     single argument, defaults, and a schema in 'IRModule.schemas') and runs a body block; that body
--     (an agent 'BlockSequence', a leaf 'BlockPrimitive' / 'BlockConstruct' / 'BlockRequest' /
--     'BlockExternal', or a 'BlockHandle' for @where { handlers }@) is what the call actually does. The
--     remaining blocks are structural nodes that inherit the caller's scope.
--   * Invocation is split by what it summons, not by two verbs at the call site:
--       - 'OperationCall' enters a local structural node (by 'BlockId', no argument, in the same scope);
--       - 'OperationDelegate' invokes a 'BlockAgent' (by 'QualifiedName' — cross-module-safe — or by value,
--         with the single argument). Whether a delegation commits the transaction is a property of that
--         agent's body (external / effectful prim commit; pure prim / ctor stay in-transaction), so it
--         is derived at run time and not encoded in the op.
--   * Non-local control ('OperationExit' / 'OperationContinue') names the enclosing block it unwinds to / resumes; the
--     kind (return / break / for-break, next / for-next) is implied by that block's role.
--   * No type information. The public schema of each 'BlockAgent' lives in 'IRModule.schemas'.
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
-- and the target of an 'OperationCall' / 'OperationMakeClosure'. Module-local: a cross-module callee is addressed
-- by 'QualifiedName', never by a foreign 'BlockId'.
newtype BlockId = BlockId Word32
  deriving stock (Eq, Ord, Show)

-- | IR-level variable. Lowering allocates one per value slot within a block's scope.
newtype VariableId = VariableId Word32
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
    -- | Every block (a 'BlockAgent' wrapper, an agent body, a leaf body, or a structural node), keyed by id.
    blocks :: Map BlockId Block,
    -- | The schema of every 'BlockAgent'. Only 'BlockAgent's appear here — leaf bodies and structural
    -- nodes have none. A closure value resolves to its 'BlockAgent', so its schema is reachable here too
    -- (by 'BlockId'), not only top-level names.
    schemas :: Map BlockId SchemaInfo,
    -- | Top-level callable name -> its 'BlockAgent', for resolving an 'OperationDelegate' 'CalleeName' at run time.
    entries :: Map QualifiedName BlockId,
    -- | Debug-only block names (pretty printer / traces). The runtime's hot path ignores it.
    names :: Map BlockId Text
  }
  deriving stock (Eq, Show)

---------------------------------------------------------------------------------------------------
-- Blocks (each runs as its own thread)
---------------------------------------------------------------------------------------------------

-- | A schedulable unit. 'BlockAgent' is the sole value-addressable wrapper (it carries the calling
-- convention and a schema in 'IRModule.schemas'); every other block is reached only as some
-- 'BlockAgent'\'s body or as a structural node, and carries no schema.
data Block where
  BlockAgent :: Agent -> Block
  -- | An agent body (user code): operations run in the agent's fresh scope.
  BlockSequence :: Sequence -> Block
  -- | Leaf body — a built-in primitive (resolved against the runtime's prim registry).
  BlockPrimitive :: Primitive -> Block
  -- | Leaf body — a data constructor: build the tagged value from the argument.
  BlockConstruct :: Construct -> Block
  -- | Leaf body — a request: raise it as an escalation to the enclosing handler.
  BlockRequest :: Request -> Block
  -- | Leaf body — an external agent: the external handler dispatches it (no endpoint / module routing).
  BlockExternal :: External -> Block
  BlockMatch :: Match -> Block
  BlockFor :: For -> Block
  BlockHandle :: Handle -> Block
  -- | A parallel sequence literal (@par [e1, ...]@): its elements run concurrently.
  BlockParallel :: ParallelBlock -> Block
  deriving stock (Eq, Show)

-- | The single value-addressable callable: every agent / external / primitive / data-constructor /
-- request declaration, and every closure, lowers to one of these. It owns the whole calling
-- convention — the incoming argument binds to 'parameter' in a fresh scope (a @return@ boundary) and
-- omitted optionals are filled from 'defaults' — and then runs 'body'. The body is what the call
-- actually does: a 'BlockSequence' (agent code), a leaf ('BlockPrimitive' / 'BlockConstruct' /
-- 'BlockRequest' / 'BlockExternal'), or a 'BlockHandle' (@where { handlers }@). Whether the call
-- commits is the body's property (effectful leaf → suspend\/commit; pure leaf → in-transaction), so
-- it is derived at run time, not stored here. Its schema is in 'IRModule.schemas', keyed by this
-- block's id; the scope parent (isolated vs a closure's captured scope) comes from how the value was
-- summoned (a bare callable vs a closure value), not from a field here.
data Agent = Agent
  { parameter :: Maybe VariableId,
    defaults :: Map Text Literal,
    body :: BlockId
  }
  deriving stock (Eq, Show)

-- | A built-in primitive leaf: consumes the wrapping 'Agent'\'s argument (bound to 'parameter' in the
-- inherited scope) and is resolved against the runtime's prim registry by 'name'.
newtype Primitive = Primitive {name :: Text}
  deriving stock (Eq, Show)

-- | A data-constructor leaf: build the tagged value of 'name' from the wrapping 'Agent'\'s argument.
newtype Construct = Construct {name :: QualifiedName}
  deriving stock (Eq, Show)

-- | A request leaf: raise 'name' as an escalation to the enclosing handler, carrying the wrapping
-- 'Agent'\'s argument.
newtype Request = Request {name :: QualifiedName}
  deriving stock (Eq, Show)

-- | An external-agent leaf: the external handler dispatches it. 'key' is the opaque dispatch key the
-- handler interprets.
newtype External = External {key :: Text}
  deriving stock (Eq, Show)

-- | A block body: a list of operations plus the variable holding its value (if any).
data Sequence = Sequence
  { operations :: List Operation,
    result :: Maybe VariableId
  }
  deriving stock (Eq, Show)

---------------------------------------------------------------------------------------------------
-- Structural node blocks
---------------------------------------------------------------------------------------------------

-- | @match subject { ... }@. The runtime reads 'subject' from the inherited scope, tries 'arms' in
-- order, and runs the first matching arm's body (or 'fallback').
data Match = Match
  { subject :: VariableId,
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
    iterators :: List (VariableId, VariableId),
    -- | (state var in the body scope, initial-value var in the caller scope). Empty when parallel.
    states :: List (VariableId, VariableId),
    body :: BlockId,
    thenClause :: Maybe ThenClause
  }
  deriving stock (Eq, Show)

-- | A @handle@ scope: runs 'body', dispatches escalations to 'handlers', and on completion runs
-- 'thenClause'. State vars are seeded from the caller's scope.
data Handle = Handle
  { parallel :: Bool,
    states :: List (VariableId, VariableId),
    body :: BlockId,
    handlers :: List Handler,
    thenClause :: Maybe ThenClause
  }
  deriving stock (Eq, Show)

-- | One request handler. On a matching escalation the runtime binds the request arguments to
-- 'parameter' (in the handler body's scope) and runs 'body'.
data Handler = Handler
  { request :: QualifiedName,
    parameter :: Maybe VariableId,
    body :: BlockId
  }
  deriving stock (Eq, Show)

-- | A @then (pattern) { body }@ clause: 'parameter' receives the produced value (the for-mapping
-- array / the handle body's result), bound in the clause body's scope.
data ThenClause = ThenClause
  { parameter :: Maybe VariableId,
    body :: BlockId
  }
  deriving stock (Eq, Show)

-- | @par [e1, ...]@: each element is its own block, evaluated concurrently, results collected in
-- order. A sequential @[e1, ...]@ lowers to 'OperationMakeTuple' instead (no concurrency, no own thread).
newtype ParallelBlock = ParallelBlock
  { elements :: List BlockId
  }
  deriving stock (Eq, Show)

---------------------------------------------------------------------------------------------------
-- Operations (each runs within the enclosing block's thread)
---------------------------------------------------------------------------------------------------

data Operation where
  -- | Enter a local structural node ('Match' / 'For' / 'Handle' / 'BlockParallel') in the current
  -- scope. No argument (the node reads the scope directly). This step itself does not commit (any
  -- commit happens at a leaf delegation inside the node).
  OperationCall :: CallOperation -> Operation
  -- | Invoke a 'BlockAgent' with the single argument value. Target is a 'QualifiedName' (resolved via
  -- 'IRModule.entries', cross-module-safe) or a runtime value (a dynamically-supplied agent /
  -- closure). The commit boundary, if any, is the agent body's property (see 'Agent').
  OperationDelegate :: DelegateOperation -> Operation
  OperationLoadLiteral :: LoadLiteralOperation -> Operation
  -- | Make a closure value capturing the current scope; it resolves to the given 'BlockAgent'.
  OperationMakeClosure :: MakeClosureOperation -> Operation
  -- | Build a record value from in-scope vars (a named-args record / a record literal).
  OperationMakeRecord :: MakeRecordOperation -> Operation
  -- | Build a sequential array value from in-scope vars. (@par [...]@ uses 'BlockParallel' instead.)
  OperationMakeTuple :: MakeTupleOperation -> Operation
  -- | Read one field of a record value (@obj.field@ / a parameter binding); @null@ when absent.
  OperationGetField :: GetFieldOperation -> Operation
  -- | Irrefutably destructure a value (a @let@ pattern; exhaustiveness guaranteed by the checker).
  OperationBindPattern :: BindPatternOperation -> Operation
  -- | Attach a generic substitution to a callable value (for @get_metadata@ schema specialisation).
  OperationApplyGenerics :: ApplyGenericsOperation -> Operation
  -- | A non-local exit (return / break / for-break). 'target' is the enclosing block it unwinds to;
  -- the kind is implied by that block (agent = return, handle = break, for = for-break).
  OperationExit :: ExitOperation -> Operation
  -- | A non-local continue (next / for-next). 'target' is the enclosing handle / for it resumes.
  OperationContinue :: ContinueOperation -> Operation
  deriving stock (Eq, Show)

data CallOperation = CallOperation
  { target :: BlockId,
    output :: Maybe VariableId
  }
  deriving stock (Eq, Show)

data DelegateOperation = DelegateOperation
  { target :: CalleeReference,
    argument :: VariableId,
    output :: Maybe VariableId
  }
  deriving stock (Eq, Show)

data LoadLiteralOperation = LoadLiteralOperation
  { output :: VariableId,
    value :: Literal
  }
  deriving stock (Eq, Show)

data MakeClosureOperation = MakeClosureOperation
  { output :: VariableId,
    -- | The 'BlockAgent' this closure resolves to; calling the closure spawns it with the captured
    -- scope as parent.
    agent :: BlockId
  }
  deriving stock (Eq, Show)

data MakeRecordOperation = MakeRecordOperation
  { entries :: List (Text, VariableId),
    output :: VariableId
  }
  deriving stock (Eq, Show)

data MakeTupleOperation = MakeTupleOperation
  { elements :: List VariableId,
    output :: VariableId
  }
  deriving stock (Eq, Show)

data GetFieldOperation = GetFieldOperation
  { source :: VariableId,
    field :: Text,
    output :: VariableId
  }
  deriving stock (Eq, Show)

data BindPatternOperation = BindPatternOperation
  { source :: VariableId,
    pattern :: Pattern
  }
  deriving stock (Eq, Show)

data ApplyGenericsOperation = ApplyGenericsOperation
  { source :: VariableId,
    -- | Apply the target's generics by name; any reference inside a 'GenericArgumentSchema' is by
    -- 'GenericId' (resolved against the current frame's generic environment). The resolved callee's
    -- 'SchemaInfo.genericBindings' maps these names back onto its template's 'GenericId's.
    generics :: List (Text, GenericArgumentSchema),
    output :: VariableId
  }
  deriving stock (Eq, Show)

data ExitOperation = ExitOperation
  { target :: BlockId,
    value :: VariableId
  }
  deriving stock (Eq, Show)

data ContinueOperation = ContinueOperation
  { target :: BlockId,
    value :: Maybe VariableId,
    -- | @with (name = e, ...)@ state updates: (state var in the target's scope, new-value var here).
    modifiers :: List (VariableId, VariableId)
  }
  deriving stock (Eq, Show)

-- | A callable-invocation target: a name (resolved through 'IRModule.entries', cross-module-safe) or
-- a runtime value (a dynamically-supplied agent / closure).
data CalleeReference where
  CalleeName :: QualifiedName -> CalleeReference
  CalleeValue :: VariableId -> CalleeReference
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
  PatternVariable :: VariableId -> Pattern
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

-- | The public schema of one callable: its input, output, the requests it may raise, and the binding
-- of its generic parameter names to the 'GenericId's its template references.
data SchemaInfo = SchemaInfo
  { input :: JSONSchema,
    output :: JSONSchema,
    requests :: List RequestSchema,
    -- | This callable's generic parameters, in declaration order: each name paired with the
    -- 'GenericId' its references use in 'input' / 'output' ('SchemaGeneric') and 'requests'
    -- ('RequestGeneric'). The single bridge from a name-keyed application (an 'ApplyGenericsOperation'
    -- / a value's attached substitution) onto the id-keyed template — used both to build a frame's
    -- generic environment on delegation and to fill the @get_metadata@ schema.
    genericBindings :: List (Text, GenericId)
  }
  deriving stock (Eq, Show)

-- | One entry of a callable's requests schema: a concrete request, or a reference to an effect-generic
-- parameter (by 'GenericId'; filled from the substituted effect via 'SchemaInfo.genericBindings').
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

-- | The schema of one generic argument supplied at an 'OperationApplyGenerics' site: a type's schema, or an
-- effect's requests. (Attribute generics carry no runtime schema.)
data GenericArgumentSchema where
  GenericArgumentType :: JSONSchema -> GenericArgumentSchema
  GenericArgumentRequests :: List RequestSchema -> GenericArgumentSchema
  deriving stock (Eq, Show)
