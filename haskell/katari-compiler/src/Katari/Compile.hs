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

import Control.Parallel.Strategies (parMap, rseq)
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

-- | Per-module compilation cache. Stores only the outputs needed to
-- skip ALL compilation phases on cache hit.
data ModuleCache = ModuleCache
  { cacheSourceHash :: Int,
    -- Identifier output (needed for downstream modules' identify)
    cacheIdentifierVariables :: Map QualifiedName VariableData,
    cacheIdentifierTypes :: Map QualifiedName TypeData,
    cacheIdentifierRequests :: Map QualifiedName RequestData,
    cacheIdentifierConstructors :: Map QualifiedName ConstructorData,
    cacheModuleData :: ModuleData,
    cacheModuleExports :: Map Text SymbolEntry,
    cacheModuleTopLevel :: Map Text SymbolEntry,
    cacheScopeFrames :: [(SourceSpan, Map Text SymbolEntry)],
    cacheIdentifiedAST :: Module Identified,
    -- Typecheck output
    cacheInterface :: ModuleInterface,
    cacheZonkedModule :: Module Zonked,
    cacheZonkedTypeEnv :: Map VariableResolution (SemanticType Resolved),
    -- IR output
    cacheLoweringResult :: ModuleLoweringResult,
    -- Schema output
    cacheSchemaEntries :: [SchemaEntry],
    -- Diagnostics
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
    identifierResult :: IdentifierResult,
    zonkResult :: ZonkResult,
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
                { declarations = map DeclarationImport (extractImportDeclarations cached.cacheIdentifiedAST),
                  sourceSpan = cached.cacheModuleData.moduleSourceSpan
                }
          )
          cacheHitModules
      allParsed = Map.union freshParsed cachedSkeletonParsed

  for_ (Set.toList cacheMissNames) (emitLog . CompileLogIdentifying)
  let (idResult, idErrors) = runIdentify Stdlib.stdlibModuleNames allParsed cacheHitModules
      idDiags = map Identifier.toDiagnostic idErrors

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

  let (mergedZonkResult, typecheckDiags, typecheckLogs, typecheckCache) =
        typecheckModules idResult moduleLevels sourceHashes input.cache
  for_ typecheckLogs emitLog

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
        identifierResult = idResult,
        zonkResult = mergedZonkResult,
        updatedCache = updatedCacheMap
      }

eitherToMaybe :: Either a b -> Maybe b
eitherToMaybe = \case
  Left _ -> Nothing
  Right x -> Just x

-- ===========================================================================
-- Per-module typecheck loop
-- ===========================================================================

data TypecheckCacheEntry = TypecheckCacheEntry
  { tceInterface :: ModuleInterface,
    tceIdentified :: Module Identified,
    tceZonkedModule :: Module Zonked,
    tceZonkedTypeEnv :: Map VariableResolution (SemanticType Resolved),
    tceDiagnostics :: [Diagnostic]
  }

data TypecheckAccumulator = TypecheckAccumulator
  { accImportedTypes :: Map QualifiedName (SemanticType Resolved),
    accZonkedModules :: Map Text (Module Zonked),
    accZonkedTypeEnvironment :: Map Text (Map VariableResolution (SemanticType Resolved)),
    accDiagnostics :: [Diagnostic],
    accLogs :: [CompileLog],
    accUpdatedCache :: Map ModuleName TypecheckCacheEntry,
    accAllPriorCacheValid :: Bool
  }

data ModuleTypecheckResult = ModuleTypecheckResult
  { mtrModuleName :: Text,
    mtrImportedTypes :: Map QualifiedName (SemanticType Resolved),
    mtrZonkedModule :: Module Zonked,
    mtrTypeEnvironment :: Map VariableResolution (SemanticType Resolved),
    mtrDiagnostics :: [Diagnostic],
    mtrLogs :: [CompileLog],
    mtrCacheEntry :: TypecheckCacheEntry,
    mtrIsCacheHit :: Bool
  }

typecheckModules ::
  IdentifierResult ->
  [Set.Set Text] ->
  Map ModuleName Int ->
  Map ModuleName ModuleCache ->
  (ZonkResult, [Diagnostic], [CompileLog], Map ModuleName TypecheckCacheEntry)
typecheckModules idResult moduleLevels sourceHashes inputCache =
  let initial =
        TypecheckAccumulator
          { accImportedTypes = Map.empty,
            accZonkedModules = Map.empty,
            accZonkedTypeEnvironment = Map.empty,
            accDiagnostics = [],
            accLogs = [],
            accUpdatedCache = Map.empty,
            accAllPriorCacheValid = True
          }
      final = foldl' (typecheckLevel idResult sourceHashes inputCache) initial moduleLevels
      mergedZonkResult =
        ZonkResult
          { zonkedModules = final.accZonkedModules,
            zonkedTypeEnvironment = final.accZonkedTypeEnvironment
          }
   in ( mergedZonkResult,
        final.accDiagnostics,
        final.accLogs,
        final.accUpdatedCache
      )

typecheckLevel ::
  IdentifierResult ->
  Map ModuleName Int ->
  Map ModuleName ModuleCache ->
  TypecheckAccumulator ->
  Set.Set Text ->
  TypecheckAccumulator
typecheckLevel idResult sourceHashes inputCache accumulator level =
  let moduleNames = Set.toList level
      results =
        parMap
          rseq
          (typecheckOneModule idResult sourceHashes inputCache accumulator)
          moduleNames
   in foldl' mergeModuleResult accumulator results

mergeModuleResult ::
  TypecheckAccumulator ->
  ModuleTypecheckResult ->
  TypecheckAccumulator
mergeModuleResult accumulator result =
  accumulator
    { accImportedTypes = Map.union accumulator.accImportedTypes result.mtrImportedTypes,
      accZonkedModules = Map.insert result.mtrModuleName result.mtrZonkedModule accumulator.accZonkedModules,
      accZonkedTypeEnvironment = Map.insert result.mtrModuleName result.mtrTypeEnvironment accumulator.accZonkedTypeEnvironment,
      accDiagnostics = accumulator.accDiagnostics <> result.mtrDiagnostics,
      accLogs = accumulator.accLogs <> result.mtrLogs,
      accUpdatedCache = Map.insert result.mtrModuleName result.mtrCacheEntry accumulator.accUpdatedCache,
      accAllPriorCacheValid = accumulator.accAllPriorCacheValid && result.mtrIsCacheHit
    }

typecheckOneModule ::
  IdentifierResult ->
  Map ModuleName Int ->
  Map ModuleName ModuleCache ->
  TypecheckAccumulator ->
  Text ->
  ModuleTypecheckResult
typecheckOneModule idResult sourceHashes inputCache accumulator moduleName =
  let currentHash = Map.lookup moduleName sourceHashes
      cachedEntry = Map.lookup moduleName inputCache
      cacheHit = case (currentHash, cachedEntry) of
        (Just sourceHash, Just cached) ->
          accumulator.accAllPriorCacheValid && sourceHash == cached.cacheSourceHash
        _ -> False
   in if cacheHit
        then applyCacheToResult moduleName cachedEntry
        else recompileModuleToResult idResult moduleName accumulator

applyCacheToResult ::
  Text ->
  Maybe ModuleCache ->
  ModuleTypecheckResult
applyCacheToResult moduleName cachedEntry =
  case cachedEntry of
    Nothing ->
      ModuleTypecheckResult
        { mtrModuleName = moduleName,
          mtrImportedTypes = Map.empty,
          mtrZonkedModule = Module {declarations = [], sourceSpan = emptySrcSpan},
          mtrTypeEnvironment = Map.empty,
          mtrDiagnostics = [],
          mtrLogs = [],
          mtrCacheEntry =
            TypecheckCacheEntry
              { tceInterface = ModuleInterface {exportedTypes = Map.empty},
                tceIdentified = Module {declarations = [], sourceSpan = emptySrcSpan},
                tceZonkedModule = Module {declarations = [], sourceSpan = emptySrcSpan},
                tceZonkedTypeEnv = Map.empty,
                tceDiagnostics = []
              },
          mtrIsCacheHit = True
        }
    Just cached ->
      ModuleTypecheckResult
        { mtrModuleName = moduleName,
          mtrImportedTypes = cached.cacheInterface.exportedTypes,
          mtrZonkedModule = cached.cacheZonkedModule,
          mtrTypeEnvironment = cached.cacheZonkedTypeEnv,
          mtrDiagnostics = cached.cacheDiagnostics,
          mtrLogs = [],
          mtrCacheEntry =
            TypecheckCacheEntry
              { tceInterface = cached.cacheInterface,
                tceIdentified = cached.cacheIdentifiedAST,
                tceZonkedModule = cached.cacheZonkedModule,
                tceZonkedTypeEnv = cached.cacheZonkedTypeEnv,
                tceDiagnostics = cached.cacheDiagnostics
              },
          mtrIsCacheHit = True
        }

recompileModuleToResult ::
  IdentifierResult ->
  Text ->
  TypecheckAccumulator ->
  ModuleTypecheckResult
recompileModuleToResult idResult moduleName accumulator =
  let result = Typechecker.typecheckModule idResult accumulator.accImportedTypes moduleName
      identifiedAST = case Map.lookup moduleName idResult.moduleASTs of
        Just ast -> ast
        Nothing -> Module {declarations = [], sourceSpan = emptySrcSpan}
      newCacheEntry =
        TypecheckCacheEntry
          { tceInterface = result.moduleInterface,
            tceIdentified = identifiedAST,
            tceZonkedModule = result.zonkedModule,
            tceZonkedTypeEnv = result.localTypeEnv,
            tceDiagnostics = result.diagnostics
          }
   in ModuleTypecheckResult
        { mtrModuleName = moduleName,
          mtrImportedTypes = result.moduleInterface.exportedTypes,
          mtrZonkedModule = result.zonkedModule,
          mtrTypeEnvironment = result.localTypeEnv,
          mtrDiagnostics = result.diagnostics,
          mtrLogs = [CompileLogTypechecking moduleName],
          mtrCacheEntry = newCacheEntry,
          mtrIsCacheHit = False
        }

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
            let injectedState =
                  state
                    { variables = Map.union cached.cacheIdentifierVariables state.variables,
                      types = Map.union cached.cacheIdentifierTypes state.types,
                      requests = Map.union cached.cacheIdentifierRequests state.requests,
                      constructors = Map.union cached.cacheIdentifierConstructors state.constructors,
                      modules = Map.insert moduleName cached.cacheModuleData state.modules,
                      capturedScopeFrames = cached.cacheScopeFrames ++ state.capturedScopeFrames
                    }
             in ( Map.insert moduleName cached.cacheIdentifiedAST asts,
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
                          tceIdentified = Module {declarations = [], sourceSpan = emptySrcSpan},
                          tceZonkedModule = Module {declarations = [], sourceSpan = emptySrcSpan},
                          tceZonkedTypeEnv = Map.empty,
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
                moduleScopeFrames =
                  case Map.lookup (moduleSourceFilePath moduleName idResult) idResult.scopeIndex.framesByFile of
                    Just frames -> [(f.frameSpan, f.frameSymbols) | f <- frames]
                    Nothing -> []
             in ModuleCache
                  { cacheSourceHash = Map.findWithDefault 0 moduleName sourceHashes,
                    cacheIdentifierVariables = moduleVariables,
                    cacheIdentifierTypes = moduleTypes,
                    cacheIdentifierRequests = moduleRequests,
                    cacheIdentifierConstructors = moduleConstructors,
                    cacheModuleData = moduleData,
                    cacheModuleExports = moduleExports,
                    cacheModuleTopLevel = moduleTopLevel,
                    cacheScopeFrames = moduleScopeFrames,
                    cacheIdentifiedAST = tce.tceIdentified,
                    cacheInterface = tce.tceInterface,
                    cacheZonkedModule = tce.tceZonkedModule,
                    cacheZonkedTypeEnv = tce.tceZonkedTypeEnv,
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
