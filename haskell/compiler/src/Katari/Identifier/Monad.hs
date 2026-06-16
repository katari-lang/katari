-- | The monad the Identifier pass runs in, and its cross-module name-resolution surface.
--
-- A name reference is resolved by looking it up in the 'Scope' (three namespaces: variable, type,
-- module — labels are resolved type-directed by the checker, so have no namespace). The pass reads the
-- scope (extended downward by 'bindInScope'), accumulates 'Diagnostics', and supplies fresh ids. As it
-- binds names it also records a 'Symbol' for each into a flat 'SymbolTable' (the LSP visibility
-- surface); 'bindInScope' extends the scope and records the symbols together so the two never drift.
--
-- Lives apart from the entry module ("Katari.Identifier") so the resolution walk
-- (@Katari.Identifier.*@) can import the monad without an import cycle.
module Katari.Identifier.Monad where

import Control.Monad.RWS.CPS (RWS, evalRWS)
import Control.Monad.RWS.Class (MonadReader, MonadState, MonadWriter, asks, gets, local, modify, state)
import Data.List (find, foldl', sortOn)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (isJust)
import Data.Ord (Down (..))
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.AST (Module, ModuleQualifier (..), Phase (..), Reference (..), ReferenceKind (..), ReferenceResolution)
import Katari.Data.Id (GenericId (..), LocalVariableId (..), TypeResolution (..), VariableResolution (..))
import Katari.Data.ModuleName (ModuleName)
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SourceSpan (Position, SourceSpan (..), spanContains)
import Katari.Diagnostics (Diagnostics, reportAt)
import Katari.Error (CompilerError (..), DuplicateNameErrorInfo (..), IdentifierError (..), NotAModuleErrorInfo (..), UndefinedMemberErrorInfo (..), UndefinedNameErrorInfo (..), UndefinedStateVariableErrorInfo (..), UnknownImportModuleErrorInfo (..), UnknownImportNameErrorInfo (..))

---------------------------------------------------------------------------------------------------
-- Scope (the resolution environment)
---------------------------------------------------------------------------------------------------

-- | The names visible at a point in the source, one map per namespace. Top-level and imported names
-- seed it; local bindings (parameters, generics, @let@) extend it via 'bindInScope'. Internal to
-- resolution — the LSP-facing visibility surface is the 'SymbolTable', not this.
data Scope = Scope
  { variableBindings :: Map Text VariableResolution,
    typeBindings :: Map Text TypeResolution,
    moduleBindings :: Map Text ModuleName
  }
  deriving stock (Eq, Show)

emptyScope :: Scope
emptyScope = Scope {variableBindings = Map.empty, typeBindings = Map.empty, moduleBindings = Map.empty}

---------------------------------------------------------------------------------------------------
-- Cross-module interface
---------------------------------------------------------------------------------------------------

-- | One exported name's resolution surface: the namespaces it populates and what each resolves to.
-- Only what an importer needs — type shapes, generic arity, and variance are derived later by the
-- global env-build pass from the identified declarations.
data ExportedSymbol = ExportedSymbol
  { variable :: Maybe VariableResolution,
    typeLevel :: Maybe TypeResolution
  }
  deriving stock (Eq, Show)

-- | What a module exposes to importers, keyed by exported name. Produced by @scanExports@ from the
-- parsed module alone (import-independent), so every module's interface is available before any
-- module is resolved — letting @identifyModule@ run per-module and tolerate import cycles.
newtype ModuleInterface = ModuleInterface
  { exports :: Map Text ExportedSymbol
  }
  deriving stock (Eq, Show)

-- | The context an @identifyModule@ run resolves against: the interfaces of every importable module
-- and the default-import roots opened into every module. Primitive / stdlib are ordinary modules
-- (present in 'moduleInterfaces' like any other); listing a name in 'defaultImports' brings its root
-- and submodules into scope as module qualifiers (see 'Katari.Identifier.defaultImportScope').
data ImportContext = ImportContext
  { moduleInterfaces :: Map ModuleName ModuleInterface,
    defaultImports :: List ModuleName
  }
  deriving stock (Eq, Show)

---------------------------------------------------------------------------------------------------
-- Symbol table (LSP)
---------------------------------------------------------------------------------------------------

-- | What a 'Symbol' resolves to, tagged by namespace. Mirrors the three resolution kinds the pass
-- produces; the namespace a symbol lives in is implied by the constructor.
data SymbolResolution
  = SymbolVariable VariableResolution
  | SymbolType TypeResolution
  | SymbolModule ModuleName
  deriving stock (Eq, Show)

-- | One binding the pass introduced: its name, the span of its /defining/ occurrence
-- (go-to-definition target), the source region it is visible over ('region'), and what it resolves to.
-- Every occurrence carries the same 'resolution' and looks the rest up here. Synthetic names (no
-- source) are not recorded.
data Symbol = Symbol
  { name :: Text,
    definitionSpan :: SourceSpan,
    region :: SourceSpan,
    resolution :: SymbolResolution
  }
  deriving stock (Eq, Show)

-- | Every binding recorded while resolving a module: the source of LSP visibility, go-to-definition,
-- and find-references.
newtype SymbolTable = SymbolTable
  { symbols :: List Symbol
  }
  deriving stock (Eq, Show)

-- | Insert a name's resolution into the scope map for its namespace. Shared by 'scopeAt' (replaying
-- the symbol table) and 'extendScope' (extending the live resolution scope) so the two never disagree
-- on how a resolution lands in a 'Scope'.
insertResolution :: Text -> SymbolResolution -> Scope -> Scope
insertResolution name resolution scope = case resolution of
  SymbolVariable target -> scope {variableBindings = Map.insert name target scope.variableBindings}
  SymbolType target -> scope {typeBindings = Map.insert name target scope.typeBindings}
  SymbolModule target -> scope {moduleBindings = Map.insert name target scope.moduleBindings}

-- | The names visible at @position@: every symbol whose 'region' contains it, assembled into a
-- 'Scope'. Inner bindings shadow outer ones — symbols are installed outermost-first (widest region
-- first), so a tighter region's binding overwrites the one it shadows.
scopeAt :: SymbolTable -> Position -> Scope
scopeAt table position = foldl' install emptyScope ordered
  where
    visible = filter (\symbol -> spanContains symbol.region position) table.symbols
    ordered = sortOn (\symbol -> (symbol.region.start, Down symbol.region.end)) visible
    install scope symbol = insertResolution symbol.name symbol.resolution scope

-- | Where the binding behind a resolution is defined (go-to-definition). 'Nothing' for a resolution
-- with no recorded binding in this module (a cross-module or synthetic name — resolve it through the
-- defining module's table instead).
definitionSpanOf :: SymbolTable -> SymbolResolution -> Maybe SourceSpan
definitionSpanOf table resolution =
  (.definitionSpan) <$> find (\symbol -> symbol.resolution == resolution) table.symbols

---------------------------------------------------------------------------------------------------
-- Identifier output
---------------------------------------------------------------------------------------------------

-- | The product of resolving one module: the identified AST (every reference carries its resolution)
-- and the symbol table for LSP. Cross-module data is recovered elsewhere (the 'ModuleInterface' from
-- @scanExports@), so it is not duplicated here.
data IdentifiedModule = IdentifiedModule
  { identifiedAst :: Module Identified,
    symbolTable :: SymbolTable
  }
  deriving stock (Eq, Show)

---------------------------------------------------------------------------------------------------
-- Monad
---------------------------------------------------------------------------------------------------

-- | Read-only context of the pass: the module being identified (to qualify its own declarations),
-- the interfaces it resolves @module.member@ references against, the names currently in scope, and
-- the enclosing @for@ / @handler@ state variables (the only names a @with@ modifier may target).
data IdentifierEnvironment = IdentifierEnvironment
  { moduleName :: ModuleName,
    moduleInterfaces :: Map ModuleName ModuleInterface,
    scope :: Scope,
    stateVariables :: Map Text VariableResolution
  }

-- | The fresh-id supply (counters only ever increase) plus the symbols recorded for the LSP table,
-- threaded as state across the whole pass.
data IdentifierState = IdentifierState
  { nextGenericId :: Int,
    nextLocalVariableId :: Int,
    recordedSymbols :: List Symbol
  }

initialIdentifierState :: IdentifierState
initialIdentifierState = IdentifierState {nextGenericId = 0, nextLocalVariableId = 0, recordedSymbols = []}

-- | The Identifier monad: read the scope, accumulate diagnostics, supply fresh ids. A plain RWS
-- alias (like the Normalizer); emission, supply, and scope are free functions over the mtl classes.
type Identifier a = RWS IdentifierEnvironment Diagnostics IdentifierState a

runIdentifier :: IdentifierEnvironment -> Identifier a -> (a, Diagnostics)
runIdentifier environment action = evalRWS action environment initialIdentifierState

-- Fresh-id supply ---------------------------------------------------------------------------------

-- | A fresh generic id, stamped with the module currently being identified so the id is globally
-- unique despite the per-module counter (see 'Katari.Data.Id.GenericId').
freshGenericId :: (MonadReader IdentifierEnvironment m, MonadState IdentifierState m) => m GenericId
freshGenericId = do
  moduleName <- currentModuleName
  state (\current -> (GenericId moduleName current.nextGenericId, current {nextGenericId = current.nextGenericId + 1}))

freshLocalVariableId :: (MonadState IdentifierState m) => m LocalVariableId
freshLocalVariableId = state (\current -> (LocalVariableId current.nextLocalVariableId, current {nextLocalVariableId = current.nextLocalVariableId + 1}))

-- Environment access ------------------------------------------------------------------------------

currentModuleName :: (MonadReader IdentifierEnvironment m) => m ModuleName
currentModuleName = asks (.moduleName)

lookupModuleInterface :: (MonadReader IdentifierEnvironment m) => ModuleName -> m (Maybe ModuleInterface)
lookupModuleInterface name = asks (\environment -> Map.lookup name environment.moduleInterfaces)

-- | The variable resolution a top-level name carries: its module-qualified name. Shared by the
-- export scan and the defining-occurrence resolution so the two never disagree.
qualifiedVariableResolution :: ModuleName -> Text -> VariableResolution
qualifiedVariableResolution moduleName name = VariableResolutionQualifiedName QualifiedName {moduleName = moduleName, name = name}

-- | The type resolution a top-level name carries: its module-qualified name.
qualifiedTypeResolution :: ModuleName -> Text -> TypeResolution
qualifiedTypeResolution moduleName name = TypeResolutionQualifiedName QualifiedName {moduleName = moduleName, name = name}

-- | A reference to one of this module's own top-level declarations, as a value.
ownVariableResolution :: (MonadReader IdentifierEnvironment m) => Text -> m VariableResolution
ownVariableResolution name = do
  moduleName <- currentModuleName
  pure (qualifiedVariableResolution moduleName name)

-- | A reference to one of this module's own top-level declarations, as a type.
ownTypeResolution :: (MonadReader IdentifierEnvironment m) => Text -> m TypeResolution
ownTypeResolution name = do
  moduleName <- currentModuleName
  pure (qualifiedTypeResolution moduleName name)

-- Scope lookup ------------------------------------------------------------------------------------

lookupVariable :: (MonadReader IdentifierEnvironment m) => Text -> m (Maybe VariableResolution)
lookupVariable name = asks (\environment -> Map.lookup name environment.scope.variableBindings)

lookupType :: (MonadReader IdentifierEnvironment m) => Text -> m (Maybe TypeResolution)
lookupType name = asks (\environment -> Map.lookup name environment.scope.typeBindings)

lookupModule :: (MonadReader IdentifierEnvironment m) => Text -> m (Maybe ModuleName)
lookupModule name = asks (\environment -> Map.lookup name environment.scope.moduleBindings)

-- | The enclosing @for@ / @handler@ state variable a @with@ modifier name targets, if any.
lookupStateVariable :: (MonadReader IdentifierEnvironment m) => Text -> m (Maybe VariableResolution)
lookupStateVariable name = asks (\environment -> Map.lookup name environment.stateVariables)

-- Scope extension ---------------------------------------------------------------------------------

-- | Run an action with the scope replaced (used to install the ambient / top-level base scope).
withScope :: (MonadReader IdentifierEnvironment m) => Scope -> m a -> m a
withScope scope = local (\environment -> environment {scope = scope})

-- | Run an action with the enclosing state variables replaced — the @var@ state of the @for@ /
-- @handler@ whose body the action resolves. Each loop / handler owns its own state, so this replaces
-- rather than extends.
withStateVariables :: (MonadReader IdentifierEnvironment m) => Map Text VariableResolution -> m a -> m a
withStateVariables states = local (\environment -> environment {stateVariables = states})

-- | A name the walk brings into scope: its text, the span of its defining occurrence, and what it
-- resolves to. The scope region (the same for every name bound together) is supplied by 'bindInScope'.
data Binding = Binding
  { name :: Text,
    definitionSpan :: SourceSpan,
    resolution :: SymbolResolution
  }

variableBinding :: Text -> SourceSpan -> VariableResolution -> Binding
variableBinding name definitionSpan target = Binding {name = name, definitionSpan = definitionSpan, resolution = SymbolVariable target}

typeBinding :: Text -> SourceSpan -> TypeResolution -> Binding
typeBinding name definitionSpan target = Binding {name = name, definitionSpan = definitionSpan, resolution = SymbolType target}

moduleBinding :: Text -> SourceSpan -> ModuleName -> Binding
moduleBinding name definitionSpan target = Binding {name = name, definitionSpan = definitionSpan, resolution = SymbolModule target}

-- | Bring @bindings@ into scope over @region@: record a 'Symbol' for each (visible over @region@) and
-- extend the resolution scope, then run the action. Recording and scoping happen together so the LSP
-- table and the resolution scope can never drift apart.
bindInScope :: SourceSpan -> List Binding -> Identifier a -> Identifier a
bindInScope region bindings action = do
  recordSymbols [Symbol {name = binding.name, definitionSpan = binding.definitionSpan, region = region, resolution = binding.resolution} | binding <- bindings]
  local (extendScope bindings) action

-- | Extend a scope with bindings (later bindings win on a name clash within the list).
extendScope :: List Binding -> IdentifierEnvironment -> IdentifierEnvironment
extendScope bindings environment = environment {scope = foldl' addBinding environment.scope bindings}
  where
    addBinding scope binding = insertResolution binding.name binding.resolution scope

-- | The variable bindings among @bindings@, as a name map — the @for@ / @handler@ state a @with@
-- modifier may target. Used with 'withStateVariables'.
stateVariableMap :: List Binding -> Map Text VariableResolution
stateVariableMap bindings = Map.fromList [(binding.name, target) | binding <- bindings, SymbolVariable target <- [binding.resolution]]

-- | Resolve each item — each yielding a resolved node and the bindings it introduces — collecting the
-- resolved nodes and concatenating their bindings. The shared shape of the pattern / parameter
-- list resolvers.
resolveAll :: (a -> Identifier (b, List Binding)) -> List a -> Identifier (List b, List Binding)
resolveAll resolve items = fmap concat . unzip <$> traverse resolve items

-- | Append symbols to the table (newest first; 'scopeAt' is order-independent up to shadow ties).
recordSymbols :: List Symbol -> Identifier ()
recordSymbols newSymbols = modify (\current -> current {recordedSymbols = newSymbols <> current.recordedSymbols})

-- | The symbols recorded so far (read after the walk to build the 'SymbolTable').
currentSymbols :: Identifier (List Symbol)
currentSymbols = gets (.recordedSymbols)

---------------------------------------------------------------------------------------------------
-- Reference construction + resolution
---------------------------------------------------------------------------------------------------

-- | Build an 'Identified' reference whose resolution is the @Maybe@ produced by a lookup. The
-- @sourceSpan@ is the occurrence's own span; the binding's definition / scope live in the symbol
-- table, keyed by the resolution.
identifiedReference ::
  (ReferenceResolution Identified nameReferenceKind ~ Maybe resolution) =>
  SourceSpan ->
  Maybe resolution ->
  Reference Identified nameReferenceKind
identifiedReference sourceSpan resolution = Reference {sourceSpan = sourceSpan, resolution = resolution}

-- | Resolve a bare name in one namespace: look it up, report through @reportMissing@ when absent, and
-- build the identified reference (which carries the @Maybe@ resolution either way). The shared shape of
-- the bare variable / type / state-variable resolvers — they differ only in the binding map consulted
-- and the diagnostic an absence raises.
resolveBareReference ::
  (ReferenceResolution Identified nameReferenceKind ~ Maybe resolution) =>
  (Text -> Identifier (Maybe resolution)) ->
  (SourceSpan -> Text -> Identifier ()) ->
  SourceSpan ->
  Text ->
  Identifier (Reference Identified nameReferenceKind)
resolveBareReference lookupName reportMissing sourceSpan name = do
  resolution <- lookupName name
  maybe (reportMissing sourceSpan name) (const (pure ())) resolution
  pure (identifiedReference sourceSpan resolution)

-- | Resolve a bare variable name, reporting K2001 when it is in no variable binding (a module name
-- used as a value lands here too — it is not a value).
resolveVariableReference :: SourceSpan -> Text -> Identifier (Reference Identified VariableReference)
resolveVariableReference = resolveBareReference lookupVariable reportUndefinedName

-- | Resolve a bare (unqualified) type name, reporting K2001 when it is in no type binding. Generic
-- parameters share the type namespace (bound by 'Katari.Identifier.Type.withGenericParameters'), so an
-- in-scope generic resolves through here like any other bare type name.
resolveTypeReference :: SourceSpan -> Text -> Identifier (Reference Identified TypeReference)
resolveTypeReference = resolveBareReference lookupType reportUndefinedName

-- | Resolve a name in the module namespace, reporting K2004 when it is a value / type rather than a
-- module, or K2001 when it is undefined entirely.
resolveModuleName :: SourceSpan -> Text -> Identifier (Maybe ModuleName)
resolveModuleName sourceSpan name = do
  resolution <- lookupModule name
  case resolution of
    Just _ -> pure ()
    Nothing -> do
      asVariable <- lookupVariable name
      asType <- lookupType name
      if isJust asVariable || isJust asType
        then reportNotAModule sourceSpan name
        else reportUndefinedName sourceSpan name
  pure resolution

-- | Resolve a parsed @module.@ qualifier into its identified form and the module it names.
resolveModuleQualifier :: ModuleQualifier Parsed -> Identifier (ModuleQualifier Identified, Maybe ModuleName)
resolveModuleQualifier qualifier = do
  moduleResolution <- resolveModuleName qualifier.sourceSpan qualifier.name
  pure
    ( ModuleQualifier {name = qualifier.name, moduleReference = identifiedReference qualifier.sourceSpan moduleResolution, sourceSpan = qualifier.sourceSpan},
      moduleResolution
    )

-- | Resolve a member of @moduleName@ in the variable namespace, reporting K2002 when absent.
resolveVariableMember :: SourceSpan -> ModuleName -> Text -> Identifier (Maybe VariableResolution)
resolveVariableMember sourceSpan moduleName name = do
  interface <- lookupModuleInterface moduleName
  reportMember sourceSpan moduleName name (interface >>= memberVariable name)

-- | Resolve a member of @moduleName@ in the type namespace, reporting K2002 when absent.
resolveTypeMember :: SourceSpan -> ModuleName -> Text -> Identifier (Maybe TypeResolution)
resolveTypeMember sourceSpan moduleName name = do
  interface <- lookupModuleInterface moduleName
  reportMember sourceSpan moduleName name (interface >>= memberType name)

memberVariable :: Text -> ModuleInterface -> Maybe VariableResolution
memberVariable name moduleInterface = Map.lookup name moduleInterface.exports >>= (.variable)

memberType :: Text -> ModuleInterface -> Maybe TypeResolution
memberType name moduleInterface = Map.lookup name moduleInterface.exports >>= (.typeLevel)

reportMember :: SourceSpan -> ModuleName -> Text -> Maybe resolution -> Identifier (Maybe resolution)
reportMember sourceSpan moduleName name = \case
  Just resolution -> pure (Just resolution)
  Nothing -> reportUndefinedMember sourceSpan moduleName name >> pure Nothing

-- | Resolve a (possibly @module.@-qualified) name reference in one namespace, returning the identified
-- qualifier (if any) and the resolved reference. A bare name goes through @resolveBare@ (K2001 if
-- undefined); @module.name@ resolves the qualifier in the module namespace (K2004 / K2001) then the
-- member through that module's interface via @resolveMember@ (K2002 if absent). Shared by the
-- type-name, constructor, and request-handler resolvers so the three never disagree on qualified/bare
-- handling.
resolveQualifiedReference ::
  (ReferenceResolution Identified nameReferenceKind ~ Maybe resolution) =>
  (SourceSpan -> Text -> Identifier (Reference Identified nameReferenceKind)) ->
  (SourceSpan -> ModuleName -> Text -> Identifier (Maybe resolution)) ->
  Maybe (ModuleQualifier Parsed) ->
  Text ->
  Reference Parsed nameReferenceKind ->
  Identifier (Maybe (ModuleQualifier Identified), Reference Identified nameReferenceKind)
resolveQualifiedReference resolveBare resolveMember moduleQualifier name reference = case moduleQualifier of
  Nothing -> do
    resolved <- resolveBare reference.sourceSpan name
    pure (Nothing, resolved)
  Just qualifier -> do
    (identifiedQualifier, moduleResolution) <- resolveModuleQualifier qualifier
    memberResolution <- maybe (pure Nothing) (\moduleName -> resolveMember reference.sourceSpan moduleName name) moduleResolution
    pure (Just identifiedQualifier, identifiedReference reference.sourceSpan memberResolution)

-- | Resolve a @with@ modifier target: it must name an enclosing @for@ / @handler@ state variable, not
-- an arbitrary in-scope local. Reports K2007 otherwise.
resolveStateVariableReference :: SourceSpan -> Text -> Identifier (Reference Identified VariableReference)
resolveStateVariableReference = resolveBareReference lookupStateVariable reportUndefinedStateVariable

-- Diagnostics -------------------------------------------------------------------------------------

-- | Emit an Identifier-phase diagnostic at a span — the 'CompilerErrorIdentifier' wrapper every
-- reporter below shares.
reportIdentifierError :: (MonadWriter Diagnostics m) => SourceSpan -> IdentifierError -> m ()
reportIdentifierError sourceSpan = reportAt sourceSpan . CompilerErrorIdentifier

reportUndefinedName :: (MonadWriter Diagnostics m) => SourceSpan -> Text -> m ()
reportUndefinedName sourceSpan name = reportIdentifierError sourceSpan (IdentifierErrorUndefinedName UndefinedNameErrorInfo {name = name})

reportUndefinedMember :: (MonadWriter Diagnostics m) => SourceSpan -> ModuleName -> Text -> m ()
reportUndefinedMember sourceSpan moduleName name = reportIdentifierError sourceSpan (IdentifierErrorUndefinedMember UndefinedMemberErrorInfo {moduleName = moduleName, name = name})

reportDuplicateName :: (MonadWriter Diagnostics m) => SourceSpan -> Text -> m ()
reportDuplicateName sourceSpan name = reportIdentifierError sourceSpan (IdentifierErrorDuplicateName DuplicateNameErrorInfo {name = name})

reportNotAModule :: (MonadWriter Diagnostics m) => SourceSpan -> Text -> m ()
reportNotAModule sourceSpan name = reportIdentifierError sourceSpan (IdentifierErrorNotAModule NotAModuleErrorInfo {name = name})

reportUnknownImportModule :: (MonadWriter Diagnostics m) => SourceSpan -> ModuleName -> m ()
reportUnknownImportModule sourceSpan moduleName = reportIdentifierError sourceSpan (IdentifierErrorUnknownImportModule UnknownImportModuleErrorInfo {moduleName = moduleName})

reportUnknownImportName :: (MonadWriter Diagnostics m) => SourceSpan -> ModuleName -> Text -> m ()
reportUnknownImportName sourceSpan moduleName name = reportIdentifierError sourceSpan (IdentifierErrorUnknownImportName UnknownImportNameErrorInfo {moduleName = moduleName, name = name})

reportUndefinedStateVariable :: (MonadWriter Diagnostics m) => SourceSpan -> Text -> m ()
reportUndefinedStateVariable sourceSpan name = reportIdentifierError sourceSpan (IdentifierErrorUndefinedStateVariable UndefinedStateVariableErrorInfo {name = name})
