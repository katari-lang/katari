-- | The Lower phase: a 'Typed' AST to the runtime IR ('IRModule'), per module. The runtime uploads
-- modules individually, so there is no whole-program link step; each module's 'BlockId' / 'VariableId'
-- space is its own, allocated from zero. Lowering also produces each callable's schema (into the
-- 'BlockAgent''s 'SchemaInformation'), since only it knows the runtime shape the schema describes.
--
-- The IR is type-erased: values carry a /dynamic/ runtime tag, distinct from the static type. The
-- 'Typed' AST's types are read only to (1) build each callable's public schema and (2) emit the
-- generic substitution an 'OperationApplyGenerics' carries. Everything else is a structural translation
-- — statements / expressions to operations, the control-flow constructs to structural-node blocks.
--
-- The single argument of a delegation is always a record; an agent body is seeded with it under the
-- well-known @parameter@ key and reads each declared parameter out of it (mirroring 'BlockInformation').
-- Control transfers ('OperationExit' / 'OperationContinue') name the lexically-enclosing block they
-- unwind to / resume, stamped on the way down ('returnTarget' / 'forTarget' / 'handleTarget').
module Katari.Lowering
  ( lowerModule,
  )
where

import Control.Monad (foldM)
import Control.Monad.RWS.CPS (RWS, runRWS)
import Control.Monad.RWS.Class (asks, gets, local, modify)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (fromMaybe, isNothing, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word32)
import GHC.List (List)
import Katari.Data.AST qualified as AST
import Katari.Data.Environment
  ( DataEnvironment,
    DataInformation (..),
    GenericParameterInformation (..),
    GenericParameters (..),
    RequestEnvironment,
    RequestInformation (..),
    Scheme (..),
    ValueEnvironment,
  )
import Katari.Data.IR
import Katari.Data.Id (GenericId, LocalVariableId, TypeResolution (..), VariableResolution (..))
import Katari.Data.JSONSchema (JSONSchema (..))
import Katari.Data.ModuleName (ModuleName)
import Katari.Data.NormalizedType (bottomAttribute)
import Katari.Data.QualifiedName (QualifiedName (..), renderQualifiedName)
import Katari.Data.SemanticType (SemanticEffect (..), SemanticGenericArgument (..), SemanticType (..), substituteGenerics)
import Katari.Diagnostics (Diagnostics)
import Katari.Lowering.Drop (insertDropOperations)
import Katari.Panic (panic)
import Katari.Primitive (panicRequestName, preludeModuleName, recordMergeLeftLabel, recordMergeName, recordMergeRightLabel)
import Katari.Schema qualified as Schema
import Katari.Typechecker.Elaborate (ElaborateContext)
import Katari.Typechecker.Environment (TypeEnvironment (..))
import Katari.Typechecker.Normalizer (Normalizer, NormalizerEnvironment, SubtypingContext (..), denormalize, objectAsType)

---------------------------------------------------------------------------------------------------
-- The lowering monad
---------------------------------------------------------------------------------------------------

-- | Per-module read-only schema context, shared across every block of one module. The type / value
-- environments are global (the schema of a callable in another module is needed when it is referenced),
-- but the IR a module emits is otherwise self-contained.
data LowerContext = LowerContext
  { valueEnvironment :: ValueEnvironment,
    -- | The denormalized @data@ constructor shapes the schema converter inline-expands.
    dataDefinitions :: Schema.DataDefinitions,
    -- | The denormalized request shapes, for turning an effect into its requests schema.
    requestDefinitions :: Map QualifiedName RequestDefinition,
    -- | The environment 'denormalize' runs against (to turn a stored 'Scheme' into a 'SemanticType').
    normalizerEnvironment :: NormalizerEnvironment,
    -- | The elaborator's signature registry, for resolving a type-filter's matched type to a runtime tag.
    elaborateContext :: ElaborateContext
  }

-- | One request reduced to what a requests-schema entry needs: its parameter / return type as
-- 'SemanticType' (the request's own generics surviving as 'SemanticTypeGeneric') and the parameter
-- name -> 'GenericId' map, so a @req[args]@ effect's arguments specialise them.
data RequestDefinition = RequestDefinition
  { parameterType :: SemanticType,
    returnType :: SemanticType,
    parameterGenericIds :: Map Text GenericId,
    -- | A marker effect: type-level only, so it contributes no requests-schema entry — the runtime
    -- must never present an unperformable capability tag as a catchable request.
    marker :: Bool
  }

-- | The scope-local environment, threaded by 'local'. 'localVariables' maps each resolved local to the
-- IR variable holding it; the three targets are the lexically-enclosing blocks a @return@ / @break@ /
-- @next@ unwinds to (an agent / a @handle@ / a @for@).
data LowerEnvironment = LowerEnvironment
  { context :: LowerContext,
    localVariables :: Map LocalVariableId VariableId,
    returnTarget :: Maybe BlockId,
    forTarget :: Maybe BlockId,
    handleTarget :: Maybe BlockId
  }

-- | The field names ('blockTable' / 'entryTable' / 'nameTable') deliberately differ from 'IRModule''s
-- (@blocks@ / @entries@ / @names@) so the accumulator's record updates are unambiguous.
data LowerState = LowerState
  { nextBlockId :: Word32,
    nextVariableId :: Word32,
    blockTable :: Map BlockId BlockInformation,
    entryTable :: Map QualifiedName BlockId,
    nameTable :: Map BlockId Text,
    -- | The operations of the block currently being built, accumulated in reverse for O(1) prepend and
    -- reversed once at the block boundary ('withFreshOperations').
    currentOperations :: List Operation
  }

initialLowerState :: LowerState
initialLowerState =
  LowerState
    { nextBlockId = 0,
      nextVariableId = 0,
      blockTable = mempty,
      entryTable = mempty,
      nameTable = mempty,
      currentOperations = []
    }

-- | The writer is unused: lowering runs only after the pipeline gates on an error-free program, so a
-- malformed shape here is a compiler bug and 'panic's rather than emitting a diagnostic.
type Lower = RWS LowerEnvironment Diagnostics LowerState

-- | How a block body finished: normally with an optional tail value (carried on the block's @result@),
-- or via a non-local jump (so the jump already emitted its 'OperationExit' / 'OperationContinue' and the
-- tail is unreachable). A @for@ / request-handler body's normal completion is an implicit @next@: the
-- tail value rides on @result@ and the runtime resumes from the body's fall-through.
data BlockCompletion
  = CompletedWith (Maybe VariableId)
  | Exited

completionResult :: BlockCompletion -> Maybe VariableId
completionResult = \case
  CompletedWith value -> value
  Exited -> Nothing

---------------------------------------------------------------------------------------------------
-- Allocation / emission helpers
---------------------------------------------------------------------------------------------------

freshBlockId :: Lower BlockId
freshBlockId = do
  identifier <- gets (.nextBlockId)
  modify (\state -> state {nextBlockId = identifier + 1})
  pure (BlockId identifier)

freshVariableId :: Lower VariableId
freshVariableId = do
  identifier <- gets (.nextVariableId)
  modify (\state -> state {nextVariableId = identifier + 1})
  pure (VariableId identifier)

-- | Append an operation to the block currently being built.
emit :: Operation -> Lower ()
emit operation = modify (\state -> state {currentOperations = operation : state.currentOperations})

-- | Run @action@ with a fresh (empty) operation buffer; restore the caller's buffer afterwards and
-- return the action's result alongside the forward-ordered operations it emitted. Used at every block
-- boundary so a nested block's operations do not leak into its parent.
withFreshOperations :: Lower a -> Lower (a, List Operation)
withFreshOperations action = do
  saved <- gets (.currentOperations)
  modify (\state -> state {currentOperations = []})
  result <- action
  emitted <- gets (.currentOperations)
  modify (\state -> state {currentOperations = saved})
  pure (result, reverse emitted)

recordBlock :: BlockId -> Block -> Map Text VariableId -> Maybe Text -> Lower ()
recordBlock blockId block parameters name =
  modify $ \state ->
    state
      { blockTable = Map.insert blockId BlockInformation {block = block, parameters = parameters} state.blockTable,
        nameTable = maybe state.nameTable (\debugName -> Map.insert blockId debugName state.nameTable) name
      }

registerEntry :: QualifiedName -> BlockId -> Lower ()
registerEntry qualifiedName blockId =
  modify (\state -> state {entryTable = Map.insert qualifiedName blockId state.entryTable})

---------------------------------------------------------------------------------------------------
-- Scope / jump-target helpers
---------------------------------------------------------------------------------------------------

withLocals :: List (LocalVariableId, VariableId) -> Lower a -> Lower a
withLocals bindings =
  local (\environment -> environment {localVariables = Map.union (Map.fromList bindings) environment.localVariables})

-- | Enter an agent body: a @return@ inside now unwinds to @blockId@. The @for@ / @handle@ targets reset
-- — control cannot break / next across an agent boundary. (A @use@ continuation does /not/ use this; it
-- keeps the enclosing targets, so a @return@ in it unwinds to the agent that wrote the @use@.)
withReturnTarget :: BlockId -> Lower a -> Lower a
withReturnTarget blockId =
  local (\environment -> environment {returnTarget = Just blockId, forTarget = Nothing, handleTarget = Nothing})

withForTarget :: BlockId -> Lower a -> Lower a
withForTarget blockId = local (\environment -> environment {forTarget = Just blockId})

-- | Enter a request-handler body: a @break@ / @next@ targets the @handle@. A handler body runs deferred,
-- so it cannot @return@ to (or @for@-jump out of) the enclosing agent; those targets are cleared.
withHandlerContext :: BlockId -> Lower a -> Lower a
withHandlerContext blockId =
  local (\environment -> environment {handleTarget = Just blockId, returnTarget = Nothing, forTarget = Nothing})

requireLocal :: LocalVariableId -> Lower VariableId
requireLocal localId = do
  bindings <- asks (.localVariables)
  case Map.lookup localId bindings of
    Just variable -> pure variable
    Nothing -> panic ("lowering: unbound local variable " <> Text.pack (show localId))

requireReturnTarget :: Lower BlockId
requireReturnTarget = asks (.returnTarget) >>= maybe (panic "lowering: `return` has no enclosing agent") pure

requireForTarget :: Lower BlockId
requireForTarget = asks (.forTarget) >>= maybe (panic "lowering: `for` `next`/`break` has no enclosing `for`") pure

requireHandleTarget :: Lower BlockId
requireHandleTarget = asks (.handleTarget) >>= maybe (panic "lowering: `next`/`break` has no enclosing handler") pure

---------------------------------------------------------------------------------------------------
-- Resolution helpers
--
-- A reference is always resolved at 'Typed' (the pipeline gates on a clean identify pass), so an
-- unexpected shape is a compiler bug.
---------------------------------------------------------------------------------------------------

resolvedQualifiedName :: AST.Reference AST.Typed AST.VariableReference -> QualifiedName
resolvedQualifiedName reference = case reference.resolution of
  Just (VariableResolutionQualifiedName qualifiedName) -> qualifiedName
  _ -> panic "lowering: expected a resolved top-level callable reference"

resolvedLocalVariableId :: AST.Reference AST.Typed AST.VariableReference -> LocalVariableId
resolvedLocalVariableId reference = case reference.resolution of
  Just (VariableResolutionLocalVariable localId) -> localId
  _ -> panic "lowering: expected a resolved local variable reference"

resolvedRequestName :: AST.Reference AST.Typed AST.TypeReference -> QualifiedName
resolvedRequestName reference = case reference.resolution of
  Just (TypeResolutionQualifiedName qualifiedName) -> qualifiedName
  _ -> panic "lowering: request handler is not resolved to a request"

-- | The 'QualifiedName' of a call target that is a direct reference to a top-level callable, so the
-- delegation can name it ('CalleeName') rather than materialise it as a value first.
topLevelCalleeName :: AST.Expression AST.Typed -> Maybe QualifiedName
topLevelCalleeName = \case
  AST.ExpressionVariable expression -> topLevelResolution expression.variableReference
  AST.ExpressionQualifiedReference expression -> topLevelResolution expression.variableReference
  _ -> Nothing

topLevelResolution :: AST.Reference AST.Typed AST.VariableReference -> Maybe QualifiedName
topLevelResolution reference = case reference.resolution of
  Just (VariableResolutionQualifiedName qualifiedName) -> Just qualifiedName
  _ -> Nothing

-- | A callable's generic parameter names mapped to their 'GenericId's (as the schema references them),
-- taken from the declared parameters.
genericBindingsOfDeclaration :: List (AST.GenericParameter AST.Typed) -> Map Text GenericId
genericBindingsOfDeclaration parameters = Map.fromList (mapMaybe binding parameters)
  where
    binding parameter = case parameter.typeReference.resolution of
      Just (TypeResolutionGeneric genericId) -> Just (parameter.name, genericId)
      _ -> Nothing

genericBindingsOfScheme :: Scheme -> Map Text GenericId
genericBindingsOfScheme scheme = Map.map (.genericId) scheme.genericParameters.parameterInformation

lowerLiteralValue :: AST.LiteralValue -> Literal
lowerLiteralValue = \case
  AST.LiteralValueInteger value -> LiteralInteger value
  AST.LiteralValueNumber value -> LiteralNumber value
  AST.LiteralValueString value -> LiteralString value
  AST.LiteralValueBoolean value -> LiteralBoolean value
  AST.LiteralValueNull -> LiteralNull

---------------------------------------------------------------------------------------------------
-- Schema building (pure over the precomputed context)
---------------------------------------------------------------------------------------------------

-- | Run a 'denormalize' (or any 'Normalizer' action) against the module's normalizer environment. The
-- normalizer is span-free and a stored type is already well-formed, so its diagnostics are discarded.
runDenormalize :: NormalizerEnvironment -> Normalizer a -> a
runDenormalize environment action = let (result, _, _) = runRWS action environment () in result

-- | Denormalize every @data@ declaration's constructor into the inline-expansion shape the schema
-- converter consumes.
buildDataDefinitions :: NormalizerEnvironment -> DataEnvironment -> Schema.DataDefinitions
buildDataDefinitions environment = Map.map convert
  where
    convert information =
      Schema.DataDefinition
        { fields = constructorFields (runDenormalize environment (denormalize (objectAsType information.constructor))),
          parameterGenericIds = Map.map (.genericId) information.genericParameters.parameterInformation
        }
    -- A constructor is always an object; a nullary constructor denormalizes to the empty record, which
    -- carries no fields.
    constructorFields = \case
      SemanticTypeObject fields -> fields
      _ -> mempty

buildRequestDefinitions :: NormalizerEnvironment -> RequestEnvironment -> Map QualifiedName RequestDefinition
buildRequestDefinitions environment = Map.map convert
  where
    convert information =
      RequestDefinition
        { parameterType = runDenormalize environment (denormalize information.parameterType),
          returnType = runDenormalize environment (denormalize information.returnType),
          parameterGenericIds = Map.map (.genericId) information.genericParameters.parameterInformation,
          marker = information.marker
        }

-- | The open schema, used for the value-addressable wrappers lowering synthesises (a @use@
-- continuation) and as a fallback when a callable's type is somehow unavailable.
openSchema :: SchemaInformation
openSchema = SchemaInformation {input = SchemaAny, output = SchemaAny, requests = [], genericBindings = mempty}

-- | The agent / argument / return / effect parts of a callable's function type, peeling the
-- information-flow attribute (which has no schema meaning).
agentParts :: SemanticType -> Maybe (SemanticType, SemanticType, SemanticEffect)
agentParts = \case
  SemanticTypeAgent parameterType returnType effect -> Just (parameterType, returnType, effect)
  SemanticTypeAttribute baseType _ -> agentParts baseType
  _ -> Nothing

-- | Build a callable's public 'SchemaInformation' from its (denormalized) function type and its
-- generic-parameter bindings.
buildSchemaInformation :: LowerContext -> Map Text GenericId -> SemanticType -> SchemaInformation
buildSchemaInformation context genericBindings functionType =
  case agentParts functionType of
    Just (parameterType, returnType, effect) ->
      SchemaInformation
        { input = Schema.toJSONSchema context.dataDefinitions parameterType,
          output = Schema.toJSONSchema context.dataDefinitions returnType,
          requests = effectRequestSchemas context effect,
          genericBindings = genericBindings
        }
    Nothing -> openSchema {genericBindings = genericBindings}

-- | The callable's schema looked up from the value environment (used for the four signature-determined
-- kinds — data constructor / request / external / primitive — which are always top-level).
callableSchema :: LowerContext -> QualifiedName -> SchemaInformation
callableSchema context qualifiedName = case Map.lookup qualifiedName context.valueEnvironment of
  Just scheme ->
    buildSchemaInformation
      context
      (genericBindingsOfScheme scheme)
      (runDenormalize context.normalizerEnvironment (denormalize scheme.valueType))
  Nothing -> openSchema

-- | Turn an effect into its requests schema: each concrete request becomes a descriptor (its parameter /
-- return type specialised by the request's arguments), each effect-generic a reference. @all@ cannot be
-- enumerated, so it contributes no concrete requests; a marker effect is type-level only and vanishes.
effectRequestSchemas :: LowerContext -> SemanticEffect -> List RequestSchema
effectRequestSchemas context = go
  where
    go = \case
      SemanticEffectPure -> []
      SemanticEffectAny -> []
      -- io is not a request, so it contributes no request schema (it is a type-level IO marker only).
      SemanticEffectIo -> []
      SemanticEffectRequest qualifiedName arguments -> concreteRequest qualifiedName arguments
      SemanticEffectGeneric genericId -> [RequestGeneric genericId]
      SemanticEffectUnion effects -> concatMap go effects
      SemanticEffectOverwrite baseEffect overrides ->
        go baseEffect <> concatMap (uncurry concreteRequest) overrides
    -- A marker effect names no operations, so a row that carries one exposes nothing to the runtime.
    concreteRequest qualifiedName arguments
      | isMarkerRequest context qualifiedName = []
      | otherwise = [RequestConcrete (requestDescriptor context qualifiedName arguments)]

-- | Whether a request name refers to a marker effect declaration (a name absent from the definitions
-- is an ordinary request, matching 'requestDescriptor''s open fallback).
isMarkerRequest :: LowerContext -> QualifiedName -> Bool
isMarkerRequest context qualifiedName = case Map.lookup qualifiedName context.requestDefinitions of
  Just definition -> definition.marker
  Nothing -> False

requestDescriptor :: LowerContext -> QualifiedName -> Map Text SemanticGenericArgument -> RequestDescriptor
requestDescriptor context qualifiedName arguments = case Map.lookup qualifiedName context.requestDefinitions of
  Just definition ->
    let substitution = Schema.buildSubstitution definition.parameterGenericIds arguments
     in RequestDescriptor
          { name = qualifiedName,
            input = Schema.toJSONSchema context.dataDefinitions (substituteGenerics substitution definition.parameterType),
            output = Schema.toJSONSchema context.dataDefinitions (substituteGenerics substitution definition.returnType)
          }
  Nothing -> RequestDescriptor {name = qualifiedName, input = SchemaAny, output = SchemaAny}

-- | The runtime schema of one generic argument at an 'OperationApplyGenerics' site: a type's schema, or
-- an effect's requests. Attribute arguments carry no runtime schema, so they are dropped.
genericArgumentSchema :: LowerContext -> SemanticGenericArgument -> Maybe GenericArgumentSchema
genericArgumentSchema context = \case
  SemanticGenericArgumentType argumentType -> Just (GenericArgumentType (Schema.toJSONSchema context.dataDefinitions argumentType))
  SemanticGenericArgumentEffect argumentEffect -> Just (GenericArgumentRequests (effectRequestSchemas context argumentEffect))
  SemanticGenericArgumentAttribute _ -> Nothing

---------------------------------------------------------------------------------------------------
-- Entry
---------------------------------------------------------------------------------------------------

-- | Lower one typed module to IR. The 'TypeEnvironment' / 'ValueEnvironment' are shared across the
-- program (a referenced callable's schema may live in another module); the emitted IR is otherwise
-- self-contained, with module-local 'BlockId' / 'VariableId' spaces. No lowering diagnostics fire on a
-- clean program (a malformed shape 'panic's), so the diagnostics are always empty. Once every block is
-- built, the drop-insertion pass ("Katari.Lowering.Drop") releases provably-dead temporaries early —
-- it needs the whole module's mentions, so it runs over the finished 'IRModule'.
lowerModule :: TypeEnvironment -> ValueEnvironment -> ModuleName -> AST.Module AST.Typed -> (IRModule, Diagnostics)
lowerModule typeEnvironment valueEnvironment _moduleName module' =
  ( insertDropOperations
      IRModule
        { metadata = currentMetadata,
          blocks = finalState.blockTable,
          entries = finalState.entryTable,
          names = finalState.nameTable
        },
    diagnostics
  )
  where
    normalizerEnvironment =
      SubtypingContext
        { dataEnvironment = typeEnvironment.dataEnvironment,
          requestEnvironment = typeEnvironment.requestEnvironment,
          genericsInScope = mempty,
          world = bottomAttribute
        }
    context =
      LowerContext
        { valueEnvironment = valueEnvironment,
          dataDefinitions = buildDataDefinitions normalizerEnvironment typeEnvironment.dataEnvironment,
          requestDefinitions = buildRequestDefinitions normalizerEnvironment typeEnvironment.requestEnvironment,
          normalizerEnvironment = normalizerEnvironment,
          elaborateContext = typeEnvironment.elaborateContext
        }
    environment =
      LowerEnvironment
        { context = context,
          localVariables = mempty,
          returnTarget = Nothing,
          forTarget = Nothing,
          handleTarget = Nothing
        }
    (_, finalState, diagnostics) = runRWS (mapM_ lowerDeclaration module'.declarations) environment initialLowerState

---------------------------------------------------------------------------------------------------
-- Declarations
---------------------------------------------------------------------------------------------------

lowerDeclaration :: AST.Declaration AST.Typed -> Lower ()
lowerDeclaration = \case
  AST.DeclarationAgent declaration -> do
    let qualifiedName = resolvedQualifiedName declaration.variableReference
    agentBlock <- freshBlockId
    registerEntry qualifiedName agentBlock
    buildAgent
      True
      agentBlock
      declaration.name
      (descriptionOf declaration.annotation)
      (genericBindingsOfDeclaration declaration.genericParameters)
      declaration.typeOf
      declaration.parameters
      declaration.body
  AST.DeclarationData declaration ->
    lowerSignatureCallable declaration.variableReference declaration.name declaration.annotation declaration.parameters $ \input ->
      BlockConstruct Construct {name = resolvedQualifiedName declaration.variableReference, input = input}
  AST.DeclarationRequest declaration ->
    lowerSignatureCallable declaration.variableReference declaration.name declaration.annotation declaration.parameters $ \input ->
      BlockRequest Request {name = resolvedQualifiedName declaration.variableReference, input = input}
  AST.DeclarationExternalAgent declaration ->
    lowerSignatureCallable declaration.variableReference declaration.name declaration.annotation declaration.parameters $ \input ->
      -- The declaration name is the external's sole handle; its rendered qualified name is the opaque
      -- dispatch key the runtime's external handler interprets. The @from "name"@ clause (default @"ffi"@)
      -- names the reactor the call routes to.
      BlockExternal
        External
          { key = renderQualifiedName (resolvedQualifiedName declaration.variableReference),
            input = input,
            reactor = fromMaybe "ffi" declaration.reactor
          }
  AST.DeclarationPrimitiveAgent declaration ->
    lowerSignatureCallable declaration.variableReference declaration.name declaration.annotation declaration.parameters $ \input ->
      -- A primitive's registry key is its fully-qualified name (e.g. @primitive.add@).
      BlockPrimitive Primitive {name = renderQualifiedName (resolvedQualifiedName declaration.variableReference), input = input}
  AST.DeclarationImport _ -> pure ()
  AST.DeclarationTypeSynonym _ -> pure ()
  -- A marker effect is type-level only: nothing to perform, nothing to handle, so it lowers to
  -- nothing at all (and 'effectRequestSchemas' drops it from every requests schema).
  AST.DeclarationMarkerEffect _ -> pure ()
  AST.DeclarationError _ -> pure ()

-- | A declaration's user-facing description: its @\@"..."@ annotation, or empty when undocumented.
descriptionOf :: Maybe Text -> Text
descriptionOf = fromMaybe ""

-- | Lower one of the four signature-determined callables (data constructor / request / external /
-- primitive): a 'BlockAgent' wrapper whose body is the leaf block @makeLeaf@ builds. The leaf reads the
-- whole incoming argument record as its @input@ (seeded under @parameter@); the wrapping agent carries
-- the defaults the runtime fills before the leaf runs ('Agent.defaults').
lowerSignatureCallable ::
  AST.Reference AST.Typed AST.VariableReference ->
  Text ->
  Maybe Text ->
  List (AST.ParameterSignature AST.Typed) ->
  (VariableId -> Block) ->
  Lower ()
lowerSignatureCallable reference name annotation parameters makeLeaf = do
  let qualifiedName = resolvedQualifiedName reference
  agentBlock <- freshBlockId
  registerEntry qualifiedName agentBlock
  inputVariable <- freshVariableId
  let defaults =
        Map.fromList
          [(parameter.name, lowerLiteralValue parameterDefault.value) | parameter <- parameters, Just parameterDefault <- [parameter.defaultValue]]
  leafBlock <- freshBlockId
  recordBlock leafBlock (makeLeaf inputVariable) (Map.singleton "parameter" inputVariable) (Just (name <> ".leaf"))
  context <- asks (.context)
  recordBlock agentBlock (BlockAgent Agent {body = leafBlock, schema = callableSchema context qualifiedName, description = descriptionOf annotation, defaults = defaults}) mempty (Just name)

---------------------------------------------------------------------------------------------------
-- Agents
---------------------------------------------------------------------------------------------------

-- | Build a 'BlockAgent' wrapper at @agentBlock@ over a freshly-allocated body 'Sequence'. The single
-- argument is seeded into the body's scope under @parameter@; each declared parameter is read out of it
-- by label and destructured. @catchesReturn@ distinguishes a real agent (its body's @return@ targets
-- @agentBlock@) from a @use@ continuation (which keeps the enclosing return target).
buildAgent ::
  Bool ->
  BlockId ->
  Text ->
  Text ->
  Map Text GenericId ->
  SemanticType ->
  List (AST.ParameterBinding AST.Typed) ->
  AST.Block AST.Typed ->
  Lower ()
buildAgent catchesReturn agentBlock name description genericBindings functionType parameters body = do
  argumentVariable <- freshVariableId
  (completion, operations) <- withFreshOperations $ do
    parameterLocals <- concat <$> mapM (bindAgentParameter argumentVariable) parameters
    let enter = if catchesReturn then withReturnTarget agentBlock else id
    enter (withLocals parameterLocals (lowerBlockValue body))
  bodyBlock <- freshBlockId
  recordBlock
    bodyBlock
    (BlockSequence Sequence {operations = operations, result = completionResult completion})
    (Map.singleton "parameter" argumentVariable)
    (Just (name <> ".body"))
  context <- asks (.context)
  -- Defaulted parameters are filled by the runtime from 'Agent.defaults' before the body runs, the same
  -- mechanism the signature callables use — so the body simply binds each parameter.
  let defaults =
        Map.fromList
          [(parameter.name, lowerLiteralValue parameterDefault.value) | parameter <- parameters, AST.BindVariable _ _ (Just parameterDefault) <- [parameter.binder]]
  recordBlock agentBlock (BlockAgent Agent {body = bodyBlock, schema = buildSchemaInformation context genericBindings functionType, description = description, defaults = defaults}) mempty (Just name)

-- | Read one declared parameter out of the incoming argument record and bind it, returning the locals
-- it introduces. A plain variable parameter binds the field variable directly; a destructuring
-- parameter is taken apart. Defaults are handled by the runtime via 'Agent.defaults', not here.
bindAgentParameter :: VariableId -> AST.ParameterBinding AST.Typed -> Lower (List (LocalVariableId, VariableId))
bindAgentParameter argumentVariable parameter = do
  fieldVariable <- freshVariableId
  emit (OperationGetField GetFieldOperation {source = argumentVariable, field = parameter.name, output = fieldVariable})
  case parameter.binder of
    AST.BindVariable variableReference _ _ -> pure [(resolvedLocalVariableId variableReference, fieldVariable)]
    AST.BindDestructure pattern -> destructurePattern fieldVariable pattern

---------------------------------------------------------------------------------------------------
-- Blocks, statements
---------------------------------------------------------------------------------------------------

-- | Lower a block's statements and trailing expression into the current operation buffer, threading
-- @let@ / local-agent bindings through the remaining statements, and report how it completed.
lowerBlockValue :: AST.Block AST.Typed -> Lower BlockCompletion
lowerBlockValue block = go block.statements
  where
    go [] = case block.returnExpression of
      Just expression -> CompletedWith . Just <$> lowerExpression expression
      Nothing -> pure (CompletedWith Nothing)
    go (statement : rest) = case statement of
      AST.StatementLet letStatement -> do
        valueVariable <- lowerExpression letStatement.value
        locals <- destructurePattern valueVariable letStatement.pattern
        withLocals locals (go rest)
      AST.StatementAgent agentDeclaration -> do
        let localId = resolvedLocalVariableId agentDeclaration.variableReference
        closureVariable <- freshVariableId
        agentBlock <- freshBlockId
        -- The closure is in scope while its own body is lowered, so a self-reference resolves to it (the
        -- body, as a closure, sees the captured enclosing scope where the closure variable lives).
        withLocals [(localId, closureVariable)] $ do
          buildAgent
            True
            agentBlock
            agentDeclaration.name
            (descriptionOf agentDeclaration.annotation)
            (genericBindingsOfDeclaration agentDeclaration.genericParameters)
            agentDeclaration.typeOf
            agentDeclaration.parameters
            agentDeclaration.body
          emit (OperationMakeClosure MakeClosureOperation {output = closureVariable, agent = agentBlock})
          go rest
      -- A @use@ captures the rest of the block as its continuation, so it is terminal: its result is the
      -- block's value.
      AST.StatementUse useStatement -> CompletedWith . Just <$> lowerUse useStatement
      _ -> do
        exited <- lowerStatement statement
        if exited then pure Exited else go rest

-- | Lower one non-binding statement; 'True' if it transfers control non-locally (so the caller stops).
lowerStatement :: AST.Statement AST.Typed -> Lower Bool
lowerStatement = \case
  AST.StatementReturn statement -> do
    value <- lowerExpression statement.value
    target <- requireReturnTarget
    emit (OperationExit ExitOperation {target = target, value = value})
    pure True
  AST.StatementBreak statement -> do
    value <- lowerExpression statement.value
    target <- requireHandleTarget
    emit (OperationExit ExitOperation {target = target, value = value})
    pure True
  AST.StatementForBreak statement -> do
    value <- lowerExpression statement.value
    target <- requireForTarget
    emit (OperationExit ExitOperation {target = target, value = value})
    pure True
  AST.StatementNext statement -> do
    value <- lowerExpression statement.value
    modifiers <- mapM lowerModifier statement.modifiers
    target <- requireHandleTarget
    emit (OperationContinue ContinueOperation {target = target, value = Just value, modifiers = modifiers})
    pure True
  AST.StatementForNext statement -> do
    value <- lowerExpression statement.value
    modifiers <- mapM lowerModifier statement.modifiers
    target <- requireForTarget
    emit (OperationContinue ContinueOperation {target = target, value = Just value, modifiers = modifiers})
    pure True
  AST.StatementExpression expression -> do
    _ <- lowerExpression expression
    pure False
  -- @finally { ... }@ lowers the body to its own parameterless 'Sequence' block (the finalizer reads
  -- the enclosing scope through the parent chain) and arms it with an 'OperationDefer'. Arming does not
  -- transfer control, so the rest of the block still runs.
  AST.StatementFinally statement -> do
    blockId <- buildBlockSequence statement.body
    emit (OperationDefer DeferOperation {block = blockId})
    pure False
  AST.StatementError _ -> pure False
  AST.StatementLet _ -> panic "lowering: StatementLet must be handled by lowerBlockValue"
  AST.StatementAgent _ -> panic "lowering: StatementAgent must be handled by lowerBlockValue"
  AST.StatementUse _ -> panic "lowering: StatementUse must be handled by lowerBlockValue"

-- | A @with (name = e, ...)@ state update: the state variable in the target's scope paired with the
-- new value here.
lowerModifier :: AST.Modifier AST.Typed -> Lower (VariableId, VariableId)
lowerModifier modifier = do
  newValue <- lowerExpression modifier.value
  stateVariable <- requireLocal (resolvedLocalVariableId modifier.variableReference)
  pure (stateVariable, newValue)

---------------------------------------------------------------------------------------------------
-- Expressions
---------------------------------------------------------------------------------------------------

lowerExpression :: AST.Expression AST.Typed -> Lower VariableId
lowerExpression = \case
  AST.ExpressionLiteral expression -> loadLiteral (lowerLiteralValue expression.value)
  AST.ExpressionVariable expression -> lowerVariableReference expression.variableReference
  AST.ExpressionQualifiedReference expression -> lowerVariableReference expression.variableReference
  AST.ExpressionRecord expression -> lowerRecord expression.entries
  AST.ExpressionTuple expression
    | expression.parallel -> lowerParallel expression.elements
    | otherwise -> lowerTuple expression.elements
  AST.ExpressionCall expression -> lowerCall expression
  AST.ExpressionFieldAccess expression -> do
    object <- lowerExpression expression.object
    readField object expression.fieldName
  AST.ExpressionTypeApplication expression -> lowerTypeApplication expression
  AST.ExpressionTemplate expression -> lowerTemplate expression
  AST.ExpressionIf expression -> lowerIf expression
  AST.ExpressionMatch expression -> lowerMatch expression
  AST.ExpressionFor expression -> lowerFor expression
  AST.ExpressionBlock expression -> lowerBlockExpression expression.block
  AST.ExpressionHandler expression -> lowerHandlerExpression expression
  -- Operators are desugared into primitive calls by the identifier, so they never reach lowering.
  AST.ExpressionBinaryOperator _ -> panic "lowering: binary operator survived past the identifier desugar"
  AST.ExpressionUnaryOperator _ -> panic "lowering: unary operator survived past the identifier desugar"

-- | A local reference is the IR variable holding it; a top-level reference is materialised as a
-- first-class agent value by name (resolved via the module's entries at run time).
lowerVariableReference :: AST.Reference AST.Typed AST.VariableReference -> Lower VariableId
lowerVariableReference reference = case reference.resolution of
  Just (VariableResolutionLocalVariable localId) -> requireLocal localId
  Just (VariableResolutionQualifiedName qualifiedName) -> do
    output <- freshVariableId
    emit (OperationLoadAgent LoadAgentOperation {output = output, name = qualifiedName})
    pure output
  Nothing -> panic "lowering: unresolved variable reference"

loadLiteral :: Literal -> Lower VariableId
loadLiteral literal = do
  output <- freshVariableId
  emit (OperationLoadLiteral LoadLiteralOperation {output = output, value = literal})
  pure output

readField :: VariableId -> Text -> Lower VariableId
readField source field = do
  output <- freshVariableId
  emit (OperationGetField GetFieldOperation {source = source, field = field, output = output})
  pure output

lowerRecord :: List (AST.RecordEntry AST.Typed) -> Lower VariableId
lowerRecord recordEntries = do
  entries <- mapM (\entry -> do value <- lowerExpression entry.value; pure (entry.name, value)) recordEntries
  output <- freshVariableId
  emit (OperationMakeRecord MakeRecordOperation {entries = entries, output = output})
  pure output

lowerTuple :: List (AST.Expression AST.Typed) -> Lower VariableId
lowerTuple elements = do
  variables <- mapM lowerExpression elements
  output <- freshVariableId
  emit (OperationMakeTuple MakeTupleOperation {elements = variables, output = output})
  pure output

-- | @parallel [e1, ...]@: each element runs as its own block, concurrently, results collected in order.
lowerParallel :: List (AST.Expression AST.Typed) -> Lower VariableId
lowerParallel elements = do
  elementBlocks <- mapM buildElementBlock elements
  parallelBlock <- freshBlockId
  recordBlock parallelBlock (BlockParallel ParallelBlock {elements = elementBlocks}) mempty Nothing
  output <- freshVariableId
  emit (OperationCall CallOperation {target = parallelBlock, output = Just output})
  pure output

buildElementBlock :: AST.Expression AST.Typed -> Lower BlockId
buildElementBlock element = do
  (variable, operations) <- withFreshOperations (lowerExpression element)
  blockId <- freshBlockId
  recordBlock blockId (BlockSequence Sequence {operations = operations, result = Just variable}) mempty Nothing
  pure blockId

-- | A call delegates to the callee with the single argument record built from its labelled arguments.
-- The call's inferred generic instantiation (recorded by the checker; an explicit @callee[T]@ rides on
-- the callee value via 'lowerTypeApplication' instead) is stamped onto the delegate as runtime schemas,
-- exactly like an 'OperationApplyGenerics' would carry them. A call with @_@ holes is a partial
-- application: it produces a closure instead of delegating ('lowerPartialApplication').
lowerCall :: AST.CallExpression AST.Typed -> Lower VariableId
lowerCall callExpression = case AST.callArgumentHoles callExpression.arguments of
  [] -> delegateCall callExpression []
  _holes -> lowerPartialApplication callExpression

-- | Delegate a call expression's callee with the argument record built from its labelled arguments
-- joined with any synthetic extra entries — the @use@ statement adds its continuation closure this
-- way, so it emits the exact delegate a directly written call would.
delegateCall :: AST.CallExpression AST.Typed -> List (Text, VariableId) -> Lower VariableId
delegateCall callExpression extraEntries = do
  target <- calleeReference callExpression.callee
  argumentVariable <- buildArgumentRecord callExpression.arguments extraEntries
  context <- asks (.context)
  let generics =
        mapMaybe
          (\(name, argument) -> (,) name <$> genericArgumentSchema context argument)
          (Map.toList callExpression.instantiation)
  output <- freshVariableId
  emit (OperationDelegate DelegateOperation {target = target, argument = argumentVariable, output = Just output, generics = generics})
  pure output

calleeReference :: AST.Expression AST.Typed -> Lower CalleeReference
calleeReference callee = case topLevelCalleeName callee of
  Just qualifiedName -> pure (CalleeName qualifiedName)
  Nothing -> CalleeValue <$> lowerExpression callee

buildArgumentRecord :: List (AST.CallArgument AST.Typed) -> List (Text, VariableId) -> Lower VariableId
buildArgumentRecord arguments extraEntries = do
  entries <- mapM loweredEntry arguments
  output <- freshVariableId
  emit (OperationMakeRecord MakeRecordOperation {entries = entries <> extraEntries, output = output})
  pure output
  where
    loweredEntry argument = case argument.value of
      AST.ArgumentExpression expression -> do
        value <- lowerExpression expression
        pure (argument.name, value)
      -- A holed call lowers through 'lowerPartialApplication' and a @use@ provider rejects holes at
      -- check time; the pipeline gates on a clean check, so a hole here is a compiler bug.
      AST.ArgumentHole _ -> panic "lowering: a `_` hole reached a full call's argument record"

-- | A partial application @f(x = _, y = e)@ produces a CLOSURE over the enclosing scope, not a
-- delegate. Now, in the enclosing scope: the callee is resolved once (a named callee stays a name; a
-- value callee lowers to a captured variable), the supplied argument expressions are evaluated in
-- written order — the same callee-then-arguments order a full call uses — and the supplied fields are
-- built into ONE captured record. Later, when the residual is called: its body merges its own
-- incoming argument record (the hole-labelled parameters) with that captured record via
-- @prelude.record.merge@ (captured values win a shared key) and delegates to the callee. Merging —
-- rather than rebuilding the record field by field — preserves the ABSENCE of an omitted optional
-- hole, so the callee's runtime defaults still fill it. The call site's generic instantiation is
-- stamped on the inner delegate exactly as on a full call's; an explicit @f[T]@ instead rides the
-- captured callee value ('lowerTypeApplication').
lowerPartialApplication :: AST.CallExpression AST.Typed -> Lower VariableId
lowerPartialApplication callExpression = do
  target <- calleeReference callExpression.callee
  suppliedEntries <- concat <$> mapM suppliedEntry callExpression.arguments
  suppliedRecord <- freshVariableId
  emit (OperationMakeRecord MakeRecordOperation {entries = suppliedEntries, output = suppliedRecord})
  context <- asks (.context)
  let generics =
        mapMaybe
          (\(name, argument) -> (,) name <$> genericArgumentSchema context argument)
          (Map.toList callExpression.instantiation)
  argumentVariable <- freshVariableId
  (resultVariable, operations) <- withFreshOperations $ do
    mergeArgument <- freshVariableId
    emit (OperationMakeRecord MakeRecordOperation {entries = [(recordMergeLeftLabel, argumentVariable), (recordMergeRightLabel, suppliedRecord)], output = mergeArgument})
    mergedArgument <- freshVariableId
    emit (OperationDelegate DelegateOperation {target = CalleeName recordMergeName, argument = mergeArgument, output = Just mergedArgument, generics = mempty})
    output <- freshVariableId
    emit (OperationDelegate DelegateOperation {target = target, argument = mergedArgument, output = Just output, generics = generics})
    pure output
  bodyBlock <- freshBlockId
  recordBlock
    bodyBlock
    (BlockSequence Sequence {operations = operations, result = Just resultVariable})
    (Map.singleton "parameter" argumentVariable)
    (Just "partial.body")
  agentBlock <- freshBlockId
  -- The residual's schema comes from the checker's stamped type — the callee's parameter object
  -- restricted to the hole labels — so @get_metadata@ and the delegate boundary see exactly the
  -- parameters that are still open (an optional hole stays optional).
  recordBlock
    agentBlock
    (BlockAgent Agent {body = bodyBlock, schema = buildSchemaInformation context mempty callExpression.typeOf, description = "", defaults = mempty})
    mempty
    (Just "partial")
  closureVariable <- freshVariableId
  emit (OperationMakeClosure MakeClosureOperation {output = closureVariable, agent = agentBlock})
  pure closureVariable
  where
    suppliedEntry argument = case argument.value of
      AST.ArgumentExpression expression -> do
        value <- lowerExpression expression
        pure [(argument.name, value)]
      AST.ArgumentHole _ -> pure []

-- | @callee[args]@: attach the generic substitution to the callee value (for @get_metadata@ schema
-- specialisation). A purely-attribute instantiation has no runtime schema, so it is a pass-through.
lowerTypeApplication :: AST.TypeApplicationExpression AST.Typed -> Lower VariableId
lowerTypeApplication typeApplicationExpression = do
  source <- lowerExpression typeApplicationExpression.callee
  context <- asks (.context)
  let generics =
        mapMaybe
          (\(name, argument) -> (,) name <$> genericArgumentSchema context argument)
          (Map.toList typeApplicationExpression.instantiation)
  case generics of
    [] -> pure source
    _ -> do
      output <- freshVariableId
      emit (OperationApplyGenerics ApplyGenericsOperation {source = source, generics = generics, output = output})
      pure output

-- | A template literal folds its parts with the @primitive.concat@ string concatenation; interpolations
-- are string-typed (the checker enforces it), so no stringification is needed.
lowerTemplate :: AST.TemplateExpression AST.Typed -> Lower VariableId
lowerTemplate templateExpression = do
  parts <- mapM lowerTemplateElement templateExpression.elements
  case parts of
    [] -> loadLiteral (LiteralString "")
    (first : rest) -> foldM concatTemplate first rest

concatTemplate :: VariableId -> VariableId -> Lower VariableId
concatTemplate left right = do
  argumentVariable <- freshVariableId
  emit (OperationMakeRecord MakeRecordOperation {entries = [("left", left), ("right", right)], output = argumentVariable})
  output <- freshVariableId
  emit (OperationDelegate DelegateOperation {target = CalleeName concatName, argument = argumentVariable, output = Just output, generics = mempty})
  pure output
  where
    concatName = QualifiedName {moduleName = preludeModuleName, name = "concat"}

lowerTemplateElement :: AST.TemplateElement AST.Typed -> Lower VariableId
lowerTemplateElement = \case
  AST.TemplateElementString element -> loadLiteral (LiteralString element.value)
  AST.TemplateElementExpression element -> lowerExpression element.value

-- | A standalone @{ ... }@ block in expression position becomes a structural-node 'Sequence' entered in
-- the current scope.
lowerBlockExpression :: AST.Block AST.Typed -> Lower VariableId
lowerBlockExpression block = do
  blockId <- buildBlockSequence block
  output <- freshVariableId
  emit (OperationCall CallOperation {target = blockId, output = Just output})
  pure output

-- | A 'Sequence' block over a source block, entered in (and inheriting) the current scope.
buildBlockSequence :: AST.Block AST.Typed -> Lower BlockId
buildBlockSequence block = do
  (completion, operations) <- withFreshOperations (lowerBlockValue block)
  blockId <- freshBlockId
  recordBlock blockId (BlockSequence Sequence {operations = operations, result = completionResult completion}) mempty Nothing
  pure blockId

-- | A 'Sequence' that yields @null@ — the implicit else of an @if@ without an @else@.
buildNullBlock :: Lower BlockId
buildNullBlock = do
  (variable, operations) <- withFreshOperations (loadLiteral LiteralNull)
  blockId <- freshBlockId
  recordBlock blockId (BlockSequence Sequence {operations = operations, result = Just variable}) mempty Nothing
  pure blockId

---------------------------------------------------------------------------------------------------
-- Control flow: if / match
---------------------------------------------------------------------------------------------------

-- | @if c { ... } else { ... }@ lowers to a 'Match' on the boolean condition: the @true@ literal arm is
-- the then branch; the fallback is the else branch (a @null@ block when omitted).
lowerIf :: AST.IfExpression AST.Typed -> Lower VariableId
lowerIf ifExpression = do
  condition <- lowerExpression ifExpression.condition
  thenBlock <- buildBlockSequence ifExpression.thenBlock
  elseBlock <- maybe buildNullBlock buildBlockSequence ifExpression.elseBlock
  matchBlock <- freshBlockId
  recordBlock
    matchBlock
    (BlockMatch Match {subject = condition, arms = [MatchArm {pattern = PatternLiteral (LiteralBoolean True), body = thenBlock}], fallback = Just elseBlock})
    mempty
    Nothing
  output <- freshVariableId
  emit (OperationCall CallOperation {target = matchBlock, output = Just output})
  pure output

lowerMatch :: AST.MatchExpression AST.Typed -> Lower VariableId
lowerMatch matchExpression = do
  subject <- lowerExpression matchExpression.subject
  arms <- mapM lowerCaseArm matchExpression.cases
  matchBlock <- freshBlockId
  recordBlock matchBlock (BlockMatch Match {subject = subject, arms = arms, fallback = Nothing}) mempty Nothing
  output <- freshVariableId
  emit (OperationCall CallOperation {target = matchBlock, output = Just output})
  pure output

lowerCaseArm :: AST.CaseArm AST.Typed -> Lower MatchArm
lowerCaseArm caseArm = do
  (pattern, locals) <- lowerPattern caseArm.pattern
  body <- buildScopedBlock locals caseArm.body
  pure MatchArm {pattern = pattern, body = body}

-- | A 'Sequence' block with extra locals in scope (a match arm body; the runtime binds the arm's
-- pattern variables into the shared instance scope before running it).
buildScopedBlock :: List (LocalVariableId, VariableId) -> AST.Block AST.Typed -> Lower BlockId
buildScopedBlock locals block = do
  (completion, operations) <- withFreshOperations (withLocals locals (lowerBlockValue block))
  blockId <- freshBlockId
  recordBlock blockId (BlockSequence Sequence {operations = operations, result = completionResult completion}) mempty Nothing
  pure blockId

---------------------------------------------------------------------------------------------------
-- Control flow: for
---------------------------------------------------------------------------------------------------

-- | @[par] for (pattern in source; var s = init) { body } [then (p) { ... }]@. The source and state
-- initialisers evaluate in the outer scope; the body is seeded per iteration with the @iterator@ and the
-- @state_N@s, and collects each @next@ value into the mapped array.
lowerFor :: AST.ForExpression AST.Typed -> Lower VariableId
lowerFor forExpression = do
  forBlock <- freshBlockId
  source <- lowerExpression forExpression.inBinding.source
  (initialStates, stateParameters, stateLocals) <- lowerStateBindings forExpression.varBindings
  body <- buildForBody forBlock forExpression.inBinding.pattern stateParameters stateLocals forExpression.body
  thenClause <- traverse (buildThenClause stateParameters stateLocals) forExpression.thenClause
  recordBlock
    forBlock
    (BlockFor For {parallel = forExpression.parallel, source = source, initialStates = initialStates, body = body, thenClause = thenClause})
    mempty
    Nothing
  output <- freshVariableId
  emit (OperationCall CallOperation {target = forBlock, output = Just output})
  pure output

-- | Lower a list of @var@ state bindings (of a @for@ or a @handle@). Returns the initial-value variables
-- (in the outer scope, for @initialStates@), the @state_N@ -> body-variable parameter entries, and the
-- locals binding each state's resolved identity to its body variable. The body variable is shared
-- between the body, the handlers and the @then@ clause: it is one instance-scope slot holding the
-- current state, re-seeded by @state_N@ on each entry.
lowerStateBindings ::
  List (AST.VariableBinding AST.Typed) ->
  Lower (List VariableId, List (Text, VariableId), List (LocalVariableId, VariableId))
lowerStateBindings bindings = do
  triples <- mapM lowerStateBinding (zip [0 :: Int ..] bindings)
  pure
    ( [initialVariable | (initialVariable, _, _) <- triples],
      [parameterEntry | (_, parameterEntry, _) <- triples],
      [stateLocal | (_, _, stateLocal) <- triples]
    )

lowerStateBinding :: (Int, AST.VariableBinding AST.Typed) -> Lower (VariableId, (Text, VariableId), (LocalVariableId, VariableId))
lowerStateBinding (index, binding) = do
  initialVariable <- lowerExpression binding.initial
  stateVariable <- freshVariableId
  let localId = resolvedLocalVariableId binding.variableReference
  pure (initialVariable, ("state_" <> Text.pack (show index), stateVariable), (localId, stateVariable))

buildForBody ::
  BlockId ->
  AST.Pattern AST.Typed ->
  List (Text, VariableId) ->
  List (LocalVariableId, VariableId) ->
  AST.Block AST.Typed ->
  Lower BlockId
buildForBody forBlock pattern stateParameters stateLocals body = do
  iteratorVariable <- freshVariableId
  (completion, operations) <- withFreshOperations $ do
    -- The element pattern is destructured inside the body so the bind runs against the per-iteration
    -- element value.
    iteratorLocals <- destructurePattern iteratorVariable pattern
    withForTarget forBlock (withLocals (iteratorLocals <> stateLocals) (lowerBlockValue body))
  blockId <- freshBlockId
  recordBlock
    blockId
    (BlockSequence Sequence {operations = operations, result = completionResult completion})
    (Map.fromList (("iterator", iteratorVariable) : stateParameters))
    Nothing
  pure blockId

-- | A @then (p) { body }@ clause (of a @for@ or a @handle@): seeded with the produced value under
-- @result@ and the final @state_N@s, with the state locals in scope.
buildThenClause ::
  List (Text, VariableId) ->
  List (LocalVariableId, VariableId) ->
  AST.ThenClause AST.Typed ->
  Lower ThenClause
buildThenClause stateParameters stateLocals thenClause = do
  resultVariable <- freshVariableId
  (completion, operations) <- withFreshOperations $ do
    binderLocals <- maybe (pure []) (destructurePattern resultVariable) thenClause.binder
    withLocals (stateLocals <> binderLocals) (lowerBlockValue thenClause.body)
  blockId <- freshBlockId
  recordBlock
    blockId
    (BlockSequence Sequence {operations = operations, result = completionResult completion})
    (Map.fromList (("result", resultVariable) : stateParameters))
    Nothing
  pure ThenClause {body = blockId}

---------------------------------------------------------------------------------------------------
-- Control flow: handler / use
---------------------------------------------------------------------------------------------------

-- | A @handler { ... }@ expression lowers to a /provider/ closure: an agent taking the continuation @k@
-- as its argument and running a 'Handle' whose body invokes @k@. Below lowering this is a hand-written
-- @agent provider(k) { handle { k() } with { handlers } then { ... } }@ closed over the definition scope;
-- the type-level @R@ / @E@ generics are erased (dispatch is by request name + value). The provider does
-- not catch @return@ — a @return@ in a @then@ clause is the enclosing agent's, escalating across the
-- delegation boundary.
lowerHandlerExpression :: AST.HandlerExpression AST.Typed -> Lower VariableId
lowerHandlerExpression handlerExpression = do
  providerBlock <- freshBlockId
  argumentVariable <- freshVariableId
  continuationVariable <- freshVariableId
  handleBlock <- freshBlockId
  (handleOutput, operations) <- withFreshOperations $ do
    -- The provider is an ordinary callable, so its argument follows the calling convention its type
    -- declares: a record carrying the continuation under the protocol field @continuation@ (what the
    -- checker types, the schema documents, and the delegate boundary validates). The body reads the
    -- continuation out of it first.
    emit (OperationGetField GetFieldOperation {source = argumentVariable, field = "continuation", output = continuationVariable})
    (initialStates, stateParameters, stateLocals) <- lowerStateBindings handlerExpression.stateVariables
    handleBody <- buildHandleBody continuationVariable stateParameters
    handlers <- withLocals stateLocals (mapM (lowerRequestHandler handleBlock stateParameters stateLocals) handlerExpression.handlers)
    thenClause <- traverse (buildThenClause stateParameters stateLocals) handlerExpression.thenClause
    recordBlock
      handleBlock
      (BlockHandle Handle {parallel = handlerExpression.parallel, initialStates = initialStates, body = handleBody, handlers = handlers, thenClause = thenClause})
      mempty
      Nothing
    output <- freshVariableId
    emit (OperationCall CallOperation {target = handleBlock, output = Just output})
    pure output
  providerBodyBlock <- freshBlockId
  recordBlock
    providerBodyBlock
    (BlockSequence Sequence {operations = operations, result = Just handleOutput})
    (Map.singleton "parameter" argumentVariable)
    (Just "handler.body")
  context <- asks (.context)
  recordBlock providerBlock (BlockAgent Agent {body = providerBodyBlock, schema = providerSchema context handlerExpression.typeOf, description = "", defaults = mempty}) mempty (Just "handler")
  closureVariable <- freshVariableId
  emit (OperationMakeClosure MakeClosureOperation {output = closureVariable, agent = providerBlock})
  pure closureVariable

providerSchema :: LowerContext -> SemanticType -> SchemaInformation
providerSchema context functionType = case agentParts functionType of
  Just _ -> buildSchemaInformation context mempty functionType
  Nothing -> openSchema

-- | The handle body of a synthesised handler provider: invoke the continuation @k@ with the unit
-- argument. State slots are seeded here (under @state_N@) so the handlers and @then@ clause observe the
-- initial state.
buildHandleBody :: VariableId -> List (Text, VariableId) -> Lower BlockId
buildHandleBody continuationVariable stateParameters = do
  argumentVariable <- freshVariableId
  resultVariable <- freshVariableId
  let operations =
        [ OperationMakeRecord MakeRecordOperation {entries = [], output = argumentVariable},
          OperationDelegate DelegateOperation {target = CalleeValue continuationVariable, argument = argumentVariable, output = Just resultVariable, generics = mempty}
        ]
  blockId <- freshBlockId
  recordBlock blockId (BlockSequence Sequence {operations = operations, result = Just resultVariable}) (Map.fromList stateParameters) Nothing
  pure blockId

-- | One request handler. Its body is seeded with the request argument under @parameter@ and the current
-- @state_N@s; on normal completion its tail value is the implicit @next@ (resume) — it rides on the
-- block's @result@ and the runtime treats the body's fall-through as a @next@, mirroring a @for@ body.
-- An explicit @break@ inside (which 'Exited') exits the whole handle instead.
lowerRequestHandler ::
  BlockId ->
  List (Text, VariableId) ->
  List (LocalVariableId, VariableId) ->
  AST.RequestHandler AST.Typed ->
  Lower Handler
lowerRequestHandler handleBlock stateParameters stateLocals requestHandler = do
  -- The ambient @panic@ clause is undeclared, so its reference never resolves; lower it to the wired-in
  -- @prelude.panic@ name directly (recognized structurally, as in the checker), rather than reading a
  -- resolution that is not there.
  let requestName =
        if isNothing requestHandler.moduleQualifier && requestHandler.name == panicRequestName.name
          then panicRequestName
          else resolvedRequestName requestHandler.typeReference
  argumentVariable <- freshVariableId
  (completion, operations) <- withFreshOperations $ do
    parameterLocals <- concat <$> mapM (bindAgentParameter argumentVariable) requestHandler.parameters
    withHandlerContext handleBlock (withLocals (parameterLocals <> stateLocals) (lowerBlockValue requestHandler.body))
  blockId <- freshBlockId
  recordBlock
    blockId
    (BlockSequence Sequence {operations = operations, result = completionResult completion})
    (Map.fromList (("parameter", argumentVariable) : stateParameters))
    Nothing
  pure Handler {request = requestName, body = blockId}

-- | @(let p =)? use provider@: the rest of the block (already captured as the use's body) becomes a
-- continuation closure whose argument binds @p@; the provider is then delegated that closure. The
-- continuation keeps the enclosing jump targets — a @return@ inside it unwinds to the agent that wrote
-- the @use@, across the delegation boundary.
lowerUse :: AST.UseStatement AST.Typed -> Lower VariableId
lowerUse useStatement = do
  continuationBlock <- freshBlockId
  argumentVariable <- freshVariableId
  (completion, operations) <- withFreshOperations $ do
    -- The continuation is called with the protocol record @{value: A}@ (see the checker's
    -- 'continuationAgentType'); the binder binds the @value@ FIELD, not the whole protocol record.
    binderLocals <- case useStatement.binder of
      Nothing -> pure []
      Just binderPattern -> do
        valueVariable <- freshVariableId
        emit (OperationGetField GetFieldOperation {source = argumentVariable, field = "value", output = valueVariable})
        destructurePattern valueVariable binderPattern
    withLocals binderLocals (lowerBlockValue useStatement.body)
  continuationBodyBlock <- freshBlockId
  recordBlock
    continuationBodyBlock
    (BlockSequence Sequence {operations = operations, result = completionResult completion})
    (Map.singleton "parameter" argumentVariable)
    (Just "use.continuation.body")
  recordBlock continuationBlock (BlockAgent Agent {body = continuationBodyBlock, schema = openSchema, description = "", defaults = mempty}) mempty (Just "use.continuation")
  closureVariable <- freshVariableId
  emit (OperationMakeClosure MakeClosureOperation {output = closureVariable, agent = continuationBlock})
  -- The checker types every provider as ONE application (a bare provider is wrapped into its
  -- zero-written-argument call), so the callee was checked against the written arguments joined
  -- with the continuation and the same joined record is delegated here — @use p(x = 1)@ emits
  -- exactly the delegate of @p(x = 1, continuation = <closure>)@ (generics stamped and all).
  case useStatement.provider of
    AST.ExpressionCall callExpression ->
      delegateCall callExpression [("continuation", closureVariable)]
    _ -> panic "lowering: a typed `use` provider is always a call (the checker normalizes bare providers)"

---------------------------------------------------------------------------------------------------
-- Patterns
---------------------------------------------------------------------------------------------------

-- | Irrefutably destructure @source@ by the pattern (exhaustiveness guaranteed by the checker), emitting
-- the bind and returning the locals it introduces.
destructurePattern :: VariableId -> AST.Pattern AST.Typed -> Lower (List (LocalVariableId, VariableId))
destructurePattern source pattern = do
  (irPattern, locals) <- lowerPattern pattern
  emit (OperationBindPattern BindPatternOperation {source = source, pattern = irPattern})
  pure locals

-- | Translate an AST pattern to its IR form and the @(resolved local, fresh IR variable)@ bindings every
-- variable sub-pattern introduces (the runtime binds the matched sub-values into them).
lowerPattern :: AST.Pattern AST.Typed -> Lower (Pattern, List (LocalVariableId, VariableId))
lowerPattern = \case
  AST.PatternVariable variablePattern -> do
    let localId = resolvedLocalVariableId variablePattern.variableReference
    variable <- freshVariableId
    pure (PatternVariable variable, [(localId, variable)])
  AST.PatternWildcard _ -> pure (PatternAny, [])
  AST.PatternLiteral literalPattern -> pure (PatternLiteral (lowerLiteralValue literalPattern.value), [])
  AST.PatternTuple tuplePattern -> do
    results <- mapM lowerPattern tuplePattern.elements
    pure (PatternTuple (map fst results), concatMap snd results)
  AST.PatternRecord recordPattern -> do
    results <- mapM lowerFieldPattern recordPattern.fields
    pure (PatternRecord (map fst results), concatMap snd results)
  AST.PatternConstructor constructorPattern -> do
    let qualifiedName = resolvedQualifiedName constructorPattern.constructorReference
    results <- mapM lowerFieldPattern constructorPattern.fields
    pure (PatternConstructor qualifiedName (map fst results), concatMap snd results)
  AST.PatternTypeFilter typeFilterPattern -> do
    (innerPattern, locals) <- lowerPattern typeFilterPattern.inner
    pure (PatternTypeGuard (filterTypeTag typeFilterPattern.matchedType) innerPattern, locals)

lowerFieldPattern :: AST.FieldPattern AST.Typed -> Lower ((Text, Pattern), List (LocalVariableId, VariableId))
lowerFieldPattern fieldPattern = do
  (subPattern, locals) <- lowerPattern fieldPattern.bindPattern
  pure ((fieldPattern.name, subPattern), locals)

-- | The runtime tag a @tag(pattern)@ type filter narrows on — a direct mapping of the (already
-- runtime-shaped) 'AST.TypeFilter'. @array@ covers tuples, @record@ covers objects / records / data.
filterTypeTag :: AST.TypeFilter -> TypeTag
filterTypeTag = \case
  AST.FilterNull -> TagNull
  AST.FilterBoolean -> TagBoolean
  AST.FilterInteger -> TagInteger
  AST.FilterNumber -> TagNumber
  AST.FilterString -> TagString
  AST.FilterFile -> TagFile
  AST.FilterArray -> TagArray
  AST.FilterRecord -> TagRecord
  AST.FilterAgent -> TagAgent
