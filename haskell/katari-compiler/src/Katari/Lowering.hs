{-# LANGUAGE DuplicateRecordFields #-}
{-# OPTIONS_GHC -Wno-ambiguous-fields #-}

-- | Per-module lowering: Zonked AST → IR fragments.
--
-- Each module is lowered in complete isolation (its own BlockId/VarId
-- counters starting from 0). The orchestrator ('Katari.Compile')
-- collects the per-module fragments and merges them with
-- 'mergeModuleLowerings', which offsets all IDs to avoid collisions.
module Katari.Lowering
  ( LowerContext (..),
    lowerModule,
    ModuleLoweringResult (..),
    mergeModuleLowerings,
    LoweringError (..),
    toDiagnostic,
  )
where

import Control.Monad (foldM, forM, mapAndUnzipM)
import Control.Monad.Except (ExceptT, runExceptT, throwError)
import Control.Monad.Reader (ReaderT, ask, asks, local, runReaderT)
import Control.Monad.State.Strict (State, gets, modify, runState)
import Data.Aeson (FromJSON (..), ToJSON (..), Value, defaultOptions, encode, genericParseJSON, genericToJSON)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Bifunctor (Bifunctor (..))
import Data.Foldable (for_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text.Encoding qualified as Encoding
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word32)
import GHC.Generics (Generic)
import Katari.AST (Phase (Zonked))
import Katari.AST qualified as AST
import Katari.Diagnostic (Diagnostic, diagnosticError)
import Katari.IR
import Katari.Id qualified as Id
import Katari.Internal qualified as Internal
import Katari.Schema qualified as Schema
import Katari.SemanticType (Resolved, SemanticType (..))
import Katari.SourceSpan (SourceSpan)

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
-- the prim's pre-allocated 'VariableResolution' so call-site resolution flows
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

-- | Cross-module context needed by Lowering: types and data
-- declarations reachable from this module (own + transitive imports).
-- Built once by the orchestrator and reused across the module's
-- compilation.
data LowerContext = LowerContext
  { topLevelTypes :: Map Id.QualifiedName (SemanticType Resolved),
    dataDefs :: Schema.DataDefs,
    requestNames :: Set Id.QualifiedName,
    constructorNames :: Set Id.QualifiedName
  }

data LowerEnv = LowerEnv
  { -- | Local bindings: @VariableResolution → IR's VarId@ introduced by
    -- @let@ / function param / pattern / local agent. Top-level callable
    -- resolution uses 'lsTopLevelBlocks' separately.
    localVars :: Map Id.VariableResolution VarId,
    currentModule :: Text,
    -- | The current module's own type environment (locals + own top-level).
    localTypeEnv :: Map Id.VariableResolution (SemanticType Resolved),
    topLevelTypes :: Map Id.QualifiedName (SemanticType Resolved),
    dataDefs :: Schema.DataDefs,
    requestNames :: Set Id.QualifiedName,
    constructorNames :: Set Id.QualifiedName,
    -- | The lexically-nearest enclosing catching blocks, stamped onto exits /
    -- conts so the runtime routes them to the block the SOURCE lexically meant
    -- (not the dynamically-nearest one). A @use@ continuation is lowered with
    -- these UNCHANGED (it is the enclosing agent's body), so a @return@ inside
    -- it targets that agent; a user local @agent@ overrides 'currentReturnTarget'
    -- with its own block, so a @return@ inside it stops there.
    currentReturnTarget :: Maybe BlockId,
    currentForTarget :: Maybe BlockId,
    currentHandleTarget :: Maybe BlockId
  }

initialLowerEnv :: LowerContext -> Text -> Map Id.VariableResolution (SemanticType Resolved) -> LowerEnv
initialLowerEnv ctx moduleName moduleLocalTypeEnv =
  LowerEnv
    { localVars = Map.empty,
      currentModule = moduleName,
      localTypeEnv = moduleLocalTypeEnv,
      topLevelTypes = ctx.topLevelTypes,
      dataDefs = ctx.dataDefs,
      requestNames = ctx.requestNames,
      constructorNames = ctx.constructorNames,
      currentReturnTarget = Nothing,
      currentForTarget = Nothing,
      currentHandleTarget = Nothing
    }

data LowerState = LowerState
  { lsNextBlockId :: Word32,
    lsNextVarId :: Word32,
    lsBlocks :: Map BlockId Block,
    lsVarNames :: Map VarId Text,
    lsBlockNames :: Map BlockId Text,
    -- | Top-level @VariableResolution@ → its callable @BlockId@. Used at
    -- call / closure sites to resolve agent / req / ext-agent / data-ctor names.
    lsTopLevelBlocks :: Map Id.VariableResolution BlockId,
    -- | FFI translation table: qualified name → BlockId. Populated as
    -- top-level callables are registered; surfaces in
    -- 'IRModule.entries'.
    lsEntries :: Map QualifiedName BlockId,
    -- | Reverse of 'lsEntries': BlockId → QualifiedName. Maintained in
    -- sync with 'lsEntries' so reverse lookups are O(log n) instead of
    -- O(n) scans.
    lsBlockQNames :: Map BlockId QualifiedName,
    -- | Prim bare name → leaf 'BlockPrim' 'BlockId'. Same-module only:
    -- populated by 'registerDecl' for DeclarationPrimAgent, read by
    -- 'lowerOneDeclaration' to wire the wrapper agent's entryBody.
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
      lsEntries = Map.empty,
      lsBlockQNames = Map.empty,
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
withLocals :: [(Id.VariableResolution, VarId)] -> Lower a -> Lower a
withLocals binds = local $ \env ->
  env {localVars = Map.union (Map.fromList binds) env.localVars}

-- | Look up a local variable resolution in the current scope.
lookupLocal :: Id.VariableResolution -> Lower (Maybe VarId)
lookupLocal variableResolution = asks (Map.lookup variableResolution . (.localVars))

-- | Run @action@ as a user agent body: @return@ targets @blockId@, and the
-- break / next targets reset (you cannot break/next across an agent boundary).
-- A @use@ continuation does NOT use this (it keeps the enclosing targets), so a
-- @return@ inside it unwinds to the agent that lexically wrote the @use@.
withReturnTarget :: BlockId -> Lower a -> Lower a
withReturnTarget blockId = local (\env -> env {currentReturnTarget = Just blockId, currentForTarget = Nothing, currentHandleTarget = Nothing})

withForTarget :: BlockId -> Lower a -> Lower a
withForTarget blockId = local (\env -> env {currentForTarget = Just blockId})

withHandleTarget :: BlockId -> Lower a -> Lower a
withHandleTarget blockId = local (\env -> env {currentHandleTarget = Just blockId})

-- | The block a @return@ / @break@ / @next@ exits to (its lexical catcher),
-- stamped onto the IR. A missing target is an internal invariant violation
-- (the typechecker rejects break/next/return outside their context).
returnTargetBlock :: Lower BlockId
returnTargetBlock = asks (.currentReturnTarget) >>= maybe (throwError (Internal.internalErrorNoSpan "lowering: return with no enclosing agent")) pure

forTargetBlock :: Lower BlockId
forTargetBlock = asks (.currentForTarget) >>= maybe (throwError (Internal.internalErrorNoSpan "lowering: for-break/next with no enclosing for")) pure

handleTargetBlock :: Lower BlockId
handleTargetBlock = asks (.currentHandleTarget) >>= maybe (throwError (Internal.internalErrorNoSpan "lowering: break/next with no enclosing handle")) pure

-- ===========================================================================
-- Variable resolution
-- ===========================================================================

-- | Resolve a variable reference in 'value' context: locals pass
-- through, top-level callables emit a 'LiteralValueAgent' carrying
-- the QualifiedName. The runtime resolves QualifiedNames to BlockIds
-- via 'IRModule.entries' at dispatch time, so cross-module references
-- need no registration at lowering time.
resolveAsValue ::
  Bool ->
  AST.NameRefResolution Zonked AST.VariableRef ->
  SourceSpan ->
  Text ->
  Maybe Text ->
  Lower VarId
resolveAsValue canBeLocal resolution sourceSpan nameText hint = case resolution of
  Nothing -> do
    recordError (LoweringErrorUnresolvedVariable sourceSpan nameText)
    freshVarId Nothing
  Just variableResolution -> do
    mLocal <- if canBeLocal then lookupLocal variableResolution else pure Nothing
    case mLocal of
      Just irVar -> pure irVar
      Nothing -> case variableResolution of
        Id.ResolvedTopLevel qualifiedName -> do
          v <- freshVarId hint
          emit (StatementLoadLiteral LoadLiteralData {output = v, value = LiteralValueAgent qualifiedName})
          pure v
        Id.ResolvedLocal _ -> do
          recordError (LoweringErrorUnresolvedVariable sourceSpan nameText)
          freshVarId Nothing

-- | Emit a call to a primitive via the standard delegate path
-- (LiteralValueAgent → DelegateTargetValue). The prim is resolved by
-- QualifiedName at runtime through IRModule.entries, so no cross-module
-- BlockId dependency is needed.
emitPrimCall :: Text -> [(Text, VarId)] -> Lower VarId
emitPrimCall primName labeledArgs = do
  let qname = primQualifiedName primName
  calleeVar <- freshVarId Nothing
  emit (StatementLoadLiteral LoadLiteralData {output = calleeVar, value = LiteralValueAgent qname})
  delegateBlk <- freshBlockId
  recordBlock
    delegateBlk
    (BlockDelegate DelegateBlock {target = DelegateTargetValue calleeVar})
    Nothing
  argument <- emitArgumentRecord labeledArgs
  out <- freshVarId Nothing
  emit (StatementCall CallData {block = delegateBlk, argument = argument, output = Just out})
  pure out

-- | Build the single argument value for a named call from its already-lowered
-- @(label, var)@ pairs: collect them into a record Value (via 'BlockRecord').
-- An empty argument list lowers to 'Nothing' (an argument-less call).
emitArgumentRecord :: [(Text, VarId)] -> Lower (Maybe VarId)
emitArgumentRecord [] = pure Nothing
emitArgumentRecord labeledVars = do
  entryBlocks <- mapM (\(label, var) -> (label,) <$> wrapVarInBlock var) labeledVars
  recordBlockId <- freshBlockId
  recordBlock recordBlockId (BlockRecord RecordBlock {entries = entryBlocks}) Nothing
  out <- freshVarId Nothing
  emit (StatementCall CallData {block = recordBlockId, argument = Nothing, output = Just out})
  pure (Just out)

-- | Wrap an already-bound 'VarId' in a trivial inline block whose trailing
-- value is that var (the block inherits the lexical scope, so the var is in
-- scope). Used to feed existing values into 'BlockRecord' / 'BlockTuple'
-- entry slots, which expect a block per entry.
wrapVarInBlock :: VarId -> Lower BlockId
wrapVarInBlock var = do
  blockId <- freshBlockId
  recordBlock blockId (BlockUser (defaultUserBlock {trailing = Just var})) Nothing
  pure blockId

-- | Read a record field: allocate a 'BlockGetField' over @source@ (read from
-- the inherited scope) and call it, returning the var its value lands in. Used
-- both for surface @obj.field@ and for binding named parameters out of a
-- block's incoming argument record.
emitGetField :: VarId -> Text -> Lower VarId
emitGetField source field = do
  blockId <- freshBlockId
  recordBlock blockId (BlockGetField GetFieldBlock {source = source, field = field}) Nothing
  out <- freshVarId Nothing
  emit (StatementCall CallData {block = blockId, argument = Nothing, output = Just out})
  pure out

-- | Build the QualifiedName for a prim dispatch name. Bare names
-- (e.g. "get_field") live in module "primitive"; qualified names
-- (e.g. "json.parse") are split at the last dot.
primQualifiedName :: Text -> QualifiedName
primQualifiedName name =
  case Text.breakOnEnd "." name of
    ("", bare) -> QualifiedName {module_ = "primitive", name = bare}
    (prefix, bare) -> QualifiedName {module_ = "primitive." <> Text.dropEnd 1 prefix, name = bare}

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
  Id.VariableResolution ->
  [(Text, Maybe Text)] ->
  Lower (Text, Text, Text)
schemasForVariable variableResolution labelsAndAnnotations = do
  env <- ask
  let resolved = case variableResolution of
        Id.ResolvedTopLevel qualifiedName -> Map.lookup qualifiedName env.topLevelTypes
        Id.ResolvedLocal _ -> Map.lookup variableResolution env.localTypeEnv
  case resolved of
    Just functionType -> schemasForFunctionType functionType labelsAndAnnotations
    Nothing -> pure ("{}", "{}", "[]")

-- | Direct variant of 'schemasForVariable' for call sites that already
-- hold the resolved function type (e.g. prim wrappers, which read it
-- straight from 'Katari.Prim.primDefinitions').
schemasForFunctionType ::
  SemanticType Resolved ->
  [(Text, Maybe Text)] ->
  Lower (Text, Text, Text)
schemasForFunctionType functionType labelsAndAnnotations = do
  dd <- asks (.dataDefs)
  topLevelTypes <- asks (.topLevelTypes)
  case functionType of
    SemanticTypeFunction parameters returnType requestSet ->
      pure
        ( Schema.jsonSchemaToText
            (Schema.buildInputObject dd parameters labelsAndAnnotations),
          Schema.jsonSchemaToText (Schema.buildOutputSchema dd returnType),
          encodeValueText (Schema.buildRequestsSchema dd topLevelTypes requestSet)
        )
    _ -> pure ("{}", "{}", "[]")

-- | Aeson-encode a JSON 'Value' to strict 'Text' (for embedding a precomputed
-- requests schema in 'AgentBlock.requestsSchema').
encodeValueText :: Value -> Text
encodeValueText = Encoding.decodeUtf8 . LazyByteString.toStrict . encode

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
    { input = Nothing,
      defaults = Map.empty,
      statements = [],
      trailing = Nothing
    }

-- ===========================================================================
-- Entry
-- ===========================================================================

-- ===========================================================================
-- Per-module lowering result
-- ===========================================================================

-- | IR fragment produced by lowering a single module. The orchestrator
-- merges these via 'mergeModuleLowerings'.
data ModuleLoweringResult = ModuleLoweringResult
  { mlrBlocks :: Map BlockId Block,
    mlrEntries :: Map QualifiedName BlockId,
    mlrNameTable :: NameTable,
    mlrBlockCount :: Word32,
    mlrVarCount :: Word32
  }
  deriving (Show, Generic)

instance ToJSON ModuleLoweringResult where
  toJSON = genericToJSON defaultOptions

instance FromJSON ModuleLoweringResult where
  parseJSON = genericParseJSON defaultOptions

-- | Lower one module in complete isolation (BlockId/VarId counters
-- start from 0). Returns the IR fragment and any structural errors.
lowerModule ::
  LowerContext ->
  Text ->
  Map Id.VariableResolution (SemanticType Resolved) ->
  AST.Module Zonked ->
  (Either Diagnostic ModuleLoweringResult, [LoweringError])
lowerModule ctx moduleName moduleLocalTypeEnv moduleAST =
  let env = initialLowerEnv ctx moduleName moduleLocalTypeEnv
      (result, finalState) =
        runState
          (runReaderT (runExceptT (lowerModuleM moduleName moduleAST)) env)
          initialLowerState
      errors = reverse finalState.lsErrors
   in case result of
        Left diagnostic -> (Left diagnostic, errors)
        Right () ->
          ( Right
              ModuleLoweringResult
                { mlrBlocks = finalState.lsBlocks,
                  mlrEntries = finalState.lsEntries,
                  mlrNameTable =
                    NameTable
                      { varNames = finalState.lsVarNames,
                        blockNames = finalState.lsBlockNames
                      },
                  mlrBlockCount = finalState.lsNextBlockId,
                  mlrVarCount = finalState.lsNextVarId
                },
            errors
          )

-- | Internal: lower one module (register + lower bodies).
lowerModuleM :: Text -> AST.Module Zonked -> Lower ()
lowerModuleM moduleName moduleAST = do
  mapM_ (registerDecl moduleName) moduleAST.declarations
  mapM_ (lowerOneDeclaration moduleName) moduleAST.declarations

-- | Merge per-module IR fragments into a single 'IRModule'. BlockIds
-- and VarIds are offset so they don't collide across modules.
mergeModuleLowerings :: [ModuleLoweringResult] -> IRModule
mergeModuleLowerings fragments =
  let (mergedBlocks, mergedEntries, mergedNameTable) = go 0 0 fragments
   in IRModule
        { metadata = currentIRMetadata,
          blocks = mergedBlocks,
          entries = mergedEntries,
          nameTable = mergedNameTable
        }
  where
    go _ _ [] = (Map.empty, Map.empty, emptyNameTable)
    go blockOffset varOffset (fragment : rest) =
      let offsetBlock = offsetBlockId (BlockId blockOffset)
          offsetVar = offsetVarId (VarId varOffset)
          offsetBlocks =
            Map.fromList
              [ (offsetBlock blockId, offsetBlockInBlock offsetBlock offsetVar block)
                | (blockId, block) <- Map.toList fragment.mlrBlocks
              ]
          offsetEntries =
            Map.map offsetBlock fragment.mlrEntries
          offsetNameTable =
            NameTable
              { varNames =
                  Map.fromList
                    [ (offsetVar varId, name)
                      | (varId, name) <- Map.toList fragment.mlrNameTable.varNames
                    ],
                blockNames =
                  Map.fromList
                    [ (offsetBlock blockId, name)
                      | (blockId, name) <- Map.toList fragment.mlrNameTable.blockNames
                    ]
              }
          (restBlocks, restEntries, restNameTable) =
            go
              (blockOffset + fragment.mlrBlockCount)
              (varOffset + fragment.mlrVarCount)
              rest
       in ( Map.union offsetBlocks restBlocks,
            Map.union offsetEntries restEntries,
            NameTable
              { varNames = Map.union offsetNameTable.varNames restNameTable.varNames,
                blockNames = Map.union offsetNameTable.blockNames restNameTable.blockNames
              }
          )

-- | Register a single module's declarations (reserve BlockIds / build
-- prim leaves). Called by 'lowerModuleM' before lowering bodies.
registerDecl :: Text -> AST.Declaration Zonked -> Lower ()
registerDecl moduleName = \case
  -- Prim agents additionally build a leaf 'BlockPrim' and index it by
  -- dispatch name so 'lowerOneDeclaration' can wire the wrapper to it.
  -- The dispatch name is the prim's fully-qualified name (@primitive.add@,
  -- @primitive.record.get@) — the runtime's @executePrim@ switches on exactly
  -- this string, with no prefix stripping on either side.
  AST.DeclarationPrimAgent decl ->
    registerCallable decl.name decl.sourceSpan $ \variableResolution -> do
      let primName = moduleName <> "." <> decl.name.text
      agentBlk <- reserveBlockId (Just decl.name.text)
      leafBlk <- freshBlockId
      recordBlock leafBlk (BlockPrim primName) (Just ("prim:" <> primName <> ":leaf"))
      modify $ \state ->
        state {lsPrimBlockIds = Map.insert primName leafBlk state.lsPrimBlockIds}
      recordTopLevelCallable variableResolution moduleName decl.name.text agentBlk
  AST.DeclarationError sourceSpan -> recordError (LoweringErrorParseSentinel sourceSpan)
  -- Every other top-level callable (agent / request / external / data)
  -- reserves a single wrapper-agent BlockId in exactly the same way.
  decl -> case callableNameRef decl of
    Just (nameRef, sourceSpan) ->
      registerCallable nameRef sourceSpan $ \variableResolution -> do
        blockId <- reserveBlockId (Just nameRef.text)
        recordTopLevelCallable variableResolution moduleName nameRef.text blockId
    Nothing -> pure () -- import / type synonym: nothing to reserve

-- | The signature 'NameRef' + span of a single-slot top-level callable
-- (agent / request / external / data). 'DeclarationPrimAgent' is excluded
-- because it also builds a leaf 'BlockPrim'; non-callable declarations
-- (import / type synonym / error) return 'Nothing'.
callableNameRef :: AST.Declaration Zonked -> Maybe (AST.NameRef Zonked AST.VariableRef, SourceSpan)
callableNameRef = \case
  AST.DeclarationAgent decl -> Just (decl.name, decl.sourceSpan)
  AST.DeclarationRequest decl -> Just (decl.name, decl.sourceSpan)
  AST.DeclarationExternalAgent decl -> Just (decl.name, decl.sourceSpan)
  AST.DeclarationData decl -> Just (decl.name, decl.sourceSpan)
  _ -> Nothing

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
  -- | per-parameter @(label, optional literal default)@ in source order
  [(Text, Maybe LiteralValue)] ->
  BlockId ->
  Text ->
  Text ->
  Maybe Text ->
  Text ->
  Text ->
  Text ->
  Lower ()
writeWrapperAgent agentBlk qname paramSpecs innerBlk hint simpleName desc inputSchemaJson outputSchemaJson requestsSchemaJson =
  -- A wrapper just fills any defaulted parameter the caller omitted (when the
  -- incoming value is a record) and hands the value to its leaf body, which
  -- reads the named fields directly — no var binding here.
  recordBlock
    agentBlk
    ( BlockAgent
        AgentBlock
          { qualifiedName = qname,
            defaults = Map.fromList [(label, d) | (label, Just d) <- paramSpecs],
            entryBody = innerBlk,
            name = simpleName,
            description = desc,
            inputSchema = inputSchemaJson,
            outputSchema = outputSchemaJson,
            requestsSchema = requestsSchemaJson
          }
    )
    (Just (hint <> ":agent"))

-- | Bind a top-level @VariableResolution@ to its callable @BlockId@.
recordVarBlockId :: Id.VariableResolution -> BlockId -> Lower ()
recordVarBlockId variableResolution blockId =
  modify (\state -> state {lsTopLevelBlocks = Map.insert variableResolution blockId state.lsTopLevelBlocks})

-- | Run @action@ with the resolved 'VariableResolution' from a top-level callable
-- declaration name. If the name didn't resolve (parser/identifier left an
-- 'Nothing' marker), record a Lowering error and skip.
registerCallable ::
  AST.NameRef Zonked AST.VariableRef ->
  SourceSpan ->
  (Id.VariableResolution -> Lower ()) ->
  Lower ()
registerCallable nameRef sourceSpan action = case nameRef.resolution of
  Just variableResolution -> action variableResolution
  Nothing -> recordError (LoweringErrorUnresolvedVariable sourceSpan nameRef.text)

-- | Register a top-level callable: bind the resolution to its BlockId,
-- record its QualifiedName, and expose it in entries.
recordTopLevelCallable :: Id.VariableResolution -> Text -> Text -> BlockId -> Lower ()
recordTopLevelCallable variableResolution moduleName_ declName blockId = do
  let qualifiedName = QualifiedName {module_ = moduleName_, name = declName}
  recordVarBlockId variableResolution blockId
  modify $ \state ->
    state
      { lsEntries = Map.insert qualifiedName blockId state.lsEntries,
        lsBlockQNames = Map.insert blockId qualifiedName state.lsBlockQNames
      }

-- | Lower one declaration body within a module. Dispatches on the
-- declaration kind: agents get their body lowered; data / request /
-- external / prim get their wrapper agent + inner leaf written.
-- Non-callable declarations (import, type synonym, error sentinel)
-- are skipped.
lowerOneDeclaration :: Text -> AST.Declaration Zonked -> Lower ()
lowerOneDeclaration moduleName = \case
  AST.DeclarationAgent decl -> resolveDeclaration decl.name $ \_variableResolution blockId ->
    lowerAgentDeclaration decl blockId
  AST.DeclarationData decl ->
    lowerWrapperCallable decl.name decl.annotation [(p.name, p.annotation, (.value) <$> p.defaultValue) | p <- decl.parameters] decl.name.text $
      \variableResolution -> do
        ctorQName <- lookupConstructorQName variableResolution
        innerBlk <- freshBlockId
        recordBlock innerBlk (BlockConstructor ctorQName) (Just (decl.name.text <> ":ctor"))
        pure innerBlk
  AST.DeclarationExternalAgent decl ->
    lowerWrapperCallable decl.name decl.annotation [(pb.name.text, pb.annotation, (.value) <$> pb.defaultValue) | pb <- decl.parameters] decl.name.text $
      \_variableResolution -> do
        innerBlk <- freshBlockId
        recordBlock
          innerBlk
          ( BlockDelegate
              DelegateBlock
                { target =
                    DelegateTargetExternal
                      ExternalDispatch {endpoint = decl.endpoint, dispatchName = decl.dispatchName}
                }
          )
          (Just (decl.name.text <> ":external"))
        pure innerBlk
  AST.DeclarationRequest decl ->
    lowerWrapperCallable decl.name decl.annotation [(pb.name.text, pb.annotation, (.value) <$> pb.defaultValue) | pb <- decl.parameters] decl.name.text $
      \variableResolution -> do
        reqQName <- lookupRequestQName variableResolution
        innerBlk <- freshBlockId
        recordBlock innerBlk (BlockRequest reqQName) (Just (decl.name.text <> ":request"))
        pure innerBlk
  AST.DeclarationPrimAgent decl ->
    lowerWrapperCallable decl.name decl.annotation [(pb.name.text, pb.annotation, (.value) <$> pb.defaultValue) | pb <- decl.parameters] ("prim:" <> decl.name.text) $
      \_variableResolution -> do
        let primName = moduleName <> "." <> decl.name.text
        gets (Map.lookup primName . (.lsPrimBlockIds)) >>= \case
          Just b -> pure b
          Nothing ->
            throwError
              ( Internal.internalErrorNoSpan
                  ("DeclarationPrimAgent: leaf for '" <> primName <> "' missing from lsPrimBlockIds")
              )
  _ -> pure ()

-- | Look up the (already reserved) wrapper agent 'BlockId' for a
-- declaration's name and run the per-kind body builder. If the name
-- did not resolve or has no reserved slot, skip silently.
resolveDeclaration ::
  AST.NameRef Zonked AST.VariableRef ->
  (Id.VariableResolution -> BlockId -> Lower ()) ->
  Lower ()
resolveDeclaration nameRef action = case nameRef.resolution of
  Just variableResolution -> do
    maybeBlockId <- gets (Map.lookup variableResolution . (.lsTopLevelBlocks))
    for_ maybeBlockId (action variableResolution)
  Nothing -> pure ()

-- | Phase 1 invariant: every reserved agent slot has exactly one
-- 'lsEntries' entry pointing at it (registered by
-- 'recordTopLevelCallable'). Look up the 'QualifiedName' stamped
-- on the wrapper agent's 'BlockId'.
requireAgentQName :: Text -> BlockId -> Lower QualifiedName
requireAgentQName declName agentBlk = do
  blockQNames <- gets (.lsBlockQNames)
  case Map.lookup agentBlk blockQNames of
    Just qualifiedName -> pure qualifiedName
    Nothing ->
      throwError
        ( Internal.internalErrorNoSpan
            ("'" <> declName <> "' agent slot not in lsEntries")
        )

-- | Shared shape for the four non-agent top-level callables (data ctor /
-- external / request / prim): each wraps a single leaf block in a
-- 'BlockAgent'. @mkLeaf@ builds (or looks up) the leaf block and returns
-- its 'BlockId'; the surrounding qname lookup, schema computation, and
-- wrapper emission are identical across all four kinds.
lowerWrapperCallable ::
  AST.NameRef Zonked AST.VariableRef ->
  -- | declaration annotation (@\@"..."@)
  Maybe Text ->
  -- | per-parameter @(label, annotation, literal default)@ in source order
  [(Text, Maybe Text, Maybe LiteralValue)] ->
  -- | block-name hint (@"prim:foo"@ for prims, else the bare name)
  Text ->
  -- | builds the inner leaf block, returning its 'BlockId'
  (Id.VariableResolution -> Lower BlockId) ->
  Lower ()
lowerWrapperCallable nameRef annotation parameterInfos hint mkLeaf =
  resolveDeclaration nameRef $ \variableResolution agentBlk -> do
    qname <- requireAgentQName nameRef.text agentBlk
    innerBlk <- mkLeaf variableResolution
    (inputSchema, outputSchema, requestsSchema) <-
      schemasForVariable variableResolution [(label, annotation') | (label, annotation', _) <- parameterInfos]
    writeWrapperAgent
      agentBlk
      qname
      [(label, parameterDefault) | (label, _, parameterDefault) <- parameterInfos]
      innerBlk
      hint
      nameRef.text
      annotation
      inputSchema
      outputSchema
      requestsSchema

-- | Look up the constructor 'QualifiedName' for a data declaration's
-- 'VariableResolution'. The constructor must have been registered by
-- the Identifier pass.
lookupConstructorQName :: Id.VariableResolution -> Lower QualifiedName
lookupConstructorQName = \case
  Id.ResolvedTopLevel qualifiedName -> do
    known <- asks (.constructorNames)
    if Set.member qualifiedName known
      then pure qualifiedName
      else
        throwError
          ( Internal.internalErrorNoSpan
              "lookupConstructorQName: QualifiedName not in constructorNames"
          )
  Id.ResolvedLocal _ ->
    throwError
      ( Internal.internalErrorNoSpan
          "lookupConstructorQName: local variable cannot be a constructor"
      )

-- | Look up the request 'QualifiedName' for a req declaration's
-- 'VariableResolution'. Mirrors 'lookupConstructorQName' for the
-- request side.
lookupRequestQName :: Id.VariableResolution -> Lower QualifiedName
lookupRequestQName = \case
  Id.ResolvedTopLevel qualifiedName -> do
    known <- asks (.requestNames)
    if Set.member qualifiedName known
      then pure qualifiedName
      else
        throwError
          ( Internal.internalErrorNoSpan
              "lookupRequestQName: QualifiedName not in requestNames"
          )
  Id.ResolvedLocal _ ->
    throwError
      ( Internal.internalErrorNoSpan
          "lookupRequestQName: local variable cannot be a request"
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
  Maybe Id.VariableResolution ->
  Maybe Text ->
  [AST.ParameterBinding Zonked] ->
  AST.Block Zonked ->
  BlockId ->
  Lower ()
lowerAgentLike name mVariableResolution description parameters body blockId = do
  let labelsAndAnnotations = [(pb.name.text, pb.annotation) | pb <- parameters]
  (bodyInput, agentDefaults, prelude) <- agentInputBinding parameters
  (inputSchema, outputSchema, requestsSchema) <- case mVariableResolution of
    Just variableResolution -> schemasForVariable variableResolution labelsAndAnnotations
    Nothing -> pure ("{}", "{}", "[]")
  lowerSimpleAgent
    True
    blockId
    name
    bodyInput
    agentDefaults
    prelude
    body
    description
    inputSchema
    outputSchema
    requestsSchema

-- | Compute how an agent consumes its single incoming argument value: the
-- body's input var, the agent's default-fill map, and a prelude (run inside
-- the body buffer) that emits the per-parameter field reads and returns the
-- locals they bind.
--
--   * A sole spread parameter @...obj: T@ binds the whole value to @obj@'s var
--     (no field reads, no defaults).
--   * Otherwise the value is a record: a fresh input var holds it, each named
--     parameter is read out of it with a 'StatementGetField', and the agent
--     carries the defaulted parameters' literals.
agentInputBinding ::
  [AST.ParameterBinding Zonked] ->
  Lower (Maybe VarId, Map Text LiteralValue, Lower [(Id.VariableResolution, VarId)])
agentInputBinding parameters = case parameters of
  [] -> pure (Nothing, Map.empty, pure [])
  [pb] | pb.spread -> do
    objVar <- freshVarId (Just pb.name.text)
    pure (Just objVar, Map.empty, bindParamLocal pb objVar)
  _ -> do
    inputVar <- freshVarId (Just "args")
    let agentDefaults = Map.fromList [(pb.name.text, pd.value) | pb <- parameters, Just pd <- [pb.defaultValue]]
        -- Each named param is read out of the incoming record into a fresh var
        -- (the 'BlockGetField' output), which becomes the param's slot.
        prelude =
          concat
            <$> forM
              parameters
              ( \pb -> do
                  paramVar <- emitGetField inputVar pb.name.text
                  bindParamLocal pb paramVar
              )
    pure (Just inputVar, agentDefaults, prelude)

-- | The local binding a parameter introduces (its resolved variable → IR var).
bindParamLocal :: AST.ParameterBinding Zonked -> VarId -> Lower [(Id.VariableResolution, VarId)]
bindParamLocal pb var = case pb.name.resolution of
  Just variableResolution -> pure [(variableResolution, var)]
  Nothing -> do
    recordError (LoweringErrorUnresolvedVariable pb.sourceSpan pb.name.text)
    pure []

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
  -- | Does this agent catch @return@ (a real user agent), or is it a @use@
  -- continuation that lets @return@ pass through to the lexically-enclosing
  -- agent? Drives whether the body's @return@ targets @blockId@ or the inherited
  -- 'currentReturnTarget'.
  Bool ->
  BlockId ->
  Text ->
  Maybe VarId ->
  Map Text LiteralValue ->
  Lower [(Id.VariableResolution, VarId)] ->
  AST.Block Zonked ->
  Maybe Text ->
  Text ->
  Text ->
  Text ->
  Lower ()
lowerSimpleAgent catchesReturn blockId name bodyInput agentDefaults prelude blk description inputSchema outputSchema requestsSchema = do
  (trailing, statements) <- runWithFreshBuffer $ do
    locals <- prelude
    (if catchesReturn then withReturnTarget blockId else id) (withLocals locals (lowerBlockInto blk))
  -- Allocate the inner BlockUser body, then wrap it in a BlockAgent at
  -- @blockId@ (the externally-callable id). The agent fills defaults into the
  -- incoming value; the body binds it and reads its fields (already emitted by
  -- the prelude into @statements@).
  bodyBlockId <- freshBlockId
  let bodyBlock =
        defaultUserBlock
          { input = bodyInput,
            statements = statements,
            trailing = trailing
          }
  recordBlock bodyBlockId (BlockUser bodyBlock) (Just (name <> ".body"))
  -- Resolve qualifiedName by reverse-lookup of the wrapper blockId in
  -- lsEntries (top-level agents are pre-registered with their qname).
  -- Local / nested agents use a synthetic name; the runtime never reads
  -- AgentBlock.qualifiedName for dispatch, only for debug output.
  blockQNames <- gets (.lsBlockQNames)
  let qname = case Map.lookup blockId blockQNames of
        Just qn -> qn
        Nothing -> QualifiedName "<local>" name
      agent =
        AgentBlock
          { qualifiedName = qname,
            defaults = agentDefaults,
            entryBody = bodyBlockId,
            name = name,
            description = description,
            inputSchema = inputSchema,
            outputSchema = outputSchema,
            requestsSchema = requestsSchema
          }
  recordBlock blockId (BlockAgent agent) (Just name)

-- | Lower a 'RequestHandler' to a 'BlockUser'. The handler body inherits
-- the handle scope (state vars are directly accessible via 'withLocals'
-- in the enclosing 'lowerHandlerExpr'). Only req args are passed via
-- 'parameters'. The body's trailing value is treated as an implicit
-- @break@; an explicit 'StatementExit ExitKindBreak' is appended if
-- the body completes normally.
lowerHandler :: AST.RequestHandler Zonked -> Lower Handler
lowerHandler hr = do
  reqQName <- case hr.name.resolution of
    Just (Id.ResolvedConcreteRequest qualifiedName) -> pure qualifiedName
    _ -> do
      recordError (LoweringErrorUnresolvedVariable hr.sourceSpan hr.name.text)
      pure (QualifiedName "<unresolved>" hr.name.text)
  bodyBlockId <- freshBlockId
  -- A handler consumes the request's argument record exactly like an agent
  -- consumes its call: bind it, read each req param out by field, fill the
  -- req's parameter defaults.
  (handlerInput, handlerDefaults, paramPrelude) <- agentInputBinding hr.parameters
  (trailing, statements) <- runWithFreshBuffer $ do
    locals <- paramPrelude
    withLocals locals (lowerBlockInto hr.body)
  -- A handler body's trailing value is an implicit @break@ of the handle scope.
  handleTarget <- handleTargetBlock
  let lastIsExit = case reverse statements of
        (StatementExit {} : _) -> True
        _ -> False
      finalStatements = case trailing of
        Just t
          | not lastIsExit ->
              statements ++ [StatementExit ExitData {exitKind = ExitKindBreak, value = t, target = handleTarget}]
        _ -> statements
      userBlock =
        defaultUserBlock
          { input = handlerInput,
            defaults = handlerDefaults,
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
              { -- The then-block receives the body's tail value directly bound
                -- to its param var (the runtime spawns it with that value).
                input = Just paramVar,
                statements = statements,
                trailing = trailing
              }
      recordBlock blockId (BlockUser userBlock) Nothing
    pure (Just blockId)


-- | Allocate a fresh IR var for an incoming value and destructure it by
-- emitting a single 'StatementBindPattern'. Returns the fresh 'VarId' and the
-- '(VariableResolution, VarId)' pairs to add to the local scope.
--
-- Irrefutability is guaranteed upstream by the Maranget exhaustiveness
-- checker (K0291); callers do not need to guard against refutable patterns.
bindPatternToFreshVar :: AST.Pattern Zonked -> Maybe Text -> Lower (VarId, [(Id.VariableResolution, VarId)])
bindPatternToFreshVar pat hint = do
  let nameHint = case pat of
        AST.PatternVariable vp -> Just vp.name.text
        _ -> hint
  var <- freshVarId nameHint
  locals <- destructurePattern var pat
  pure (var, locals)

-- | Emit a 'StatementBindPattern' that destructures @incoming@ according to the
-- given AST pattern. Returns the '(VariableResolution, VarId)' pairs for all
-- variable sub-patterns; the runtime walks the pattern tree at execution time.
--
-- Irrefutability (no unguarded literal patterns) is guaranteed by the
-- Maranget exhaustiveness checker (K0291) before lowering runs.
destructurePattern :: VarId -> AST.Pattern Zonked -> Lower [(Id.VariableResolution, VarId)]
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
      Just variableResolution -> do
        blockId <- freshBlockId
        var <- freshVarId (Just stmt.name.text)
        withLocals [(variableResolution, var)] $ do
          lowerAgentLike
            stmt.name.text
            (Just variableResolution)
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
    target <- returnTargetBlock
    emit (StatementExit ExitData {exitKind = ExitKindReturn, value = var, target = target})
    pure True
  AST.StatementBreak stmt -> do
    var <- lowerExpr stmt.value
    target <- handleTargetBlock
    emit (StatementExit ExitData {exitKind = ExitKindBreak, value = var, target = target})
    pure True
  AST.StatementForBreak stmt -> do
    var <- lowerExpr stmt.value
    target <- forTargetBlock
    emit (StatementExit ExitData {exitKind = ExitKindForBreak, value = var, target = target})
    pure True
  AST.StatementNext stmt -> do
    var <- lowerExpr stmt.value
    modPairs <- mapM lowerModifier stmt.modifiers
    target <- handleTargetBlock
    emit (StatementCont ContData {contKind = ContKindNext, value = Just var, modifiers = modPairs, target = target})
    pure True
  AST.StatementForNext stmt -> do
    var <- lowerExpr stmt.value
    modPairs <- mapM lowerModifier stmt.modifiers
    target <- forTargetBlock
    emit (StatementCont ContData {contKind = ContKindForNext, value = Just var, modifiers = modPairs, target = target})
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
-- resolved via 'lookupLocal' using the Modifier's 'VariableResolution'.
lowerModifier :: AST.Modifier Zonked -> Lower (VarId, VarId)
lowerModifier m = do
  newValue <- lowerExpr m.value
  targetVar <- case m.name.resolution of
    Just variableResolution -> do
      mLocal <- lookupLocal variableResolution
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
-- '(VariableResolution, VarId)' pairs to bring into scope via 'withLocals'.
bindPatternLocals :: VarId -> AST.Pattern Zonked -> Lower [(Id.VariableResolution, VarId)]
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
  AST.ExpressionRecord recordExpr -> lowerRecordExpr recordExpr.entries
  AST.ExpressionFieldAccess fieldAccessExpr -> do
    object <- lowerExpr fieldAccessExpr.object
    emitGetField object fieldAccessExpr.fieldName.text
  -- Generic instantiation @foo[args]@: the callee value carries a generic
  -- substitution (consulted by @get_metadata@ to specialise its schema). The
  -- callable code itself is generic-erased, so we lower the bare callee and
  -- attach the substitution template — each callee 'GenericsId' mapped to the
  -- (Generic)Schema of its argument: a type parameter to its type schema, an
  -- effect parameter to the requests array of the substituted effect. A
  -- non-generic application (no substitutions) is a plain pass-through.
  AST.ExpressionTypeApplication typeApplicationExpr -> do
    sourceVar <- lowerExpr typeApplicationExpr.callee
    let (typeSubstitution, effectSubstitution) = typeApplicationExpr.instantiation
    case (typeSubstitution, effectSubstitution) of
      ([], []) -> pure sourceVar
      _ -> do
        dataDefs <- asks (.dataDefs)
        topLevelTypes <- asks (.topLevelTypes)
        let typeTemplate =
              [ (genericsId, Schema.jsonSchemaToText (Schema.buildOutputSchema dataDefs argType))
                | (genericsId, argType) <- typeSubstitution
              ]
            effectTemplate =
              [ (genericsId, encodeValueText (Schema.buildRequestsSchema dataDefs topLevelTypes argEffect))
                | (genericsId, argEffect) <- effectSubstitution
              ]
        out <- freshVarId Nothing
        emit (StatementApplyGenerics ApplyGenericsData {source = sourceVar, generics = typeTemplate ++ effectTemplate, output = out})
        pure out
  AST.ExpressionTemplate templateExpr -> lowerTemplate templateExpr
  AST.ExpressionBlock blockExpr -> lowerBlockExpr blockExpr
  AST.ExpressionIf ifExpr -> lowerIfExpr ifExpr
  AST.ExpressionMatch matchExpr -> lowerMatchExpr matchExpr
  AST.ExpressionFor forExpr -> lowerForExpr forExpr
  AST.ExpressionHandler handlerExpr -> lowerHandlerExpr handlerExpr
  AST.ExpressionUse useExpr -> lowerUseExpr useExpr
  AST.ExpressionParTuple parTupleExpr -> lowerTupleExpr True parTupleExpr.elements
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
  calleeVar <- lowerExpr callExpression.callee
  delegateBlk <- freshBlockId
  recordBlock
    delegateBlk
    (BlockDelegate DelegateBlock {target = DelegateTargetValue calleeVar})
    Nothing
  -- A spread call @foo(...e)@ passes @e@'s value directly as the single
  -- argument; a named call builds the argument record from its labelled args.
  argument <- case callExpression.spreadArgument of
    Just spreadExpr -> Just <$> lowerExpr spreadExpr
    Nothing -> do
      argVars <- mapM (lowerExpr . (.value)) callExpression.arguments
      emitArgumentRecord (zip (map (.label.text) callExpression.arguments) argVars)
  out <- freshVarId Nothing
  emit
    ( StatementCall
        CallData {block = delegateBlk, argument = argument, output = Just out}
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
    (firstVarId : rest) -> do
      initVar <- stringify firstVarId
      foldM concatStep initVar rest
  where
    stringify v = emitPrimCall "format" [("value", v)]

    concatStep lhs rhsRaw = do
      rhs <- stringify rhsRaw
      emitPrimCall "concat" [("lhs", lhs), ("rhs", rhs)]

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
          argument = Nothing,
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
          argument = Nothing,
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
          argument = Nothing,
          output = Just out
        }
  pure out

-- | Lower one source arm. Translate the AST pattern to an IR
-- 'MatchPattern' and collect every binding (Identifier 'VariableResolution' →
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
lowerPattern :: AST.Pattern Zonked -> Lower (MatchPattern, [(Id.VariableResolution, VarId)])
lowerPattern = \case
  AST.PatternVariable vp -> case vp.name.resolution of
    Just variableResolution -> do
      var <- freshVarId (Just vp.name.text)
      pure (MatchPatternVariable var, [(variableResolution, var)])
    Nothing -> do
      recordError (LoweringErrorUnresolvedVariable vp.sourceSpan vp.name.text)
      pure (MatchPatternAny, [])
  AST.PatternWildcard _ -> pure (MatchPatternAny, [])
  AST.PatternLiteral lp -> pure (MatchPatternLiteral lp.value, [])
  AST.PatternTuple tp -> do
    (subs, localss) <- mapAndUnzipM lowerPattern tp.elements
    pure (MatchPatternTuple subs, concat localss)
  AST.PatternQualifiedConstructor qp -> do
    ctorQName <- case qp.constructorName.resolution of
      Just qualifiedName -> pure qualifiedName
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
    pure (MatchPatternTypeGuard tp.typeTag innerPat, innerLocals)
  AST.PatternRecord rp -> do
    pairs <- forM rp.entries $ \(entryLabel, sub) -> do
      (subPat, subLocals) <- lowerPattern sub
      pure ((entryLabel, subPat), subLocals)
    let entries = map fst pairs
        locals = concatMap snd pairs
    pure (MatchPatternRecord entries, locals)

-- | Build a child block for a match arm body. The given locals (from
-- pattern bindings) are added to the Reader scope before lowering the
-- body, so user-side variable references resolve to the right
-- 'VarId's.
buildArmBodyWithLocals :: [(Id.VariableResolution, VarId)] -> AST.Block Zonked -> Lower BlockId
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
  -- Allocate the for block id up front so break / next inside the body (and
  -- then-clause) can be stamped with it as their lexical target.
  forBlockId <- freshBlockId
  -- Sources / inits evaluate in the OUTER context (a break there targets the
  -- enclosing construct), so they are NOT wrapped in 'withForTarget'.
  iters <- lowerForIters forExpression.inBindings
  (stateInits, stateLocals) <- lowerForStates forExpression.varBindings
  bodyBlockId <- withForTarget forBlockId (buildForBody iters stateLocals forExpression.body)
  -- The @then@ clause sees state vars (their final value after the loop)
  -- but not iter vars (iteration is over). Its optional pattern binds the
  -- loop's mapped output array. Mirrors the surface semantics:
  -- `for (x in xs) { next x } then (xs2) { ... }` — `xs2` is the mapped
  -- array; `for (x in xs, var acc = 0) { ... } then { acc }` reads state.
  thenBlockId <- traverse (withForTarget forBlockId . buildForThenClause stateLocals) forExpression.thenBlock
  let iterPairs = map (\(e, s, _) -> (e, s)) iters
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
          argument = Nothing,
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
-- (no Text labels) and @stateLocals@ maps each state var's VariableResolution to
-- its bodyVar so the for body can resolve references via 'lookupLocal'.
lowerForStates ::
  [AST.ForVarBinding Zonked] ->
  Lower ([(VarId, VarId)], [(Id.VariableResolution, VarId)])
lowerForStates bindings = do
  results <- mapM one bindings
  pure (map fst (catMaybes results), concatMap snd (catMaybes results))
  where
    one binding = do
      let nameRef = binding.name
      initVar <- lowerExpr binding.initial
      case nameRef.resolution of
        Just variableResolution -> do
          bodyVar <- freshVarId (Just nameRef.text)
          pure (Just ((bodyVar, initVar), [(variableResolution, bodyVar)]))
        Nothing -> do
          recordError (LoweringErrorUnresolvedVariable binding.sourceSpan nameRef.text)
          pure Nothing

-- | Build the inner body block of a @for@. Destructures each iter
-- element pattern into the body's local scope (so the bind statements
-- run per iteration, against the current iter value) and brings the
-- @for@'s state vars into scope. State-var bindings are bare
-- '(VariableResolution, VarId)' pairs because they are written by the runtime
-- on @next with { ... }@; no destructuring statement is needed.
buildForBody ::
  [(VarId, VarId, AST.Pattern Zonked)] ->
  [(Id.VariableResolution, VarId)] ->
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

-- | Build the @then [(pat)] { ... }@ clause of a @for@ expression. The
-- runtime spawns this block with the loop's mapped output array as its
-- single input value; the optional pattern destructures that array (the
-- destructure statement is emitted INSIDE the block, before the body, so it
-- reads the block's input var). The caller passes the @for@'s state-var
-- locals so the body can resolve references to them; iter vars intentionally
-- are NOT in scope. Mirrors 'lowerThenClause' (a handle's @then@).
buildForThenClause ::
  [(Id.VariableResolution, VarId)] ->
  (Maybe (AST.Pattern Zonked), AST.Block Zonked) ->
  Lower BlockId
buildForThenClause stateLocals (maybePattern, body) = do
  blockId <- freshBlockId
  paramVar <- freshVarId (Just "value")
  (trailing, statements) <- runWithFreshBuffer $ do
    paramLocals <- case maybePattern of
      Just pat -> destructurePattern paramVar pat
      Nothing -> pure []
    withLocals (stateLocals ++ paramLocals) (lowerBlockInto body)
  let userBlock =
        defaultUserBlock
          { input = Just paramVar,
            statements = statements,
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
          argument = Nothing,
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
          argument = Nothing,
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

-- | Lower a @handler {...}@ expression into a /provider agent/ closure value:
-- an agent that takes the continuation @k@ as its single (spread) input and runs
-- it under the installed handlers via a 'BlockHandle' whose body is just @k()@.
-- Below Lowering this is indistinguishable from a hand-written
-- @agent provider(...k) { handle { k() } with {handlers} then {...} }@ closed over
-- the definition scope; the type-level @R@/@E@ generics are erased (dispatch is
-- by request id + value, so the runtime needs no substitution). The continuation
-- comes from applying the closure (a direct spread call, or @use@).
--
-- The provider does NOT catch @return@ (it pushes no return target): a @return@
-- in the @then@ clause is lexically the enclosing agent's, so it escalates out
-- across the delegation boundary (lexical control routing), exactly like a @use@
-- continuation.
lowerHandlerExpr :: AST.HandlerExpression Zonked -> Lower VarId
lowerHandlerExpr handlerExpr = do
  providerBlockId <- freshBlockId
  -- The continuation parameter: the provider's single spread input.
  contVar <- freshVarId (Just "$cont")
  handleBlockId <- freshBlockId
  providerBodyBlockId <- freshBlockId
  -- Build the provider agent's body buffer: state inits + a call to the
  -- BlockHandle, whose own body is `{ k() }`. State inits evaluate INSIDE the
  -- provider (per invocation), reading any captured definition-scope vars.
  (providerTrailing, providerStatements) <- runWithFreshBuffer $ do
    stateBinds <- mapM mkHandleStateInit handlerExpr.stateVariables
    let stateInits_ = [(bodyVar, initVar) | (_, bodyVar, initVar) <- stateBinds]
        stateLocals = [(variableResolution, bodyVar) | (Just variableResolution, bodyVar, _) <- stateBinds]
    withLocals stateLocals $ withHandleTarget handleBlockId $ do
      -- The handle body: call the continuation `k()` (no args) and trail it.
      handleBodyBlockId <- freshBlockId
      (handleBodyTrailing, handleBodyStatements) <- runWithFreshBuffer $ do
        kCallBlockId <- freshBlockId
        recordBlock kCallBlockId (BlockDelegate DelegateBlock {target = DelegateTargetValue contVar}) Nothing
        resultVar <- freshVarId Nothing
        emit (StatementCall CallData {block = kCallBlockId, argument = Nothing, output = Just resultVar})
        pure (Just resultVar)
      recordBlock
        handleBodyBlockId
        (BlockUser (defaultUserBlock {statements = handleBodyStatements, trailing = handleBodyTrailing}))
        Nothing
      handlerList <- mapM lowerHandler handlerExpr.handlers
      thenBlockId <- lowerThenClause handlerExpr.thenClause
      recordBlock
        handleBlockId
        ( BlockHandle
            ( HandleBlock
                { parallel = handlerExpr.parallel,
                  stateInits = stateInits_,
                  body = handleBodyBlockId,
                  handlers = handlerList,
                  thenBlock = thenBlockId
                }
            )
        )
        Nothing
      out <- freshVarId Nothing
      emit (StatementCall CallData {block = handleBlockId, argument = Nothing, output = Just out})
      pure (Just out)
  recordBlock
    providerBodyBlockId
    (BlockUser (defaultUserBlock {input = Just contVar, statements = providerStatements, trailing = providerTrailing}))
    (Just "handler.body")
  recordBlock
    providerBlockId
    ( BlockAgent
        AgentBlock
          { qualifiedName = QualifiedName "<local>" "handler",
            defaults = Map.empty,
            entryBody = providerBodyBlockId,
            name = "handler",
            description = Nothing,
            inputSchema = "{}",
            outputSchema = "{}",
            requestsSchema = "[]"
          }
    )
    (Just "handler")
  closureVar <- freshVarId Nothing
  emit (StatementMakeClosure MakeClosureData {output = closureVar, block = providerBlockId})
  pure closureVar
  where
    mkHandleStateInit ::
      AST.StateVariableBinding Zonked ->
      Lower (Maybe Id.VariableResolution, VarId, VarId)
    mkHandleStateInit svb = do
      initVar <- lowerExpr svb.initial
      case svb.name.resolution of
        Just variableResolution -> do
          bodyVar <- freshVarId (Just svb.name.text)
          pure (Just variableResolution, bodyVar, initVar)
        Nothing -> do
          recordError (LoweringErrorUnresolvedVariable svb.sourceSpan svb.name.text)
          bodyVar <- freshVarId Nothing
          pure (Nothing, bodyVar, initVar)

-- | Lower @(let x =)? use expr@ by desugaring into existing IR: the captured
-- continuation @body@ becomes a closure (a local-agent-like block whose single
-- input is the optional binder @x@), and @expr@ is applied to it as a
-- single-value spread call. No dedicated IR block — below Lowering this is
-- indistinguishable from a hand-written @agent k(...x){ body }; expr(...k)@.
lowerUseExpr :: AST.UseExpression Zonked -> Lower VarId
lowerUseExpr useExpr = do
  continuationBlockId <- freshBlockId
  (bodyInput, prelude) <- case useExpr.binder of
    Just binderRef | Just variableResolution <- binderRef.resolution -> do
      binderVar <- freshVarId (Just binderRef.text)
      pure (Just binderVar, pure [(variableResolution, binderVar)])
    _ -> pure (Nothing, pure [])
  -- catchesReturn = False: the continuation is the enclosing agent's body, so
  -- `return` inside it must target THAT agent (it keeps the inherited
  -- currentReturnTarget), not the continuation block.
  lowerSimpleAgent False continuationBlockId "use continuation" bodyInput Map.empty prelude useExpr.body Nothing "{}" "{}" "[]"
  closureVar <- freshVarId Nothing
  emit (StatementMakeClosure MakeClosureData {output = closureVar, block = continuationBlockId})
  -- Apply the handler-provider value to the continuation (single-value call).
  exprVar <- lowerExpr useExpr.expr
  delegateBlk <- freshBlockId
  recordBlock delegateBlk (BlockDelegate DelegateBlock {target = DelegateTargetValue exprVar}) Nothing
  out <- freshVarId Nothing
  emit (StatementCall CallData {block = delegateBlk, argument = Just closureVar, output = Just out})
  pure out

-- | Emit a fresh load-literal statement and return the resulting var.
emitLoadLiteral :: LiteralValue -> Lower VarId
emitLoadLiteral literalValue = do
  outputVar <- freshVarId Nothing
  emit (StatementLoadLiteral LoadLiteralData {output = outputVar, value = literalValue})
  pure outputVar

-- | Lower an 'AST.LiteralExpression' as an 'StatementLoadLiteral'.
lowerLiteral :: AST.LiteralExpression Zonked -> Lower VarId
lowerLiteral lit = emitLoadLiteral lit.value

-- | Lower an 'AST.VariableExpression'. Result depends on whether the
-- referenced 'VariableResolution' is a local binding (just return its IR var) or
-- a top-level decl (allocate a closure value via 'StatementMakeClosure').
lowerVariable :: AST.VariableExpression Zonked -> Lower VarId
lowerVariable variableExpression =
  resolveAsValue True variableExpression.name.resolution variableExpression.sourceSpan variableExpression.name.text (Just variableExpression.name.text)

-- ===========================================================================
-- ID offsetting for merge
-- ===========================================================================

offsetBlockId :: BlockId -> BlockId -> BlockId
offsetBlockId (BlockId base) (BlockId original) = BlockId (base + original)

offsetVarId :: VarId -> VarId -> VarId
offsetVarId (VarId base) (VarId original) = VarId (base + original)

offsetBlockInBlock :: (BlockId -> BlockId) -> (VarId -> VarId) -> Block -> Block
offsetBlockInBlock offsetB offsetV = \case
  BlockAgent agent ->
    -- 'defaults' are literals (no vars); only the entry body is offset.
    BlockAgent agent {entryBody = offsetB agent.entryBody}
  BlockUser user ->
    BlockUser
      user
        { input = fmap offsetV user.input,
          statements = map (offsetStatement offsetB offsetV) user.statements,
          trailing = fmap offsetV user.trailing
        }
  BlockPrim name -> BlockPrim name
  BlockRequest qname -> BlockRequest qname
  BlockConstructor qname -> BlockConstructor qname
  BlockDelegate delegate ->
    BlockDelegate
      delegate
        { target = case delegate.target of
            DelegateTargetExternal ext -> DelegateTargetExternal ext
            DelegateTargetValue varId -> DelegateTargetValue (offsetV varId)
            DelegateTargetInternal internal -> DelegateTargetInternal internal
        }
  BlockMatch matchBlock ->
    BlockMatch
      matchBlock
        { subject = offsetV matchBlock.subject,
          arms = map (offsetArm offsetB offsetV) matchBlock.arms,
          defaultArm = fmap offsetB matchBlock.defaultArm
        }
  BlockFor forBlock ->
    BlockFor
      forBlock
        { iters = map (Data.Bifunctor.bimap offsetV offsetV) forBlock.iters,
          stateInits = map (Data.Bifunctor.bimap offsetV offsetV) forBlock.stateInits,
          bodyBlock = offsetB forBlock.bodyBlock,
          thenBlock = fmap offsetB forBlock.thenBlock
        }
  BlockHandle handleBlock ->
    BlockHandle
      handleBlock
        { stateInits = map (Data.Bifunctor.bimap offsetV offsetV) handleBlock.stateInits,
          body = offsetB handleBlock.body,
          handlers = map (offsetHandler offsetB) handleBlock.handlers,
          thenBlock = fmap offsetB handleBlock.thenBlock
        }
  BlockTuple tupleBlock ->
    BlockTuple tupleBlock {elements = map offsetB tupleBlock.elements}
  BlockRecord block ->
    BlockRecord block {entries = map (second offsetB) block.entries}
  BlockGetField block ->
    BlockGetField block {source = offsetV block.source}


offsetStatement :: (BlockId -> BlockId) -> (VarId -> VarId) -> Statement -> Statement
offsetStatement offsetB offsetV = \case
  StatementCall callData ->
    StatementCall
      callData
        { block = offsetB callData.block,
          argument = fmap offsetV callData.argument,
          output = fmap offsetV callData.output
        }
  StatementMakeClosure closureData ->
    StatementMakeClosure
      closureData
        { output = offsetV closureData.output,
          block = offsetB closureData.block
        }
  StatementLoadLiteral loadData ->
    StatementLoadLiteral loadData {output = offsetV loadData.output}
  StatementExit exitData ->
    StatementExit exitData {value = offsetV exitData.value, target = offsetB exitData.target}
  StatementCont contData ->
    StatementCont
      contData
        { value = fmap offsetV contData.value,
          modifiers = map (Data.Bifunctor.bimap offsetV offsetV) contData.modifiers,
          target = offsetB contData.target
        }
  StatementBindPattern bindData ->
    StatementBindPattern
      bindData
        { source = offsetV bindData.source,
          pattern = offsetMatchPattern offsetV bindData.pattern
        }
  StatementApplyGenerics applyData ->
    StatementApplyGenerics
      applyData
        { source = offsetV applyData.source,
          output = offsetV applyData.output
        }

offsetArm :: (BlockId -> BlockId) -> (VarId -> VarId) -> MatchArm -> MatchArm
offsetArm offsetB offsetV arm =
  arm {pattern = offsetMatchPattern offsetV arm.pattern, body = offsetB arm.body}

offsetMatchPattern :: (VarId -> VarId) -> MatchPattern -> MatchPattern
offsetMatchPattern offsetV = \case
  MatchPatternAny -> MatchPatternAny
  MatchPatternVariable varId -> MatchPatternVariable (offsetV varId)
  MatchPatternLiteral literal -> MatchPatternLiteral literal
  MatchPatternConstructor qname fields ->
    MatchPatternConstructor qname (map (Data.Bifunctor.second (offsetMatchPattern offsetV)) fields)
  MatchPatternTuple elements ->
    MatchPatternTuple (map (offsetMatchPattern offsetV) elements)
  MatchPatternTypeGuard tag inner ->
    MatchPatternTypeGuard tag (offsetMatchPattern offsetV inner)
  MatchPatternRecord entries ->
    MatchPatternRecord (map (Data.Bifunctor.second (offsetMatchPattern offsetV)) entries)

offsetHandler :: (BlockId -> BlockId) -> Handler -> Handler
offsetHandler offsetB handler =
  handler {handlerBody = offsetB handler.handlerBody}
