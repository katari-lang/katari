-- | The Identifier pass resolves every name reference in a 'Parsed' module against the names in
-- scope, producing an 'Identified' module (each reference carries 'Just' its resolution, or 'Nothing'
-- when unresolved). This module is the entry point and orchestration: the export scan, import
-- resolution, the top-level scope, and declaration dispatch. Expressions, statements, types, and
-- patterns are resolved in the @Katari.Identifier.*@ submodules over the monad in
-- "Katari.Identifier.Monad".
--
-- Resolution is per-module and order-independent: 'scanExports' yields every module's interface up
-- front, so 'identifyModule' resolves bodies against a fixed import context and tolerates import
-- cycles. All of a module's top-level names are in scope throughout it (mutual recursion); a value and
-- a type may share a name (distinct namespaces), but re-using a name within one namespace is K2003.
-- Type-synonym cycles are left for the checker.
module Katari.Identifier where

import Control.Applicative ((<|>))
import Control.Monad (when)
import Data.List (foldl')
import Data.Map qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.ModuleName (ModuleName, covers, lastSegment)
import Katari.Data.SourceSpan (SourceSpan)
import Katari.Diagnostics (Diagnostics)
import Katari.Identifier.Expression (resolveAgentDeclaration)
import Katari.Identifier.Monad
import Katari.Identifier.Type (resolveParameterSignature, resolveType, withGenericParameters)

---------------------------------------------------------------------------------------------------
-- Export scan
---------------------------------------------------------------------------------------------------

-- | Project a parsed module's public surface: every top-level declaration is exported (imports and
-- bodies are not consulted, so this is import-independent). Built from the same 'declarationBindings'
-- as the module's own top-level scope, so the interface and in-module resolution never disagree.
scanExports :: ModuleName -> Module Parsed -> ModuleInterface
scanExports moduleName parsedModule =
  ModuleInterface {exports = Map.fromListWith mergeExportedSymbol entries}
  where
    entries = [(binding.name, exportedSymbolOf binding) | binding <- concatMap (declarationBindings moduleName) parsedModule.declarations]

-- | Every top-level binding a declaration introduces: its module-qualified resolution and the span of
-- its defining occurrence, one per namespace it populates. The single source of truth shared by the
-- export scan and the module's own top-level scope.
declarationBindings :: ModuleName -> Declaration Parsed -> List Binding
declarationBindings moduleName = \case
  DeclarationAgent declaration -> [ownVariable declaration.name declaration.variableReference]
  DeclarationExternalAgent declaration -> [ownVariable declaration.name declaration.variableReference]
  DeclarationPrimitiveAgent declaration -> [ownVariable declaration.name declaration.variableReference]
  DeclarationRequest declaration -> [ownVariable declaration.name declaration.variableReference, ownType declaration.name declaration.typeReference]
  DeclarationData declaration -> [ownVariable declaration.name declaration.variableReference, ownType declaration.name declaration.typeReference]
  DeclarationTypeSynonym declaration -> [ownType declaration.name declaration.typeReference]
  DeclarationImport _ -> []
  DeclarationError _ -> []
  where
    ownVariable name reference = variableBinding name reference.sourceSpan (qualifiedVariableResolution moduleName name)
    ownType name reference = typeBinding name reference.sourceSpan (qualifiedTypeResolution moduleName name)

exportedSymbolOf :: Binding -> ExportedSymbol
exportedSymbolOf binding = case binding.resolution of
  SymbolVariable resolution -> ExportedSymbol {variable = Just resolution, typeLevel = Nothing}
  SymbolType resolution -> ExportedSymbol {variable = Nothing, typeLevel = Just resolution}
  -- Declarations never produce a module binding (modules come only from imports), so this is unreachable.
  SymbolModule _ -> ExportedSymbol {variable = Nothing, typeLevel = Nothing}

-- | Combine two same-named exported symbols, keeping a resolution from either namespace (so a value
-- and a type sharing a name both survive). On a genuine same-namespace clash the earlier-scanned
-- resolution is kept; the duplicate is reported separately by 'reportTopLevelDuplicates'.
mergeExportedSymbol :: ExportedSymbol -> ExportedSymbol -> ExportedSymbol
mergeExportedSymbol newer older =
  ExportedSymbol {variable = older.variable <|> newer.variable, typeLevel = older.typeLevel <|> newer.typeLevel}

---------------------------------------------------------------------------------------------------
-- Entry point
---------------------------------------------------------------------------------------------------

-- | Resolve every name reference in a parsed module against the names in scope, producing the
-- identified module (AST + symbol table) and the diagnostics emitted along the way.
identifyModule :: ImportContext -> ModuleName -> Module Parsed -> (IdentifiedModule, Diagnostics)
identifyModule importContext moduleName parsedModule =
  runIdentifier environment (resolveModule parsedModule)
  where
    environment =
      IdentifierEnvironment
        { moduleName = moduleName,
          moduleInterfaces = importContext.moduleInterfaces,
          -- The default-import qualifiers form the base scope; own and imported names extend it downward.
          scope = defaultImportScope importContext,
          stateVariables = Map.empty
        }

-- | Assemble the top-level scope (own declarations and imports over the default-import base), report
-- duplicate top-level names, then resolve every declaration under it. Own and imported names are
-- recorded as symbols visible over the whole module; the default-import base is not recorded (it has no
-- import statement to navigate to — see 'defaultImportScope').
resolveModule :: Module Parsed -> Identifier IdentifiedModule
resolveModule parsedModule = do
  moduleName <- currentModuleName
  importBindings <- resolveImports parsedModule.declarations
  let ownBindingGroups = declarationBindings moduleName <$> parsedModule.declarations
      ownBindings = concat ownBindingGroups
  reportTopLevelDuplicates ownBindingGroups
  bindInScope parsedModule.sourceSpan (importBindings <> ownBindings) $ do
    declarations <- traverse resolveDeclaration parsedModule.declarations
    symbols <- currentSymbols
    pure
      IdentifiedModule
        { identifiedAst = Module {declarations = declarations, sourceSpan = parsedModule.sourceSpan},
          symbolTable = SymbolTable {symbols = symbols}
        }

-- | The base scope every module is identified under: each default-import root and its @root.@-prefixed
-- descendants (by 'Katari.Data.ModuleName.covers') brought in as a module qualifier keyed by its last
-- segment — so a default import of @primitive@ makes @primitive.add@ resolvable and @primitive.array@
-- reachable as the qualifier @array@. Nothing is opened unqualified; every reference goes through a
-- qualifier (operators desugar to qualified @primitive.*@ calls, see "Katari.Identifier.Expression").
--
-- Keying by last segment would collide if two covered modules shared one, but the covered set is the
-- wired-in stdlib — compiler-controlled and kept collision-free by "Katari.StdlibSpec" (a user module
-- cannot enter a reserved namespace), so the fold order is immaterial. The module's own and imported
-- names shadow this base. These qualifiers carry no navigable source, so they are the module's base
-- scope (installed in 'identifyModule') rather than recorded symbols.
defaultImportScope :: ImportContext -> Scope
defaultImportScope importContext = foldl' qualify emptyScope coveredModules
  where
    coveredModules = filter covered (Map.keys importContext.moduleInterfaces)
    covered moduleName = any (`covers` moduleName) importContext.defaultImports
    qualify scope moduleName = insertResolution (lastSegment moduleName) (SymbolModule moduleName) scope

---------------------------------------------------------------------------------------------------
-- Imports
---------------------------------------------------------------------------------------------------

-- | Resolve every import declaration into the bindings it contributes (later imports win on a name
-- clash, as 'bindInScope' inserts them in order). Reports K2005 (unknown module) / K2006 (unknown /
-- wrong-namespace name).
resolveImports :: List (Declaration Parsed) -> Identifier (List Binding)
resolveImports declarations = concat <$> traverse resolveImport [importDeclaration | DeclarationImport importDeclaration <- declarations]

resolveImport :: ImportDeclaration -> Identifier (List Binding)
resolveImport importDeclaration = case importDeclaration.kind of
  ImportModule moduleImport -> resolveModuleImport importDeclaration.sourceSpan moduleImport
  ImportNames namesImport -> resolveNamesImport importDeclaration.sourceSpan namesImport

resolveModuleImport :: SourceSpan -> ModuleImport -> Identifier (List Binding)
resolveModuleImport sourceSpan moduleImport = do
  interface <- lookupModuleInterface moduleImport.moduleName
  case interface of
    Nothing -> reportUnknownImportModule sourceSpan moduleImport.moduleName >> pure []
    Just _ ->
      let qualifier = fromMaybe (lastSegment moduleImport.moduleName) moduleImport.alias
       in pure [moduleBinding qualifier sourceSpan moduleImport.moduleName]

resolveNamesImport :: SourceSpan -> NamesImport -> Identifier (List Binding)
resolveNamesImport sourceSpan namesImport = do
  interface <- lookupModuleInterface namesImport.moduleName
  case interface of
    Nothing -> reportUnknownImportModule sourceSpan namesImport.moduleName >> pure []
    Just moduleInterface -> concat <$> traverse (addImportItem namesImport.moduleName moduleInterface) namesImport.items

-- | Resolve one imported name into the binding it adds (def span = the import item itself). Reports
-- K2006 when the module does not export it in the requested namespace.
addImportItem :: ModuleName -> ModuleInterface -> ImportItem -> Identifier (List Binding)
addImportItem moduleName moduleInterface item =
  case Map.lookup item.name moduleInterface.exports of
    Nothing -> unknown
    Just symbol -> case item.kind of
      ImportItemValue -> maybe unknown (\resolution -> pure [variableBinding item.name item.sourceSpan resolution]) symbol.variable
      ImportItemType -> maybe unknown (\resolution -> pure [typeBinding item.name item.sourceSpan resolution]) symbol.typeLevel
  where
    unknown = reportUnknownImportName item.sourceSpan moduleName item.name >> pure []

---------------------------------------------------------------------------------------------------
-- Duplicate top-level names
---------------------------------------------------------------------------------------------------

-- | Report K2003 once per declaration that re-introduces a name in a namespace it already occupies.
-- Each group is one declaration's bindings (the same 'declarationBindings' the scope uses), keyed by
-- name and namespace: a value and a type may share a name, but a request / data redeclared clashes in
-- both namespaces yet is reported once. Imports and ambient names may be shadowed silently.
reportTopLevelDuplicates :: List (List Binding) -> Identifier ()
reportTopLevelDuplicates = go Set.empty
  where
    go :: Set (Text, Namespace) -> List (List Binding) -> Identifier ()
    go seen groups = case groups of
      [] -> pure ()
      group : rest -> do
        let keys = bindingKey <$> group
        when (any (`Set.member` seen) keys) (reportGroupDuplicate group)
        go (foldr Set.insert seen keys) rest

    reportGroupDuplicate group = case group of
      [] -> pure ()
      binding : _ -> reportDuplicateName binding.definitionSpan binding.name

-- | The namespace a top-level binding occupies, for duplicate detection.
data Namespace = NamespaceVariable | NamespaceType | NamespaceModule
  deriving stock (Eq, Ord)

bindingKey :: Binding -> (Text, Namespace)
bindingKey binding = (binding.name, namespaceOf binding.resolution)
  where
    namespaceOf = \case
      SymbolVariable _ -> NamespaceVariable
      SymbolType _ -> NamespaceType
      SymbolModule _ -> NamespaceModule

---------------------------------------------------------------------------------------------------
-- Declarations
---------------------------------------------------------------------------------------------------

resolveDeclaration :: Declaration Parsed -> Identifier (Declaration Identified)
resolveDeclaration = \case
  DeclarationAgent declaration -> do
    ownResolution <- ownVariableResolution declaration.name
    DeclarationAgent <$> resolveAgentDeclaration ownResolution declaration
  DeclarationRequest declaration -> DeclarationRequest <$> resolveRequestDeclaration declaration
  DeclarationExternalAgent declaration -> DeclarationExternalAgent <$> resolveExternalAgentDeclaration declaration
  DeclarationPrimitiveAgent declaration -> DeclarationPrimitiveAgent <$> resolvePrimitiveAgentDeclaration declaration
  DeclarationData declaration -> DeclarationData <$> resolveDataDeclaration declaration
  DeclarationTypeSynonym declaration -> DeclarationTypeSynonym <$> resolveTypeSynonymDeclaration declaration
  DeclarationImport declaration -> pure (DeclarationImport declaration)
  DeclarationError sourceSpan -> pure (DeclarationError sourceSpan)

-- | The defining occurrence of a top-level declaration's own name resolves to its qualified name.
ownVariableReference :: Reference Parsed VariableReference -> Text -> Identifier (Reference Identified VariableReference)
ownVariableReference reference name = do
  resolution <- ownVariableResolution name
  pure (identifiedReference reference.sourceSpan (Just resolution))

ownTypeReference :: Reference Parsed TypeReference -> Text -> Identifier (Reference Identified TypeReference)
ownTypeReference reference name = do
  resolution <- ownTypeResolution name
  pure (identifiedReference reference.sourceSpan (Just resolution))

-- | The shared envelope of a signature declaration (request / external / primitive / data): open the
-- generic parameters over the declaration, resolve the parameter signatures and the own name, then
-- hand them to the continuation that assembles the specific declaration record.
withSignatureParts ::
  SourceSpan ->
  List (GenericParameter Parsed) ->
  List (ParameterSignature Parsed) ->
  Reference Parsed VariableReference ->
  Text ->
  (List (GenericParameter Identified) -> List (ParameterSignature Identified) -> Reference Identified VariableReference -> Identifier result) ->
  Identifier result
withSignatureParts declarationSpan genericParameters parameters variableReferenceNode name continuation =
  withGenericParameters declarationSpan genericParameters $ \identifiedGenerics -> do
    identifiedParameters <- traverse resolveParameterSignature parameters
    variableReference <- ownVariableReference variableReferenceNode name
    continuation identifiedGenerics identifiedParameters variableReference

resolveRequestDeclaration :: RequestDeclaration Parsed -> Identifier (RequestDeclaration Identified)
resolveRequestDeclaration declaration =
  withSignatureParts declaration.sourceSpan declaration.genericParameters declaration.parameters declaration.variableReference declaration.name $ \genericParameters parameters variableReference -> do
    returnType <- resolveType declaration.returnType
    typeReference <- ownTypeReference declaration.typeReference declaration.name
    pure
      RequestDeclaration
        { annotation = declaration.annotation,
          name = declaration.name,
          variableReference = variableReference,
          typeReference = typeReference,
          genericParameters = genericParameters,
          parameters = parameters,
          returnType = returnType,
          sourceSpan = declaration.sourceSpan
        }

resolveExternalAgentDeclaration :: ExternalAgentDeclaration Parsed -> Identifier (ExternalAgentDeclaration Identified)
resolveExternalAgentDeclaration declaration =
  withSignatureParts declaration.sourceSpan declaration.genericParameters declaration.parameters declaration.variableReference declaration.name $ \genericParameters parameters variableReference -> do
    returnType <- resolveType declaration.returnType
    effects <- traverse resolveType declaration.effects
    pure
      ExternalAgentDeclaration
        { annotation = declaration.annotation,
          name = declaration.name,
          variableReference = variableReference,
          genericParameters = genericParameters,
          parameters = parameters,
          returnType = returnType,
          effects = effects,
          sourceSpan = declaration.sourceSpan
        }

resolvePrimitiveAgentDeclaration :: PrimitiveAgentDeclaration Parsed -> Identifier (PrimitiveAgentDeclaration Identified)
resolvePrimitiveAgentDeclaration declaration =
  withSignatureParts declaration.sourceSpan declaration.genericParameters declaration.parameters declaration.variableReference declaration.name $ \genericParameters parameters variableReference -> do
    returnType <- resolveType declaration.returnType
    effects <- traverse resolveType declaration.effects
    pure
      PrimitiveAgentDeclaration
        { annotation = declaration.annotation,
          name = declaration.name,
          variableReference = variableReference,
          genericParameters = genericParameters,
          parameters = parameters,
          returnType = returnType,
          effects = effects,
          sourceSpan = declaration.sourceSpan
        }

resolveDataDeclaration :: DataDeclaration Parsed -> Identifier (DataDeclaration Identified)
resolveDataDeclaration declaration =
  withSignatureParts declaration.sourceSpan declaration.genericParameters declaration.parameters declaration.variableReference declaration.name $ \genericParameters parameters variableReference -> do
    typeReference <- ownTypeReference declaration.typeReference declaration.name
    pure
      DataDeclaration
        { annotation = declaration.annotation,
          name = declaration.name,
          variableReference = variableReference,
          typeReference = typeReference,
          genericParameters = genericParameters,
          parameters = parameters,
          sourceSpan = declaration.sourceSpan
        }

resolveTypeSynonymDeclaration :: TypeSynonymDeclaration Parsed -> Identifier (TypeSynonymDeclaration Identified)
resolveTypeSynonymDeclaration declaration =
  withGenericParameters declaration.sourceSpan declaration.genericParameters $ \genericParameters -> do
    definition <- resolveType declaration.definition
    typeReference <- ownTypeReference declaration.typeReference declaration.name
    pure
      TypeSynonymDeclaration
        { name = declaration.name,
          typeReference = typeReference,
          genericParameters = genericParameters,
          definition = definition,
          sourceSpan = declaration.sourceSpan
        }
