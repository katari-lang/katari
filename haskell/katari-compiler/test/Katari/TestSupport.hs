-- | Test-local helpers. The library itself only exposes per-module step
-- functions (@identifyModule@, @generateConstraintsForSCC@, @zonk@) and
-- the IO entry point @compile@. This module re-creates the legacy
-- whole-program aggregation expected by older phase-specific tests by
-- driving the per-module APIs directly.
module Katari.TestSupport
  ( -- * compile sugar
    compileSync,
    singleSourceInput,
    multiSourceInput,

    -- * Parser helpers
    parsedStdlibModules,
    parseModule,

    -- * Identifier aggregation
    IdentifierResult (..),
    identifyAll,
    identifyWithStdlib,

    -- * Constraint-gen aggregation
    generateConstraintsAll,
    generateConstraintsForModule,

    -- * Zonker aggregation
    ZonkResult (..),
    zonkAll,
  )
where

import Data.Foldable (foldl', for_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text, unpack)
import Data.Text qualified as Text
import Katari.AST
  ( Module (..),
    Phase (Identified, Parsed, Zonked),
  )
import Katari.Compile
  ( CompileInput (..),
    CompileResult,
    SourceEntry (..),
    compile,
  )
import Katari.Id (QualifiedName (..), VariableResolution (..))
import Katari.SourceSpan (emptySourceSpan)
import Katari.Lexer qualified as Lexer
import Katari.Parser qualified as Parser
import Katari.SemanticType (Resolved, SemanticType)
import Katari.Stdlib qualified as Stdlib
import Katari.Typechecker.ConstraintGenerator
  ( ConstraintError,
    ConstraintGenResult (..),
    VariableSupply (..),
    generateConstraintsForSCC,
  )
import Katari.Typechecker.Identifier
  ( ConstructorData,
    IdentifierError,
    IdentifierState (..),
    ModuleData,
    ModuleIdentifyResult (..),
    RequestData,
    SymbolEntry,
    TypeData,
    VariableData (..),
    emitImportCycleError,
    identifyModule,
    registerAllModules,
    runIdentifier,
    runIdentifierFrom,
    scanExportNames,
  )
import Katari.Typechecker.ScopeIndex (ScopeIndex)
import Katari.Typechecker.ImportGraph (findImportCycles, topologicalSort)
import Katari.Typechecker.ScopeIndex (ScopeFrame (..), buildScopeIndex)
import Katari.Typechecker.Solver (SolverResult)
import Katari.Typechecker.Zonker (ModuleZonkResult (..), ZonkError, zonk)
import System.IO.Unsafe (unsafePerformIO)

-- ===========================================================================
-- compile sugar
-- ===========================================================================

compileSync :: CompileInput -> CompileResult
compileSync input = unsafePerformIO (compile (const (pure ())) input)

singleSourceInput :: Text -> CompileInput
singleSourceInput src =
  CompileInput
    { sources =
        Map.singleton
          "main"
          SourceEntry {filePath = "main", sourceText = src},
      cache = Map.empty
    }

multiSourceInput :: [(Text, Text)] -> CompileInput
multiSourceInput entries =
  CompileInput
    { sources =
        Map.fromList
          [ (moduleName, SourceEntry {filePath = unpack moduleName, sourceText = src})
            | (moduleName, src) <- entries
          ],
      cache = Map.empty
    }

-- ===========================================================================
-- Parser helpers
-- ===========================================================================

parsedStdlibModules :: Map Text (Module Parsed)
parsedStdlibModules =
  Map.mapWithKey
    ( \moduleName src ->
        let path = "<stdlib:" <> Text.unpack moduleName <> ">"
            (stream, _) = Lexer.lex path src
            (parsed, _) = Parser.parse path stream
         in parsed
    )
    Stdlib.stdlibSources

parseModule :: FilePath -> Text -> Module Parsed
parseModule path src =
  let (stream, _) = Lexer.lex path src
      (parsed, _) = Parser.parse path stream
   in parsed

-- ===========================================================================
-- Identifier aggregation
-- ===========================================================================

-- | Test-local replica of the legacy aggregated @IdentifierResult@. The
-- library itself no longer exposes this whole-program view (it ships
-- per-module results via 'ModuleIdentifyResult'); the test suite still
-- finds the aggregated shape convenient, so we rebuild it here from
-- per-module data inside 'identifyAll'.
data IdentifierResult = IdentifierResult
  { identifiedModules :: Map Text ModuleData,
    identifiedVariables :: Map QualifiedName VariableData,
    identifiedTypes :: Map QualifiedName TypeData,
    identifiedRequests :: Map QualifiedName RequestData,
    identifiedConstructors :: Map QualifiedName ConstructorData,
    moduleASTs :: Map Text (Module Identified),
    scopeIndex :: ScopeIndex SymbolEntry,
    moduleVisibleSymbols :: Map Text (Map Text SymbolEntry),
    moduleExports :: Map Text (Map Text SymbolEntry)
  }
  deriving (Show)

type IdentifyAccum =
  ( Map Text (Module Identified),
    Map Text (Map Text SymbolEntry),
    Map Text (Map Text SymbolEntry),
    [ScopeFrame SymbolEntry],
    IdentifierState
  )

-- | Run the identifier across every module in topological order. Mirrors
-- the orchestration buried inside 'Katari.Compile.compile' (without
-- cache support); duplicated here so the test suite can exercise
-- identifier output without going through the IO entry point.
identifyAll ::
  Set Text ->
  Map Text (Module Parsed) ->
  (IdentifierResult, [IdentifierError])
identifyAll trustedStdlibNames moduleMap =
  let ((), cycleState) =
        runIdentifier $
          for_ (findImportCycles moduleMap) (emitImportCycleError moduleMap)

      ((), phaseAState) =
        runIdentifierFrom cycleState $
          registerAllModules trustedStdlibNames moduleMap

      allModuleNames = Map.keysSet moduleMap
      allExportNames = Map.map scanExportNames moduleMap

      stepFresh :: IdentifyAccum -> Text -> IdentifyAccum
      stepFresh (asts, exports, topLevels, frames, state) moduleName =
        case Map.lookup moduleName moduleMap of
          Nothing -> (asts, exports, topLevels, frames, state)
          Just parsedModule ->
            let moduleResult =
                  identifyModule
                    allExportNames
                    exports
                    allModuleNames
                    state
                    moduleName
                    parsedModule
             in ( Map.insert moduleName moduleResult.identifiedAST asts,
                  Map.insert moduleName moduleResult.moduleExportTable exports,
                  Map.insert moduleName moduleResult.moduleTopLevel topLevels,
                  frames <> moduleResult.moduleScopeFrames,
                  moduleResult.moduleState
                )

      stdlibModuleNames =
        [ moduleName
          | moduleName <- Map.keys moduleMap,
            Set.member moduleName trustedStdlibNames
        ]
      sortedStdlibNames =
        filter (== "primitive") stdlibModuleNames
          ++ filter (/= "primitive") stdlibModuleNames
      initialAccum = (Map.empty, Map.empty, Map.empty, [], phaseAState)
      (stdlibASTs, stdlibExports, stdlibTopLevels, stdlibFrames, stdlibState) =
        foldl' stepFresh initialAccum sortedStdlibNames

      userModuleMap =
        Map.filterWithKey
          (\moduleName _ -> not (Set.member moduleName trustedStdlibNames))
          moduleMap
      levels = topologicalSort userModuleMap
      (acyclicASTs, acyclicExports, acyclicTopLevels, acyclicFrames, acyclicState) =
        foldl'
          (\accumulator level -> foldl' stepFresh accumulator (Set.toList level))
          (stdlibASTs, stdlibExports, stdlibTopLevels, stdlibFrames, stdlibState)
          levels

      processedModuleNames = Map.keysSet acyclicASTs
      remainingModuleNames =
        [ moduleName
          | moduleName <- Map.keys moduleMap,
            not (Set.member moduleName processedModuleNames)
        ]
      (allASTs, allExports, allTopLevels, allFrames, finalState) =
        foldl'
          stepFresh
          (acyclicASTs, acyclicExports, acyclicTopLevels, acyclicFrames, acyclicState)
          remainingModuleNames

      result =
        IdentifierResult
          { identifiedModules = finalState.modules,
            identifiedVariables = finalState.variables,
            identifiedTypes = finalState.types,
            identifiedRequests = finalState.requests,
            identifiedConstructors = finalState.constructors,
            moduleASTs = allASTs,
            scopeIndex = buildScopeIndex allFrames,
            moduleVisibleSymbols = allTopLevels,
            moduleExports = allExports
          }
   in (result, reverse finalState.errors)

-- | Convenience wrapper: union the user-supplied modules with the parsed
-- stdlib and run 'identifyAll'.
identifyWithStdlib ::
  Map Text (Module Parsed) ->
  (IdentifierResult, [IdentifierError])
identifyWithStdlib userMods =
  identifyAll Stdlib.stdlibModuleNames (Map.union userMods parsedStdlibModules)

-- ===========================================================================
-- Constraint-gen aggregation
-- ===========================================================================

-- | Run constraint generation over @moduleName@ treating every top-level
-- qname declared in that module as a single SCC. Enough for single-module
-- pipeline tests; multi-module tests typically only care about the user
-- module being focused on.
generateConstraintsForModule ::
  Text ->
  IdentifierResult ->
  (ConstraintGenResult, [ConstraintError])
generateConstraintsForModule moduleName idResult =
  let moduleAST =
        Map.findWithDefault
          (Module {declarations = [], sourceSpan = emptySourceSpan})
          moduleName
          idResult.moduleASTs
      sccQNames =
        Set.fromList
          [ qualifiedName
            | qualifiedName <- Map.keys idResult.identifiedVariables,
              qualifiedName.module_ == moduleName
          ]
      knownRequests = Map.keysSet idResult.identifiedRequests
      primRules = Map.mapMaybe (.variablePrimRule) idResult.identifiedVariables
   in generateConstraintsForSCC
        Map.empty
        moduleAST
        sccQNames
        idResult.identifiedTypes
        knownRequests
        primRules

-- | Constraint-gen over every user-defined module (i.e. anything not
-- in 'Stdlib.stdlibModuleNames'), merging the per-module results into
-- one whole-program-shaped 'ConstraintGenResult'. Used by phase-level
-- tests that want to assert against the legacy whole-program shape.
generateConstraintsAll ::
  IdentifierResult ->
  (ConstraintGenResult, [ConstraintError])
generateConstraintsAll idResult =
  let userModuleNames =
        [ moduleName
          | moduleName <- Map.keys idResult.moduleASTs,
            not (Set.member moduleName Stdlib.stdlibModuleNames)
        ]
      perModule = map (`generateConstraintsForModule` idResult) userModuleNames
      mergedConstraints = Set.unions (map ((.constraints) . fst) perModule)
      mergedEnv = Map.unions (map ((.typeEnvironment) . fst) perModule)
      mergedDeclarations = concatMap ((.declarations) . (.constrainedModule) . fst) perModule
      mergedSourceSpan = case perModule of
        ((firstResult, _) : _) -> firstResult.constrainedModule.sourceSpan
        [] -> emptySourceSpan
      mergedErrors = concatMap snd perModule
      finalSupply = case perModule of
        [] ->
          VariableSupply {typeVarSupply = 0, requestVarSupply = 0}
        ((firstResult, _) : _) -> firstResult.variableSupply
      result =
        ConstraintGenResult
          { constrainedModule =
              Module {declarations = mergedDeclarations, sourceSpan = mergedSourceSpan},
            typeEnvironment = mergedEnv,
            constraints = mergedConstraints,
            variableSupply = finalSupply
          }
   in (result, mergedErrors)

-- ===========================================================================
-- Zonker aggregation
-- ===========================================================================

-- | Whole-program-shaped zonker output for tests that expect the legacy
-- aggregated structure (one entry per module).
data ZonkResult = ZonkResult
  { zonkedModules :: Map Text (Module Zonked),
    zonkedTypeEnvironment :: Map Text (Map VariableResolution (SemanticType Resolved))
  }
  deriving (Show)

-- | Run the per-module zonker for @moduleName@ and wrap the result in
-- the legacy 'ZonkResult' shape with a single-entry map.
zonkAll ::
  Text ->
  IdentifierResult ->
  ConstraintGenResult ->
  SolverResult ->
  (ZonkResult, [ZonkError])
zonkAll moduleName idResult cgResult solverResult =
  let ownVariables =
        Map.filterWithKey
          (\qualifiedName _ -> qualifiedName.module_ == moduleName)
          idResult.identifiedVariables
      (mzResult, errs) = zonk ownVariables cgResult solverResult
      result =
        ZonkResult
          { zonkedModules = Map.singleton moduleName mzResult.zonkedModule,
            zonkedTypeEnvironment = Map.singleton moduleName mzResult.zonkedTypeEnv
          }
   in (result, errs)
