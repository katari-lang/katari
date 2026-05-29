-- | Orchestration entry point for the Katari compiler.
--
-- Each phase exposes a per-module function; this module sequences them:
--
-- @
-- parseSources           (all modules, parallel)
--   → identifyProgram       (all modules, dependency order, fresh per-module state)
--   → typecheckModulesAsync (all modules, Async by dependency order)
--   → exhaustiveness        (all modules)
--   → lowering / schema     (only invalidated modules recompute; the rest
--                            are restored from 'ModuleCache')
-- @
--
-- The incremental cache covers only the heavy back end (lowering + schema).
-- The front end (parse / identify / typecheck) is cheap and runs every time,
-- so a module's diagnostics and hover/type info are always current. A
-- module's lowering/schema is reused from cache only when it is /valid/: its
-- own source is unchanged AND none of its transitive import dependencies
-- changed (so its zonked AST — hence its IR — is guaranteed identical).
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

    -- * Identify orchestration (exposed for the test suite)
    IdentifyResult (..),
    identifyProgram,
  )
where

import Control.Monad (foldM)
import Data.Foldable (for_)
import Data.Hashable (hash)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
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
import Katari.Lowering (ModuleLoweringResult, lowerModule, mergeModuleLowerings)
import Katari.Lowering qualified as Lowering
import Katari.Parser qualified as Parser
import Katari.Prim (PrimRule)
import Katari.Query qualified as Query
import Katari.Schema
  ( SchemaContext (..),
    SchemaEntry,
    buildDataDefs,
    buildModuleSchemas,
    collectDataAnnotations,
  )
import Katari.SemanticType (Resolved, SemanticType)
import Katari.SourceSpan (emptySourceSpan)
import Katari.Stdlib qualified as Stdlib
import Katari.Typechecker (ModuleTypecheckResult (..), TypecheckSubject (..), typecheckModule)
import Katari.Typechecker.Exhaustive (ExhaustiveEnv (..), checkExhaustiveModule)
import Katari.Typechecker.Exhaustive qualified as Exhaustive
import Katari.Typechecker.Identifier
  ( ConstructorData,
    ModuleData (..),
    RequestData,
    SymbolEntry,
    TypeData,
    VariableData (..),
    identifyModule,
    importCycleErrors,
  )
import Katari.Typechecker.Identifier qualified as Identifier
import Katari.Typechecker.ImportGraph (importModuleName, topologicalSort)
import Katari.Typechecker.ModuleInterface (ModuleInterface (..))
import Katari.Typechecker.ScopeIndex (ScopeFrame (..), buildScopeIndex)

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

-- | Per-module back-end cache. Holds only the lowering / schema outputs (the
-- expensive artefacts); identify / typecheck always rerun, so nothing from
-- the front end is stored. A cached entry is reused for a module only when
-- that module is /valid/ (source + transitive deps unchanged).
data ModuleCache = ModuleCache
  { cacheSourceHash :: Int,
    cacheLoweringResult :: ModuleLoweringResult,
    cacheSchemaEntries :: [SchemaEntry],
    cacheLoweringDiagnostics :: [Diagnostic]
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

  -- Parse every module. The front end is cheap and the full AST is needed
  -- for identify / typecheck regardless of cache state.
  for_ (Map.keys mergedSources) (emitLog . CompileLogParsing)
  let (allParsed, parseDiags) = parseSources mergedSources

  -- Identify every module from fresh per-module state.
  for_ (Map.keys allParsed) (emitLog . CompileLogIdentifying)
  let idResult = identifyProgram Stdlib.stdlibModuleNames allParsed
      idDiags = map Identifier.toDiagnostic idResult.errors

  -- Intra-program direct import deps (drives the typecheck pipeline order
  -- and the lowering/schema cache invalidation).
  let directDeps =
        Map.map
          ( \m ->
              [ depName
                | DeclarationImport imp <- m.declarations,
                  let depName = importModuleName imp.kind,
                  Map.member depName allParsed
              ]
          )
          allParsed
      orderedModules = compilationOrder Stdlib.stdlibModuleNames allParsed

  -- Typecheck every module in dependency order (each module only needs its
  -- imports' interfaces). Parallelisable one topological level at a time;
  -- see the note on parallelism in 'typecheckModules'.
  let primRules = Map.mapMaybe (.variablePrimRule) idResult.variables
      knownRequests = Map.keysSet idResult.requests
  (zonkedModulesMap, typeEnvMap, typecheckDiags) <-
    typecheckModules emitLog idResult primRules knownRequests orderedModules directDeps

  -- Exhaustiveness.
  let topLevelTypes =
        Map.fromList
          [ (qualifiedName, ty)
            | perModuleEnv <- Map.elems typeEnvMap,
              (ResolvedTopLevel qualifiedName, ty) <- Map.toList perModuleEnv
          ]
      exhaustiveDiags =
        concat
          [ map Exhaustive.toDiagnostic $
              checkExhaustiveModule
                ExhaustiveEnv
                  { constructors = idResult.constructors,
                    topLevelTypes = topLevelTypes,
                    localTypeEnv = Map.findWithDefault Map.empty moduleName typeEnvMap
                  }
                moduleAST
            | (moduleName, moduleAST) <- Map.toList zonkedModulesMap
          ]
      preLowerDiags = parseDiags <> idDiags <> typecheckDiags <> exhaustiveDiags
      shouldLower = not (hasErrors preLowerDiags)

  -- Back-end cache invalidation: a module is invalid if its source changed
  -- (or it has no cache entry), or transitively if it imports an invalid
  -- module. Valid modules reuse their cached lowering/schema.
  let changedModules =
        Set.fromList
          [ moduleName
            | moduleName <- Map.keys allParsed,
              case Map.lookup moduleName input.cache of
                Just cached -> Map.findWithDefault 0 moduleName sourceHashes /= cached.cacheSourceHash
                Nothing -> True
          ]
      invalidModules = invalidClosure directDeps changedModules
      reuseFromCache moduleName =
        not (Set.member moduleName invalidModules) && Map.member moduleName input.cache

  -- Lowering: cached modules restore their fragment; the rest lower fresh.
  let dataAnnotations =
        Map.unions
          [ collectDataAnnotations idResult.variables m
            | m <- Map.elems zonkedModulesMap
          ]
      mergedDataDefs = buildDataDefs idResult.constructors topLevelTypes dataAnnotations
      lowerContext =
        Lowering.LowerContext
          { Lowering.topLevelTypes = topLevelTypes,
            Lowering.dataDefs = mergedDataDefs,
            Lowering.requestNames = knownRequests,
            Lowering.constructorNames = Map.keysSet idResult.constructors
          }
      freshLowerInputs =
        [ (moduleName, moduleAST)
          | (moduleName, moduleAST) <- Map.toList zonkedModulesMap,
            not (reuseFromCache moduleName)
        ]
  for_ (map fst freshLowerInputs) (emitLog . CompileLogLowering)
  let perModuleLowering
        | shouldLower =
            let cachedLowering =
                  Map.fromList
                    [ (moduleName, (Right cached.cacheLoweringResult, cached.cacheLoweringDiagnostics))
                      | moduleName <- Map.keys zonkedModulesMap,
                        reuseFromCache moduleName,
                        Just cached <- [Map.lookup moduleName input.cache]
                    ]
                -- Per-module and independent: this 'map' could become a
                -- 'parMap' once 'ModuleLoweringResult' has an NFData instance
                -- to force the work onto worker threads. Sequential for now.
                freshLowering =
                  Map.fromList
                    ( map
                        ( \(moduleName, moduleAST) ->
                            let localEnv = Map.findWithDefault Map.empty moduleName typeEnvMap
                                (result, errors) = lowerModule lowerContext moduleName localEnv moduleAST
                             in (moduleName, (result, map Lowering.toDiagnostic errors))
                        )
                        freshLowerInputs
                    )
             in Map.union cachedLowering freshLowering
        | otherwise = Map.empty
      loweringResults = Map.mapMaybe (eitherToMaybe . fst) perModuleLowering
      loweringDiags = concatMap snd (Map.elems perModuleLowering)

      shouldEmitArtefacts = shouldLower && not (hasErrors loweringDiags)
      finalIR
        | shouldEmitArtefacts = Just (mergeModuleLowerings (Map.elems loweringResults))
        | otherwise = Nothing

  -- Schema: same valid/invalid split as lowering.
  for_ (map fst freshLowerInputs) (emitLog . CompileLogSchemaGeneration)
  let schemaContext =
        SchemaContext
          { dataDefs = mergedDataDefs,
            topLevelTypes = topLevelTypes,
            requestData = idResult.requests
          }
      schemaByModule
        | shouldEmitArtefacts =
            Map.fromList
              [ ( moduleName,
                  if reuseFromCache moduleName
                    then maybe [] (.cacheSchemaEntries) (Map.lookup moduleName input.cache)
                    else buildModuleSchemas schemaContext (moduleOwned moduleName idResult.variables)
                )
                | moduleName <- Map.keys zonkedModulesMap
              ]
        | otherwise = Map.empty
      schema
        | shouldEmitArtefacts = Just (concat (Map.elems schemaByModule))
        | otherwise = Nothing

      allDiags = preLowerDiags <> loweringDiags

      -- Refresh the cache for every successfully-lowered module (keeps both
      -- freshly-built and restored fragments, so the next run's valid set is
      -- correct).
      updatedCache =
        Map.fromList
          [ ( moduleName,
              ModuleCache
                { cacheSourceHash = Map.findWithDefault 0 moduleName sourceHashes,
                  cacheLoweringResult = loweringResult,
                  cacheSchemaEntries = Map.findWithDefault [] moduleName schemaByModule,
                  cacheLoweringDiagnostics = maybe [] snd (Map.lookup moduleName perModuleLowering)
                }
            )
            | (moduleName, loweringResult) <- Map.toList loweringResults
          ]

  emitLog CompileLogComplete
  pure
    CompileResult
      { irModule = finalIR,
        schemaEntries = schema,
        diagnostics = allDiags,
        querySnapshot =
          Query.QuerySnapshot
            { Query.variables = idResult.variables,
              Query.types = idResult.types,
              Query.requests = idResult.requests,
              Query.constructors = idResult.constructors,
              Query.modules = idResult.modules,
              Query.scopeIndex = buildScopeIndex idResult.scopeFrames,
              Query.visibleSymbols = idResult.topLevelTables,
              Query.exports = idResult.exportTables,
              Query.zonkedModules = zonkedModulesMap,
              Query.typeEnv = typeEnvMap
            },
        updatedCache = updatedCache
      }

eitherToMaybe :: Either a b -> Maybe b
eitherToMaybe = \case
  Left _ -> Nothing
  Right x -> Just x

-- | The top-level variables owned by @moduleName@.
moduleOwned :: ModuleName -> Map QualifiedName a -> Map QualifiedName a
moduleOwned moduleName = Map.filterWithKey (\qualifiedName _ -> qualifiedName.module_ == moduleName)

-- ===========================================================================
-- Parse
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

-- ===========================================================================
-- Identify orchestration
-- ===========================================================================

-- | Whole-program identifier output, assembled by unioning the per-module
-- 'Identifier.ModuleIdentifyResult' values. Fans out to typecheck, lowering,
-- schema, and the query layer.
data IdentifyResult = IdentifyResult
  { variables :: Map QualifiedName VariableData,
    types :: Map QualifiedName TypeData,
    requests :: Map QualifiedName RequestData,
    constructors :: Map QualifiedName ConstructorData,
    modules :: Map Text ModuleData,
    asts :: Map Text (Module Identified),
    exportTables :: Map Text (Map Text SymbolEntry),
    topLevelTables :: Map Text (Map Text SymbolEntry),
    scopeFrames :: [ScopeFrame SymbolEntry],
    errors :: [Identifier.IdentifierError]
  }

-- | Identify every module from fresh per-module state and aggregate the
-- results. Modules are visited in dependency order (see 'compilationOrder')
-- so each sees its dependencies' export tables, which are threaded forward.
-- Import cycles are reported up front; tangled modules are still identified
-- (best effort) after the acyclic ones.
identifyProgram :: Set Text -> Map Text (Module Parsed) -> IdentifyResult
identifyProgram trustedStdlibNames moduleMap =
  let allModuleNames = Map.keysSet moduleMap
      allModuleData = Map.map (\m -> ModuleData {moduleSourceSpan = m.sourceSpan}) moduleMap
      identifyOne depExports moduleName =
        ( moduleName,
          identifyModule allModuleData depExports allModuleNames trustedStdlibNames moduleName (moduleMap Map.! moduleName)
        )
      -- Modules within a level are mutually independent (every dependency is
      -- in an earlier level), so a level is embarrassingly parallel: this
      -- 'map' could become a 'parMap' once 'ModuleIdentifyResult' has an
      -- NFData instance to force the work onto worker threads. Export tables
      -- accumulate between levels. Sequential for now.
      runLevels _ [] = []
      runLevels depExports (level : rest) =
        let levelResults = map (identifyOne depExports) level
            depExports' =
              Map.union depExports (Map.fromList [(m, r.moduleExportTable) | (m, r) <- levelResults])
         in levelResults ++ runLevels depExports' rest
      results = runLevels Map.empty (compilationLevels trustedStdlibNames moduleMap)
   in IdentifyResult
        { variables = Map.unions [result.moduleVariables | (_, result) <- results],
          types = Map.unions [result.moduleTypes | (_, result) <- results],
          requests = Map.unions [result.moduleRequests | (_, result) <- results],
          constructors = Map.unions [result.moduleConstructors | (_, result) <- results],
          modules = Map.fromList [(name, result.moduleData) | (name, result) <- results],
          asts = Map.fromList [(name, result.identifiedAST) | (name, result) <- results],
          exportTables = Map.fromList [(name, result.moduleExportTable) | (name, result) <- results],
          topLevelTables = Map.fromList [(name, result.moduleTopLevel) | (name, result) <- results],
          scopeFrames = concat [result.moduleScopeFrames | (_, result) <- results],
          errors =
            importCycleErrors moduleMap
              ++ concat [result.moduleNewErrors | (_, result) <- results]
        }

-- | Dependency-ordered /levels/: @primitive@ first, then the rest of the
-- trusted stdlib, then user modules grouped into topological levels, then
-- any leftover (import-cycle) modules. Modules within a level have no
-- dependency on one another, so identification processes a level in parallel.
compilationLevels :: Set Text -> Map Text (Module Parsed) -> [[Text]]
compilationLevels trustedStdlibNames moduleMap =
  let stdlibNames = [m | m <- Map.keys moduleMap, Set.member m trustedStdlibNames]
      primLevel = filter (== "primitive") stdlibNames
      otherStdlib = filter (/= "primitive") stdlibNames
      userModuleMap = Map.filterWithKey (\m _ -> not (Set.member m trustedStdlibNames)) moduleMap
      userLevels = map Set.toList (topologicalSort userModuleMap)
      placed = Set.fromList (primLevel ++ otherStdlib ++ concat userLevels)
      leftover = [m | m <- Map.keys moduleMap, not (Set.member m placed)]
   in filter (not . null) ([primLevel, otherStdlib] ++ userLevels ++ [leftover])

-- | Flat dependency order (= 'compilationLevels' concatenated), used by the
-- typecheck pipeline where each task waits on its imports individually.
compilationOrder :: Set Text -> Map Text (Module Parsed) -> [Text]
compilationOrder trustedStdlibNames moduleMap = concat (compilationLevels trustedStdlibNames moduleMap)

-- ===========================================================================
-- Per-module typecheck pipeline
-- ===========================================================================

-- | Per-module typecheck output. Each module reads its imports'
-- 'taskExportedTypes' to seed its own typecheck.
data TypecheckTaskResult = TypecheckTaskResult
  { taskZonkedModule :: Module Zonked,
    taskTypeEnvironment :: Map VariableResolution (SemanticType Resolved),
    taskExportedTypes :: Map QualifiedName (SemanticType Resolved),
    taskDiagnostics :: [Diagnostic]
  }

-- | Typecheck every module in dependency order, threading each module's
-- exported types forward so its importers can read them.
--
-- A module needs only its direct imports' interfaces, so this is
-- parallelisable one topological level at a time (see 'compilationLevels')
-- via Async + an NFData instance that forces the per-module work onto worker
-- threads. Kept sequential for now: without forcing, parMap/Async evaluate
-- only to WHNF and leave the heavy inference as thunks for the main thread,
-- so the parallelism would not pay off.
typecheckModules ::
  (CompileLog -> IO ()) ->
  IdentifyResult ->
  Map QualifiedName PrimRule ->
  Set QualifiedName ->
  [ModuleName] ->
  Map ModuleName [ModuleName] ->
  IO
    ( Map ModuleName (Module Zonked),
      Map ModuleName (Map VariableResolution (SemanticType Resolved)),
      [Diagnostic]
    )
typecheckModules emitLog idResult primRules knownRequests orderedModules directDeps = do
  (_, results) <- foldM step (Map.empty, Map.empty) orderedModules
  pure
    ( Map.map (.taskZonkedModule) results,
      Map.map (.taskTypeEnvironment) results,
      concatMap (.taskDiagnostics) (Map.elems results)
    )
  where
    step (exportedSoFar, acc) moduleName = do
      emitLog (CompileLogTypechecking moduleName)
      let importedTypes =
            Map.unions
              [ Map.findWithDefault Map.empty depName exportedSoFar
                | depName <- Map.findWithDefault [] moduleName directDeps
              ]
          result = typecheckOne idResult primRules knownRequests moduleName importedTypes
      pure
        ( Map.insert moduleName result.taskExportedTypes exportedSoFar,
          Map.insert moduleName result acc
        )

typecheckOne ::
  IdentifyResult ->
  Map QualifiedName PrimRule ->
  Set QualifiedName ->
  ModuleName ->
  Map QualifiedName (SemanticType Resolved) ->
  TypecheckTaskResult
typecheckOne idResult primRules knownRequests moduleName importedTypes =
  let moduleAST =
        Map.findWithDefault
          Module {declarations = [], sourceSpan = emptySourceSpan}
          moduleName
          idResult.asts
      subject =
        TypecheckSubject
          { moduleName = moduleName,
            moduleAST = moduleAST,
            ownVariables = moduleOwned moduleName idResult.variables,
            typeData = idResult.types,
            knownRequests = knownRequests,
            primRules = primRules,
            importedTypes = importedTypes
          }
      result = typecheckModule subject
   in TypecheckTaskResult
        { taskZonkedModule = result.zonkedModule,
          taskTypeEnvironment = result.localTypeEnv,
          taskExportedTypes = result.moduleInterface.exportedTypes,
          taskDiagnostics = result.diagnostics
        }

-- ===========================================================================
-- Cache invalidation
-- ===========================================================================

-- | Grow @changed@ to its transitive closure under "imports an invalid
-- module": a module is invalid if it (directly or indirectly) imports any
-- changed module. Used to decide which modules must re-lower / re-schema.
invalidClosure :: Map ModuleName [ModuleName] -> Set ModuleName -> Set ModuleName
invalidClosure directDeps = grow
  where
    grow current =
      let next =
            Set.union
              current
              ( Set.fromList
                  [ moduleName
                    | (moduleName, deps) <- Map.toList directDeps,
                      any (`Set.member` current) deps
                  ]
              )
       in if Set.size next == Set.size current then current else grow next
