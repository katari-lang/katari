-- | Per-module typecheck orchestration: runs constraint generation,
-- solving, and zonking for a single module's SCCs and aggregates the
-- results.
--
-- 'typecheckModule' is the only public entry point. The caller supplies
-- everything the typechecker needs (the module's AST, its own
-- variables, the cross-module type / request / prim tables, and the
-- imported resolved types from upstream modules) via a
-- 'TypecheckSubject' — no aggregated phase-output types are required.
module Katari.Typechecker
  ( TypecheckSubject (..),
    ModuleTypecheckResult (..),
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
    NameRefResolution,
    Phase (Identified, Zonked),
    PrimAgentDeclaration (..),
    RequestDeclaration (..),
    TypeSynonymDeclaration (..),
    retagNameRef,
    retagSyntacticType,
  )
import Katari.Diagnostic (Diagnostic)
import Katari.Id (QualifiedName (..), VariableResolution (..))
import Katari.Prim (PrimRule)
import Katari.SemanticType (Resolved, SemanticType)
import Katari.SourceSpan (emptySourceSpan)
import Katari.Typechecker.AgentGraph (agentSCCs)
import Katari.Typechecker.Check (checkSCC)
import Katari.Typechecker.Identifier
  ( TypeData (..),
    VariableData (..),
  )
import Katari.Typechecker.ModuleInterface (ModuleInterface (..), extractModuleInterface)

-- | Everything 'typecheckModule' needs about one module's input. The
-- caller (compile orchestrator) assembles this from per-module
-- identify outputs + the module's transitive imports.
data TypecheckSubject = TypecheckSubject
  { moduleName :: Text,
    moduleAST :: Module Identified,
    -- | The module's own top-level variables. Used by 'extractModuleInterface'
    -- to compute the public-facing exported types.
    ownVariables :: Map QualifiedName VariableData,
    -- | All type declarations reachable from this module's signatures
    -- (own + transitive imports). Used by the CG to resolve type
    -- synonyms.
    typeData :: Map QualifiedName TypeData,
    -- | All request qualified names reachable from this module. Used
    -- by the CG as the membership filter when elaborating @with@-clauses.
    knownRequests :: Set QualifiedName,
    -- | Prim rules reachable from this module. CG looks up call sites
    -- against this map to specialise prim behaviour.
    primRules :: Map QualifiedName PrimRule,
    -- | Resolved types coming from already-typechecked dependencies.
    importedTypes :: Map QualifiedName (SemanticType Resolved)
  }

-- | Per-module typecheck output.
data ModuleTypecheckResult = ModuleTypecheckResult
  { zonkedModule :: Module Zonked,
    -- | The module's own type environment (locals + own top-level).
    -- @ResolvedLocal@ entries are guaranteed not to collide with other
    -- modules' locals.
    localTypeEnv :: Map VariableResolution (SemanticType Resolved),
    -- | The exported top-level types — what other modules see during
    -- their own typecheck.
    moduleInterface :: ModuleInterface,
    diagnostics :: [Diagnostic]
  }

typecheckModule :: TypecheckSubject -> ModuleTypecheckResult
typecheckModule subject =
  let nonAgentQNames = collectNonAgentQualifiedNames subject.moduleName subject.moduleAST
      agentSCCsRaw = agentSCCs subject.moduleName subject.moduleAST
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
          { sccImportedTypes = subject.importedTypes,
            sccTypeEnv = Map.empty,
            sccDeclarations = Map.empty,
            sccDiagnostics = []
          }
      final = foldl' (runOneSCC subject) initial allSCCs

      assembledModule = assembleZonkedModule subject.moduleAST final.sccDeclarations
      moduleInterface_ =
        extractModuleInterface
          subject.moduleName
          subject.ownVariables
          final.sccTypeEnv
      ownedTypeEnv = removeImported subject.importedTypes final.sccTypeEnv
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
  TypecheckSubject ->
  SCCAccumulator ->
  Set QualifiedName ->
  SCCAccumulator
runOneSCC subject accum sccQNames =
  let (zonkedDeclarations, signatures, typeEnv, diagnostics) =
        checkSCC
          subject.moduleName
          accum.sccImportedTypes
          subject.moduleAST
          sccQNames
          subject.typeData
          subject.primRules
   in SCCAccumulator
        { sccImportedTypes = Map.union accum.sccImportedTypes signatures,
          sccTypeEnv = Map.union accum.sccTypeEnv typeEnv,
          sccDeclarations = Map.union accum.sccDeclarations zonkedDeclarations,
          sccDiagnostics = accum.sccDiagnostics <> diagnostics
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

-- | Phase-parametric extraction of the top-level 'QualifiedName' a
-- declaration introduces. The phases the typechecker bridges ('Identified'
-- and 'Zonked') share the same @Maybe VariableResolution@ shape for
-- 'VariableRef' resolution, so one function covers both.
declarationQName ::
  (NameRefResolution phase VariableRef ~ Maybe VariableResolution) =>
  Declaration phase ->
  Maybe QualifiedName
declarationQName = \case
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
          ( \declaration -> case declarationQName declaration of
              Just qualifiedName -> case Map.lookup qualifiedName sccDeclarationMap of
                Just zonkedDeclaration -> zonkedDeclaration
                Nothing -> retagNonCallableDeclaration declaration
              Nothing -> retagNonCallableDeclaration declaration
          )
          identifiedModule.declarations,
      sourceSpan = identifiedModule.sourceSpan
    }

-- | Retag declarations the SCC pipeline doesn't process (type synonyms,
-- imports, parse errors). Callable kinds (agent / request / external /
-- prim / data) reach this only via 'assembleZonkedModule' bypass paths;
-- they are handled by looking the matching zonked declaration out of
-- 'sccDeclarationMap' instead.
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
  DeclarationAgent _ -> internalError
  DeclarationRequest _ -> internalError
  DeclarationExternalAgent _ -> internalError
  DeclarationPrimAgent _ -> internalError
  DeclarationData _ -> internalError
  where
    internalError = DeclarationError emptySourceSpan
