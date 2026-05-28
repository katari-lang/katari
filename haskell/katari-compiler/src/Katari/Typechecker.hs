-- | Per-module typecheck orchestration: runs constraint generation,
-- solving, and zonking for a single module's SCCs and aggregates the
-- results.
--
-- 'typecheckModule' is the only public entry point. It takes the
-- module's identified AST, an 'IdentifierResult' covering the module
-- itself and its transitive imports (used by the constraint generator
-- to look up cross-module names), and a map of imported types
-- (resolved exports of the dependencies). It returns the zonked module,
-- the module's local type environment, the public module interface,
-- and the collected diagnostics.
module Katari.Typechecker
  ( ModuleTypecheckResult (..),
    typecheckModule,
  )
where

import Data.Foldable (foldl')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.AST
  ( AgentDeclaration (..),
    DataDeclaration (..),
    Declaration (..),
    ExternalAgentDeclaration (..),
    Module (..),
    NameRef (..),
    NameRefKind (VariableRef),
    Phase (Identified, Zonked),
    PrimAgentDeclaration (..),
    RequestDeclaration (..),
    TypeSynonymDeclaration (..),
    retagNameRef,
    retagSyntacticType,
  )
import Katari.Diagnostic (Diagnostic)
import Katari.Id (QualifiedName (..), VariableResolution (..))
import Katari.SemanticType (Resolved, SemanticType)
import Katari.SourceSpan (Position (..), SourceSpan (..))
import Katari.Typechecker.AgentGraph (agentSCCs)
import Katari.Typechecker.ConstraintGenerator (generateConstraintsForSCC)
import Katari.Typechecker.ConstraintGenerator qualified as CG
import Katari.Typechecker.Identifier (IdentifierResult (..))
import Katari.Typechecker.ModuleInterface (ModuleInterface (..), extractModuleInterface)
import Katari.Typechecker.Solver (solve)
import Katari.Typechecker.Solver qualified as Solver
import Katari.Typechecker.Zonker (ZonkResult (..), zonk)
import Katari.Typechecker.Zonker qualified as Zonker

-- | Per-module typecheck output. Together with the module's
-- 'ModuleIdentifyResult' and (optionally) its 'ModuleLoweringResult'
-- this is the complete per-module artifact set produced by the
-- compiler pipeline.
data ModuleTypecheckResult = ModuleTypecheckResult
  { zonkedModule :: Module Zonked,
    -- | Type environment restricted to this module's own bindings
    -- (locals + own top-level). 'ResolvedLocal' entries here are
    -- guaranteed not to collide with other modules' locals.
    localTypeEnv :: Map VariableResolution (SemanticType Resolved),
    -- | The exported top-level types — the public interface other
    -- modules see during their own typecheck.
    moduleInterface :: ModuleInterface,
    diagnostics :: [Diagnostic]
  }

-- | Typecheck a single module. The constraint generator needs to look
-- up identifiers from this module and from its transitive imports; the
-- caller is responsible for supplying an 'IdentifierResult' that covers
-- exactly that range. @importedTypes@ carries the resolved types that
-- have already been typechecked in dependencies (top-level only).
typecheckModule ::
  IdentifierResult ->
  Map QualifiedName (SemanticType Resolved) ->
  Text ->
  ModuleTypecheckResult
typecheckModule idResult importedTypes moduleName =
  let moduleAST = Map.lookup moduleName idResult.moduleASTs
      nonAgentQNames = case moduleAST of
        Just ast -> collectNonAgentQualifiedNames moduleName ast
        Nothing -> Set.empty
      agentSCCsRaw = case moduleAST of
        Just ast -> agentSCCs moduleName ast
        Nothing -> []
      agentOnlySCCs =
        [ filtered
          | scc <- agentSCCsRaw,
            let filtered = Set.difference scc nonAgentQNames,
            not (Set.null filtered)
        ]
      allSCCs =
        ([nonAgentQNames | not (Set.null nonAgentQNames)])
          <> agentOnlySCCs

      initial =
        SCCAccumulator
          { sccImportedTypes = importedTypes,
            sccTypeEnv = Map.empty,
            sccDeclarations = Map.empty,
            sccDiagnostics = []
          }
      final = foldl' (runOneSCC idResult moduleName) initial allSCCs

      assembledModule = case moduleAST of
        Just ast -> assembleZonkedModule ast final.sccDeclarations
        Nothing -> Module {declarations = [], sourceSpan = emptySrcSpan}
      moduleInterface_ =
        extractModuleInterface
          moduleName
          idResult.identifiedVariables
          final.sccTypeEnv
      ownedTypeEnv = removeImported importedTypes final.sccTypeEnv
   in ModuleTypecheckResult
        { zonkedModule = assembledModule,
          localTypeEnv = ownedTypeEnv,
          moduleInterface = moduleInterface_,
          diagnostics = final.sccDiagnostics
        }

-- ---------------------------------------------------------------------------
-- Internal accumulator
-- ---------------------------------------------------------------------------

data SCCAccumulator = SCCAccumulator
  { sccImportedTypes :: Map QualifiedName (SemanticType Resolved),
    sccTypeEnv :: Map VariableResolution (SemanticType Resolved),
    sccDeclarations :: Map QualifiedName (Declaration Zonked),
    sccDiagnostics :: [Diagnostic]
  }

runOneSCC ::
  IdentifierResult ->
  Text ->
  SCCAccumulator ->
  Set QualifiedName ->
  SCCAccumulator
runOneSCC idResult moduleName accum sccQNames =
  let (cgResult, cgErrors) =
        generateConstraintsForSCC accum.sccImportedTypes idResult moduleName sccQNames
      cgDiags = map CG.toDiagnostic cgErrors
      (solverResult, solverErrors) = solve cgResult
      solverDiags = map Solver.toDiagnostic solverErrors
      (zonkResult_, zonkErrors) = zonk moduleName idResult cgResult solverResult
      zonkDiags = map Zonker.toDiagnostic zonkErrors
      sccLocalEnv = Map.findWithDefault Map.empty moduleName zonkResult_.zonkedTypeEnvironment
      sccInterface = extractSCCInterface sccQNames sccLocalEnv
      knownResolutions =
        Set.map
          ResolvedTopLevel
          (Map.keysSet (Map.intersection idResult.identifiedVariables accum.sccImportedTypes))
      ownedSCCEnv = Map.withoutKeys sccLocalEnv knownResolutions
      sccDecls = case Map.lookup moduleName zonkResult_.zonkedModules of
        Just sccModule -> sccModule.declarations
        Nothing -> []
   in SCCAccumulator
        { sccImportedTypes = Map.union accum.sccImportedTypes sccInterface,
          sccTypeEnv = Map.union accum.sccTypeEnv ownedSCCEnv,
          sccDeclarations = foldl' indexDeclaration accum.sccDeclarations sccDecls,
          sccDiagnostics = accum.sccDiagnostics <> cgDiags <> solverDiags <> zonkDiags
        }

-- ---------------------------------------------------------------------------
-- Pure helpers
-- ---------------------------------------------------------------------------

collectNonAgentQualifiedNames :: Text -> Module Identified -> Set QualifiedName
collectNonAgentQualifiedNames moduleName moduleAST =
  Set.fromList (concatMap extractQualifiedName moduleAST.declarations)
  where
    extractQualifiedName :: Declaration Identified -> [QualifiedName]
    extractQualifiedName = \case
      DeclarationRequest decl -> resolveToLocal decl.name
      DeclarationExternalAgent decl -> resolveToLocal decl.name
      DeclarationPrimAgent decl -> resolveToLocal decl.name
      DeclarationData decl -> resolveToLocal decl.name
      DeclarationAgent _ -> []
      DeclarationTypeSynonym _ -> []
      DeclarationImport _ -> []
      DeclarationError _ -> []

    resolveToLocal :: NameRef Identified VariableRef -> [QualifiedName]
    resolveToLocal nameRef = case nameRef.resolution of
      Just (ResolvedTopLevel qualifiedName)
        | qualifiedName.module_ == moduleName -> [qualifiedName]
      _ -> []

extractSCCInterface ::
  Set QualifiedName ->
  Map VariableResolution (SemanticType Resolved) ->
  Map QualifiedName (SemanticType Resolved)
extractSCCInterface sccQNames typeEnv =
  Map.fromList
    [ (qualifiedName, resolvedType)
      | qualifiedName <- Set.toList sccQNames,
        Just resolvedType <- [Map.lookup (ResolvedTopLevel qualifiedName) typeEnv]
    ]

removeImported ::
  Map QualifiedName (SemanticType Resolved) ->
  Map VariableResolution (SemanticType Resolved) ->
  Map VariableResolution (SemanticType Resolved)
removeImported importedTypes fullEnv =
  let importedKeys =
        Map.keysSet
          ( Map.filterWithKey
              ( \variableResolution _ -> case variableResolution of
                  ResolvedTopLevel qualifiedName -> Map.member qualifiedName importedTypes
                  ResolvedLocal _ -> False
              )
              fullEnv
          )
   in Map.withoutKeys fullEnv importedKeys

indexDeclaration ::
  Map QualifiedName (Declaration Zonked) ->
  Declaration Zonked ->
  Map QualifiedName (Declaration Zonked)
indexDeclaration declarationMap declaration = case declarationQName declaration of
  Just qualifiedName -> Map.insert qualifiedName declaration declarationMap
  Nothing -> declarationMap

declarationQName :: Declaration Zonked -> Maybe QualifiedName
declarationQName = \case
  DeclarationAgent AgentDeclaration {name = NameRef {resolution}} -> resolveTopLevel resolution
  DeclarationRequest RequestDeclaration {name = NameRef {resolution}} -> resolveTopLevel resolution
  DeclarationExternalAgent ExternalAgentDeclaration {name = NameRef {resolution}} -> resolveTopLevel resolution
  DeclarationPrimAgent PrimAgentDeclaration {name = NameRef {resolution}} -> resolveTopLevel resolution
  DeclarationData DataDeclaration {name = NameRef {resolution}} -> resolveTopLevel resolution
  DeclarationTypeSynonym _ -> Nothing
  DeclarationImport _ -> Nothing
  DeclarationError _ -> Nothing

identifiedDeclQName :: Declaration Identified -> Maybe QualifiedName
identifiedDeclQName = \case
  DeclarationAgent AgentDeclaration {name = NameRef {resolution}} -> resolveTopLevel resolution
  DeclarationRequest RequestDeclaration {name = NameRef {resolution}} -> resolveTopLevel resolution
  DeclarationExternalAgent ExternalAgentDeclaration {name = NameRef {resolution}} -> resolveTopLevel resolution
  DeclarationPrimAgent PrimAgentDeclaration {name = NameRef {resolution}} -> resolveTopLevel resolution
  DeclarationData DataDeclaration {name = NameRef {resolution}} -> resolveTopLevel resolution
  DeclarationTypeSynonym _ -> Nothing
  DeclarationImport _ -> Nothing
  DeclarationError _ -> Nothing

resolveTopLevel :: Maybe VariableResolution -> Maybe QualifiedName
resolveTopLevel = \case
  Just (ResolvedTopLevel qualifiedName) -> Just qualifiedName
  _ -> Nothing

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
  _ -> DeclarationError emptySrcSpan

emptySrcSpan :: SourceSpan
emptySrcSpan =
  SrcSpan
    { filePath = "",
      start = Position {line = 0, column = 0},
      end = Position {line = 0, column = 0}
    }
