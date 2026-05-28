-- | Pure orchestration entry point for the Katari compiler.
--
-- Each phase exposes a per-module function; this module calls them in
-- the right order and manages the incremental cache.
--
-- @
-- parseSources (parallel, cache-miss only)
--   → identify (per module, topological order)
--   → typecheck (per module, SCC per module, parallel within topo level)
--   → lower (per module, fully parallel)
--   → schema (per module, fully parallel)
-- @
module Katari.Compile
  ( -- * Inputs / outputs
    ModuleName,
    SourceEntry (..),
    CompileInput (..),
    CompileResult (..),
    CompileLog (..),
    renderCompileLog,
    ModuleCache (..),

    -- * Entry
    compile,

    -- * Helpers (exposed for testing)
    parseSources,
    parsedStdlibModules,
    identifyWithStdlib,
    generateConstraintsAll,
    compileSync,
  )
where

import Control.Concurrent.Async (Async, async, wait)
import Control.Monad (when)
import Control.Parallel.Strategies (parMap, rseq)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Maybe (mapMaybe)
import Data.Foldable (foldl', for_)
import Data.Hashable (hash)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import System.IO.Unsafe (unsafePerformIO)
import Katari.AST
  ( Declaration (..),
    ImportDeclaration (..),
    ImportKind (..),
    Module (..),
    Phase (Identified, Parsed, Zonked),
  )
import Katari.Diagnostic (Diagnostic, hasErrors)
import Katari.IR qualified
import Katari.Id (QualifiedName (..), VariableResolution (..))
import Katari.Lexer qualified as Lexer
import Katari.Lowering (ModuleLoweringResult (..), lowerModule, mergeModuleLowerings)
import Katari.Lowering qualified as Lowering
import Katari.Parser qualified as Parser
import Katari.Query qualified as Query
import Katari.Schema
  ( DataDefs,
    SchemaContext (..),
    SchemaEntry (..),
    buildDataDefs,
    buildModuleSchemas,
    collectDataAnnotations,
  )
import Katari.SemanticType (Resolved, SemanticType)
import Katari.SourceSpan (Position (..), SourceSpan (..))
import Katari.Stdlib qualified as Stdlib
import Katari.Typechecker qualified as Typechecker
import Katari.Typechecker.ConstraintGenerator (ConstraintGenResult (..), VariableSupply (..))
import Katari.Typechecker.ConstraintGenerator qualified as CG
import Katari.Typechecker.Exhaustive (ExhaustiveEnv (..), checkExhaustiveModule)
import Katari.Typechecker.Exhaustive qualified as Exhaustive
import Katari.Typechecker.Identifier
  ( ConstructorData (..),
    IdentifierResult (..),
    IdentifierState (..),
    ModuleData (..),
    ModuleIdentifyResult (..),
    RequestData (..),
    SymbolEntry (..),
    TypeData (..),
    VariableData (..),
  )
import Katari.Typechecker.Identifier qualified as Identifier
import Katari.Typechecker.ImportGraph (findImportCycles, topologicalSort)
import Katari.Typechecker.ModuleInterface (ModuleInterface (..))
import Katari.Typechecker.ScopeIndex (ScopeFrame (..), ScopeIndex (..), buildScopeIndex)
import Katari.Typechecker.Zonker (ZonkResult (..))

-- ===========================================================================
-- Input / output
-- ===========================================================================

type ModuleName = Text

data SourceEntry = SourceEntry
  { filePath :: FilePath,
    sourceText :: Text
  }
  deriving (Show)

data CompileInput = CompileInput
  { sources :: Map ModuleName SourceEntry,
    cache :: Map ModuleName ModuleCache
  }
  deriving (Show)

-- | Per-module compilation cache. Stores just enough to (a) skip the
-- module's own compile on a cache hit and (b) let downstream modules
-- typecheck, lower, and schema-generate against this module without
-- re-parsing or re-identifying it.
--
-- Notably absent: full Identified / Zonked ASTs. The query layer can't
-- answer hover / references queries on cache-hit modules until they're
-- recompiled (e.g. on next file change).
data ModuleCache = ModuleCache
  { cacheSourceHash :: Int,
    -- | Imports of the original module, used to rebuild the import
    -- skeleton needed for the dependency graph.
    cacheImports :: [ImportDeclaration],
    -- For downstream identify:
    cacheModuleData :: ModuleData,
    cacheModuleExports :: Map Text SymbolEntry,
    cacheModuleTopLevel :: Map Text SymbolEntry,
    cacheIdentifierVariables :: Map QualifiedName VariableData,
    cacheIdentifierTypes :: Map QualifiedName TypeData,
    cacheIdentifierRequests :: Map QualifiedName RequestData,
    cacheIdentifierConstructors :: Map QualifiedName ConstructorData,
    -- For downstream typecheck:
    cacheInterface :: ModuleInterface,
    -- For downstream lower/schema's DataDefs construction:
    cacheDataAnnotations :: Map QualifiedName (Map Text (Maybe Text)),
    -- For the final bundle:
    cacheLoweringResult :: ModuleLoweringResult,
    cacheSchemaEntries :: [SchemaEntry],
    -- Diagnostics this module emitted in its previous compile:
    cacheDiagnostics :: [Diagnostic]
  }
  deriving (Show)

data CompileLog where
  CompileLogParsing :: ModuleName -> CompileLog
  CompileLogIdentifying :: ModuleName -> CompileLog
  CompileLogTypechecking :: ModuleName -> CompileLog
  CompileLogLowering :: ModuleName -> CompileLog
  CompileLogSchemaGeneration :: ModuleName -> CompileLog
  CompileLogComplete :: CompileLog
  deriving (Show)

renderCompileLog :: CompileLog -> Text
renderCompileLog = \case
  CompileLogParsing moduleName -> "[parsing] " <> moduleName
  CompileLogIdentifying moduleName -> "[identifying] " <> moduleName
  CompileLogTypechecking moduleName -> "[typechecking] " <> moduleName
  CompileLogLowering moduleName -> "[lowering] " <> moduleName
  CompileLogSchemaGeneration moduleName -> "[schema] " <> moduleName
  CompileLogComplete -> "[done]"

data CompileResult = CompileResult
  { irModule :: Maybe Katari.IR.IRModule,
    schemaEntries :: Maybe [SchemaEntry],
    diagnostics :: [Diagnostic],
    -- | Pre-built input for the query layer (hover / completion / etc.).
    -- Owned by 'Katari.Query'; the orchestrator only fills it in.
    querySnapshot :: Query.QuerySnapshot,
    updatedCache :: Map ModuleName ModuleCache
  }

-- ===========================================================================
-- Top-level entry
-- ===========================================================================

compile :: (CompileLog -> IO ()) -> CompileInput -> IO CompileResult
compile emitLog input = do
  let stdlibEntries =
        Map.mapWithKey
          (\moduleName src -> SourceEntry ("<stdlib:" <> Text.unpack moduleName <> ">") src)
          Stdlib.stdlibSources
      mergedSources = Map.union input.sources stdlibEntries
      sourceHashes = Map.map (\entry -> hash entry.sourceText) mergedSources
      cacheHitModules =
        Map.filterWithKey
          ( \moduleName cached ->
              case Map.lookup moduleName sourceHashes of
                Just sourceHash -> sourceHash == cached.cacheSourceHash
                Nothing -> False
          )
          input.cache
      cacheHitNames = Map.keysSet cacheHitModules
      cacheMissNames = Set.difference (Map.keysSet mergedSources) cacheHitNames

  for_ (Set.toList cacheMissNames) (emitLog . CompileLogParsing)
  let cacheMissSources = Map.restrictKeys mergedSources cacheMissNames
      (freshParsed, parseDiags) = parseSources cacheMissSources
      cachedSkeletonParsed =
        Map.map
          ( \cached ->
              Module
                { declarations = map DeclarationImport cached.cacheImports,
                  sourceSpan = cached.cacheModuleData.moduleSourceSpan
                }
          )
          cacheHitModules
      allParsed = Map.union freshParsed cachedSkeletonParsed

  for_ (Set.toList cacheMissNames) (emitLog . CompileLogIdentifying)
  let (idResult, idErrors) = runIdentify Stdlib.stdlibModuleNames allParsed cacheHitModules
      idDiags = map Identifier.toDiagnostic idErrors

  -- Compute topological order + direct deps for the Async pipeline.
  let stdlibModuleSet =
        Set.fromList
          [ moduleName
            | moduleName <- Map.keys allParsed,
              Set.member moduleName Stdlib.stdlibModuleNames
          ]
      primitiveSingleton = Set.singleton "primitive"
      otherStdlibModules = Set.delete "primitive" stdlibModuleSet
      stdlibLevels =
        ([primitiveSingleton | Set.member "primitive" stdlibModuleSet])
          ++ ([otherStdlibModules | not (Set.null otherStdlibModules)])
      userModuleMap = Map.filterWithKey (\moduleName _ -> not (Set.member moduleName Stdlib.stdlibModuleNames)) allParsed
      userLevels = topologicalSort userModuleMap
      remainingUserNames =
        Set.fromList
          [ moduleName
            | moduleName <- Map.keys userModuleMap,
              not (Set.member moduleName (Set.unions userLevels))
          ]
      moduleLevels =
        stdlibLevels
          ++ userLevels
          ++ ([remainingUserNames | not (Set.null remainingUserNames)])
      orderedModules = concatMap Set.toList moduleLevels
      directDeps =
        Map.map
          ( \m ->
              [ depName
                | DeclarationImport imp <- m.declarations,
                  let depName = importedModuleName imp,
                  Map.member depName allParsed
              ]
          )
          allParsed

  -- Per-module Async typecheck. Each module's task waits for its direct
  -- imports' tasks before running.
  (mergedZonkResult, typecheckDiags, typecheckCache) <-
    typecheckModulesAsync
      emitLog
      idResult
      orderedModules
      directDeps
      sourceHashes
      input.cache

  let exhaustiveEnv =
        ExhaustiveEnv
          { constructors = idResult.identifiedConstructors,
            topLevelTypes =
              Map.fromList
                [ (qualifiedName, ty)
                  | (_, perModuleEnv) <- Map.toList mergedZonkResult.zonkedTypeEnvironment,
                    (ResolvedTopLevel qualifiedName, ty) <- Map.toList perModuleEnv
                ],
            localTypeEnv = Map.empty -- replaced per module below
          }
      exhaustiveDiags =
        concat
          [ map Exhaustive.toDiagnostic $
              checkExhaustiveModule
                exhaustiveEnv {localTypeEnv = Map.findWithDefault Map.empty moduleName mergedZonkResult.zonkedTypeEnvironment}
                moduleAST
            | (moduleName, moduleAST) <- Map.toList mergedZonkResult.zonkedModules
          ]
      preLowerDiags =
        parseDiags
          <> idDiags
          <> typecheckDiags
          <> exhaustiveDiags
      shouldLower = not (hasErrors preLowerDiags)

  let freshLowerInputs =
        [ (moduleName, moduleAST)
          | (moduleName, moduleAST) <- Map.toList mergedZonkResult.zonkedModules,
            Set.member moduleName cacheMissNames
        ]
  for_ (map fst freshLowerInputs) (emitLog . CompileLogLowering)
  let dataAnnotations =
        Map.unions
          [ collectDataAnnotations idResult.identifiedVariables m
            | m <- Map.elems mergedZonkResult.zonkedModules
          ]
      mergedDataDefs =
        buildDataDefs
          idResult.identifiedConstructors
          exhaustiveEnv.topLevelTypes
          dataAnnotations
      lowerContext =
        Lowering.LowerContext
          { Lowering.topLevelTypes = exhaustiveEnv.topLevelTypes,
            Lowering.dataDefs = mergedDataDefs,
            Lowering.requestNames = Map.keysSet idResult.identifiedRequests,
            Lowering.constructorNames = Map.keysSet idResult.identifiedConstructors
          }
  let (loweringResults, loweringDiags)
        | shouldLower =
            let cachedResults =
                  Map.map (.cacheLoweringResult) cacheHitModules
                freshResults =
                  Map.fromList
                    ( parMap
                        rseq
                        ( \(moduleName, moduleAST) ->
                            let localEnv = Map.findWithDefault Map.empty moduleName mergedZonkResult.zonkedTypeEnvironment
                                (result, errors) = lowerModule lowerContext moduleName localEnv moduleAST
                             in (moduleName, (result, errors))
                        )
                        freshLowerInputs
                    )
                freshOk = Map.map fst freshResults
                freshErrors = concatMap snd (Map.elems freshResults)
                freshDiags = map Lowering.toDiagnostic freshErrors
                allResults = Map.union cachedResults (Map.mapMaybe eitherToMaybe freshOk)
             in (allResults, freshDiags)
        | otherwise = (Map.empty, [])

      shouldEmitArtefacts = shouldLower && not (hasErrors loweringDiags)
      finalIR
        | shouldEmitArtefacts = Just (mergeModuleLowerings (Map.elems loweringResults))
        | otherwise = Nothing

  for_ (Set.toList cacheMissNames) (emitLog . CompileLogSchemaGeneration)
  let cachedSchemaEntries = concatMap (.cacheSchemaEntries) (Map.elems cacheHitModules)
      freshSchemaEntries =
        if shouldEmitArtefacts
          then buildSchemasForModules idResult mergedDataDefs exhaustiveEnv.topLevelTypes cacheMissNames
          else []
      schema =
        if shouldEmitArtefacts
          then Just (cachedSchemaEntries <> freshSchemaEntries)
          else Nothing

      allDiags = preLowerDiags <> loweringDiags

      freshCache =
        buildFreshCacheEntries
          sourceHashes
          idResult
          typecheckCache
          loweringResults
          freshSchemaEntries
          cacheMissNames
      updatedCacheMap = Map.union freshCache cacheHitModules

  emitLog CompileLogComplete
  pure
    CompileResult
      { irModule = finalIR,
        schemaEntries = schema,
        diagnostics = allDiags,
        querySnapshot = Query.buildQuerySnapshot idResult mergedZonkResult,
        updatedCache = updatedCacheMap
      }

eitherToMaybe :: Either a b -> Maybe b
eitherToMaybe = \case
  Left _ -> Nothing
  Right x -> Just x

-- ===========================================================================
-- Per-module Async typecheck pipeline
-- ===========================================================================

-- | What each typecheck task hands back to the final-cache assembler.
-- Holds only what's needed to construct a 'ModuleCache' downstream.
data TypecheckCacheEntry = TypecheckCacheEntry
  { tceInterface :: ModuleInterface,
    tceDataAnnotations :: Map QualifiedName (Map Text (Maybe Text)),
    tceDiagnostics :: [Diagnostic]
  }

-- | Per-module typecheck task output. Each Async task produces one of
-- these; downstream tasks @wait@ for their imports' results and read
-- 'exportedTypes' to feed into their own typecheck call.
data TypecheckTaskResult = TypecheckTaskResult
  { taskModuleName :: Text,
    taskZonkedModule :: Module Zonked,
    taskTypeEnvironment :: Map VariableResolution (SemanticType Resolved),
    taskExportedTypes :: Map QualifiedName (SemanticType Resolved),
    taskDiagnostics :: [Diagnostic],
    taskCacheEntry :: TypecheckCacheEntry,
    taskIsCacheHit :: Bool
  }

typecheckModulesAsync ::
  (CompileLog -> IO ()) ->
  IdentifierResult ->
  [ModuleName] ->
  Map ModuleName [ModuleName] ->
  Map ModuleName Int ->
  Map ModuleName ModuleCache ->
  IO (ZonkResult, [Diagnostic], Map ModuleName TypecheckCacheEntry)
typecheckModulesAsync emitLog idResult orderedModules directDeps sourceHashes inputCache = do
  tasksRef <- newIORef Map.empty
  for_ orderedModules $ \modName -> do
    existing <- readIORef tasksRef
    let depTasks =
          mapMaybe (`Map.lookup` existing) (Map.findWithDefault [] modName directDeps)
        cached = Map.lookup modName inputCache
        sourceHash = Map.findWithDefault 0 modName sourceHashes
    task <-
      async (runTypecheckTask emitLog idResult modName cached sourceHash depTasks)
    modifyIORef' tasksRef (Map.insert modName task)
  tasks <- readIORef tasksRef
  results <- traverse wait tasks

  let zonkedModules' = Map.map (.taskZonkedModule) results
      zonkedTypeEnv' = Map.map (.taskTypeEnvironment) results
      mergedZonkResult =
        ZonkResult
          { zonkedModules = zonkedModules',
            zonkedTypeEnvironment = zonkedTypeEnv'
          }
      diagnostics' = concatMap (.taskDiagnostics) (Map.elems results)
      cache' = Map.map (.taskCacheEntry) results
  pure (mergedZonkResult, diagnostics', cache')

runTypecheckTask ::
  (CompileLog -> IO ()) ->
  IdentifierResult ->
  ModuleName ->
  Maybe ModuleCache ->
  Int ->
  [Async TypecheckTaskResult] ->
  IO TypecheckTaskResult
runTypecheckTask emitLog idResult moduleName cached sourceHash depTasks = do
  depResults <- mapM wait depTasks
  let allDepsCacheHit = all (.taskIsCacheHit) depResults
      cacheValid = case cached of
        Just c -> allDepsCacheHit && c.cacheSourceHash == sourceHash
        Nothing -> False
  case cached of
    Just c | cacheValid -> pure (typecheckFromCache moduleName c)
    _ -> do
      emitLog (CompileLogTypechecking moduleName)
      let importedTypes = Map.unions (map (.taskExportedTypes) depResults)
          result = Typechecker.typecheckModule idResult importedTypes moduleName
          dataAnnotations =
            collectDataAnnotations idResult.identifiedVariables result.zonkedModule
          newCacheEntry =
            TypecheckCacheEntry
              { tceInterface = result.moduleInterface,
                tceDataAnnotations = dataAnnotations,
                tceDiagnostics = result.diagnostics
              }
      pure
        TypecheckTaskResult
          { taskModuleName = moduleName,
            taskZonkedModule = result.zonkedModule,
            taskTypeEnvironment = result.localTypeEnv,
            taskExportedTypes = result.moduleInterface.exportedTypes,
            taskDiagnostics = result.diagnostics,
            taskCacheEntry = newCacheEntry,
            taskIsCacheHit = False
          }

typecheckFromCache :: ModuleName -> ModuleCache -> TypecheckTaskResult
typecheckFromCache moduleName c =
  TypecheckTaskResult
    { taskModuleName = moduleName,
      -- Cache-hit modules contribute no zonked AST / local typeEnv to the
      -- result — only their exported types matter for downstream phases.
      taskZonkedModule = Module {declarations = [], sourceSpan = emptySrcSpan},
      taskTypeEnvironment = Map.empty,
      taskExportedTypes = c.cacheInterface.exportedTypes,
      taskDiagnostics = c.cacheDiagnostics,
      taskCacheEntry =
        TypecheckCacheEntry
          { tceInterface = c.cacheInterface,
            tceDataAnnotations = c.cacheDataAnnotations,
            tceDiagnostics = c.cacheDiagnostics
          },
      taskIsCacheHit = True
    }

importedModuleName :: ImportDeclaration -> Text
importedModuleName imp = case imp.kind of
  ImportNames {moduleName = m} -> m
  ImportModule {moduleName = m} -> m

emptySrcSpan :: SourceSpan
emptySrcSpan =
  SrcSpan
    { filePath = "",
      start = Position {line = 0, column = 0},
      end = Position {line = 0, column = 0}
    }

-- ===========================================================================
-- Parse helper
-- ===========================================================================

parseSources :: Map ModuleName SourceEntry -> (Map ModuleName (Module Parsed), [Diagnostic])
parseSources sources =
  let parseEntry (modName, entry) =
        let (stream, lexErrors) = Lexer.lex entry.filePath entry.sourceText
            (m, errs) = Parser.parse entry.filePath stream
         in ((modName, m), map Parser.toDiagnostic errs <> map Lexer.toDiagnostic lexErrors)
      parsedEntries = map parseEntry (Map.toList sources)
      modules = Map.fromList (map fst parsedEntries)
      diags = concatMap snd parsedEntries
   in (modules, diags)

parsedStdlibModules :: Map ModuleName (Module Parsed)
parsedStdlibModules = fst (parseSources stdlibEntries)
  where
    stdlibEntries =
      Map.mapWithKey
        (\moduleName src -> SourceEntry ("<stdlib:" <> Text.unpack moduleName <> ">") src)
        Stdlib.stdlibSources

identifyWithStdlib ::
  Map ModuleName (Module Parsed) ->
  (IdentifierResult, [Identifier.IdentifierError])
identifyWithStdlib userMods =
  runIdentify Stdlib.stdlibModuleNames (Map.union userMods parsedStdlibModules) Map.empty

generateConstraintsAll ::
  IdentifierResult ->
  (ConstraintGenResult, [CG.ConstraintError])
generateConstraintsAll = CG.generateConstraints

compileSync :: CompileInput -> CompileResult
compileSync input = unsafePerformIO $ compile (const (pure ())) input

-- ===========================================================================
-- Identifier orchestration
-- ===========================================================================

type IdentifyAccum =
  ( Map Text (Module Identified),
    Map Text (Map Text SymbolEntry),
    Map Text (Map Text SymbolEntry),
    IdentifierState
  )

runIdentify ::
  Set.Set Text ->
  Map Text (Module Parsed) ->
  Map ModuleName ModuleCache ->
  (IdentifierResult, [Identifier.IdentifierError])
runIdentify trustedStdlibNames moduleMap cachedModules =
  let ((), cycleState) =
        Identifier.runIdentifier $
          for_ (findImportCycles moduleMap) (Identifier.emitImportCycleError moduleMap)

      ((), phaseAState) =
        Identifier.runIdentifierFrom cycleState $
          Identifier.registerAllModules trustedStdlibNames moduleMap

      allModuleNames = Map.keysSet moduleMap
      allExportNames = Map.map Identifier.scanExportNames moduleMap

      stepFresh :: IdentifyAccum -> Text -> IdentifyAccum
      stepFresh (asts, exports, topLevels, state) moduleName =
        case Map.lookup moduleName moduleMap of
          Nothing -> (asts, exports, topLevels, state)
          Just parsedModule ->
            let moduleResult =
                  Identifier.identifyModule
                    allExportNames
                    exports
                    allModuleNames
                    state
                    moduleName
                    parsedModule
             in ( Map.insert moduleName moduleResult.identifiedAST asts,
                  Map.insert moduleName moduleResult.moduleExportTable exports,
                  Map.insert moduleName moduleResult.moduleTopLevel topLevels,
                  moduleResult.moduleState
                )

      stepCachedOrFresh :: IdentifyAccum -> Text -> IdentifyAccum
      stepCachedOrFresh accumulator@(asts, exports, topLevels, state) moduleName =
        case Map.lookup moduleName cachedModules of
          Just cached ->
            -- Cached modules don't restore an Identified AST or scope
            -- frames — the LSP layer can't answer hover / scope queries
            -- on a cache-hit module until it's recompiled.
            let injectedState =
                  state
                    { variables = Map.union cached.cacheIdentifierVariables state.variables,
                      types = Map.union cached.cacheIdentifierTypes state.types,
                      requests = Map.union cached.cacheIdentifierRequests state.requests,
                      constructors = Map.union cached.cacheIdentifierConstructors state.constructors,
                      modules = Map.insert moduleName cached.cacheModuleData state.modules
                    }
             in ( asts,
                  Map.insert moduleName cached.cacheModuleExports exports,
                  Map.insert moduleName cached.cacheModuleTopLevel topLevels,
                  injectedState
                )
          Nothing -> stepFresh accumulator moduleName

      stdlibModuleNames =
        [ moduleName
          | moduleName <- Map.keys moduleMap,
            Set.member moduleName trustedStdlibNames
        ]
      sortedStdlibNames =
        filter (== "primitive") stdlibModuleNames
          ++ filter (/= "primitive") stdlibModuleNames
      (stdlibASTs, stdlibExports, stdlibTopLevels, stdlibState) =
        foldl' stepCachedOrFresh (Map.empty, Map.empty, Map.empty, phaseAState) sortedStdlibNames

      userModuleMap = Map.filterWithKey (\moduleName _ -> not (Set.member moduleName trustedStdlibNames)) moduleMap
      levels = topologicalSort userModuleMap
      (acyclicASTs, acyclicExports, acyclicTopLevels, acyclicState) =
        foldl'
          (\accumulator level -> foldl' stepCachedOrFresh accumulator (Set.toList level))
          (stdlibASTs, stdlibExports, stdlibTopLevels, stdlibState)
          levels

      processedModuleNames = Map.keysSet acyclicASTs
      remainingModuleNames =
        [ moduleName
          | moduleName <- Map.keys moduleMap,
            not (Set.member moduleName processedModuleNames)
        ]
      (allASTs, allExports, allTopLevels, finalState) =
        foldl' stepCachedOrFresh (acyclicASTs, acyclicExports, acyclicTopLevels, acyclicState) remainingModuleNames

      capturedFrames =
        [ScopeFrame {frameSpan = sp, frameSymbols = sym} | (sp, sym) <- finalState.capturedScopeFrames]
      result =
        Identifier.mkIdentifierResult
          finalState.modules
          finalState.variables
          finalState.types
          finalState.requests
          finalState.constructors
          allASTs
          (buildScopeIndex capturedFrames)
          allTopLevels
          allExports
   in (result, reverse finalState.errors)

-- ===========================================================================
-- Helpers
-- ===========================================================================

-- | Extract import declarations from an Identified module (for cache
-- skeleton building).
extractImportDeclarations :: Module Identified -> [ImportDeclaration]
extractImportDeclarations moduleAST =
  [importDecl | DeclarationImport importDecl <- moduleAST.declarations]

-- | Build schema entries for cache-miss modules only.
buildSchemasForModules ::
  IdentifierResult ->
  DataDefs ->
  Map QualifiedName (SemanticType Resolved) ->
  Set.Set Text ->
  [SchemaEntry]
buildSchemasForModules idResult mergedDataDefs topLevelTypes moduleNames =
  let ctx =
        SchemaContext
          { dataDefs = mergedDataDefs,
            topLevelTypes = topLevelTypes,
            requestData = idResult.identifiedRequests
          }
      filteredVariables =
        Map.filterWithKey
          (\qualifiedName _ -> Set.member qualifiedName.module_ moduleNames)
          idResult.identifiedVariables
   in buildModuleSchemas ctx filteredVariables

-- ===========================================================================
-- Cache construction
-- ===========================================================================

buildFreshCacheEntries ::
  Map ModuleName Int ->
  IdentifierResult ->
  Map ModuleName TypecheckCacheEntry ->
  Map ModuleName ModuleLoweringResult ->
  [SchemaEntry] ->
  Set.Set Text ->
  Map ModuleName ModuleCache
buildFreshCacheEntries sourceHashes idResult typecheckCache loweringResults schemaEntries_ cacheMissNames_ =
  let schemaByModule =
        foldl'
          ( \accumulator entry ->
              let moduleName = schemaEntryModule entry
               in Map.insertWith (++) moduleName [entry] accumulator
          )
          Map.empty
          schemaEntries_
      emptyLoweringResult =
        ModuleLoweringResult
          { mlrBlocks = Map.empty,
            mlrEntries = Map.empty,
            mlrNameTable = Katari.IR.emptyNameTable,
            mlrBlockCount = 0,
            mlrVarCount = 0
          }
   in Map.fromSet
        ( \moduleName ->
            let tce =
                  Map.findWithDefault
                    ( TypecheckCacheEntry
                        { tceInterface = ModuleInterface {exportedTypes = Map.empty},
                          tceDataAnnotations = Map.empty,
                          tceDiagnostics = []
                        }
                    )
                    moduleName
                    typecheckCache
                moduleVariables =
                  Map.filterWithKey (\qualifiedName _ -> qualifiedName.module_ == moduleName) idResult.identifiedVariables
                moduleTypes =
                  Map.filterWithKey (\qualifiedName _ -> qualifiedName.module_ == moduleName) idResult.identifiedTypes
                moduleRequests =
                  Map.filterWithKey (\qualifiedName _ -> qualifiedName.module_ == moduleName) idResult.identifiedRequests
                moduleConstructors =
                  Map.filterWithKey (\qualifiedName _ -> qualifiedName.module_ == moduleName) idResult.identifiedConstructors
                moduleData =
                  Map.findWithDefault
                    (ModuleData {moduleSourceSpan = emptySrcSpan})
                    moduleName
                    idResult.identifiedModules
                moduleExports = Map.findWithDefault Map.empty moduleName idResult.moduleExports
                moduleTopLevel = Map.findWithDefault Map.empty moduleName idResult.moduleVisibleSymbols
                moduleImports = case Map.lookup moduleName idResult.moduleASTs of
                  Just ast -> extractImportDeclarations ast
                  Nothing -> []
             in ModuleCache
                  { cacheSourceHash = Map.findWithDefault 0 moduleName sourceHashes,
                    cacheImports = moduleImports,
                    cacheIdentifierVariables = moduleVariables,
                    cacheIdentifierTypes = moduleTypes,
                    cacheIdentifierRequests = moduleRequests,
                    cacheIdentifierConstructors = moduleConstructors,
                    cacheModuleData = moduleData,
                    cacheModuleExports = moduleExports,
                    cacheModuleTopLevel = moduleTopLevel,
                    cacheInterface = tce.tceInterface,
                    cacheDataAnnotations = tce.tceDataAnnotations,
                    cacheLoweringResult = Map.findWithDefault emptyLoweringResult moduleName loweringResults,
                    cacheSchemaEntries = Map.findWithDefault [] moduleName schemaByModule,
                    cacheDiagnostics = tce.tceDiagnostics
                  }
        )
        cacheMissNames_

schemaEntryModule :: SchemaEntry -> Text
schemaEntryModule (SchemaEntry {name = entryName}) =
  let parts = Text.splitOn "." entryName
   in case parts of
        [] -> ""
        [single] -> single
        _ -> Text.intercalate "." (init parts)

moduleSourceFilePath :: Text -> IdentifierResult -> FilePath
moduleSourceFilePath moduleName idResult =
  case Map.lookup moduleName idResult.identifiedModules of
    Just moduleData_ -> moduleData_.moduleSourceSpan.filePath
    Nothing -> ""
