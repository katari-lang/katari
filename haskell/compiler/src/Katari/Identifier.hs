-- | The Identifier pass resolves every name reference in a 'Parsed' module against the names in
-- scope, producing an 'Identified' module (each reference carries a @Just@ resolution, or @Nothing@
-- when it could not be resolved). This module is the entry point and the top-level orchestration:
-- the export scan, import resolution, the top-level scope it assembles, and the declaration dispatch.
-- Expressions / statements / types / patterns are resolved in the @Katari.Identifier.*@ submodules,
-- over the monad in "Katari.Identifier.Monad".
--
-- Resolution is per-module and order-independent at the top level: 'scanExports' yields every
-- module's interface up front, so 'identifyModule' resolves bodies against a fixed import context and
-- tolerates import cycles. Within a module, all top-level names are in scope everywhere (mutual
-- recursion); a name re-introduced in a namespace it already occupies is reported (K2003), but a
-- value and a type may share a name (distinct namespaces). Type-synonym cycles are left for the
-- checker.
module Katari.Identifier where

import Control.Applicative ((<|>))
import Control.Monad (when)
import Data.Map qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.SourceSpan (SourceSpan)
import Katari.Diagnostics (Diagnostics)
import Katari.Identifier.Expression (resolveAgentDeclaration)
import Katari.Identifier.Monad
import Katari.Identifier.Type (resolveParameterSignature, resolveType, withGenericParameters)

---------------------------------------------------------------------------------------------------
-- Export scan
---------------------------------------------------------------------------------------------------

-- | Project a parsed module's public surface. Import-independent and side-effect-free: a name is
-- exported by virtue of being a top-level declaration, so neither imports nor bodies are consulted.
-- Built from the same 'declarationBindings' the module's own top-level scope is, so the interface and
-- the in-module resolution never disagree. Names are merged per namespace ('mergeExportedSymbol'), so
-- a value and a type that share a name both survive.
scanExports :: ModuleName -> Module Parsed -> ModuleInterface
scanExports moduleName parsedModule =
  ModuleInterface {exports = Map.fromListWith mergeExportedSymbol [(binding.name, exportedSymbolOf binding) | binding <- concatMap (declarationBindings moduleName) parsedModule.declarations]}

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
  runIdentifier environment (resolveModule importContext parsedModule)
  where
    environment =
      IdentifierEnvironment
        { moduleName = moduleName,
          moduleInterfaces = importContext.moduleInterfaces,
          scope = emptyScope,
          stateVariables = Map.empty
        }

-- | Assemble the top-level scope (own declarations and imports over the ambient names), report
-- duplicate top-level names, then resolve every declaration under it. The own and imported names are
-- recorded as symbols visible over the whole module; the ambient names are in scope for resolution
-- but not recorded (they have no source to navigate to).
resolveModule :: ImportContext -> Module Parsed -> Identifier IdentifiedModule
resolveModule importContext parsedModule = do
  moduleName <- currentModuleName
  importBindings <- resolveImports parsedModule.declarations
  let ownBindingGroups = declarationBindings moduleName <$> parsedModule.declarations
      ownBindings = concat ownBindingGroups
  reportTopLevelDuplicates ownBindingGroups
  withScope (ambientToScope importContext) $
    bindInScope parsedModule.sourceSpan (importBindings <> ownBindings) $ do
      declarations <- traverse resolveDeclaration parsedModule.declarations
      symbols <- currentSymbols
      pure
        IdentifiedModule
          { identifiedAst = Module {declarations = declarations, sourceSpan = parsedModule.sourceSpan},
            symbolTable = SymbolTable {symbols = symbols}
          }

ambientToScope :: ImportContext -> Scope
ambientToScope importContext =
  Scope
    { variableBindings = importContext.ambientVariables,
      typeBindings = importContext.ambientTypes,
      moduleBindings = importContext.ambientModules
    }

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

-- | The trailing dot-segment of a module name, used as the qualifier of an unaliased prefix import.
lastSegment :: ModuleName -> Text
lastSegment (ModuleName moduleName) = Text.takeWhileEnd (/= '.') moduleName

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

-- | Report a duplicate (K2003) once per declaration that re-introduces a name in a namespace it
-- already occupies. Driven by the same per-declaration 'declarationBindings' as the scope and the
-- export scan (no separate classification to drift): each group is one declaration's bindings, keyed
-- by name and namespace. A value and a type may share a name (distinct namespaces), so that is not a
-- duplicate; a request / data redeclared (both namespaces) clashes in both but is reported once per
-- declaration, not once per namespace. Imports and ambient names may be shadowed silently.
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
