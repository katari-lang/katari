-- | Pure orchestration entry point for the Katari compiler.
--
-- Embedders (@katari-project@, @katari-lsp@, the playground, test
-- harnesses) call 'compile' with an in-memory map of source texts and
-- receive an 'IRModule' + @[SchemaEntry]@ + a unified 'Diagnostic' stream.
-- This module performs **no** I\/O: all file system / @katari.toml@
-- handling lives in @katari-project@.
--
-- Pipeline:
--
-- @
-- parseSources
--   → identify         -- emits import-cycle (K0110) and missing-import (K0107)
--                      --   diagnostics in addition to name-resolution errors
--   → for each module in topological order:
--       agentSCCs              -- split declarations into SCC groups
--       for each SCC in dependency order:
--         generateConstraintsForSCC  -- per-SCC CG with known types
--         → solve                    -- per-SCC solving
--         → zonk                     -- per-SCC zonking
--         → accumulate resolved types for downstream SCCs
--       assembleZonkedModule   -- merge SCC results into full Module Zonked
--   → lower            -- → IRModule (pure, whole-program)
--   → buildSchemas     -- → [SchemaEntry] (independent of lower; reads ZonkResult)
-- @
--
-- 'compile' never aborts on errors: each phase produces diagnostics that
-- are merged into 'CompileResult.diagnostics'. If any error-severity
-- diagnostic is present, downstream artefacts ('irModule',
-- 'schemaEntries') are returned as 'Nothing' to make the failure mode
-- explicit at the type level.
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
import Katari.Id (QualifiedName (..), VariableResolution (..))
import Katari.SourceSpan (Position (..), SourceSpan (..))
import Katari.IR (IRModule)
import Katari.Lexer as Lexer
import Katari.Lowering (lowerProgram)
import Katari.Lowering qualified as Lowering
import Katari.Parser qualified as Parser
import Katari.Schema (SchemaEntry, buildSchemas)
import Katari.SemanticType (Resolved, SemanticType)
import Katari.Stdlib qualified as Stdlib
import Katari.Typechecker.ModuleInterface (ModuleInterface (..), extractModuleInterface)
import Katari.Typechecker.AgentGraph (agentSCCs)
import Katari.Typechecker.ConstraintGenerator (generateConstraintsForSCC)
import Katari.Typechecker.ConstraintGenerator qualified as CG
import Katari.Typechecker.Exhaustive (checkExhaustive)
import Katari.Typechecker.Exhaustive qualified as Exhaustive
import Katari.Typechecker.Identifier (IdentifierResult (..), identify)
import Katari.Typechecker.Identifier qualified as Identifier
import Katari.Typechecker.ImportGraph (topologicalSort)
import Katari.Typechecker.Solver (SolverResult (..), solve)
import Katari.Typechecker.Solver qualified as Solver
import Katari.Typechecker.Zonker (ZonkResult (..), zonk)
import Katari.Typechecker.Zonker qualified as Zonker

-- ===========================================================================
-- Input / output
-- ===========================================================================

-- | Dot-separated module path ("foo.bar.baz"). The compiler treats this
-- as an opaque key; the file-system mapping is the embedder's
-- responsibility.
type ModuleName = Text

-- | One entry per source file.
-- The compiler assumes no relationship whatsoever between 'filePath' and
-- 'moduleName'. 'filePath' is the real file path used by diagnostic spans
-- and the Query layer.
data SourceEntry = SourceEntry
  { filePath :: FilePath,
    sourceText :: Text
  }
  deriving (Show)

-- | Input bundle for 'compile'. Carries the full set of modules the
-- compiler should treat as in scope. The compiler is package-agnostic:
-- merging packages, resolving dependencies, and locating @.ktr@ files
-- happens upstream (in @katari-project@), and the result is handed to
-- the compiler as a flat 'Map' so the entire pipeline stays pure.
data CompileInput = CompileInput
  { -- | Module name → source entry. The map is treated as the complete
    -- world: any module not present here is "missing" from the
    -- compiler's point of view.
    --
    -- Module names are derived from file paths by the embedder (= the
    -- relative path under the package's @src/@ root, dot-joined). By
    -- convention every file in a package @P@ lives under @src\/P.ktr@
    -- or @src\/P\/...@, so module keys are naturally
    -- package-qualified (e.g. @P@, @P.helpers@). The compiler itself
    -- is package-agnostic and just does name lookup; the embedder
    -- (= @katari-project@) is responsible for assembling sources
    -- from all reachable packages.
    sources :: Map ModuleName SourceEntry,
    -- | Optional per-module compilation cache from a previous
    -- 'compile' invocation. Pass 'Map.empty' for a fresh compile.
    -- When supplied, modules whose source hash matches and whose
    -- upstream interfaces are unchanged are skipped (their cached
    -- type environment and diagnostics are reused). The cache is
    -- keyed by module name.
    cache :: Map ModuleName ModuleCache
  }
  deriving (Show)

-- | Per-module compilation cache entry. Stores everything needed to
-- skip recompilation of an unchanged module: the source hash for
-- staleness detection, the module interface for downstream
-- invalidation, and the typechecking products (identified AST, zonked
-- module, type environment, diagnostics) that would otherwise be
-- recomputed.
data ModuleCache = ModuleCache
  { cacheSourceHash :: Int,
    cacheInterface :: ModuleInterface,
    cacheIdentified :: Module Identified,
    cacheZonkedModule :: Module Zonked,
    cacheZonkedTypeEnv :: Map VariableResolution (SemanticType Resolved),
    cacheDiagnostics :: [Diagnostic]
  }
  deriving (Show)

-- | Structured progress log emitted at each phase boundary. Callers
-- (CLI, LSP, playground) can render these to show compile progress.
data CompileLog where
  CompileLogParsing :: CompileLog
  CompileLogIdentifying :: CompileLog
  CompileLogTypechecking :: Text -> Int -> Int -> CompileLog
  CompileLogLowering :: CompileLog
  CompileLogSchemaGeneration :: CompileLog
  CompileLogComplete :: CompileLog
  deriving (Show)

-- | Output of 'compile'. The 'diagnostics' field is the single source of
-- truth for success / failure; the @Maybe@-wrapped artefacts ('irModule',
-- 'schemaEntries') are convenience hints that mirror @not (hasErrors
-- diagnostics)@. The non-@Maybe@ intermediate-phase results
-- ('identifierResult', 'solverResult', 'zonkResult') are always returned
-- so LSP / CLI tooling can serve partial information (hover, completion,
-- agent listing) even when the program fails to compile end-to-end.
data CompileResult = CompileResult
  { -- | The lowered IR. 'Nothing' if any error-severity diagnostic was
    -- raised before lowering succeeded.
    irModule :: Maybe IRModule,
    -- | API-surface schema entries for AI tool calling and runtime validation.
    -- 'Nothing' under the same condition as 'irModule'.
    schemaEntries :: Maybe [SchemaEntry],
    -- | Unified diagnostic stream, ordered roughly by phase
    -- (parse → identify → constrain → solve → zonk → lower).
    diagnostics :: [Diagnostic],
    -- | Name resolution result. Always returned so LSP / CLI can list
    -- agents, detect unused declarations, and perform qualified-name
    -- lookup without re-running the compiler.
    identifierResult :: IdentifierResult,
    -- | Solver output for LSP type-on-hover. Always returned (even when
    -- diagnostics are present) so the editor can show partial results.
    solverResult :: SolverResult,
    -- | Zonker output for LSP type-on-hover. Always returned.
    zonkResult :: ZonkResult,
    -- | Structured compile log, one entry per phase boundary. Purely
    -- additive: callers may ignore this field. Useful for CLI / LSP
    -- progress indicators.
    compileLogs :: [CompileLog],
    -- | Updated per-module cache. Feed this back as
    -- 'CompileInput.cache' on the next invocation to enable
    -- incremental compilation. Keyed by module name (same namespace
    -- as 'CompileInput.sources').
    updatedCache :: Map ModuleName ModuleCache
  }

-- ===========================================================================
-- Top-level entry
-- ===========================================================================

-- | Compile a set of in-memory sources to IR + schema. Pure (no I\/O).
--
-- The result's @diagnostics@ list is the single source of truth for
-- failure: callers should branch on @hasErrors diagnostics@ rather than
-- on the @Maybe@ payloads.
--
-- Example:
--
-- @
-- import Data.Map.Strict qualified as Map
--
-- let src    = "agent hello() -> string { return \\"hello\\" }"
--     input  = CompileInput { sources = Map.singleton "main" (SourceEntry "main.ktr" src), cache = Map.empty }
--     result = compile input
-- null (diagnostics result)  -- True  (no errors)
-- isJust (irModule result)   -- True  (IR was emitted)
-- @
compile :: CompileInput -> CompileResult
compile input =
  let stdlibEntries =
        Map.mapWithKey
          (\moduleName src -> SourceEntry ("<stdlib:" <> Text.unpack moduleName <> ">") src)
          Stdlib.stdlibSources
      mergedSources = Map.union input.sources stdlibEntries
      (parsed, parseDiags) = parseSources mergedSources
      (idResult, idErrors) = identify Stdlib.stdlibModuleNames parsed
      idDiags = map Identifier.toDiagnostic idErrors

      -- Compute topological levels from parsed modules.
      stdlibModuleSet =
        Set.fromList
          [ moduleName
            | moduleName <- Map.keys parsed,
              Set.member moduleName Stdlib.stdlibModuleNames
          ]
      primitiveSingleton = Set.singleton "primitive"
      otherStdlibModules = Set.delete "primitive" stdlibModuleSet
      stdlibLevels =
        (if Set.member "primitive" stdlibModuleSet then [primitiveSingleton] else [])
          ++ (if Set.null otherStdlibModules then [] else [otherStdlibModules])
      userModuleMap = Map.filterWithKey (\moduleName _ -> not (Set.member moduleName Stdlib.stdlibModuleNames)) parsed
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
          ++ (if Set.null remainingUserNames then [] else [remainingUserNames])

      -- Compute per-module source hashes for cache invalidation.
      sourceHashes =
        Map.map (\entry -> hash entry.sourceText) mergedSources

      -- Per-module typecheck loop (emits per-module / per-SCC logs).
      -- Modules at the same topological level are sparked in parallel
      -- via 'parMap rseq'; inter-level ordering is sequential.
      (mergedSolverResult, mergedZonkResult, typecheckDiags, typecheckLogs, newCache) =
        typecheckModules idResult moduleLevels sourceHashes input.cache

      -- NOTE (speculative lowering): In the current pure pipeline,
      -- typechecking must complete before lowering because Lowering reads
      -- ZonkResult (for schema computation inside AgentBlock). The
      -- pipeline structure is designed so that a future version can
      -- introduce `par` / `pseq` to evaluate typechecking and a
      -- schema-free lowering pass concurrently; the schema decoration
      -- would then be applied as a post-pass once ZonkResult is
      -- available. For v0.1.0 the sequential structure is sufficient.

      exhaustiveDiags = map Exhaustive.toDiagnostic (checkExhaustive idResult mergedZonkResult)
      preLowerDiags =
        parseDiags
          <> idDiags
          <> typecheckDiags
          <> exhaustiveDiags
      -- Only error-level diagnostics suppress IR emission; warnings pass
      -- through so callers get a usable IR + warnings in the same result.
      shouldLower = not (hasErrors preLowerDiags)
      (loweredIR, loweringDiags)
        | shouldLower =
            let (eitherIR, errs) = lowerProgram idResult mergedZonkResult
                structuralDiags = map Lowering.toDiagnostic errs
             in case eitherIR of
                  Right ir -> (Just ir, structuralDiags)
                  Left internalDiag -> (Nothing, structuralDiags <> [internalDiag])
        | otherwise = (Nothing, [])
      shouldEmitArtefacts =
        shouldLower && not (hasErrors loweringDiags)
      schema = if shouldEmitArtefacts then Just (buildSchemas idResult mergedZonkResult) else Nothing
      finalIR = if shouldEmitArtefacts then loweredIR else Nothing
      allDiags = preLowerDiags <> loweringDiags

      logs =
        [CompileLogParsing, CompileLogIdentifying]
          <> typecheckLogs
          <> (if shouldLower then [CompileLogLowering] else [])
          <> (if shouldEmitArtefacts then [CompileLogSchemaGeneration] else [])
          <> [CompileLogComplete]
   in CompileResult
        { irModule = finalIR,
          schemaEntries = schema,
          diagnostics = allDiags,
          identifierResult = idResult,
          solverResult = mergedSolverResult,
          zonkResult = mergedZonkResult,
          compileLogs = logs,
          updatedCache = newCache
        }

-- ===========================================================================
-- Per-module typecheck loop
-- ===========================================================================

data TypecheckAccumulator = TypecheckAccumulator
  { accImportedTypes :: Map QualifiedName (SemanticType Resolved),
    accZonkedModules :: Map Text (Module Zonked),
    accZonkedModuleNames :: Map Text Text,
    accZonkedTypeEnvironment :: Map VariableResolution (SemanticType Resolved),
    accSolverResult :: SolverResult,
    accDiagnostics :: [Diagnostic],
    accSCCDeclarations :: Map QualifiedName (Declaration Zonked),
    accLogs :: [CompileLog],
    accUpdatedCache :: Map ModuleName ModuleCache,
    accAllPriorCacheValid :: Bool
  }

-- | Per-module typecheck result. Produced independently by each module
-- in a topological level, then merged into the accumulator.
data ModuleTypecheckResult = ModuleTypecheckResult
  { mtrModuleName :: Text,
    mtrImportedTypes :: Map QualifiedName (SemanticType Resolved),
    mtrZonkedModule :: Module Zonked,
    mtrTypeEnvironment :: Map VariableResolution (SemanticType Resolved),
    mtrSolverResult :: SolverResult,
    mtrDiagnostics :: [Diagnostic],
    mtrLogs :: [CompileLog],
    mtrCacheEntry :: ModuleCache,
    mtrIsCacheHit :: Bool
  }

typecheckModules ::
  IdentifierResult ->
  [Set.Set Text] ->
  Map ModuleName Int ->
  Map ModuleName ModuleCache ->
  (SolverResult, ZonkResult, [Diagnostic], [CompileLog], Map ModuleName ModuleCache)
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

-- | Process one topological level. Modules within a level have no
-- inter-dependencies, so they are sparked in parallel via 'parMap'.
-- Results are merged into the accumulator before the next level.
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

-- | Merge a single module's typecheck result into the accumulator.
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

-- | Typecheck one module, producing an independent result. Reads the
-- accumulator for imported types but does not mutate it.
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
          mtrCacheEntry = ModuleCache
            { cacheSourceHash = 0,
              cacheInterface = ModuleInterface {exportedTypes = Map.empty},
              cacheIdentified = Module {declarations = [], sourceSpan = emptySrcSpan},
              cacheZonkedModule = Module {declarations = [], sourceSpan = emptySrcSpan},
              cacheZonkedTypeEnv = Map.empty,
              cacheDiagnostics = []
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
          mtrCacheEntry = cached,
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
        (if Set.null nonAgentQualifiedNames then [] else [nonAgentQualifiedNames])
          <> agentOnlySCCs
      totalSCCs = length allSCCs
      indexedSCCs = zip [1 ..] allSCCs
      -- The SCC loop starts with a clean accumulator that inherits
      -- imported types from prior levels but has empty module-local
      -- fields. This ensures the produced result contains only this
      -- module's contributions.
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
        ModuleCache
          { cacheSourceHash = case Map.lookup moduleName sourceHashes of
              Just sourceHash -> sourceHash
              Nothing -> 0,
            cacheInterface = moduleInterface,
            cacheIdentified = case moduleAST of
              Just ast -> ast
              Nothing -> Module {declarations = [], sourceSpan = emptySrcSpan},
            cacheZonkedModule = assembledModule,
            cacheZonkedTypeEnv = moduleTypeEnv,
            cacheDiagnostics = sccAccumulator.accDiagnostics
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

-- | Collect the 'QualifiedName's of all non-agent declarations in a
-- module. These are data, request, external-agent, and prim-agent
-- declarations whose types are fully determined by their explicit
-- signatures (no inference needed). They are pre-processed as a
-- single batch before the agent SCC loop.
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
  -- Callable declarations should never reach here; if they do, leave as error sentinel.
  _ -> DeclarationError placeholderSpan
    where
      placeholderSpan = SrcSpan {filePath = "", start = Position {line = 0, column = 0}, end = Position {line = 0, column = 0}}

-- ===========================================================================
-- Parse helper
-- ===========================================================================

-- | Parse every source in the input map. Each 'SourceEntry' carries the
-- real 'FilePath' that is embedded into error spans; the compiler makes
-- no assumption about the relationship between a 'ModuleName' and its
-- 'FilePath'.
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

-- | Parse 'Stdlib.stdlibSources' and produce a 'Map ModuleName (Module Parsed)'
-- ready for merging into an Identifier-pass input. Parse errors are
-- ignored here (the stdlib source is compiler-managed; if it fails to
-- parse, that's a compiler bug, not a user issue).
parsedStdlibModules :: Map ModuleName (Module Parsed)
parsedStdlibModules = fst (parseSources stdlibEntries)
  where
    stdlibEntries =
      Map.mapWithKey
        (\moduleName src -> SourceEntry ("<stdlib:" <> Text.unpack moduleName <> ">") src)
        Stdlib.stdlibSources

-- | Test-facing helper: run 'identify' against a user-module map with
-- 'parsedStdlibModules' merged in and 'Stdlib.stdlibModuleNames' marked
-- as trusted. Mirrors what 'compile' does internally so unit tests don't
-- have to repeat the boilerplate.
identifyWithStdlib ::
  Map ModuleName (Module Parsed) ->
  (IdentifierResult, [Identifier.IdentifierError])
identifyWithStdlib userMods =
  identify Stdlib.stdlibModuleNames (Map.union userMods parsedStdlibModules)
