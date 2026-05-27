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
    ModuleCache (..),

    -- * Entry
    compile,

    -- * Helpers (exposed for testing)
    parseSources,
    parsedStdlibModules,
    identifyWithStdlib,
  )
where

import Control.Parallel.Strategies (parMap, rseq)
import Data.Foldable (foldl')
import Data.Hashable (hash)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.AST
  ( AgentDeclaration (..),
    DataDeclaration (..),
    Declaration (..),
    ExternalAgentDeclaration (..),
    ImportDeclaration (..),
    Module (..),
    NameRef (..),
    NameRefKind (VariableRef),
    Phase (Identified, Parsed, Zonked),
    PrimAgentDeclaration (..),
    RequestDeclaration (..),
    TypeSynonymDeclaration (..),
    retagNameRef,
    retagSyntacticType,
  )
import Katari.Diagnostic (Diagnostic, hasErrors)
import Katari.IR qualified
import Katari.Id (QualifiedName (..), VariableResolution (..))
import Katari.Lexer qualified as Lexer
import Katari.Lowering (ModuleLoweringResult (..), lowerModule, mergeModuleLowerings)
import Katari.Lowering qualified as Lowering
import Katari.Parser qualified as Parser
import Katari.Schema (SchemaEntry (..), buildSchemas)
import Katari.SemanticType (Resolved, SemanticType)
import Katari.SourceSpan (Position (..), SourceSpan (..))
import Katari.Stdlib qualified as Stdlib
import Katari.Typechecker.AgentGraph (agentSCCs)
import Katari.Typechecker.ConstraintGenerator (generateConstraintsForSCC)
import Katari.Typechecker.ConstraintGenerator qualified as CG
import Katari.Typechecker.Exhaustive (checkExhaustive)
import Katari.Typechecker.Exhaustive qualified as Exhaustive
import Katari.Typechecker.Identifier
  ( ConstructorData (..),
    IdentifierResult (..),
    ModuleData (..),
    RequestData (..),
    SymbolEntry (..),
    TypeData (..),
    VariableData (..),
    identify,
  )
import Katari.Typechecker.Identifier qualified as Identifier
import Katari.Typechecker.ImportGraph (topologicalSort)
import Katari.Typechecker.ModuleInterface (ModuleInterface (..), extractModuleInterface)
import Katari.Typechecker.ScopeIndex (ScopeFrame (..), ScopeIndex (..), emptyScopeIndex)
import Katari.Typechecker.Solver (SolverResult (..), solve)
import Katari.Typechecker.Solver qualified as Solver
import Katari.Typechecker.Zonker (ZonkResult (..), zonk)
import Katari.Typechecker.Zonker qualified as Zonker

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
  CompileLogParsing :: CompileLog
  CompileLogIdentifying :: CompileLog
  CompileLogTypechecking :: Text -> Int -> Int -> CompileLog
  CompileLogLowering :: CompileLog
  CompileLogSchemaGeneration :: CompileLog
  CompileLogComplete :: CompileLog
  deriving (Show)

data CompileResult = CompileResult
  { irModule :: Maybe Katari.IR.IRModule,
    schemaEntries :: Maybe [SchemaEntry],
    diagnostics :: [Diagnostic],
    identifierResult :: IdentifierResult,
    solverResult :: SolverResult,
    zonkResult :: ZonkResult,
    compileLogs :: [CompileLog],
    updatedCache :: Map ModuleName ModuleCache
  }

-- ===========================================================================
-- Top-level entry
-- ===========================================================================

compile :: CompileInput -> CompileResult
compile input =
  let stdlibEntries =
        Map.mapWithKey
          (\moduleName src -> SourceEntry ("<stdlib:" <> Text.unpack moduleName <> ">") src)
          Stdlib.stdlibSources
      mergedSources = Map.union input.sources stdlibEntries

      sourceHashes = Map.map (\entry -> hash entry.sourceText) mergedSources

      -- Cache hit: source hash matches.
      cacheHitModules =
        Map.filterWithKey
          (\moduleName cached ->
            case Map.lookup moduleName sourceHashes of
              Just sourceHash -> sourceHash == cached.cacheSourceHash
              Nothing -> False
          )
          input.cache
      cacheHitNames = Map.keysSet cacheHitModules
      cacheMissNames = Set.difference (Map.keysSet mergedSources) cacheHitNames

      -- Phase 1: Parse (cache-miss only).
      cacheMissSources = Map.restrictKeys mergedSources cacheMissNames
      (freshParsed, parseDiags) = parseSources cacheMissSources

      -- Build skeleton parsed modules from cache (for import graph).
      cachedSkeletonParsed =
        Map.map
          (\cached ->
            Module
              { declarations = map DeclarationImport (extractImportDeclarations cached.cacheIdentifiedAST),
                sourceSpan = cached.cacheModuleData.moduleSourceSpan
              }
          )
          cacheHitModules
      allParsed = Map.union freshParsed cachedSkeletonParsed

      -- Phase 2: Identify (incremental).
      cachedIdentifierData =
        Map.map
          (\cached ->
            Identifier.CachedIdentifierData
              { Identifier.cidVariables = cached.cacheIdentifierVariables,
                Identifier.cidTypes = cached.cacheIdentifierTypes,
                Identifier.cidRequests = cached.cacheIdentifierRequests,
                Identifier.cidConstructors = cached.cacheIdentifierConstructors,
                Identifier.cidModuleData = cached.cacheModuleData,
                Identifier.cidExportTable = cached.cacheModuleExports,
                Identifier.cidTopLevel = cached.cacheModuleTopLevel,
                Identifier.cidIdentifiedAST = cached.cacheIdentifiedAST,
                Identifier.cidScopeFrames = cached.cacheScopeFrames,
                Identifier.cidNextTypeId = 0,
                Identifier.cidNextRequestId = 0,
                Identifier.cidNextConstructorId = 0,
                Identifier.cidNextLocalVarId = 0
              }
          )
          cacheHitModules
      (idResult, idErrors) =
        if Map.null cachedIdentifierData
          then identify Stdlib.stdlibModuleNames allParsed
          else Identifier.identifyIncremental Stdlib.stdlibModuleNames allParsed cachedIdentifierData
      idDiags = map Identifier.toDiagnostic idErrors

      -- Compute topological levels.
      stdlibModuleSet =
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

      -- Phase 3: Typecheck (per-module, SCC, parallel within level).
      (mergedSolverResult, mergedZonkResult, typecheckDiags, typecheckLogs, typecheckCache) =
        typecheckModules idResult moduleLevels sourceHashes input.cache

      exhaustiveDiags = map Exhaustive.toDiagnostic (checkExhaustive idResult mergedZonkResult)
      preLowerDiags =
        parseDiags
          <> idDiags
          <> typecheckDiags
          <> exhaustiveDiags
      shouldLower = not (hasErrors preLowerDiags)

      -- Phase 4: Lower (per-module, fully parallel).
      (loweringResults, loweringDiags)
        | shouldLower =
            let cachedResults =
                  Map.map (.cacheLoweringResult) cacheHitModules
                freshResults =
                  Map.fromList
                    ( parMap rseq
                        (\(moduleName, moduleAST) ->
                          let (result, errors) = lowerModule idResult mergedZonkResult moduleName moduleAST
                           in (moduleName, (result, errors))
                        )
                        [ (moduleName, moduleAST)
                          | (moduleName, moduleAST) <- Map.toList mergedZonkResult.zonkedModules,
                            Set.member moduleName cacheMissNames
                        ]
                    )
                freshOk =
                  Map.map (fst) freshResults
                freshErrors =
                  concatMap (snd) (Map.elems freshResults)
                freshDiags = map Lowering.toDiagnostic freshErrors
                allResults = Map.union cachedResults (Map.mapMaybe eitherToMaybe freshOk)
             in (allResults, freshDiags)
        | otherwise = (Map.empty, [])

      shouldEmitArtefacts = shouldLower && not (hasErrors loweringDiags)

      finalIR
        | shouldEmitArtefacts =
            Just (mergeModuleLowerings (Map.elems loweringResults))
        | otherwise = Nothing

      -- Phase 5: Schema (per-module, parallel).
      cachedSchemaEntries = concatMap (.cacheSchemaEntries) (Map.elems cacheHitModules)
      freshSchemaEntries =
        if shouldEmitArtefacts
          then buildSchemasForModules idResult mergedZonkResult cacheMissNames
          else []
      schema =
        if shouldEmitArtefacts
          then Just (cachedSchemaEntries <> freshSchemaEntries)
          else Nothing

      allDiags = preLowerDiags <> loweringDiags

      -- Build updated cache.
      freshCache = buildFreshCacheEntries
        sourceHashes idResult typecheckCache loweringResults
        freshSchemaEntries cacheMissNames freshParsed
      updatedCacheMap = Map.union freshCache cacheHitModules

      logs =
        [CompileLogParsing, CompileLogIdentifying]
          <> typecheckLogs
          <> ([CompileLogLowering | shouldLower])
          <> ([CompileLogSchemaGeneration | shouldEmitArtefacts])
          <> [CompileLogComplete]
   in CompileResult
        { irModule = finalIR,
          schemaEntries = schema,
          diagnostics = allDiags,
          identifierResult = idResult,
          solverResult = mergedSolverResult,
          zonkResult = mergedZonkResult,
          compileLogs = logs,
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
    accZonkedModuleNames :: Map Text Text,
    accZonkedTypeEnvironment :: Map VariableResolution (SemanticType Resolved),
    accSolverResult :: SolverResult,
    accDiagnostics :: [Diagnostic],
    accSCCDeclarations :: Map QualifiedName (Declaration Zonked),
    accLogs :: [CompileLog],
    accUpdatedCache :: Map ModuleName TypecheckCacheEntry,
    accAllPriorCacheValid :: Bool
  }

data ModuleTypecheckResult = ModuleTypecheckResult
  { mtrModuleName :: Text,
    mtrImportedTypes :: Map QualifiedName (SemanticType Resolved),
    mtrZonkedModule :: Module Zonked,
    mtrTypeEnvironment :: Map VariableResolution (SemanticType Resolved),
    mtrSolverResult :: SolverResult,
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
  (SolverResult, ZonkResult, [Diagnostic], [CompileLog], Map ModuleName TypecheckCacheEntry)
typecheckModules idResult moduleLevels sourceHashes inputCache =
  let initial =
        TypecheckAccumulator
          { accImportedTypes = Map.empty,
            accZonkedModules = Map.empty,
            accZonkedModuleNames = Map.empty,
            accZonkedTypeEnvironment = Map.empty,
            accSolverResult = SolverResult {typeSubstitution = Map.empty, requestSubstitution = Map.empty},
            accDiagnostics = [],
            accSCCDeclarations = Map.empty,
            accLogs = [],
            accUpdatedCache = Map.empty,
            accAllPriorCacheValid = True
          }
      final = foldl' (typecheckLevel idResult sourceHashes inputCache) initial moduleLevels
      mergedZonkResult =
        ZonkResult
          { zonkedModules = final.accZonkedModules,
            zonkedModuleNames = final.accZonkedModuleNames,
            zonkedTypeEnvironment = final.accZonkedTypeEnvironment
          }
   in ( final.accSolverResult,
        mergedZonkResult,
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
      accZonkedModuleNames = Map.insert result.mtrModuleName result.mtrModuleName accumulator.accZonkedModuleNames,
      accZonkedTypeEnvironment = Map.union accumulator.accZonkedTypeEnvironment result.mtrTypeEnvironment,
      accSolverResult =
        SolverResult
          { typeSubstitution = Map.union result.mtrSolverResult.typeSubstitution accumulator.accSolverResult.typeSubstitution,
            requestSubstitution = Map.union result.mtrSolverResult.requestSubstitution accumulator.accSolverResult.requestSubstitution
          },
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
        else recompileModuleToResult idResult moduleName sourceHashes accumulator

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
          mtrSolverResult = SolverResult {typeSubstitution = Map.empty, requestSubstitution = Map.empty},
          mtrDiagnostics = [],
          mtrLogs = [],
          mtrCacheEntry = TypecheckCacheEntry
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
          mtrSolverResult = SolverResult {typeSubstitution = Map.empty, requestSubstitution = Map.empty},
          mtrDiagnostics = cached.cacheDiagnostics,
          mtrLogs = [],
          mtrCacheEntry = TypecheckCacheEntry
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
  Map ModuleName Int ->
  TypecheckAccumulator ->
  ModuleTypecheckResult
recompileModuleToResult idResult moduleName sourceHashes accumulator =
  let moduleAST = Map.lookup moduleName idResult.moduleASTs
      nonAgentQualifiedNames = case moduleAST of
        Just ast -> collectNonAgentQualifiedNames moduleName ast
        Nothing -> Set.empty
      agentSCCsRaw = case moduleAST of
        Just ast -> agentSCCs moduleName ast
        Nothing -> []
      agentOnlySCCs =
        [ Set.difference scc nonAgentQualifiedNames
          | scc <- agentSCCsRaw,
            let filtered = Set.difference scc nonAgentQualifiedNames,
            not (Set.null filtered)
        ]
      allSCCs =
        ([nonAgentQualifiedNames | not (Set.null nonAgentQualifiedNames)])
          <> agentOnlySCCs
      totalSCCs = length allSCCs
      indexedSCCs = zip [1 ..] allSCCs
      sccInitial =
        accumulator
          { accZonkedModules = Map.empty,
            accZonkedModuleNames = Map.empty,
            accZonkedTypeEnvironment = accumulator.accZonkedTypeEnvironment,
            accSolverResult = SolverResult {typeSubstitution = Map.empty, requestSubstitution = Map.empty},
            accDiagnostics = [],
            accSCCDeclarations = Map.empty,
            accLogs = [],
            accUpdatedCache = Map.empty,
            accAllPriorCacheValid = accumulator.accAllPriorCacheValid
          }
      typecheckIndexedSCC accum (sccIndex, scc) =
        let logged = accum {accLogs = accum.accLogs <> [CompileLogTypechecking moduleName sccIndex totalSCCs]}
         in typecheckOneSCC idResult moduleName logged scc
      sccAccumulator = foldl' typecheckIndexedSCC sccInitial indexedSCCs
      assembledModule = case moduleAST of
        Just identifiedModule -> assembleZonkedModule identifiedModule sccAccumulator.accSCCDeclarations
        Nothing -> Module {declarations = [], sourceSpan = emptySrcSpan}
      moduleInterface =
        extractModuleInterface
          moduleName
          idResult.identifiedVariables
          sccAccumulator.accZonkedTypeEnvironment
      moduleTypeEnv = moduleOwnedTypeEnvironment accumulator.accImportedTypes sccAccumulator.accZonkedTypeEnvironment
      newCacheEntry =
        TypecheckCacheEntry
          { tceInterface = moduleInterface,
            tceIdentified = case moduleAST of
              Just ast -> ast
              Nothing -> Module {declarations = [], sourceSpan = emptySrcSpan},
            tceZonkedModule = assembledModule,
            tceZonkedTypeEnv = moduleTypeEnv,
            tceDiagnostics = sccAccumulator.accDiagnostics
          }
   in ModuleTypecheckResult
        { mtrModuleName = moduleName,
          mtrImportedTypes = moduleInterface.exportedTypes,
          mtrZonkedModule = assembledModule,
          mtrTypeEnvironment = moduleTypeEnv,
          mtrSolverResult = sccAccumulator.accSolverResult,
          mtrDiagnostics = sccAccumulator.accDiagnostics,
          mtrLogs = sccAccumulator.accLogs,
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

collectNonAgentQualifiedNames :: Text -> Module Identified -> Set.Set QualifiedName
collectNonAgentQualifiedNames moduleName moduleAST =
  Set.fromList (concatMap extractQualifiedName moduleAST.declarations)
  where
    extractQualifiedName :: Declaration Identified -> [QualifiedName]
    extractQualifiedName = \case
      DeclarationRequest declaration -> resolveToLocal declaration.name
      DeclarationExternalAgent declaration -> resolveToLocal declaration.name
      DeclarationPrimAgent declaration -> resolveToLocal declaration.name
      DeclarationData declaration -> resolveToLocal declaration.name
      DeclarationAgent _ -> []
      DeclarationTypeSynonym _ -> []
      DeclarationImport _ -> []
      DeclarationError _ -> []

    resolveToLocal :: NameRef Identified VariableRef -> [QualifiedName]
    resolveToLocal nameRef = case nameRef.resolution of
      Just (ResolvedTopLevel qualifiedName)
        | qualifiedName.module_ == moduleName -> [qualifiedName]
      _ -> []

moduleOwnedTypeEnvironment ::
  Map QualifiedName (SemanticType Resolved) ->
  Map VariableResolution (SemanticType Resolved) ->
  Map VariableResolution (SemanticType Resolved)
moduleOwnedTypeEnvironment importedTypes fullTypeEnvironment =
  let knownResolutions =
        Map.keysSet
          ( Map.filterWithKey
              ( \variableResolution _ty -> case variableResolution of
                  ResolvedTopLevel qualifiedName -> Map.member qualifiedName importedTypes
                  ResolvedLocal _ -> False
              )
              fullTypeEnvironment
          )
   in Map.withoutKeys fullTypeEnvironment knownResolutions

typecheckOneSCC ::
  IdentifierResult ->
  Text ->
  TypecheckAccumulator ->
  Set.Set QualifiedName ->
  TypecheckAccumulator
typecheckOneSCC idResult moduleName accumulator sccQualifiedNames =
  let (cgResult, cgErrors) = generateConstraintsForSCC accumulator.accImportedTypes idResult moduleName sccQualifiedNames
      cgDiags = map CG.toDiagnostic cgErrors
      (solverResult_, solverErrors) = solve cgResult
      solverDiags = map Solver.toDiagnostic solverErrors
      (zonkResult_, zonkErrors) = zonk idResult cgResult solverResult_
      zonkDiags = map Zonker.toDiagnostic zonkErrors
      sccInterface = extractSCCInterface sccQualifiedNames zonkResult_.zonkedTypeEnvironment
      knownResolutions =
        Set.map ResolvedTopLevel
          (Map.keysSet (Map.intersection idResult.identifiedVariables accumulator.accImportedTypes))
      ownedTypeEnvironment =
        Map.withoutKeys zonkResult_.zonkedTypeEnvironment knownResolutions
      sccDeclarations = case Map.lookup moduleName zonkResult_.zonkedModules of
        Just sccModule -> sccModule.declarations
        Nothing -> []
      sccDeclMap = foldl' indexDeclaration accumulator.accSCCDeclarations sccDeclarations
   in TypecheckAccumulator
        { accImportedTypes = Map.union accumulator.accImportedTypes sccInterface,
          accZonkedModules = accumulator.accZonkedModules,
          accZonkedModuleNames = accumulator.accZonkedModuleNames,
          accZonkedTypeEnvironment = Map.union accumulator.accZonkedTypeEnvironment ownedTypeEnvironment,
          accSolverResult =
            SolverResult
              { typeSubstitution = Map.union solverResult_.typeSubstitution accumulator.accSolverResult.typeSubstitution,
                requestSubstitution = Map.union solverResult_.requestSubstitution accumulator.accSolverResult.requestSubstitution
              },
          accDiagnostics = accumulator.accDiagnostics <> cgDiags <> solverDiags <> zonkDiags,
          accSCCDeclarations = sccDeclMap,
          accLogs = accumulator.accLogs,
          accUpdatedCache = accumulator.accUpdatedCache,
          accAllPriorCacheValid = accumulator.accAllPriorCacheValid
        }

extractSCCInterface ::
  Set.Set QualifiedName ->
  Map VariableResolution (SemanticType Resolved) ->
  Map QualifiedName (SemanticType Resolved)
extractSCCInterface sccQualifiedNames typeEnvironment =
  Map.fromList
    [ (qualifiedName, resolvedType)
      | qualifiedName <- Set.toList sccQualifiedNames,
        Just resolvedType <- [Map.lookup (ResolvedTopLevel qualifiedName) typeEnvironment]
    ]

indexDeclaration ::
  Map QualifiedName (Declaration Zonked) ->
  Declaration Zonked ->
  Map QualifiedName (Declaration Zonked)
indexDeclaration declarationMap declaration = case declarationQualifiedName declaration of
  Just qualifiedName -> Map.insert qualifiedName declaration declarationMap
  Nothing -> declarationMap

declarationQualifiedName :: Declaration Zonked -> Maybe QualifiedName
declarationQualifiedName = \case
  DeclarationAgent AgentDeclaration {name = NameRef {resolution}} -> resolveToQName resolution
  DeclarationRequest RequestDeclaration {name = NameRef {resolution}} -> resolveToQName resolution
  DeclarationExternalAgent ExternalAgentDeclaration {name = NameRef {resolution}} -> resolveToQName resolution
  DeclarationPrimAgent PrimAgentDeclaration {name = NameRef {resolution}} -> resolveToQName resolution
  DeclarationData DataDeclaration {name = NameRef {resolution}} -> resolveToQName resolution
  DeclarationTypeSynonym _ -> Nothing
  DeclarationImport _ -> Nothing
  DeclarationError _ -> Nothing

assembleZonkedModule ::
  Module Identified ->
  Map QualifiedName (Declaration Zonked) ->
  Module Zonked
assembleZonkedModule identifiedModule sccDeclarationMap =
  Module
    { declarations =
        map
          ( \declaration -> case identifiedDeclQName declaration of
              Just qualifiedName -> case Map.lookup qualifiedName sccDeclarationMap of
                Just zonkedDeclaration -> zonkedDeclaration
                Nothing -> retagNonCallableDeclaration declaration
              Nothing -> retagNonCallableDeclaration declaration
          )
          identifiedModule.declarations,
      sourceSpan = identifiedModule.sourceSpan
    }

identifiedDeclQName :: Declaration Identified -> Maybe QualifiedName
identifiedDeclQName = \case
  DeclarationAgent AgentDeclaration {name = NameRef {resolution}} -> resolveToQName resolution
  DeclarationRequest RequestDeclaration {name = NameRef {resolution}} -> resolveToQName resolution
  DeclarationExternalAgent ExternalAgentDeclaration {name = NameRef {resolution}} -> resolveToQName resolution
  DeclarationPrimAgent PrimAgentDeclaration {name = NameRef {resolution}} -> resolveToQName resolution
  DeclarationData DataDeclaration {name = NameRef {resolution}} -> resolveToQName resolution
  DeclarationTypeSynonym _ -> Nothing
  DeclarationImport _ -> Nothing
  DeclarationError _ -> Nothing

resolveToQName :: Maybe VariableResolution -> Maybe QualifiedName
resolveToQName = \case
  Just (ResolvedTopLevel qualifiedName) -> Just qualifiedName
  _ -> Nothing

retagNonCallableDeclaration :: Declaration Identified -> Declaration Zonked
retagNonCallableDeclaration = \case
  DeclarationTypeSynonym TypeSynonymDeclaration {name, rhs, sourceSpan} ->
    DeclarationTypeSynonym
      TypeSynonymDeclaration
        { name = retagNameRef name,
          rhs = retagSyntacticType rhs,
          sourceSpan = sourceSpan
        }
  DeclarationImport declaration -> DeclarationImport declaration
  DeclarationError sourceSpan -> DeclarationError sourceSpan
  _ -> DeclarationError placeholderSpan
    where
      placeholderSpan = SrcSpan {filePath = "", start = Position {line = 0, column = 0}, end = Position {line = 0, column = 0}}

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
  identify Stdlib.stdlibModuleNames (Map.union userMods parsedStdlibModules)

-- ===========================================================================
-- Helpers
-- ===========================================================================

-- | Extract import declarations from an Identified module (for cache
-- skeleton building).
extractImportDeclarations :: Module Identified -> [ImportDeclaration]
extractImportDeclarations moduleAST =
  [ importDecl | DeclarationImport importDecl <- moduleAST.declarations ]

-- | Build schema entries for cache-miss modules only.
buildSchemasForModules ::
  IdentifierResult ->
  ZonkResult ->
  Set.Set Text ->
  [SchemaEntry]
buildSchemasForModules idResult zonkResult_ moduleNames =
  let filteredVariables =
        Map.filterWithKey
          (\qualifiedName _ -> Set.member qualifiedName.module_ moduleNames)
          idResult.identifiedVariables
      filteredIdResult = idResult {identifiedVariables = filteredVariables}
   in buildSchemas filteredIdResult zonkResult_

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
  Map ModuleName (Module Parsed) ->
  Map ModuleName ModuleCache
buildFreshCacheEntries sourceHashes idResult typecheckCache loweringResults schemaEntries_ cacheMissNames_ parsedModules =
  let schemaByModule =
        foldl'
          (\accumulator entry ->
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
        (\moduleName ->
          let tce = Map.findWithDefault
                (TypecheckCacheEntry
                  { tceInterface = ModuleInterface {exportedTypes = Map.empty},
                    tceIdentified = Module {declarations = [], sourceSpan = emptySrcSpan},
                    tceZonkedModule = Module {declarations = [], sourceSpan = emptySrcSpan},
                    tceZonkedTypeEnv = Map.empty,
                    tceDiagnostics = []
                  })
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
              moduleData = Map.findWithDefault
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
