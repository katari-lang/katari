-- | The intermediate representation handed to the runtime, one 'IRModule' per source module.
--   * Every block runs as its own thread
--   * Invocation is split by what it summons, not by two verbs at the call site:
--       - 'OperationCall' enters a local structural node (by 'BlockId', no argument, in the same scope);
--       - 'OperationDelegate' invokes a 'BlockAgent' (by 'QualifiedName' — cross-module-safe — or by value,
--         with the single argument). Whether a delegation commits the transaction is a property of that
--         agent's body.
--   * Non-local control ('OperationExit' / 'OperationContinue') names the enclosing block it unwinds to / resumes; the
--     kind (return / break / for-break, next / for-next) is implied by that block's role.
--   * No type information. The public schema of each 'BlockAgent' lives in its 'Agent.schema'.
--
-- The JSON encoding (consumed by the TS runtime) is the 'ToJSON' instances at the bottom of this
-- module; it mirrors @typescript/types/src/ir.ts@ exactly (the two are co-designed). Sum types are
-- @kind@-tagged with their payload inlined; 'BlockId'-keyed maps become objects with string keys.
module Katari.Data.IR where

import Data.Aeson (ToJSON (..), ToJSONKey, Value, object, (.=))
import Data.Aeson.Types (Pair)
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

-- | Block identifier, unique within an 'IRModule'. The key of 'IRModule.blocks'
-- and the target of an 'OperationCall' / 'OperationMakeClosure'. Module-local: a cross-module callee is addressed
-- by 'QualifiedName', never by a foreign 'BlockId'.
newtype BlockId = BlockId Word32
  deriving stock (Eq, Ord, Show)
  -- \| Wire form: a JSON number as a value, and a decimal-string object key. e.g. @{"0": {...}}@).
  deriving newtype (ToJSON, ToJSONKey)

-- | IR-level variable. Lowering allocates one per value slot within a block's scope.
newtype VariableId = VariableId Word32
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

---------------------------------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------------------------------

newtype Metadata = Metadata
  { schemaVersion :: Int
  }
  deriving stock (Eq, Show)

-- | The metadata the compiler stamps on every emitted 'IRModule'.
currentMetadata :: Metadata
currentMetadata = Metadata {schemaVersion = 1}

-- | One module's lowered output. The runtime loads it and resolves callables by 'QualifiedName'
-- through 'entries'
data IRModule = IRModule
  { metadata :: Metadata,
    -- | Every block (a 'BlockAgent' wrapper, an agent body, a leaf body, or a structural node), keyed by id.
    -- Each is wrapped in a 'BlockInformation' that carries how its thread's scope is seeded on entry.
    blocks :: Map BlockId BlockInformation,
    -- | Top-level callable name -> its 'BlockAgent', for resolving an 'OperationDelegate' 'CalleeName' at run time.
    entries :: Map QualifiedName BlockId,
    -- | Debug-only block names (pretty printer / traces). The runtime's hot path ignores it.
    names :: Map BlockId Text
  }
  deriving stock (Eq, Show)

---------------------------------------------------------------------------------------------------
-- Blocks (each runs as its own thread)
---------------------------------------------------------------------------------------------------

data BlockInformation = BlockInformation
  { block :: Block,
    -- | Runtime will be insert variables to scope with passed parameters. parameter: {name: value, name: value,...}
    -- Used by:
    --  Agent: the agent's argument (as object)
    --  Sequence: when the block is...
    --   Body of for: {iterator: value, state_0: value, state_1: value,...}  (each iterator body thread should have its own iterator variable & states)
    --   Then clause of for: {result: value, state_0: value, state_1: value,...} (then clause body will receive the result of for-mapping and the final states)
    --   Handler body: {paramter: value, state_0: value, state_1: value,...} (handler body will receive the request parameter and the final states)
    --   Handler then clause: {result: value, state_0: value, state_1: value,...} (then clause body will receive the result of handle target and the final states)
    parameters :: Map Text VariableId
  }
  deriving stock (Eq, Show)

-- | A schedulable unit.
data Block where
  -- | Sole value-addressable wrapper
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
  -- | A parallel sequence literal (@parallel [e1, ...]@): its elements run concurrently.
  BlockParallel :: ParallelBlock -> Block
  deriving stock (Eq, Show)

-- | The single value-addressable callable: every agent / external / primitive / data-constructor /
-- request declaration, and every closure, lowers to one of these.
data Agent = Agent
  { body :: BlockId,
    schema :: SchemaInformation,
    -- | Default values for omittable (optional) parameters, keyed by parameter name. Before running
    -- the body, the runtime fills any parameter absent from the argument record with its default. This
    -- is the single defaults mechanism for every callable — user agents, data constructors, requests,
    -- externals and primitives all carry their defaults here (the leaf blocks no longer do).
    defaults :: Map Text Literal
  }
  deriving stock (Eq, Show)

-- | A built-in primitive leaf: reads its argument from 'input' (seeded into the inherited scope by the
-- wrapping agent) and is resolved against the runtime's prim registry by 'name'.
data Primitive = Primitive
  { name :: Text,
    input :: VariableId
  }
  deriving stock (Eq, Show)

-- | A data-constructor leaf: build the tagged value of 'name' from the wrapping 'Agent'\'s argument.
data Construct = Construct
  { name :: QualifiedName,
    input :: VariableId
  }
  deriving stock (Eq, Show)

-- | A request leaf: raise 'name' as an escalation to the enclosing handler, carrying the wrapping
-- 'Agent'\'s argument.
data Request = Request
  { name :: QualifiedName,
    input :: VariableId
  }
  deriving stock (Eq, Show)

-- | An external-agent leaf: the external handler dispatches it. 'key' is the opaque dispatch key the
-- handler interprets.
data External = External
  { key :: Text,
    input :: VariableId
  }
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
    -- | The source array to iterate, in the caller's scope. Each element is bound to the body block's
    -- @iterator@ parameter (that body var lives in the body block's 'BlockInformation.parameters').
    source :: VariableId,
    -- | Initial state values in the caller's scope, in order: the Nth binds to the body block's
    -- @state_N@ parameter. Empty when parallel.
    initialStates :: List VariableId,
    body :: BlockId,
    thenClause :: Maybe ThenClause
  }
  deriving stock (Eq, Show)

-- | A @handle@ scope: runs 'body', dispatches escalations to 'handlers', and on completion runs
-- 'thenClause'. State vars are seeded from the caller's scope.
data Handle = Handle
  { parallel :: Bool,
    -- | Initial state values in the caller's scope, in order: the Nth binds to the body / handler
    -- block's @state_N@ parameter. Empty when parallel.
    initialStates :: List VariableId,
    body :: BlockId,
    handlers :: List Handler,
    thenClause :: Maybe ThenClause
  }
  deriving stock (Eq, Show)

-- | One request handler. On a matching escalation the runtime seeds the handler body's scope (the
-- request argument as its @parameter@, the current states as @state_N@; see 'BlockInformation') and
-- runs 'body'.
data Handler = Handler
  { request :: QualifiedName,
    body :: BlockId
  }
  deriving stock (Eq, Show)

-- | A @then (pattern) { body }@ clause. The produced value (the for-mapping array / the handle body's
-- result) is seeded into the clause body's scope as its @result@ parameter, alongside the final
-- @state_N@s (see 'BlockInformation'); the clause then runs 'body'.
newtype ThenClause = ThenClause
  { body :: BlockId
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
  -- | Materialize a top-level callable as a first-class agent value, by 'QualifiedName' (resolved via
  -- 'IRModule.entries' at run time, cross-module-safe). The counterpart of 'OperationMakeClosure' for a
  -- named top-level agent / data-constructor / request / external / primitive used as a value (passed to
  -- a higher-order callable, bound to a @let@, …); 'OperationMakeClosure' stays for a /local/ agent,
  -- which captures the enclosing scope.
  OperationLoadAgent :: LoadAgentOperation -> Operation
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

data LoadAgentOperation = LoadAgentOperation
  { output :: VariableId,
    -- | The top-level callable to load, resolved against 'IRModule.entries' at run time.
    name :: QualifiedName
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
    -- 'SchemaInformation.genericBindings' maps these names back onto its template's 'GenericId's.
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
  -- Machine-width ('Int'), matching the runtime's JS-number value model (see 'LiteralValueInteger').
  LiteralInteger :: Int -> Literal
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
data SchemaInformation = SchemaInformation
  { input :: JSONSchema,
    output :: JSONSchema,
    requests :: List RequestSchema,
    -- | This callable's generic parameters, keyed by name: each maps to the 'GenericId' its references
    -- use in 'input' / 'output' ('SchemaGeneric') and 'requests' ('RequestGeneric').
    genericBindings :: Map Text GenericId
  }
  deriving stock (Eq, Show)

-- | One entry of a callable's requests schema: a concrete request, or a reference to an effect-generic
-- parameter (by 'GenericId'; filled from the substituted effect via 'SchemaInformation.genericBindings').
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

---------------------------------------------------------------------------------------------------
-- JSON encoding
--
-- The wire format consumed by the TS runtime; it mirrors @typescript/types/src/ir.ts@ exactly (the
-- two are co-designed). Sum types are tagged with a @kind@ discriminator and their payload fields are
-- inlined alongside it; records serialise to plain objects; 'BlockId' / 'VariableId' / 'GenericId'
-- are JSON numbers, and maps keyed by 'BlockId' / 'QualifiedName' become objects with string keys.
---------------------------------------------------------------------------------------------------

-- | Build a kind-tagged JSON object @{"kind": tag, ...fields}@ — the encoding every IR sum type uses.
taggedObject :: Text -> List Pair -> Value
taggedObject tag fields = object (("kind" .= tag) : fields)

instance ToJSON Metadata where
  toJSON metadata = object ["schemaVersion" .= metadata.schemaVersion]

instance ToJSON IRModule where
  toJSON irModule =
    object
      [ "metadata" .= irModule.metadata,
        "blocks" .= irModule.blocks,
        "entries" .= irModule.entries,
        "names" .= irModule.names
      ]

instance ToJSON BlockInformation where
  toJSON blockInformation =
    object ["block" .= blockInformation.block, "parameters" .= blockInformation.parameters]

instance ToJSON Block where
  toJSON block = case block of
    BlockAgent agent ->
      taggedObject "agent" ["body" .= agent.body, "schema" .= agent.schema, "defaults" .= agent.defaults]
    BlockSequence body ->
      taggedObject "sequence" ["operations" .= body.operations, "result" .= body.result]
    BlockPrimitive primitive ->
      taggedObject "primitive" ["name" .= primitive.name, "input" .= primitive.input]
    BlockConstruct construct ->
      taggedObject "construct" ["name" .= construct.name, "input" .= construct.input]
    BlockRequest request ->
      taggedObject "request" ["name" .= request.name, "input" .= request.input]
    BlockExternal external ->
      taggedObject "external" ["key" .= external.key, "input" .= external.input]
    BlockMatch match ->
      taggedObject "match" ["subject" .= match.subject, "arms" .= match.arms, "fallback" .= match.fallback]
    BlockFor for ->
      taggedObject
        "for"
        [ "parallel" .= for.parallel,
          "source" .= for.source,
          "initialStates" .= for.initialStates,
          "body" .= for.body,
          "thenClause" .= for.thenClause
        ]
    BlockHandle handle ->
      taggedObject
        "handle"
        [ "parallel" .= handle.parallel,
          "initialStates" .= handle.initialStates,
          "body" .= handle.body,
          "handlers" .= handle.handlers,
          "thenClause" .= handle.thenClause
        ]
    BlockParallel parallelBlock -> taggedObject "parallel" ["elements" .= parallelBlock.elements]

instance ToJSON MatchArm where
  toJSON arm = object ["pattern" .= arm.pattern, "body" .= arm.body]

instance ToJSON Handler where
  toJSON handler = object ["request" .= handler.request, "body" .= handler.body]

instance ToJSON ThenClause where
  toJSON thenClause = object ["body" .= thenClause.body]

instance ToJSON Operation where
  toJSON operation = case operation of
    OperationCall op -> taggedObject "call" ["target" .= op.target, "output" .= op.output]
    OperationDelegate op ->
      taggedObject "delegate" ["target" .= op.target, "argument" .= op.argument, "output" .= op.output]
    OperationLoadLiteral op -> taggedObject "loadLiteral" ["output" .= op.output, "value" .= op.value]
    OperationLoadAgent op -> taggedObject "loadAgent" ["output" .= op.output, "name" .= op.name]
    OperationMakeClosure op -> taggedObject "makeClosure" ["output" .= op.output, "agent" .= op.agent]
    OperationMakeRecord op -> taggedObject "makeRecord" ["entries" .= op.entries, "output" .= op.output]
    OperationMakeTuple op -> taggedObject "makeTuple" ["elements" .= op.elements, "output" .= op.output]
    OperationGetField op ->
      taggedObject "getField" ["source" .= op.source, "field" .= op.field, "output" .= op.output]
    OperationBindPattern op -> taggedObject "bindPattern" ["source" .= op.source, "pattern" .= op.pattern]
    OperationApplyGenerics op ->
      taggedObject "applyGenerics" ["source" .= op.source, "generics" .= op.generics, "output" .= op.output]
    OperationExit op -> taggedObject "exit" ["target" .= op.target, "value" .= op.value]
    OperationContinue op ->
      taggedObject "continue" ["target" .= op.target, "value" .= op.value, "modifiers" .= op.modifiers]

instance ToJSON CalleeReference where
  toJSON reference = case reference of
    CalleeName name -> taggedObject "name" ["name" .= name]
    CalleeValue variable -> taggedObject "value" ["variable" .= variable]

instance ToJSON Literal where
  toJSON literal = case literal of
    LiteralNull -> taggedObject "null" []
    LiteralBoolean value -> taggedObject "boolean" ["value" .= value]
    LiteralInteger value -> taggedObject "integer" ["value" .= value]
    LiteralNumber value -> taggedObject "number" ["value" .= value]
    LiteralString value -> taggedObject "string" ["value" .= value]

instance ToJSON Pattern where
  toJSON pattern = case pattern of
    PatternAny -> taggedObject "any" []
    PatternVariable variable -> taggedObject "variable" ["variable" .= variable]
    PatternLiteral value -> taggedObject "literal" ["value" .= value]
    PatternConstructor name fields -> taggedObject "constructor" ["name" .= name, "fields" .= fields]
    PatternTuple elements -> taggedObject "tuple" ["elements" .= elements]
    PatternRecord fields -> taggedObject "record" ["fields" .= fields]
    PatternTypeGuard tag inner -> taggedObject "typeGuard" ["tag" .= tag, "pattern" .= inner]

instance ToJSON TypeTag where
  toJSON tag = case tag of
    TagNull -> "null"
    TagBoolean -> "boolean"
    TagInteger -> "integer"
    TagNumber -> "number"
    TagString -> "string"
    TagFile -> "file"
    TagArray -> "array"
    TagRecord -> "record"
    TagAgent -> "agent"

instance ToJSON SchemaInformation where
  toJSON schemaInfo =
    object
      [ "input" .= schemaInfo.input,
        "output" .= schemaInfo.output,
        "requests" .= schemaInfo.requests,
        "genericBindings" .= schemaInfo.genericBindings
      ]

instance ToJSON RequestSchema where
  toJSON requestSchema = case requestSchema of
    RequestConcrete descriptor -> taggedObject "concrete" ["descriptor" .= descriptor]
    RequestGeneric generic -> taggedObject "generic" ["generic" .= generic]

instance ToJSON RequestDescriptor where
  toJSON descriptor =
    object ["name" .= descriptor.name, "input" .= descriptor.input, "output" .= descriptor.output]

instance ToJSON GenericArgumentSchema where
  toJSON argument = case argument of
    GenericArgumentType schema -> taggedObject "type" ["schema" .= schema]
    GenericArgumentRequests requests -> taggedObject "requests" ["requests" .= requests]
