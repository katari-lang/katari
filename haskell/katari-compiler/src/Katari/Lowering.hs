-- | Lower Zonked AST to 'IRModule'.
--
-- See doc/ir-design (or equivalent) / plan for the design overview. This
-- module takes the Zonked-phase AST as input and returns an 'IRModule'
-- with type information discarded.
--
-- Pipeline:
--
--   1. registerPrimitives — assign BlockIds to primitive names
--   2. registerDeclarationKinds — reserve a kind/BlockId for the
--      VariableId of every declaration
--   3. lowerAllDeclarations — lower the body of each declaration
module Katari.Lowering
  ( lowerProgram,
    LoweringError (..),
    toDiagnostic,
  )
where

import Control.Monad (foldM, forM, mapAndUnzipM)
import Control.Monad.Except (ExceptT, runExceptT, throwError)
import Control.Monad.Reader (ReaderT, asks, local, runReaderT)
import Control.Monad.State.Strict (State, gets, modify, runState)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word32)
import Katari.AST (Phase (Zonked))
import Katari.AST qualified as AST
import Katari.Diagnostic (Diagnostic, diagnosticError)
import Katari.IR
import Katari.Id (VariableId)
import Katari.Id qualified as Id
import Katari.Internal qualified as Internal
import Katari.Schema qualified as Schema
import Katari.SemanticType (Resolved, SemanticType (..))
import Katari.SourceSpan (SourceSpan)
import Katari.Typechecker.Identifier (ConstructorData (..), IdentifierResult (..), RequestData (..))
import Katari.Typechecker.Zonker (ZonkResult (..))

-- ===========================================================================
-- Errors
-- ===========================================================================

-- | Errors raised by the Lowering pass. These are reserved for cases
-- where a sentinel from an upstream phase (parser recovery, unresolved
-- identifier) makes it as far as Lowering despite the pipeline's
-- gating; in a clean compile run no 'LoweringError' should ever fire.
-- Converted to a K0300-series 'Diagnostic' via 'toDiagnostic'.
data LoweringError where
  -- | Encountered a 'IdentifiedUnresolvedVariable' / 'Nothing'
  -- (parser/identifier produced a sentinel; cannot lower).
  LoweringErrorUnresolvedVariable :: SourceSpan -> Text -> LoweringError
  -- | A 'StatementError' / 'DeclarationError' sentinel left by parser
  -- recovery survived to Lowering.
  LoweringErrorParseSentinel :: SourceSpan -> LoweringError
  deriving (Eq, Show)

-- | Convert a 'LoweringError' to a unified 'Diagnostic'. Codes K0300-K0399
-- are reserved for the lowering pass.
toDiagnostic :: LoweringError -> Diagnostic
toDiagnostic = \case
  LoweringErrorUnresolvedVariable sourceSpan name ->
    diagnosticError
      "K0300"
      ("unresolved variable in lowering: '" <> name <> "'")
      sourceSpan
  LoweringErrorParseSentinel sourceSpan ->
    diagnosticError
      "K0301"
      "parser/identifier sentinel reached lowering (likely a recovery artifact)"
      sourceSpan

-- ===========================================================================
-- Primitive table
-- ===========================================================================
--
-- All prim definitions and operator-name mappings live in 'Katari.Prim'.
-- Lowering allocates one 'BlockPrim' block per prim and indexes them by
-- the prim's pre-allocated 'VariableId' so call-site resolution flows
-- through the standard top-level callable path.

-- ===========================================================================
-- Lowering monad
--
-- 'Lower' is @ReaderT LowerEnv (State LowerState)@.
--
--   * 'LowerEnv' carries only scope-local information. Since @local@
--     transparently saves/restores it, no @bindLocal@ + hand-written
--     restorer is required.
--   * 'LowerState' carries cumulative information (allocator counters /
--     accumulated block table / errors) plus the "statements of the block
--     currently being built" (@lsCurrentEmitted@). Statements are
--     accumulated in reverse order and reversed once in O(n) when the
--     block is finalized (@runWithFreshBuffer@).
-- ===========================================================================

data LowerEnv = LowerEnv
  { -- | Local bindings: @VariableId → IR's VarId@ introduced by @let@ /
    -- function param / pattern / local agent. Top-level callable
    -- resolution uses 'lsTopLevelBlocks' separately.
    localVars :: Map VariableId VarId,
    -- | Identifier-pass output. Lowering needs the symbol tables
    -- (@identifiedRequests@ / @identifiedConstructors@) for both id
    -- enumeration (IR.RequestId/IR.ConstructorId allocation) and call-site reverse lookup.
    identifierResult :: IdentifierResult,
    -- | Zonker-pass output. Lowering reads
    -- 'zonkedTypeEnvironment' at each agent / wrapper construction site
    -- to compute the per-agent input/output JSON Schemas for
    -- 'AgentBlock'.
    zonkResult :: ZonkResult,
    -- | Pre-built 'DataDefs' for inline expansion of 'SemanticTypeData'
    -- references when computing 'AgentBlock' schemas. Built once at
    -- 'lowerProgram' entry from 'zonkResult'.
    dataDefs :: Schema.DataDefs,
    -- | Inverse of 'identifierResult.identifiedRequests', precomputed once
    -- at 'lowerProgram' entry so per-call-site lookups are O(log n) rather
    -- than O(n).
    requestByVariable :: Map VariableId Id.RequestId,
    -- | Inverse of 'identifierResult.identifiedConstructors'. See above.
    constructorByVariable :: Map VariableId Id.ConstructorId
  }

initialLowerEnv :: IdentifierResult -> ZonkResult -> LowerEnv
initialLowerEnv idResult zonk =
  LowerEnv
    { localVars = Map.empty,
      identifierResult = idResult,
      zonkResult = zonk,
      dataDefs = Schema.buildDataDefs idResult zonk,
      requestByVariable =
        Map.fromList
          [ (requestData.requestVariableId, requestId)
            | (requestId, requestData) <- Map.toList idResult.identifiedRequests
          ],
      constructorByVariable =
        Map.fromList
          [ (constructorData.constructorVariableId, constructorId)
            | (constructorId, constructorData) <- Map.toList idResult.identifiedConstructors
          ]
    }

data LowerState = LowerState
  { lsNextBlockId :: Word32,
    lsNextVarId :: Word32,
    lsBlocks :: Map BlockId Block,
    lsVarNames :: Map VarId Text,
    lsBlockNames :: Map BlockId Text,
    -- | Top-level @VariableId@ → its callable @BlockId@. Used at call /
    -- closure sites to resolve agent / req / ext-agent / data-ctor names.
    lsTopLevelBlocks :: Map VariableId BlockId,
    -- | Top-level @VariableId@ → its 'QualifiedName' for every top-level
    -- callable (agent / req / external / data ctor / prim). When a
    -- callable name is referenced as a value (e.g. @return foo@,
    -- @let f = foo@, @foo()@), Lowering looks up the qualified name here
    -- and emits 'StatementLoadLiteral' carrying a 'LiteralValueAgent'.
    -- The runtime treats all such values uniformly: dispatch is by
    -- 'IRModule.entries' lookup of the qualified name.
    lsTopLevelQNames :: Map VariableId QualifiedName,
    -- | FFI translation table: qualified name → BlockId. Populated as
    -- top-level callables are registered; surfaces in
    -- 'IRModule.entries'.
    lsEntries :: Map QualifiedName BlockId,
    -- | Prim bare name → leaf 'BlockPrim' 'BlockId'. Populated when a
    -- 'DeclarationPrimAgent' is lowered; read by 'primBlockId' for
    -- compiler-internal desugar sites that emit direct 'StatementCall'
    -- to a prim leaf (e.g. @get_field@ for field access).
    lsPrimBlockIds :: Map Text BlockId,
    -- | Statements for the block currently being lowered, stored in
    -- reverse order. 'emit' prepends; 'runWithFreshBuffer' saves/restores
    -- and reverses at the end.
    lsCurrentEmitted :: [Statement],
    lsErrors :: [LoweringError]
  }

initialLowerState :: LowerState
initialLowerState =
  LowerState
    { lsNextBlockId = 0,
      lsNextVarId = 0,
      lsBlocks = Map.empty,
      lsVarNames = Map.empty,
      lsBlockNames = Map.empty,
      lsTopLevelBlocks = Map.empty,
      lsTopLevelQNames = Map.empty,
      lsEntries = Map.empty,
      lsPrimBlockIds = Map.empty,
      lsCurrentEmitted = [],
      lsErrors = []
    }

-- | Lowering monad. The 'ExceptT' layer carries 'K9999' invariant
-- violations from 'Katari.Internal' so they reach 'compile' as
-- diagnostics rather than as a bare 'error' panic. Most call sites
-- never encounter it; the few that do (e.g. unresolved 'BlockId'
-- lookups for an upstream-bug shape of the AST) abort the current
-- 'lowerProgram' invocation cleanly.
type Lower = ExceptT Diagnostic (ReaderT LowerEnv (State LowerState))

freshBlockId :: Lower BlockId
freshBlockId = do
  blockId <- gets (BlockId . (.lsNextBlockId))
  modify (\state -> state {lsNextBlockId = state.lsNextBlockId + 1})
  pure blockId

freshVarId :: Maybe Text -> Lower VarId
freshVarId hint = do
  varId <- gets (VarId . (.lsNextVarId))
  modify
    ( \state ->
        state
          { lsNextVarId = state.lsNextVarId + 1,
            lsVarNames = case hint of
              Just name -> Map.insert varId name state.lsVarNames
              Nothing -> state.lsVarNames
          }
    )
  pure varId

recordBlock :: BlockId -> Block -> Maybe Text -> Lower ()
recordBlock blockId block name =
  modify
    ( \s ->
        s
          { lsBlocks = Map.insert blockId block s.lsBlocks,
            lsBlockNames = case name of
              Just n -> Map.insert blockId n s.lsBlockNames
              Nothing -> s.lsBlockNames
          }
    )

reserveBlockId :: Maybe Text -> Lower BlockId
reserveBlockId name = do
  blockId <- freshBlockId
  case name of
    Just n -> modify (\state -> state {lsBlockNames = Map.insert blockId n state.lsBlockNames})
    Nothing -> pure ()
  pure blockId

recordError :: LoweringError -> Lower ()
recordError err = modify (\state -> state {lsErrors = err : state.lsErrors})

-- | Run an action with additional local variable bindings in scope. Uses
-- 'ReaderT' 'local' so cleanup is automatic — no manual restorer chain.
withLocals :: [(VariableId, VarId)] -> Lower a -> Lower a
withLocals binds = local $ \env ->
  env {localVars = Map.union (Map.fromList binds) env.localVars}

-- | Look up a local variable id in the current scope.
lookupLocal :: VariableId -> Lower (Maybe VarId)
lookupLocal variableId = asks (Map.lookup variableId . (.localVars))

-- ===========================================================================
-- Variable resolution
-- ===========================================================================

-- | Outcome of resolving a variable reference. An error has already been
-- recorded via 'recordError' before 'ResolvedVarUnresolved' is returned.
data ResolvedVar where
  ResolvedVarLocal :: VarId -> ResolvedVar
  ResolvedVarTopLevel :: BlockId -> ResolvedVar
  ResolvedVarUnresolved :: ResolvedVar

-- | Resolve a 'NameRefResolution' to a 'ResolvedVar'. Consults the local Reader
-- scope first (if @canBeLocal@), then the top-level block id map.
resolveVariable ::
  Bool ->
  AST.NameRefResolution Zonked AST.VariableRef ->
  SourceSpan ->
  Text ->
  Lower ResolvedVar
resolveVariable canBeLocal resolution sourceSpan nameText = case resolution of
  Nothing -> do
    recordError (LoweringErrorUnresolvedVariable sourceSpan nameText)
    pure ResolvedVarUnresolved
  Just variableId -> do
    mLocal <- if canBeLocal then lookupLocal variableId else pure Nothing
    case mLocal of
      Just irVar -> pure (ResolvedVarLocal irVar)
      Nothing -> do
        maybeBlockId <- gets (Map.lookup variableId . (.lsTopLevelBlocks))
        case maybeBlockId of
          Just blockId -> pure (ResolvedVarTopLevel blockId)
          Nothing -> do
            recordError (LoweringErrorUnresolvedVariable sourceSpan nameText)
            pure ResolvedVarUnresolved

-- | Resolve a variable reference in 'value' context: locals pass through,
-- top-level callables emit a 'StatementLoadLiteral' carrying a
-- 'LiteralValueAgent' (the qualified name of the callable). The runtime
-- resolves the qualified name to a 'BlockId' via 'IRModule.entries' on
-- dispatch — top-level callables therefore carry no captured scope.
-- 'StatementMakeClosure' is reserved for local-agent (closure) creation.
resolveAsValue ::
  Bool ->
  AST.NameRefResolution Zonked AST.VariableRef ->
  SourceSpan ->
  Text ->
  Maybe Text ->
  Lower VarId
resolveAsValue canBeLocal resolution sourceSpan nameText hint = do
  resolved <- resolveVariable canBeLocal resolution sourceSpan nameText
  case resolved of
    ResolvedVarLocal irVar -> pure irVar
    ResolvedVarTopLevel _blockId -> do
      qname <- topLevelQNameForResolution resolution sourceSpan nameText
      v <- freshVarId hint
      emit (StatementLoadLiteral LoadLiteralData {output = v, value = LiteralValueAgent qname})
      pure v
    ResolvedVarUnresolved -> freshVarId Nothing

-- | Look up the 'QualifiedName' of a top-level callable resolved to a
-- 'VariableId'. Invoked from 'resolveAsValue' after a successful
-- 'ResolvedVarTopLevel'; a missing entry indicates an upstream
-- registration bug (every top-level callable should appear in
-- 'lsTopLevelQNames' via 'recordTopLevelCallable' or 'registerPrimitives').
topLevelQNameForResolution ::
  AST.NameRefResolution Zonked AST.VariableRef ->
  SourceSpan ->
  Text ->
  Lower QualifiedName
topLevelQNameForResolution resolution sourceSpan nameText =
  case resolution of
    Just variableId -> do
      mQname <- gets (Map.lookup variableId . (.lsTopLevelQNames))
      case mQname of
        Just qname -> pure qname
        Nothing ->
          throwError
            ( Internal.internalError
                sourceSpan
                ("topLevelQNameForResolution: top-level callable '" <> nameText <> "' missing from lsTopLevelQNames")
            )
    Nothing ->
      throwError
        ( Internal.internalError
            sourceSpan
            ("topLevelQNameForResolution: callable '" <> nameText <> "' has no resolution but resolved to a top-level block")
        )

-- | Resolve a root-prim name to its 'BlockId'. Used by lowering sites
-- that emit prim calls directly (template / field-access / index-access
-- desugaring), as opposed to call-syntax that flows through the standard
-- callable path. A missing entry means the prim name is not registered
-- in 'Katari.Prim.primDefinitions' — compiler invariant violation.
primBlockId :: Text -> Lower BlockId
primBlockId name = do
  leaves <- gets (.lsPrimBlockIds)
  case Map.lookup name leaves of
    Just blockId -> pure blockId
    Nothing ->
      throwError
        ( Internal.internalErrorNoSpan
            ("primBlockId: unknown primitive '" <> name <> "' — stdlib not loaded or prim agent missing")
        )

-- ===========================================================================
-- Statement buffer (implicit via 'lsCurrentEmitted')
-- ===========================================================================

-- | Append a statement to the current block's emit buffer. Statements are
-- stored in reverse order in 'lsCurrentEmitted' for O(1) prepend; the
-- final list is reversed once when the block boundary is reached
-- ('runWithFreshBuffer').
emit :: Statement -> Lower ()
emit s = modify (\st -> st {lsCurrentEmitted = s : st.lsCurrentEmitted})

-- | Run an action with a fresh empty emit buffer; on completion, restore
-- the parent's buffer and return both the action's result and the
-- forward-ordered list of statements emitted during the action. Used at
-- block boundaries (e.g. when lowering an inline block / arm body).
runWithFreshBuffer :: Lower a -> Lower (a, [Statement])
runWithFreshBuffer action = do
  prev <- gets (.lsCurrentEmitted)
  modify (\st -> st {lsCurrentEmitted = []})
  result <- action
  emitted <- gets (.lsCurrentEmitted)
  modify (\st -> st {lsCurrentEmitted = prev})
  pure (result, reverse emitted)

-- ===========================================================================
-- Schema computation helpers
-- ===========================================================================

-- | Compute the @(inputSchema, outputSchema)@ text pair for an agent /
-- wrapper whose function type is recorded under @variableId@ in the
-- zonked type environment.
--
-- @labelsAndAnnotations@ supplies the surface-level annotation for each
-- parameter (so the generated JSON Schema can surface
-- @\@\"...\"@ docstrings to AI tool-calling consumers). On a missing or
-- non-function lookup we degrade to the open-schema placeholder
-- @("{}", "{}")@: the Zonker should produce a function type for every
-- callable, but a few synthetic agents (locals not yet in the
-- environment, error recovery) might land here without one.
schemasForVariable ::
  VariableId ->
  [(Text, Maybe Text)] ->
  Lower (Text, Text)
schemasForVariable variableId labelsAndAnnotations = do
  zr <- asks (.zonkResult)
  case Map.lookup variableId zr.zonkedTypeEnvironment of
    Just functionType -> schemasForFunctionType functionType labelsAndAnnotations
    Nothing -> pure ("{}", "{}")

-- | Direct variant of 'schemasForVariable' for call sites that already
-- hold the resolved function type (e.g. prim wrappers, which read it
-- straight from 'Katari.Prim.primDefinitions').
schemasForFunctionType ::
  SemanticType Resolved ->
  [(Text, Maybe Text)] ->
  Lower (Text, Text)
schemasForFunctionType functionType labelsAndAnnotations = do
  dd <- asks (.dataDefs)
  case functionType of
    SemanticTypeFunction paramTypes returnType _ ->
      pure
        ( Schema.jsonSchemaToText
            (Schema.buildInputObject dd paramTypes labelsAndAnnotations),
          Schema.jsonSchemaToText (Schema.buildOutputSchema dd returnType)
        )
    _ -> pure ("{}", "{}")

-- ===========================================================================
-- UserBlock default template
-- ===========================================================================

-- | Empty 'UserBlock' template. The 5 different roles a block plays
-- (agent entry / agent-with-handlers / handle scope / handler body / inline
-- block) used to inline several lines of record syntax each; now they
-- record-update only the fields they care about.
defaultUserBlock :: UserBlock
defaultUserBlock =
  UserBlock
    { parameters = [],
      statements = [],
      trailing = Nothing
    }

-- ===========================================================================
-- Entry
-- ===========================================================================

-- | Lower a 'ZonkResult' to an 'IRModule'.
--
-- The 'Either' carries an internal-error 'Diagnostic' (K9999) when an
-- invariant from an upstream phase is violated; the second component is
-- the list of structural lowering errors encountered along the way.
-- Structural errors do not abort the pipeline (the IR may be partial),
-- but an internal-error short-circuits early.
lowerProgram ::
  IdentifierResult ->
  ZonkResult ->
  (Either Diagnostic IRModule, [LoweringError])
lowerProgram idResult zonk =
  let (result, finalState) =
        runState
          (runReaderT (runExceptT (lowerProgramM zonk)) (initialLowerEnv idResult zonk))
          initialLowerState
   in (result, reverse finalState.lsErrors)

lowerProgramM :: ZonkResult -> Lower IRModule
lowerProgramM zonkResult = do
  registerDeclarationKinds zonkResult
  _ <- lowerAllDeclarations zonkResult
  state <- gets id
  pure
    IRModule
      { metadata = currentIRMetadata,
        blocks = state.lsBlocks,
        entries = state.lsEntries,
        nameTable =
          NameTable
            { varNames = state.lsVarNames,
              blockNames = state.lsBlockNames
            }
      }

-- | Write a 'BlockAgent' wrapper at a pre-reserved 'BlockId' for a
-- non-agent leaf (BlockPrim / BlockConstructor / BlockRequest / BlockDelegate
-- for external).
--
-- Mirrors the 2-phase shape used for 'DeclarationAgent': Phase 1
-- ('registerDeclarationKinds' / 'registerPrimitives') reserves the
-- @agentBlk@ slot and registers it in 'lsEntries' / 'lsTopLevelBlocks';
-- Phase 2 (this function) writes the 'BlockAgent' at @agentBlk@ whose
-- 'entryBody' points directly at the leaf block. The runtime's
-- 'AgentThread' spawns the leaf with the args passed by label; no
-- intermediate 'BlockUser' is needed because all leaf threads
-- (PrimThread / CtorThread / RequestThread / DelegateThread) consume
-- 'callArgs' by label directly.
--
-- This way the runtime only ever spawns 'AgentThread' for delegate
-- roots — leaf threads stay leaves.
writeWrapperAgent ::
  BlockId ->
  QualifiedName ->
  [Text] ->
  BlockId ->
  Text ->
  Text ->
  Maybe Text ->
  Text ->
  Text ->
  Lower ()
writeWrapperAgent agentBlk qname paramLabels innerBlk hint simpleName desc inputSchemaJson outputSchemaJson = do
  paramVars <- mapM (\_ -> freshVarId Nothing) paramLabels
  let wrapperParams = zipWith Param paramLabels paramVars
  recordBlock
    agentBlk
    ( BlockAgent
        AgentBlock
          { qualifiedName = qname,
            parameters = wrapperParams,
            entryBody = innerBlk,
            name = simpleName,
            description = desc,
            inputSchema = inputSchemaJson,
            outputSchema = outputSchemaJson
          }
    )
    (Just (hint <> ":agent"))

-- | Bind a top-level @VariableId@ to its callable @BlockId@.
recordVarBlockId :: VariableId -> BlockId -> Lower ()
recordVarBlockId variableId blockId =
  modify (\state -> state {lsTopLevelBlocks = Map.insert variableId blockId state.lsTopLevelBlocks})

-- Closure capture for local agents is handled by the runtime: a local
-- agent's body block runs with the parent scope visible (the runtime
-- consults a scope chain when resolving locals). Lowering therefore
-- preserves the outer 'localVars' Reader frame when entering a local
-- agent's body, and emits no per-block capture metadata. This is sound
-- because agent-side references to a state var read its current value
-- (state vars are only mutated inside @req@ handlers via @next@, which
-- a local agent cannot do without entering a different scope).

-- | Run @action@ with the resolved 'VariableId' from a top-level callable
-- declaration name. If the name didn't resolve (parser/identifier left an
-- 'Nothing' marker), record a Lowering error and skip.
registerCallable ::
  AST.NameRef Zonked AST.VariableRef ->
  SourceSpan ->
  (VariableId -> Lower ()) ->
  Lower ()
registerCallable nameRef sourceSpan action = case nameRef.resolution of
  Just variableId -> action variableId
  Nothing -> recordError (LoweringErrorUnresolvedVariable sourceSpan nameRef.text)

-- | Build the runtime dispatch name for a primitive declaration. Prims
-- in the root @primitive@ module keep their bare name (e.g. @to_string@,
-- @add@); prims in sub-modules @primitive.json@ / @primitive.record@
-- get a user-visible qualified name (@json.parse@, @record.get@) so the
-- runtime's @executePrim@ dispatch can route by namespace.
primDispatchName :: Text -> Text -> Text
primDispatchName moduleName declName =
  case Text.stripPrefix "primitive." moduleName of
    Just suffix -> suffix <> "." <> declName
    Nothing -> declName

-- | Walk all declarations, registering each top-level agent / req / ext /
-- ctor's @VariableId → BlockId@ mapping. Bodies are filled in by
-- 'lowerAllDeclarations'.
--
-- The current module's name is threaded through so that 'BlockExternal'
-- entries can be stamped with @(moduleName, name)@ — that pair is how the
-- runtime sidecar will look up the JS implementation. The @\@"..."@
-- annotation on the declaration is documentation only and is dropped here
-- (it surfaces in the Schema layer instead, Phase 11).
registerDeclarationKinds :: ZonkResult -> Lower ()
registerDeclarationKinds zonkResult =
  mapM_ registerModule (Map.toList zonkResult.zonkedModules)
  where
    registerModule (moduleId, m) = do
      moduleName <- case Map.lookup moduleId zonkResult.zonkedModuleNames of
        Just name -> pure name
        Nothing ->
          throwError $
            Internal.internalErrorNoSpan
              "registerDeclarationKinds: ModuleId not in zonkedModuleNames (internal invariant violated)"
      mapM_ (registerDecl moduleName) m.declarations

    registerDecl :: Text -> AST.Declaration Zonked -> Lower ()
    registerDecl moduleName = \case
      AST.DeclarationAgent decl ->
        registerCallable decl.name decl.sourceSpan $ \variableId -> do
          blockId <- reserveBlockId (Just decl.name.text)
          recordTopLevelCallable variableId moduleName decl.name.text blockId
      AST.DeclarationRequest decl ->
        registerCallable decl.name decl.sourceSpan $ \variableId -> do
          -- Phase 1: reserve the wrapper agent slot only. The inner
          -- 'BlockRequest' leaf + wrapping body are built in Phase 2
          -- ('lowerAllDeclarations'). The wrapper makes a req
          -- indistinguishable from prim / ext / ctor at the call site:
          -- @statementAgentCall(literalValueAgent "module.req")@ spawns
          -- the wrapper, whose body fires the request via a child
          -- 'statementCall' targeting the leaf.
          agentBlk <- reserveBlockId (Just decl.name.text)
          recordTopLevelCallable variableId moduleName decl.name.text agentBlk
      AST.DeclarationExternalAgent decl ->
        registerCallable decl.name decl.sourceSpan $ \variableId -> do
          -- Phase 1: reserve the wrapper agent slot only. The inner
          -- 'BlockExternal' leaf + wrapping body are built in Phase 2
          -- ('lowerAllDeclarations').
          agentBlk <- reserveBlockId (Just decl.name.text)
          recordTopLevelCallable variableId moduleName decl.name.text agentBlk
      AST.DeclarationPrimAgent decl ->
        registerCallable decl.name decl.sourceSpan $ \variableId -> do
          -- Phase 1: reserve the wrapper agent slot AND eagerly create
          -- the inner 'BlockPrim' leaf. The leaf must exist before any
          -- user agent body's lowering, since compile-internal desugar
          -- sites (e.g. field access → 'get_field') look it up by bare
          -- name via 'primBlockId'.
          --
          -- Sub-module qualification: prims declared inside
          -- @primitive.json@ / @primitive.record@ etc. are dispatched
          -- on the runtime by their user-visible qualified name
          -- (@json.parse@, @record.get@, …). The root @primitive@
          -- module keeps bare names so internal desugar sites
          -- (@get_field@, arithmetic) stay unchanged.
          let primName = primDispatchName moduleName decl.name.text
          agentBlk <- reserveBlockId (Just decl.name.text)
          leafBlk <- freshBlockId
          recordBlock
            leafBlk
            (BlockPrim primName)
            (Just ("prim:" <> primName <> ":leaf"))
          modify $ \state ->
            state {lsPrimBlockIds = Map.insert primName leafBlk state.lsPrimBlockIds}
          recordTopLevelCallable variableId moduleName decl.name.text agentBlk
      AST.DeclarationData decl ->
        registerCallable decl.name decl.sourceSpan $ \variableId -> do
          -- Phase 1: reserve the wrapper agent slot only. The inner
          -- 'BlockConstructor' leaf + wrapping body are built in
          -- Phase 2 ('lowerAllDeclarations').
          agentBlk <- reserveBlockId (Just decl.name.text)
          recordTopLevelCallable variableId moduleName decl.name.text agentBlk
      AST.DeclarationImport _ -> pure ()
      AST.DeclarationTypeSynonym _ -> pure ()
      AST.DeclarationError sourceSpan -> recordError (LoweringErrorParseSentinel sourceSpan)

    -- \| Register a top-level callable: bind the @VariableId@ to its
    -- @BlockId@, record its 'QualifiedName' for value-side dispatch, and
    -- expose it in 'IRModule.entries' for FFI lookup.
    recordTopLevelCallable :: VariableId -> Text -> Text -> BlockId -> Lower ()
    recordTopLevelCallable variableId moduleName_ declName blockId = do
      let qualifiedName = QualifiedName {module_ = moduleName_, name = declName}
      recordVarBlockId variableId blockId
      modify $ \state ->
        state
          { lsEntries = Map.insert qualifiedName blockId state.lsEntries,
            lsTopLevelQNames = Map.insert variableId qualifiedName state.lsTopLevelQNames
          }

lowerAllDeclarations :: ZonkResult -> Lower (Map Text BlockId)
lowerAllDeclarations zonkResult = do
  pairs <- concat <$> mapM lowerModule (Map.toList zonkResult.zonkedModules)
  pure (Map.fromList pairs)
  where
    lowerModule (moduleId, m) = do
      moduleName <- case Map.lookup moduleId zonkResult.zonkedModuleNames of
        Just name -> pure name
        Nothing ->
          throwError $
            Internal.internalErrorNoSpan
              "lowerAllDeclarations: ModuleId not in zonkedModuleNames"
      catMaybes <$> mapM (lowerDeclaration moduleName) m.declarations

    lowerDeclaration :: Text -> AST.Declaration Zonked -> Lower (Maybe (Text, BlockId))
    lowerDeclaration moduleName = \case
      AST.DeclarationAgent decl -> resolveDecl decl.name $ \_variableId blockId -> do
        lowerAgentDeclaration decl blockId
        pure (Just (decl.name.text, blockId))
      AST.DeclarationData decl -> resolveDecl decl.name $ \variableId agentBlk -> do
        qname <- requireAgentQName "DeclarationData" decl.name.text agentBlk
        let paramLabels = map (.name) decl.parameters
            labelsAndAnnotations =
              [(dataParameter.name, dataParameter.annotation) | dataParameter <- decl.parameters]
        ctorQName <- lookupConstructorQName variableId
        innerBlk <- freshBlockId
        recordBlock innerBlk (BlockConstructor ctorQName) (Just (decl.name.text <> ":ctor"))
        (inputSchema, outputSchema) <- schemasForVariable variableId labelsAndAnnotations
        writeWrapperAgent
          agentBlk
          qname
          paramLabels
          innerBlk
          decl.name.text
          decl.name.text
          decl.annotation
          inputSchema
          outputSchema
        pure (Just (decl.name.text, agentBlk))
      AST.DeclarationExternalAgent decl -> resolveDecl decl.name $ \variableId agentBlk -> do
        qname <- requireAgentQName "DeclarationExternalAgent" decl.name.text agentBlk
        let paramLabels = map (.label) decl.parameters
            labelsAndAnnotations = [(pb.label, pb.annotation) | pb <- decl.parameters]
            externalDispatch =
              ExternalDispatch
                { endpoint = decl.endpoint,
                  dispatchName = decl.dispatchName
                }
        innerBlk <- freshBlockId
        recordBlock
          innerBlk
          (BlockDelegate DelegateBlock {target = DelegateTargetExternal externalDispatch})
          (Just (decl.name.text <> ":external"))
        (inputSchema, outputSchema) <- schemasForVariable variableId labelsAndAnnotations
        writeWrapperAgent
          agentBlk
          qname
          paramLabels
          innerBlk
          decl.name.text
          decl.name.text
          decl.annotation
          inputSchema
          outputSchema
        pure (Just (decl.name.text, agentBlk))
      AST.DeclarationRequest decl -> resolveDecl decl.name $ \variableId agentBlk -> do
        qname <- requireAgentQName "DeclarationRequest" decl.name.text agentBlk
        let paramLabels = map (.label) decl.parameters
            labelsAndAnnotations = [(pb.label, pb.annotation) | pb <- decl.parameters]
        reqQName <- lookupRequestQName variableId
        innerBlk <- freshBlockId
        recordBlock innerBlk (BlockRequest reqQName) (Just (decl.name.text <> ":request"))
        (inputSchema, outputSchema) <- schemasForVariable variableId labelsAndAnnotations
        writeWrapperAgent
          agentBlk
          qname
          paramLabels
          innerBlk
          decl.name.text
          decl.name.text
          decl.annotation
          inputSchema
          outputSchema
        pure (Just (decl.name.text, agentBlk))
      AST.DeclarationPrimAgent decl -> resolveDecl decl.name $ \variableId agentBlk -> do
        qname <- requireAgentQName "DeclarationPrimAgent" decl.name.text agentBlk
        let paramLabels = map (.label) decl.parameters
            labelsAndAnnotations = [(pb.label, pb.annotation) | pb <- decl.parameters]
            primName = primDispatchName moduleName decl.name.text
        -- The leaf was pre-registered in 'registerDeclarationKinds' so any
        -- user agent's body could resolve compile-internal prim calls
        -- (e.g. @get_field@) regardless of declaration order. Sub-module
        -- prims are keyed by their qualified dispatch name (e.g.
        -- @json.parse@) so that root prims like @get_field@ stay
        -- collision-free with same-tail names in sub-modules.
        innerBlk <-
          gets (Map.lookup primName . (.lsPrimBlockIds)) >>= \case
            Just b -> pure b
            Nothing ->
              throwError
                ( Internal.internalErrorNoSpan
                    ("DeclarationPrimAgent: leaf for '" <> primName <> "' missing from lsPrimBlockIds")
                )
        (inputSchema, outputSchema) <- schemasForVariable variableId labelsAndAnnotations
        writeWrapperAgent
          agentBlk
          qname
          paramLabels
          innerBlk
          ("prim:" <> decl.name.text)
          decl.name.text
          decl.annotation
          inputSchema
          outputSchema
        pure (Just (decl.name.text, agentBlk))
      _ -> pure Nothing

    -- Look up the (already reserved) wrapper agent 'BlockId' for a
    -- declaration's name and run the per-kind body builder.
    resolveDecl ::
      AST.NameRef Zonked AST.VariableRef ->
      (VariableId -> BlockId -> Lower (Maybe (Text, BlockId))) ->
      Lower (Maybe (Text, BlockId))
    resolveDecl nameRef action = case nameRef.resolution of
      Just variableId -> do
        maybeBlockId <- gets (Map.lookup variableId . (.lsTopLevelBlocks))
        case maybeBlockId of
          Just blockId -> action variableId blockId
          Nothing -> pure Nothing
      Nothing -> pure Nothing

    -- Phase 1 invariant: every reserved agent slot has exactly one
    -- 'lsEntries' entry pointing at it (registered by
    -- 'recordTopLevelCallable' / 'registerPrimitives').
    requireAgentQName :: Text -> Text -> BlockId -> Lower QualifiedName
    requireAgentQName ctx declName agentBlk = do
      entries <- gets (.lsEntries)
      case [qn | (qn, bid) <- Map.toList entries, bid == agentBlk] of
        (qn : _) -> pure qn
        [] ->
          throwError
            ( Internal.internalErrorNoSpan
                (ctx <> ": '" <> declName <> "' agent slot not in lsEntries")
            )

    lookupConstructorQName :: VariableId -> Lower QualifiedName
    lookupConstructorQName variableId = do
      inverse <- asks (.constructorByVariable)
      idResult <- asks (.identifierResult)
      case Map.lookup variableId inverse of
        Just identCid ->
          case Map.lookup identCid idResult.identifiedConstructors of
            Just cd -> pure cd.constructorQualifiedName
            Nothing ->
              throwError
                ( Internal.internalErrorNoSpan
                    "lookupConstructorQName: ConstructorId not in identifiedConstructors"
                )
        Nothing ->
          throwError
            ( Internal.internalErrorNoSpan
                "lookupConstructorQName: VariableId not in constructorByVariable"
            )

    -- \| Look up the request 'QualifiedName' stamped on a @req@ declaration's
    -- 'BlockRequest' leaf. Mirrors 'lookupConstructorQName' for the data /
    -- ctor side.
    lookupRequestQName :: VariableId -> Lower QualifiedName
    lookupRequestQName variableId = do
      inverse <- asks (.requestByVariable)
      idResult <- asks (.identifierResult)
      case Map.lookup variableId inverse of
        Just requestId ->
          case Map.lookup requestId idResult.identifiedRequests of
            Just rd -> pure rd.requestQualifiedName
            Nothing ->
              throwError
                ( Internal.internalErrorNoSpan
                    "lookupRequestQName: RequestId not in identifiedRequests"
                )
        Nothing ->
          throwError
            ( Internal.internalErrorNoSpan
                "lookupRequestQName: VariableId not in requestByVariable"
            )

-- ===========================================================================
-- Agent declaration
-- ===========================================================================

-- | Lower a top-level 'AgentDeclaration' into the reserved BlockId.
-- Produces a 'BlockAgent' wrapper that catches @return@ and references
-- an inner 'BlockUser' body.
lowerAgentDeclaration :: AST.AgentDeclaration Zonked -> BlockId -> Lower ()
lowerAgentDeclaration decl =
  lowerAgentLike
    decl.name.text
    decl.name.resolution
    decl.annotation
    decl.parameters
    decl.body

-- | Shared lowering shape for any \"agent-like\" callable: a top-level
-- 'AgentDeclaration', or a local 'AgentStatement'. Allocates param
-- slots, threads param destructuring as a prelude, and builds the
-- agent block (with its precomputed metadata).
--
-- @variableId@ is consulted in 'zonkedTypeEnvironment' to fetch the
-- function type used to generate the input/output JSON Schemas embedded
-- in the resulting 'AgentBlock'. @description@ is the @\@\"...\"@
-- annotation on the declaration (top-level agents already carry one;
-- local agents will once Phase 1.6 lands).
lowerAgentLike ::
  Text ->
  Maybe VariableId ->
  Maybe Text ->
  [AST.ParameterBinding Zonked] ->
  AST.Block Zonked ->
  BlockId ->
  Lower ()
lowerAgentLike name mVariableId description parameters body blockId = do
  paramBindings <- mapM bindParam parameters
  let paramVars = map fst paramBindings
      paramPrelude = combineParamPreludes (map snd paramBindings)
      labelsAndAnnotations = [(pb.label, pb.annotation) | pb <- parameters]
  (inputSchema, outputSchema) <- case mVariableId of
    Just variableId -> schemasForVariable variableId labelsAndAnnotations
    Nothing -> pure ("{}", "{}")
  lowerSimpleAgent
    blockId
    name
    paramVars
    paramPrelude
    body
    description
    inputSchema
    outputSchema

-- | Plain agent (no @where@). Emits a 'BlockAgent' wrapper at @blockId@ that
-- references an inner 'BlockUser' holding the actual body statements.
-- The runtime spawns an AgentThread for @blockId@; the AgentThread
-- spawns the inner UserThread on create.
--
-- The @prelude@ runs inside the inner block's buffer so any parameter
-- destructuring is emitted before the body proper.
--
-- @description@ / @inputSchema@ / @outputSchema@ are precomputed by the
-- caller and embedded verbatim in 'AgentBlock', so @get_metadata@ at
-- runtime can return them without re-deriving from the type.
lowerSimpleAgent ::
  BlockId ->
  Text ->
  [Param] ->
  Lower [(VariableId, VarId)] ->
  AST.Block Zonked ->
  Maybe Text ->
  Text ->
  Text ->
  Lower ()
lowerSimpleAgent blockId name paramVars prelude blk description inputSchema outputSchema = do
  (trailing, statements) <- runWithFreshBuffer $ do
    locals <- prelude
    withLocals locals (lowerBlockInto blk)
  -- Allocate the inner BlockUser body, then wrap it in a BlockAgent at
  -- @blockId@ (the externally-callable id).
  bodyBlockId <- freshBlockId
  let bodyBlock =
        defaultUserBlock
          { parameters = paramVars,
            statements = statements,
            trailing = trailing
          }
  recordBlock bodyBlockId (BlockUser bodyBlock) (Just (name <> ".body"))
  -- Resolve qualifiedName by reverse-lookup of the wrapper blockId in
  -- lsEntries (top-level agents are pre-registered with their qname).
  -- Local / nested agents use a synthetic name; the runtime never reads
  -- AgentBlock.qualifiedName for dispatch, only for debug output.
  entries <- gets (.lsEntries)
  let qname = case findQNameForBlock blockId entries of
        Just qn -> qn
        Nothing -> QualifiedName "<local>" name
      agent =
        AgentBlock
          { qualifiedName = qname,
            parameters = paramVars,
            entryBody = bodyBlockId,
            name = name,
            description = description,
            inputSchema = inputSchema,
            outputSchema = outputSchema
          }
  recordBlock blockId (BlockAgent agent) (Just name)
  where
    findQNameForBlock :: BlockId -> Map QualifiedName BlockId -> Maybe QualifiedName
    findQNameForBlock target entries =
      case [qn | (qn, bid) <- Map.toList entries, bid == target] of
        (qn : _) -> Just qn
        [] -> Nothing

-- | Lower a 'RequestHandler' to a 'BlockUser'. The handler body inherits
-- the handle scope (state vars are directly accessible). Only req args
-- are passed via 'parameters'. The body's trailing value is treated as
-- an implicit @break@; an explicit 'StatementExit ExitKindBreak' is
-- appended if the body completes normally.
--
-- @stateLocals@ is the @(VariableId, VarId)@ map already in scope via
-- 'withLocals'; it is passed here only so the caller's intent is explicit.
lowerHandler :: [(VariableId, VarId)] -> AST.RequestHandler Zonked -> Lower Handler
lowerHandler _stateLocals hr = do
  reqQName <- case hr.name.resolution of
    Just identRequestId -> do
      idResult <- asks (.identifierResult)
      case Map.lookup identRequestId idResult.identifiedRequests of
        Just rd -> pure rd.requestQualifiedName
        Nothing -> do
          recordError (LoweringErrorUnresolvedVariable hr.sourceSpan hr.name.text)
          pure (QualifiedName "<unresolved>" hr.name.text)
    Nothing -> do
      recordError (LoweringErrorUnresolvedVariable hr.sourceSpan hr.name.text)
      pure (QualifiedName "<unresolved>" hr.name.text)
  bodyBlockId <- freshBlockId
  paramBindings <- mapM bindParam hr.parameters
  let reqParamVars = map fst paramBindings
      paramPrelude = combineParamPreludes (map snd paramBindings)
  (trailing, statements) <- runWithFreshBuffer $ do
    locals <- paramPrelude
    withLocals locals (lowerBlockInto hr.body)
  let lastIsExit = case reverse statements of
        (StatementExit {} : _) -> True
        _ -> False
      finalStatements = case trailing of
        Just t
          | not lastIsExit ->
              statements ++ [StatementExit ExitData {exitKind = ExitKindBreak, value = t}]
        _ -> statements
      userBlock =
        defaultUserBlock
          { parameters = reqParamVars,
            statements = finalStatements
          }
  recordBlock bodyBlockId (BlockUser userBlock) (Just hr.name.text)
  pure Handler {request = reqQName, handlerBody = bodyBlockId}

-- | Lower the optional then-clause to its own block.
lowerThenClause ::
  Maybe (Maybe (AST.Pattern Zonked), AST.Block Zonked) ->
  Lower (Maybe BlockId)
lowerThenClause = \case
  Nothing -> pure Nothing
  Just (mpat, blk) -> do
    blockId <- freshBlockId
    -- The then block receives the body's tail as a single param. If the user
    -- wrote @then(p) { ... }@ we bind the pattern; otherwise we just use
    -- a wildcard.
    (paramVar, paramLocals) <- case mpat of
      Just pat -> bindPatternToFreshVar pat (Just "value")
      Nothing -> do
        v <- freshVarId (Just "value")
        pure (v, [])
    withLocals paramLocals $ do
      (statements, trailing) <- lowerBlockBody blk
      let userBlock =
            defaultUserBlock
              { parameters = [Param {label = "value", var = paramVar}],
                statements = statements,
                trailing = trailing
              }
      recordBlock blockId (BlockUser userBlock) Nothing
    pure (Just blockId)

-- | Bind a function parameter: allocate the param's IR var (the slot the
-- runtime populates) and return a deferred destructuring action.
--
-- The 'Param' is allocated immediately so callers can install the agent /
-- handler signature before the body runs. The 'Lower' action — to be run
-- inside the body's statement buffer — emits any 'tuple_get' / 'get_field'
-- projections needed for non-variable patterns and returns the
-- @(VariableId, VarId)@ pairs introduced.
bindParam :: AST.ParameterBinding Zonked -> Lower (Param, Lower [(VariableId, VarId)])
bindParam pb = do
  let nameHint = case pb.pattern of
        AST.PatternVariable vp -> Just vp.name.text
        _ -> Just pb.label
  var <- freshVarId nameHint
  pure (Param {label = pb.label, var = var}, destructurePattern var pb.pattern)

-- | Compose multiple parameter destructuring actions into a single
-- prelude that can be threaded into a body buffer.
combineParamPreludes :: [Lower [(VariableId, VarId)]] -> Lower [(VariableId, VarId)]
combineParamPreludes acts = concat <$> sequence acts

-- | Allocate a fresh IR var for an incoming value and destructure it by
-- emitting a single 'StatementBindPattern'. Returns the fresh 'VarId' and the
-- '(VariableId, VarId)' pairs to add to the local scope.
--
-- Irrefutability is guaranteed upstream by the Maranget exhaustiveness
-- checker (K0291); callers do not need to guard against refutable patterns.
bindPatternToFreshVar :: AST.Pattern Zonked -> Maybe Text -> Lower (VarId, [(VariableId, VarId)])
bindPatternToFreshVar pat hint = do
  let nameHint = case pat of
        AST.PatternVariable vp -> Just vp.name.text
        _ -> hint
  var <- freshVarId nameHint
  locals <- destructurePattern var pat
  pure (var, locals)

-- | Emit a 'StatementBindPattern' that destructures @incoming@ according to the
-- given AST pattern. Returns the '(VariableId, VarId)' pairs for all
-- variable sub-patterns; the runtime walks the pattern tree at execution time.
--
-- Irrefutability (no unguarded literal patterns) is guaranteed by the
-- Maranget exhaustiveness checker (K0291) before lowering runs.
destructurePattern :: VarId -> AST.Pattern Zonked -> Lower [(VariableId, VarId)]
destructurePattern incoming pat = do
  (matchPattern, locals) <- lowerPattern pat
  emit (StatementBindPattern BindPatternData {source = incoming, pattern = matchPattern})
  pure locals

-- ===========================================================================
-- Block body
-- ===========================================================================

-- | Lower a 'AST.Block' (statements + returnExpression) into a fresh
-- buffer. Returns the emitted statements and the optional trailing var
-- (the value of the block's tail expression, if any).
--
-- @let@ statements need to bring their bindings into scope for the
-- statements that follow. We thread that via 'withLocals' here rather
-- than letting 'lowerStmt' mutate the environment, which keeps the
-- 'ReaderT' contract intact (no @local-then-throw-away@ tricks).
lowerBlockBody :: AST.Block Zonked -> Lower ([Statement], Maybe VarId)
lowerBlockBody blk = do
  (trailing, statements) <- runWithFreshBuffer (lowerBlockInto blk)
  pure (statements, trailing)

-- | Lower a 'AST.Block''s contents into the *current* statement buffer.
-- Unlike 'lowerBlockBody' this does not allocate a fresh buffer — the
-- caller is responsible for the surrounding 'runWithFreshBuffer' (and
-- any 'withLocals') so prelude statements (e.g. match-arm destructuring)
-- can be emitted into the same buffer first.
lowerBlockInto :: AST.Block Zonked -> Lower (Maybe VarId)
lowerBlockInto blk = go blk.statements
  where
    go [] = traverse lowerExpr blk.returnExpression
    go (AST.StatementLet ls : rest) = do
      v <- lowerExpr ls.value
      locals <- bindPatternLocals v ls.pattern
      withLocals locals (go rest)
    go (AST.StatementAgent stmt : rest) = case stmt.name.resolution of
      Nothing -> do
        recordError (LoweringErrorUnresolvedVariable stmt.sourceSpan stmt.name.text)
        go rest
      Just variableId -> do
        blockId <- freshBlockId
        var <- freshVarId (Just stmt.name.text)
        withLocals [(variableId, var)] $ do
          lowerAgentLike
            stmt.name.text
            (Just variableId)
            stmt.annotation
            stmt.parameters
            stmt.body
            blockId
          emit (StatementMakeClosure MakeClosureData {output = var, block = blockId})
          go rest
    go (stmt : rest) = do
      exited <- lowerStmt stmt
      if exited then pure Nothing else go rest

-- ===========================================================================
-- Statements
-- ===========================================================================

-- | Lower one non-let, non-agent 'AST.Statement'. Statements are emitted
-- into the current buffer. Returns 'True' if this statement causes a
-- non-local exit (return/break/etc.) so the caller can stop emitting
-- further code.
--
-- 'StatementLet' and 'StatementAgent' are peeled off before reaching
-- this dispatch by 'lowerBlockInto.go', so both arms here are
-- 'internalError' guards.
lowerStmt :: AST.Statement Zonked -> Lower Bool
lowerStmt = \case
  AST.StatementLet _ ->
    throwError (Internal.internalErrorNoSpan "lowerStmt: StatementLet must be peeled by lowerBlockInto")
  AST.StatementReturn stmt -> do
    var <- lowerExpr stmt.value
    emit (StatementExit ExitData {exitKind = ExitKindReturn, value = var})
    pure True
  AST.StatementBreak stmt -> do
    var <- lowerExpr stmt.value
    emit (StatementExit ExitData {exitKind = ExitKindBreak, value = var})
    pure True
  AST.StatementForBreak stmt -> do
    var <- lowerExpr stmt.value
    emit (StatementExit ExitData {exitKind = ExitKindForBreak, value = var})
    pure True
  AST.StatementNext stmt -> do
    var <- lowerExpr stmt.value
    modPairs <- mapM lowerModifier stmt.modifiers
    emit (StatementCont ContData {contKind = ContKindNext, value = Just var, modifiers = modPairs})
    pure True
  AST.StatementForNext stmt -> do
    modPairs <- mapM lowerModifier stmt.modifiers
    emit (StatementCont ContData {contKind = ContKindForNext, value = Nothing, modifiers = modPairs})
    pure True
  AST.StatementExpression expr -> do
    _ <- lowerExpr expr
    pure False
  AST.StatementAgent _ ->
    throwError (Internal.internalErrorNoSpan "lowerStmt: StatementAgent must be peeled by lowerBlockInto")
  AST.StatementError sourceSpan -> do
    recordError (LoweringErrorParseSentinel sourceSpan)
    pure False

-- | Lower one 'AST.Modifier' producing @(targetVar, newValueVar)@.
-- 'targetVar' is the state var's VarId in the enclosing loop/handle scope,
-- resolved via 'lookupLocal' using the Modifier's 'VariableId'.
lowerModifier :: AST.Modifier Zonked -> Lower (VarId, VarId)
lowerModifier m = do
  newValue <- lowerExpr m.value
  targetVar <- case m.name.resolution of
    Just variableId -> do
      mLocal <- lookupLocal variableId
      case mLocal of
        Just v -> pure v
        Nothing -> do
          recordError (LoweringErrorUnresolvedVariable m.sourceSpan m.name.text)
          freshVarId Nothing
    Nothing -> do
      recordError (LoweringErrorUnresolvedVariable m.sourceSpan m.name.text)
      freshVarId Nothing
  pure (targetVar, newValue)

-- | Emit a 'StatementBindPattern' for an incoming IR var and return the
-- '(VariableId, VarId)' pairs to bring into scope via 'withLocals'.
bindPatternLocals :: VarId -> AST.Pattern Zonked -> Lower [(VariableId, VarId)]
bindPatternLocals = destructurePattern

-- ===========================================================================
-- Expressions
-- ===========================================================================

-- | Lower an 'AST.Expression'. Returns the IR var holding the value;
-- statements are emitted into the current buffer.
lowerExpr :: AST.Expression Zonked -> Lower VarId
lowerExpr = \case
  AST.ExpressionLiteral lit -> lowerLiteral lit
  AST.ExpressionVariable variableExpression -> lowerVariable variableExpression
  -- The Identifier pass desugars binary / unary operator expressions
  -- into prim calls (e.g. @a + b@ → @add(lhs=a, rhs=b)@). Surviving
  -- operator nodes here indicate an upstream invariant violation.
  AST.ExpressionBinaryOperator binaryExpr ->
    throwError
      ( Internal.internalError
          binaryExpr.sourceSpan
          "Lowering: BinaryOperator survived past Identifier desugar"
      )
  AST.ExpressionUnaryOperator unaryExpr ->
    throwError
      ( Internal.internalError
          unaryExpr.sourceSpan
          "Lowering: UnaryOperator survived past Identifier desugar"
      )
  AST.ExpressionCall callExpr -> lowerCall callExpr
  AST.ExpressionTuple tupleExpr -> lowerTupleExpr False tupleExpr.elements
  AST.ExpressionArray arrayExpr -> lowerArrayExpr False arrayExpr.elements
  AST.ExpressionRecord recordExpr -> lowerRecordExpr recordExpr.entries
  AST.ExpressionFieldAccess fieldAccessExpr -> do
    object <- lowerExpr fieldAccessExpr.object
    -- Field name is loaded as a string literal; get_field consumes
    -- (object, field).
    fieldVar <- emitLoadLiteral (LiteralValueString fieldAccessExpr.fieldName.text)
    out <- freshVarId Nothing
    blockId <- primBlockId "get_field"
    emit $
      StatementCall
        CallData
          { block = blockId,
            arguments = [Arg "object" object, Arg "field" fieldVar],
            output = Just out
          }
    pure out
  AST.ExpressionIndexAccess indexAccessExpr -> do
    array <- lowerExpr indexAccessExpr.array
    index <- lowerExpr indexAccessExpr.index
    out <- freshVarId Nothing
    blockId <- primBlockId "array_get"
    emit $
      StatementCall
        CallData
          { block = blockId,
            arguments = [Arg "array" array, Arg "index" index],
            output = Just out
          }
    pure out
  AST.ExpressionTemplate templateExpr -> lowerTemplate templateExpr
  AST.ExpressionBlock blockExpr -> lowerBlockExpr blockExpr
  AST.ExpressionIf ifExpr -> lowerIfExpr ifExpr
  AST.ExpressionMatch matchExpr -> lowerMatchExpr matchExpr
  AST.ExpressionFor forExpr -> lowerForExpr forExpr
  AST.ExpressionHandle handleExpr -> lowerHandleExpr handleExpr
  AST.ExpressionParTuple parTupleExpr -> lowerTupleExpr True parTupleExpr.elements
  AST.ExpressionParArray parArrayExpr -> lowerArrayExpr True parArrayExpr.elements
  AST.ExpressionQualifiedReference qualifiedRefExpr ->
    -- Qualified references never bind locally.
    resolveAsValue
      False
      qualifiedRefExpr.target.resolution
      qualifiedRefExpr.sourceSpan
      qualifiedRefExpr.target.text
      (Just qualifiedRefExpr.target.text)

-- | Lower a function call. The callee is always evaluated to a value
-- (an @agentLiteral@ for top-level callables, a @closure@ for local
-- agents, or whatever an arbitrary expression produces); we allocate a
-- per-call-site 'BlockDelegate' whose 'DelegateTargetValue' carries the
-- callee 'VarId', and emit a regular 'StatementCall' targeting it. The
-- runtime spawns a 'DelegateThread' that resolves the value at create
-- time (agentLiteral qname → internal/external lookup; closure → CORE
-- loopback with captured scope).
--
-- Inline (structural) block invocations — @match@ arms, @for@ bodies,
-- @where@ scopes, etc. — are emitted by their respective lowering
-- helpers, not by this path.
lowerCall :: AST.CallExpression Zonked -> Lower VarId
lowerCall callExpression = do
  argVars <- mapM (lowerExpr . (.value)) callExpression.arguments
  let callArgs = zipWith Arg (map (.label.text) callExpression.arguments) argVars
  calleeVar <- lowerExpr callExpression.callee
  delegateBlk <- freshBlockId
  recordBlock
    delegateBlk
    (BlockDelegate DelegateBlock {target = DelegateTargetValue calleeVar})
    Nothing
  out <- freshVarId Nothing
  emit
    ( StatementCall
        CallData {block = delegateBlk, arguments = callArgs, output = Just out}
    )
  pure out

-- | Lower an 'AST.TemplateExpression' as a left-fold of @concat@ prim
-- calls.
lowerTemplate :: AST.TemplateExpression Zonked -> Lower VarId
lowerTemplate templateExpression = do
  vars <- mapM lowerTemplateElement templateExpression.elements
  case vars of
    [] -> emitLoadLiteral (LiteralValueString "")
    [single] -> stringify single
    (first : rest) -> do
      initVar <- stringify first
      foldM concatStep initVar rest
  where
    stringify v = do
      blockId <- primBlockId "format"
      out <- freshVarId Nothing
      emit $
        StatementCall
          CallData
            { block = blockId,
              arguments = [Arg "value" v],
              output = Just out
            }
      pure out

    concatStep lhs rhsRaw = do
      rhs <- stringify rhsRaw
      blockId <- primBlockId "concat"
      out <- freshVarId Nothing
      emit $
        StatementCall
          CallData
            { block = blockId,
              arguments = [Arg "lhs" lhs, Arg "rhs" rhs],
              output = Just out
            }
      pure out

lowerTemplateElement :: AST.TemplateElement Zonked -> Lower VarId
lowerTemplateElement = \case
  AST.TemplateElementString tse -> emitLoadLiteral (LiteralValueString tse.value)
  AST.TemplateElementExpression tee -> lowerExpr tee.value

-- ===========================================================================
-- Inline block / control-flow expressions
-- ===========================================================================

-- | Lower an inline block expression @{ stmts; tail }@. We create a child
-- 'UserBlock' (kind = 'BlockInline', so it shares the parent's scope) and
-- emit a static call to it.
lowerBlockExpr :: AST.BlockExpression Zonked -> Lower VarId
lowerBlockExpr blockExpression = do
  childBlockId <- buildInlineBlock blockExpression.block
  out <- freshVarId Nothing
  emit $
    StatementCall
      CallData
        { block = childBlockId,
          arguments = [],
          output = Just out
        }
  pure out

-- | Build an inline block (inheritScope=True, no boundary catches) and return
-- its newly minted BlockId.
buildInlineBlock :: AST.Block Zonked -> Lower BlockId
buildInlineBlock blk = do
  blockId <- freshBlockId
  (statements, trailing) <- lowerBlockBody blk
  let userBlock =
        defaultUserBlock
          { statements = statements,
            trailing = trailing
          }
  recordBlock blockId (BlockUser userBlock) Nothing
  pure blockId

-- | Lower an if expression as 'StatementMatch' on a boolean subject. The "true"
-- branch is matched by tag @"true"@; the else branch (or implicit null
-- block) is the default.
lowerIfExpr :: AST.IfExpression Zonked -> Lower VarId
lowerIfExpr ifExpression = do
  cond <- lowerExpr ifExpression.condition
  thenBlockId <- buildInlineBlock ifExpression.thenBlock
  defaultBlockId <- traverse buildInlineBlock ifExpression.elseBlock
  matchBlockId <- freshBlockId
  recordBlock
    matchBlockId
    ( BlockMatch
        ( MatchBlock
            { subject = cond,
              arms =
                [ MatchArm
                    { pattern = MatchPatternLiteral LiteralValueBoolean {boolean = True},
                      body = thenBlockId
                    }
                ],
              defaultArm = defaultBlockId
            }
        )
    )
    Nothing
  out <- freshVarId Nothing
  emit $
    StatementCall
      CallData
        { block = matchBlockId,
          arguments = [],
          output = Just out
        }
  pure out

-- | Lower a match expression. Each source arm becomes one IR
-- 'MatchArm' carrying the full nested 'MatchPattern' tree; the runtime
-- walks that tree against the subject, binds matched sub-values to the
-- 'VarId's introduced by 'MatchPatternVariable', and jumps into the arm's body
-- on success. Falling through (no arm matches) hits 'defaultArm' if
-- the match has an unconditional arm, else the runtime errors.
--
-- Compared to compiling each nested refutable position into a separate
-- inner 'StatementMatch', this design keeps the IR 1:1 with the source
-- @match@: all dispatch / binding logic lives in one place at the
-- runtime, and arbitrary nesting / overlap-on-tag arms work naturally
-- (the runtime tries arms in source order).
lowerMatchExpr :: AST.MatchExpression Zonked -> Lower VarId
lowerMatchExpr matchExpression = do
  subject <- lowerExpr matchExpression.subject
  arms <- mapM lowerMatchArm matchExpression.cases
  matchBlockId <- freshBlockId
  recordBlock
    matchBlockId
    ( BlockMatch
        ( MatchBlock
            { subject = subject,
              arms = arms,
              defaultArm = Nothing
            }
        )
    )
    Nothing
  out <- freshVarId Nothing
  emit $
    StatementCall
      CallData
        { block = matchBlockId,
          arguments = [],
          output = Just out
        }
  pure out

-- | Lower one source arm. Translate the AST pattern to an IR
-- 'MatchPattern' and collect every binding (Identifier 'VariableId' →
-- IR 'VarId') the pattern introduces, so the arm body block can read
-- them as locals.
lowerMatchArm :: AST.CaseArm Zonked -> Lower MatchArm
lowerMatchArm arm = do
  (irPat, locals) <- lowerPattern arm.pattern
  body <- buildArmBodyWithLocals locals arm.body
  pure MatchArm {pattern = irPat, body = body}

-- | Translate an AST 'Pattern' to an IR 'MatchPattern'. Each variable
-- pattern allocates a fresh 'VarId' (the runtime will bind the matched
-- sub-value into it) and records an Identifier→IR mapping so the arm
-- body's lowering can resolve user-side variable references.
lowerPattern :: AST.Pattern Zonked -> Lower (MatchPattern, [(VariableId, VarId)])
lowerPattern = \case
  AST.PatternVariable vp -> case vp.name.resolution of
    Just variableId -> do
      var <- freshVarId (Just vp.name.text)
      pure (MatchPatternVariable var, [(variableId, var)])
    Nothing -> do
      recordError (LoweringErrorUnresolvedVariable vp.sourceSpan vp.name.text)
      pure (MatchPatternAny, [])
  AST.PatternWildcard _ -> pure (MatchPatternAny, [])
  AST.PatternLiteral lp -> pure (MatchPatternLiteral (literalValueToIR lp.value), [])
  AST.PatternTuple tp -> do
    (subs, localss) <- mapAndUnzipM lowerPattern tp.elements
    pure (MatchPatternTuple subs, concat localss)
  AST.PatternQualifiedConstructor qp -> do
    ctorQName <- case qp.constructorName.resolution of
      Just identCtorId -> do
        idResult <- asks (.identifierResult)
        case Map.lookup identCtorId idResult.identifiedConstructors of
          Just cd -> pure cd.constructorQualifiedName
          Nothing -> do
            recordError
              (LoweringErrorUnresolvedVariable qp.sourceSpan qp.constructorName.text)
            pure (QualifiedName "<unresolved>" qp.constructorName.text)
      Nothing -> do
        recordError
          (LoweringErrorUnresolvedVariable qp.sourceSpan qp.constructorName.text)
        pure (QualifiedName "<unresolved>" qp.constructorName.text)
    pairs <- forM qp.parameters $ \(labelRef, sub) -> do
      (subPat, subLocals) <- lowerPattern sub
      pure ((labelRef.text, subPat), subLocals)
    let fields = map fst pairs
        locals = concatMap snd pairs
    pure (MatchPatternConstructor ctorQName fields, locals)
  AST.PatternType tp -> do
    (innerPat, innerLocals) <- lowerPattern tp.inner
    pure (MatchPatternTypeGuard (typePatternTagToIR tp.typeTag) innerPat, innerLocals)
  AST.PatternRecord rp -> do
    pairs <- forM rp.entries $ \(entryLabel, sub) -> do
      (subPat, subLocals) <- lowerPattern sub
      pure ((entryLabel, subPat), subLocals)
    let entries = map fst pairs
        locals = concatMap snd pairs
    pure (MatchPatternRecord entries, locals)

-- | AST→IR translation for runtime-type-pattern tags. Both enumerations
-- have the same shape; this exists purely as a module boundary.
typePatternTagToIR :: AST.TypePatternTag -> TypePatternTag
typePatternTagToIR = \case
  AST.TypePatternTagInteger -> TypePatternTagInteger
  AST.TypePatternTagNumber -> TypePatternTagNumber
  AST.TypePatternTagString -> TypePatternTagString
  AST.TypePatternTagBoolean -> TypePatternTagBoolean
  AST.TypePatternTagAgent -> TypePatternTagAgent

-- | AST and IR share 'LiteralValue' (defined in 'Katari.Common'), so
-- lowering is the identity. Kept as an alias for call sites that read
-- as a phase boundary.
literalValueToIR :: LiteralValue -> LiteralValue
literalValueToIR = id

-- | Build a child block for a match arm body. The given locals (from
-- pattern bindings) are added to the Reader scope before lowering the
-- body, so user-side variable references resolve to the right
-- 'VarId's.
buildArmBodyWithLocals :: [(VariableId, VarId)] -> AST.Block Zonked -> Lower BlockId
buildArmBodyWithLocals locals blk = do
  blockId <- freshBlockId
  (trailing, statements) <-
    runWithFreshBuffer (withLocals locals (lowerBlockInto blk))
  let userBlock =
        defaultUserBlock
          { statements = statements,
            trailing = trailing
          }
  recordBlock blockId (BlockUser userBlock) Nothing
  pure blockId

-- | Lower a for expression. Supports zero or more 'in' bindings, zero or
-- more 'var' (state) bindings, and an optional then-block.
lowerForExpr :: AST.ForExpression Zonked -> Lower VarId
lowerForExpr forExpression = do
  -- Each iter is (elementVar, sourceVar, pattern). The element pattern
  -- is destructured INSIDE the for body (so the bind statement reads
  -- the per-iteration element value), not in the enclosing scope.
  iters <- lowerForIters forExpression.inBindings
  (stateInits, stateLocals) <- lowerForStates forExpression.varBindings
  bodyBlockId <- buildForBody iters stateLocals forExpression.body
  -- The @then@ block sees state vars (their final value after the loop)
  -- but not iter vars (iteration is over). Mirrors the surface semantics:
  -- `for (x in xs, var acc = 0) { ... } then { acc }` — `acc` is the
  -- accumulator's final value; `x` is no longer bound.
  thenBlockId <- traverse (buildForThenBlock stateLocals) forExpression.thenBlock
  let iterPairs = map (\(e, s, _) -> (e, s)) iters
  forBlockId <- freshBlockId
  recordBlock
    forBlockId
    ( BlockFor
        ( ForBlock
            { parallel = forExpression.parallel,
              iters = iterPairs,
              stateInits = stateInits,
              bodyBlock = bodyBlockId,
              thenBlock = thenBlockId
            }
        )
    )
    Nothing
  out <- freshVarId Nothing
  emit $
    StatementCall
      CallData
        { block = forBlockId,
          arguments = [],
          output = Just out
        }
  pure out

-- | Lower @for(p in arr) ...@ bindings. Each element-pattern variable
-- receives a fresh IR var; the source array is lowered to a var.
-- Returns @[(elementVar, sourceVar, pattern)]@. The element pattern is
-- destructured INSIDE 'buildForBody' (once per iteration) — emitting
-- the bind into the enclosing scope here would read the iter var
-- before the for has run.
lowerForIters ::
  [AST.ForInBinding Zonked] ->
  Lower [(VarId, VarId, AST.Pattern Zonked)]
lowerForIters = mapM one
  where
    one b = do
      sourceVar <- lowerExpr b.source
      let nameHint = case b.pattern of
            AST.PatternVariable vp -> Just vp.name.text
            _ -> Just "iter"
      elementVar <- freshVarId nameHint
      pure (elementVar, sourceVar, b.pattern)

-- | Lower @for(... )(var s = init) ...@ state bindings. Returns
-- @(stateInits, stateLocals)@ where @stateInits = [(bodyVar, initVar)]@
-- (no Text labels) and @stateLocals@ maps each state var's VariableId to
-- its bodyVar so the for body can resolve references via 'lookupLocal'.
lowerForStates ::
  [AST.ForVarBinding Zonked] ->
  Lower ([(VarId, VarId)], [(VariableId, VarId)])
lowerForStates bindings = do
  results <- mapM one bindings
  pure (map fst (catMaybes results), concatMap snd (catMaybes results))
  where
    one binding = do
      let nameRef = binding.name
      initVar <- lowerExpr binding.initial
      case nameRef.resolution of
        Just variableId -> do
          bodyVar <- freshVarId (Just nameRef.text)
          pure (Just ((bodyVar, initVar), [(variableId, bodyVar)]))
        Nothing -> do
          recordError (LoweringErrorUnresolvedVariable binding.sourceSpan nameRef.text)
          pure Nothing

-- | Build the inner body block of a @for@. Destructures each iter
-- element pattern into the body's local scope (so the bind statements
-- run per iteration, against the current iter value) and brings the
-- @for@'s state vars into scope. State-var bindings are bare
-- '(VariableId, VarId)' pairs because they are written by the runtime
-- on @next with { ... }@; no destructuring statement is needed.
buildForBody ::
  [(VarId, VarId, AST.Pattern Zonked)] ->
  [(VariableId, VarId)] ->
  AST.Block Zonked ->
  Lower BlockId
buildForBody iters stateLocals body = do
  blockId <- freshBlockId
  (trailing, statements) <- runWithFreshBuffer $ do
    iterLocals <-
      concat
        <$> mapM
          (\(elemVar, _src, pat) -> destructurePattern elemVar pat)
          iters
    withLocals (iterLocals ++ stateLocals) (lowerBlockInto body)
  let userBlock =
        defaultUserBlock
          { statements = statements,
            trailing = trailing
          }
  recordBlock blockId (BlockUser userBlock) Nothing
  pure blockId

-- | Build the @then { ... }@ block of a @for@ expression. Differs from
-- 'buildInlineBlock' in that the caller passes the @for@'s state-var
-- locals so the @then@ block can resolve references to them; iter vars
-- intentionally are NOT in scope.
buildForThenBlock :: [(VariableId, VarId)] -> AST.Block Zonked -> Lower BlockId
buildForThenBlock stateLocals body = do
  blockId <- freshBlockId
  withLocals stateLocals $ do
    (statements, trailing) <- lowerBlockBody body
    let userBlock =
          defaultUserBlock
            { statements = statements,
              trailing = trailing
            }
    recordBlock blockId (BlockUser userBlock) Nothing
  pure blockId

-- ===========================================================================
-- Tuple / Array / Handle expression lowering
-- ===========================================================================

-- | Lower a tuple expression (sequential or parallel) to a 'BlockTuple'.
-- Each element is lowered into its own inline block.
lowerTupleExpr :: Bool -> [AST.Expression Zonked] -> Lower VarId
lowerTupleExpr isParallel elements = do
  elementBlockIds <- mapM buildElementBlock elements
  tupleBlockId <- freshBlockId
  recordBlock
    tupleBlockId
    ( BlockTuple
        ( TupleBlock
            { parallel = isParallel,
              elements = elementBlockIds
            }
        )
    )
    Nothing
  out <- freshVarId Nothing
  emit $
    StatementCall
      CallData
        { block = tupleBlockId,
          arguments = [],
          output = Just out
        }
  pure out

-- | Lower an array expression (sequential or parallel) to a 'BlockArray'.
-- Each element is lowered into its own inline block.
lowerArrayExpr :: Bool -> [AST.Expression Zonked] -> Lower VarId
lowerArrayExpr isParallel elements = do
  elementBlockIds <- mapM buildElementBlock elements
  arrayBlockId <- freshBlockId
  recordBlock
    arrayBlockId
    ( BlockArray
        ( ArrayBlock
            { parallel = isParallel,
              elements = elementBlockIds
            }
        )
    )
    Nothing
  out <- freshVarId Nothing
  emit $
    StatementCall
      CallData
        { block = arrayBlockId,
          arguments = [],
          output = Just out
        }
  pure out

-- | Lower a record literal @{ label = expr, ... }@ to a 'BlockRecord'.
-- Each entry's value expression is lowered into its own inline block;
-- the runtime constructs the record by collecting their trailing
-- values into a @{kind: "record", entries}@ Value.
lowerRecordExpr :: [(Text, AST.Expression Zonked)] -> Lower VarId
lowerRecordExpr entries = do
  entryBlocks <-
    mapM (\(lbl, e) -> (lbl,) <$> buildElementBlock e) entries
  recordBlockId <- freshBlockId
  recordBlock
    recordBlockId
    (BlockRecord RecordBlock {entries = entryBlocks})
    Nothing
  out <- freshVarId Nothing
  emit $
    StatementCall
      CallData
        { block = recordBlockId,
          arguments = [],
          output = Just out
        }
  pure out

-- | Lower a single expression into its own inline block (used for
-- tuple/array element blocks).
buildElementBlock :: AST.Expression Zonked -> Lower BlockId
buildElementBlock expr = do
  blockId <- freshBlockId
  (trailing, statements) <- runWithFreshBuffer (Just <$> lowerExpr expr)
  let userBlock =
        defaultUserBlock
          { statements = statements,
            trailing = trailing
          }
  recordBlock blockId (BlockUser userBlock) Nothing
  pure blockId

-- | Lower a handle expression (Koka-style). State vars are evaluated in
-- the current scope; the body (continuation) and handlers are built as
-- child blocks, then a 'BlockHandle' is constructed and called.
lowerHandleExpr :: AST.HandleExpression Zonked -> Lower VarId
lowerHandleExpr handleExpr = do
  bodyBlockId <- freshBlockId
  -- Evaluate state var inits in outer scope.
  stateBinds <- mapM mkHandleStateInit handleExpr.stateVariables
  let stateInits_ = [(bodyVar, initVar) | (_, bodyVar, initVar) <- stateBinds]
      stateLocals = [(variableId, bodyVar) | (Just variableId, bodyVar, _) <- stateBinds]
  withLocals stateLocals $ do
    -- Body block (the continuation).
    (bodyTrailing, bodyStatements) <- runWithFreshBuffer (lowerBlockInto handleExpr.body)
    recordBlock
      bodyBlockId
      (BlockUser (defaultUserBlock {statements = bodyStatements, trailing = bodyTrailing}))
      Nothing
    -- Handlers.
    handlerList <- mapM (lowerHandler stateLocals) handleExpr.handlers
    -- Then clause.
    thenBlockId <- lowerThenClause handleExpr.thenClause
    -- Record BlockHandle and call it.
    handleBlockId <- freshBlockId
    recordBlock
      handleBlockId
      ( BlockHandle
          ( HandleBlock
              { parallel = handleExpr.parallel,
                stateInits = stateInits_,
                body = bodyBlockId,
                handlers = handlerList,
                thenBlock = thenBlockId
              }
          )
      )
      Nothing
    out <- freshVarId Nothing
    emit $
      StatementCall
        CallData
          { block = handleBlockId,
            arguments = [],
            output = Just out
          }
    pure out
  where
    mkHandleStateInit ::
      AST.StateVariableBinding Zonked ->
      Lower (Maybe VariableId, VarId, VarId)
    mkHandleStateInit svb = do
      initVar <- lowerExpr svb.initial
      case svb.name.resolution of
        Just variableId -> do
          bodyVar <- freshVarId (Just svb.name.text)
          pure (Just variableId, bodyVar, initVar)
        Nothing -> do
          recordError (LoweringErrorUnresolvedVariable svb.sourceSpan svb.name.text)
          bodyVar <- freshVarId Nothing
          pure (Nothing, bodyVar, initVar)

-- | Emit a fresh load-literal statement and return the resulting var.
emitLoadLiteral :: LiteralValue -> Lower VarId
emitLoadLiteral literalValue = do
  outputVar <- freshVarId Nothing
  emit (StatementLoadLiteral LoadLiteralData {output = outputVar, value = literalValue})
  pure outputVar

-- | Lower an 'AST.LiteralExpression' as an 'StatementLoadLiteral'.
lowerLiteral :: AST.LiteralExpression Zonked -> Lower VarId
lowerLiteral lit = emitLoadLiteral (literalValueToIR lit.value)

-- | Lower an 'AST.VariableExpression'. Result depends on whether the
-- referenced 'VariableId' is a local binding (just return its IR var) or
-- a top-level decl (allocate a closure value via 'StatementMakeClosure').
lowerVariable :: AST.VariableExpression Zonked -> Lower VarId
lowerVariable variableExpression =
  resolveAsValue True variableExpression.name.resolution variableExpression.sourceSpan variableExpression.name.text (Just variableExpression.name.text)
