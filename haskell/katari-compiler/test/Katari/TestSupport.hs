-- | Test-local helpers. The library exposes the per-module step functions
-- (@identifyModule@, @generateConstraintsForSCC@, @zonk@), the whole-program
-- @identifyProgram@, and the IO entry point @compile@. This module adds the
-- legacy aggregated shapes that older phase-specific tests expect by driving
-- the real APIs directly — no duplicated orchestration.
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

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text, unpack)
import Data.Text qualified as Text
import Katari.AST (Module (..), Phase (Identified, Parsed, Zonked))
import Katari.Compile
  ( CompileInput (..),
    CompileResult,
    IdentifyResult (..),
    SourceEntry (..),
    compile,
    identifyProgram,
  )
import Katari.Id (QualifiedName (..), VariableResolution (..))
import Katari.Lexer qualified as Lexer
import Katari.Parser qualified as Parser
import Katari.SemanticType (Resolved, SemanticType)
import Katari.SourceSpan (emptySourceSpan)
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
    ModuleData,
    RequestData,
    SymbolEntry,
    TypeData,
    VariableData (..),
  )
import Katari.Typechecker.ScopeIndex (ScopeIndex, buildScopeIndex)
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
    { sources = Map.singleton "main" SourceEntry {filePath = "main", sourceText = src},
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

-- | Test-local replica of the legacy aggregated identifier view. The library
-- ships per-module results; tests still find the aggregated shape convenient,
-- so we reshape 'identifyProgram''s output here.
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

-- | Run the whole-program identifier and reshape its output into the legacy
-- 'IdentifierResult'. Delegates to the real 'identifyProgram' — this is the
-- exact orchestration the compiler uses, so tests exercise the production
-- path rather than a duplicate.
identifyAll :: Set Text -> Map Text (Module Parsed) -> (IdentifierResult, [IdentifierError])
identifyAll trustedStdlibNames moduleMap =
  let idResult = identifyProgram trustedStdlibNames moduleMap
      result =
        IdentifierResult
          { identifiedModules = idResult.modules,
            identifiedVariables = idResult.variables,
            identifiedTypes = idResult.types,
            identifiedRequests = idResult.requests,
            identifiedConstructors = idResult.constructors,
            moduleASTs = idResult.asts,
            scopeIndex = buildScopeIndex idResult.scopeFrames,
            moduleVisibleSymbols = idResult.topLevelTables,
            moduleExports = idResult.exportTables
          }
   in (result, idResult.errors)

-- | Union the user-supplied modules with the parsed stdlib and run 'identifyAll'.
identifyWithStdlib :: Map Text (Module Parsed) -> (IdentifierResult, [IdentifierError])
identifyWithStdlib userMods =
  identifyAll Stdlib.stdlibModuleNames (Map.union userMods parsedStdlibModules)

-- ===========================================================================
-- Constraint-gen aggregation
-- ===========================================================================

-- | Run constraint generation over @moduleName@ treating every top-level
-- qname it declares as a single SCC. Enough for single-module pipeline tests.
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

-- | Constraint-gen over every user-defined module, merged into one
-- whole-program-shaped 'ConstraintGenResult' for phase-level tests.
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
        [] -> VariableSupply {typeVarSupply = 0, requestVarSupply = 0}
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

-- | Run the per-module zonker for @moduleName@ and wrap the result in the
-- legacy 'ZonkResult' shape with a single-entry map.
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
