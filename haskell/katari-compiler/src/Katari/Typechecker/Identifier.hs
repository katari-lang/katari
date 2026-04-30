-- | Typechecker phase 1 (Identifier pass).
--
-- Takes a Parsed AST and returns an @Identified@ AST in which every 'NameRef'
-- (except labels) carries a unique id. Name conflicts, undefined references
-- and shadowing violations are also detected here.
--
-- Namespace model: each name in a scope frame occupies up to three slots
-- (variable / type / module). Slot collisions and variable+module coexistence
-- are forbidden — variable+module is rejected because it would silently flip
-- the meaning of @name.foo@ between field access and qualified module access.
--
-- Resolution of @list.foo@: variable wins (field access; the label is left for
-- the typechecker), otherwise module wins (qualified reference; @foo@ is
-- looked up in @moduleExports@'s @variableSymbol@). If neither hits, undefined.
-- Types do not appear on the left of @.@ in expression position.
--
-- A @data ctor(...)@ declaration registers the same name in both the
-- @variableSymbol@ slot (the constructor function) and the @typeSymbol@ slot
-- (the data type). Bare references therefore hit the variable; the type slot
-- is consulted only in type-annotation positions.
module Katari.Typechecker.Identifier
  ( -- * Types
    VariableId (..),
    TypeId (..),
    ModuleId (..),
    RequestId (..),
    ConstructorId (..),
    QualifiedName (..),
    renderQualifiedName,
    SymbolEntry (..),
    ModuleData (..),
    VariableData (..),
    TypeData (..),
    RequestData (..),
    ConstructorData (..),
    IdentifierResult (..),
    IdentifierError (..),

    -- * Diagnostics
    toDiagnostic,

    -- * Entry point
    identify,
  )
where

import Control.Monad (foldM, when)
import Control.Monad.State.Strict (State, get, gets, modify, put, runState)
import Data.Foldable (foldl')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Katari.AST
import Katari.AST.Identifiers
  ( ConstructorId (..),
    ModuleId (..),
    QualifiedName (..),
    RequestId (..),
    TypeId (..),
    VariableId (..),
    renderQualifiedName,
  )
import Katari.Diagnostic (Diagnostic (..), DiagnosticNote (..), diagnosticError)

-- ---------------------------------------------------------------------------
-- Identified GADT
--
-- Stable identifier types ('VariableId' / 'TypeId' / 'ModuleId') live in
-- 'Katari.AST.Identifiers' so that 'Katari.AST' and
-- 'Katari.Typechecker.SemanticType' can both depend on them without circular
-- imports. They are re-exported below for backward compatibility with
-- existing call sites.
-- ---------------------------------------------------------------------------

-- | Metadata carried by the AST after the Identifier pass.
--
-- For each 'NameRef' the @symbol@ kind determines what id (if any) is attached.
-- Expression / Pattern carry no information at this phase (they are filled in
-- by the Typechecker later).
--
-- An @Unresolved@ variant is provided per name-bearing symbol kind so that a
-- failed name resolution does not invent a sentinel id: the corresponding error
-- is recorded in 'IdentifierState.errors', and the AST node carries the
-- @Unresolved@ marker so downstream phases can recognize it.
-- The 'Identified' phase carries 'NameMeta Identified s' for name
-- resolution, defined as a closed type family in 'Katari.AST'. Each
-- 'NameRef' simply stores @Maybe Identifier@ (or @()@ for labels) in its
-- @resolution@ field; the Identifier-pass produces @Just _@ on success
-- and @Nothing@ when the name is not in scope (an error is also recorded
-- via 'IdentifierError').

-- ---------------------------------------------------------------------------
-- Top-level scope: SymbolEntry (3 slots per name)
-- ---------------------------------------------------------------------------

-- | The slots a single name may simultaneously occupy. Invariants:
--
--   * A second registration into the same slot for the same name is an
--     'ErrorDuplicateName'.
--   * variable + module coexistence is forbidden (it would silently change the
--     meaning of @name.foo@ from qualified module access to field access).
--   * Other combinations are allowed: a @data Foo()@ declaration occupies
--     three slots simultaneously (variable / type / constructor).
--
-- The @requestSymbol@ slot is populated by @req@ declarations alongside their
-- @variableSymbol@. The @constructorSymbol@ slot is populated by @data@
-- declarations alongside their @variableSymbol@ and @typeSymbol@. These extra
-- slots let the Identifier pass dispatch resolution by reference kind:
-- @match@ patterns look up @constructorSymbol@; @req@ handlers look up
-- @requestSymbol@; both reject names that resolve only to a regular
-- @variableSymbol@.
data SymbolEntry = SymbolEntry
  { variableSymbol :: Maybe VariableId,
    typeSymbol :: Maybe TypeId,
    moduleSymbol :: Maybe ModuleId,
    requestSymbol :: Maybe RequestId,
    constructorSymbol :: Maybe ConstructorId
  }
  deriving (Eq, Show)

emptySymbolEntry :: SymbolEntry
emptySymbolEntry =
  SymbolEntry
    { variableSymbol = Nothing,
      typeSymbol = Nothing,
      moduleSymbol = Nothing,
      requestSymbol = Nothing,
      constructorSymbol = Nothing
    }

singletonVariable :: VariableId -> SymbolEntry
singletonVariable variableId = emptySymbolEntry {variableSymbol = Just variableId}

singletonType :: TypeId -> SymbolEntry
singletonType typeId = emptySymbolEntry {typeSymbol = Just typeId}

singletonModule :: ModuleId -> SymbolEntry
singletonModule moduleId = emptySymbolEntry {moduleSymbol = Just moduleId}

-- ---------------------------------------------------------------------------
-- Result tables
-- ---------------------------------------------------------------------------

data ModuleData = ModuleData
  { moduleName :: Text,
    moduleSourceSpan :: SourceSpan
  }
  deriving (Eq, Show)

-- | A 'VariableId' covers both top-level callables (agent / req / ext / ctor's
-- value side) and local variables (let / pattern bind / param). Top-level
-- bindings carry @Just@ a 'QualifiedName'; locals carry @Nothing@.
data VariableData = VariableData
  { variableName :: Text,
    variableQualifiedName :: Maybe QualifiedName,
    variableSourceSpan :: SourceSpan
  }
  deriving (Eq, Show)

-- | A 'TypeId' is always issued for a top-level declaration (data / type
-- synonym), so the qualified name is always present.
data TypeData = TypeData
  { typeQualifiedName :: QualifiedName,
    typeSourceSpan :: SourceSpan,
    -- | For type synonyms, the resolved RHS expression. @Nothing@ for
    -- @data@ declarations. Populated in Phase D after the synonym body
    -- has been resolved; the constraint generator's elaboration phase
    -- expands synonyms by looking up this field.
    typeSynonymRhs :: Maybe (SyntacticType Identified)
  }
  deriving (Eq, Show)

-- | A 'RequestId' identifies a @req@ declaration. Always top-level.
-- 'requestVariableId' points back to the call-side 'VariableId' issued for
-- the same declaration so that downstream phases (constraint generator,
-- lowering) can read the request's signature type via the shared type
-- environment without re-resolving by name.
data RequestData = RequestData
  { requestQualifiedName :: QualifiedName,
    requestSourceSpan :: SourceSpan,
    requestVariableId :: VariableId
  }
  deriving (Eq, Show)

-- | A 'ConstructorId' identifies the constructor side of a @data@ declaration.
-- Always top-level. 'constructorTypeId' points back to the corresponding
-- 'TypeId' so that downstream phases can recover the type that this
-- constructor builds without re-walking the AST. 'constructorVariableId'
-- points to the call-side 'VariableId' (the @Foo(...)@ usage), giving access
-- to the constructor function's signature type.
data ConstructorData = ConstructorData
  { constructorQualifiedName :: QualifiedName,
    constructorSourceSpan :: SourceSpan,
    constructorTypeId :: TypeId,
    constructorVariableId :: VariableId
  }
  deriving (Eq, Show)

-- | Result of a successful Identifier pass. The Identified ASTs live in
-- 'moduleASTs' rather than nested inside 'ModuleData' so the State monad never
-- has to hold a placeholder AST that gets overwritten later.
--
-- The reverse maps (@*ByQName@) let downstream phases look up an id by its
-- qualified name without scanning the full forward map. They cover top-level
-- bindings only — local variables are not addressable by qualified name.
data IdentifierResult = IdentifierResult
  { identifiedModules :: Map ModuleId ModuleData,
    identifiedVariables :: Map VariableId VariableData,
    identifiedTypes :: Map TypeId TypeData,
    identifiedRequests :: Map RequestId RequestData,
    identifiedConstructors :: Map ConstructorId ConstructorData,
    moduleASTs :: Map ModuleId (Module Identified),
    -- Reverse maps (qualified name → id) for top-level lookups.
    topLevelVariablesByQName :: Map QualifiedName VariableId,
    typesByQName :: Map QualifiedName TypeId,
    requestsByQName :: Map QualifiedName RequestId,
    constructorsByQName :: Map QualifiedName ConstructorId
  }
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

data IdentifierError where
  -- | A second registration into the same slot for the same name, or
  -- variable + module coexistence.
  ErrorDuplicateName :: SourceSpan -> Text -> SourceSpan -> IdentifierError
  -- | A local definition tried to shadow an outer module binding (only
  -- module shadowing is forbidden under Rust-style local shadowing rules).
  ErrorShadowNonVariable :: SourceSpan -> Text -> IdentifierError
  ErrorUndefinedName :: SourceSpan -> Text -> IdentifierError
  -- | @module.member@ where the member cannot be resolved.
  ErrorUndefinedQualified :: SourceSpan -> Text -> Text -> IdentifierError
  -- | A name appears in a type-annotation position but no @typeSymbol@ slot is
  -- available for it.
  ErrorNotAType :: SourceSpan -> Text -> IdentifierError
  -- | The left-hand side @x@ of @x.y@ is not bound as a module.
  ErrorNotAModule :: SourceSpan -> Text -> IdentifierError
  -- | An item listed in @ImportNames@ does not exist in the source module.
  ErrorImportNameNotFound :: SourceSpan -> Text -> Text -> IdentifierError
  -- | The module referenced by @ImportModule@ / @ImportNames@ does not exist.
  ErrorImportModuleNotFound :: SourceSpan -> Text -> IdentifierError
  -- | A name appears in @req@ handler position but does not name a @req@
  -- declaration (or names nothing at all).
  ErrorNotARequest :: SourceSpan -> Text -> IdentifierError
  -- | A name appears in match-pattern constructor position but does not name
  -- a @data@ declaration (or names nothing at all).
  ErrorNotAConstructor :: SourceSpan -> Text -> IdentifierError

deriving instance Show IdentifierError

deriving instance Eq IdentifierError

instance HasSourceSpan IdentifierError where
  sourceSpanOf = \case
    ErrorDuplicateName sp _ _ -> sp
    ErrorShadowNonVariable sp _ -> sp
    ErrorUndefinedName sp _ -> sp
    ErrorUndefinedQualified sp _ _ -> sp
    ErrorNotAType sp _ -> sp
    ErrorNotAModule sp _ -> sp
    ErrorImportNameNotFound sp _ _ -> sp
    ErrorImportModuleNotFound sp _ -> sp
    ErrorNotARequest sp _ -> sp
    ErrorNotAConstructor sp _ -> sp

-- | Convert an 'IdentifierError' to a unified 'Diagnostic'. Codes
-- K0100-K0199 are reserved for the identifier pass.
toDiagnostic :: IdentifierError -> Diagnostic
toDiagnostic = \case
  ErrorDuplicateName sp name otherSp ->
    let base = diagnosticError "K0100" ("duplicate definition of '" <> name <> "'") sp
     in base
          { notes =
              [ DiagnosticNote
                  { span = otherSp,
                    message = "first defined here"
                  }
              ]
          }
  ErrorShadowNonVariable sp name ->
    diagnosticError
      "K0101"
      ("'" <> name <> "' shadows a non-variable binding (modules/types cannot be shadowed)")
      sp
  ErrorUndefinedName sp name ->
    diagnosticError "K0102" ("undefined name '" <> name <> "'") sp
  ErrorUndefinedQualified sp moduleName memberName ->
    diagnosticError
      "K0103"
      ("module '" <> moduleName <> "' does not export '" <> memberName <> "'")
      sp
  ErrorNotAType sp name ->
    diagnosticError
      "K0104"
      ("'" <> name <> "' is not a type")
      sp
  ErrorNotAModule sp name ->
    diagnosticError
      "K0105"
      ("'" <> name <> "' is not a module")
      sp
  ErrorImportNameNotFound sp moduleName memberName ->
    diagnosticError
      "K0106"
      ("import: '" <> memberName <> "' is not exported by module '" <> moduleName <> "'")
      sp
  ErrorImportModuleNotFound sp moduleName ->
    diagnosticError
      "K0107"
      ("import: module '" <> moduleName <> "' not found")
      sp
  ErrorNotARequest sp name ->
    diagnosticError
      "K0108"
      ("'" <> name <> "' is not a request (only @req@ declarations can be handled)")
      sp
  ErrorNotAConstructor sp name ->
    diagnosticError
      "K0109"
      ("'" <> name <> "' is not a data constructor")
      sp

-- ---------------------------------------------------------------------------
-- Identifier monad
-- ---------------------------------------------------------------------------

-- | Identifier-pass state: counters for the five id namespaces, the
-- materialized id → original-data maps, qualified-name reverse maps, the
-- accumulated error list, and the per-module resolve context (only meaningful
-- during Phase D; populated with a dummy in earlier phases).
data IdentifierState = IdentifierState
  { nextVariableId :: Int,
    nextTypeId :: Int,
    nextModuleId :: Int,
    nextRequestId :: Int,
    nextConstructorId :: Int,
    variables :: Map VariableId VariableData,
    types :: Map TypeId TypeData,
    modules :: Map ModuleId ModuleData,
    requests :: Map RequestId RequestData,
    constructors :: Map ConstructorId ConstructorData,
    -- Reverse maps for top-level qualified-name lookup. Populated as
    -- Phase B walks declarations; surface in 'IdentifierResult'.
    -- Field names use the @*QNames@ suffix to avoid clashing with the
    -- public @*ByQName@ names on 'IdentifierResult'.
    variableQNames :: Map QualifiedName VariableId,
    typeQNames :: Map QualifiedName TypeId,
    requestQNames :: Map QualifiedName RequestId,
    constructorQNames :: Map QualifiedName ConstructorId,
    errors :: [IdentifierError],
    resolveContext :: ResolveContext
  }

-- | Lookup tables required during name resolution. Phase D sets one up for
-- each module and stashes it in 'IdentifierState.resolveContext'.
--
-- Top-level and local bindings live in the same stack: the bottom (last) frame
-- is the module's top-level namespace (own declarations + imports), and each
-- @withScopeFrame@ pushes a new innermost frame. Lookup walks the stack from
-- innermost to outermost. This generalises top-level as just frame 0 and would
-- naturally accommodate locally-scoped imports if added later.
data ResolveContext = ResolveContext
  { scopeStack :: [Map Text SymbolEntry], -- innermost first; last element = top-level
    moduleExports :: Map ModuleId (Map Text SymbolEntry)
  }

emptyResolveContext :: ResolveContext
emptyResolveContext =
  ResolveContext
    { scopeStack = [],
      moduleExports = Map.empty
    }

type Identifier a = State IdentifierState a

runIdentifier :: Identifier a -> (a, IdentifierState)
runIdentifier action = runState action initialState
  where
    initialState =
      IdentifierState
        { nextVariableId = 0,
          nextTypeId = 0,
          nextModuleId = 0,
          nextRequestId = 0,
          nextConstructorId = 0,
          variables = Map.empty,
          types = Map.empty,
          modules = Map.empty,
          requests = Map.empty,
          constructors = Map.empty,
          variableQNames = Map.empty,
          typeQNames = Map.empty,
          requestQNames = Map.empty,
          constructorQNames = Map.empty,
          errors = [],
          resolveContext = emptyResolveContext
        }

-- ---------------------------------------------------------------------------
-- ID issuing helpers
-- ---------------------------------------------------------------------------

freshVariableId :: VariableData -> Identifier VariableId
freshVariableId variableData = do
  state <- get
  let variableId = VariableId state.nextVariableId
  put state {nextVariableId = state.nextVariableId + 1, variables = Map.insert variableId variableData state.variables}
  pure variableId

freshTypeId :: TypeData -> Identifier TypeId
freshTypeId typeData = do
  state <- get
  let typeId = TypeId state.nextTypeId
  put state {nextTypeId = state.nextTypeId + 1, types = Map.insert typeId typeData state.types}
  pure typeId

freshModuleId :: ModuleData -> Identifier ModuleId
freshModuleId moduleData = do
  state <- get
  let moduleId = ModuleId state.nextModuleId
  put state {nextModuleId = state.nextModuleId + 1, modules = Map.insert moduleId moduleData state.modules}
  pure moduleId

freshRequestId :: RequestData -> Identifier RequestId
freshRequestId requestData = do
  state <- get
  let requestId = RequestId state.nextRequestId
  put state {nextRequestId = state.nextRequestId + 1, requests = Map.insert requestId requestData state.requests}
  pure requestId

freshConstructorId :: ConstructorData -> Identifier ConstructorId
freshConstructorId constructorData = do
  state <- get
  let constructorId = ConstructorId state.nextConstructorId
  put
    state
      { nextConstructorId = state.nextConstructorId + 1,
        constructors = Map.insert constructorId constructorData state.constructors
      }
  pure constructorId

-- | Record a top-level @qualifiedName -> id@ mapping in the appropriate
-- reverse map. Idempotent on duplicates (last write wins; duplicates are
-- caught earlier by 'mergeSymbol').
recordVariableQName :: QualifiedName -> VariableId -> Identifier ()
recordVariableQName qn variableId =
  modify $ \state -> state {variableQNames = Map.insert qn variableId state.variableQNames}

recordTypeQName :: QualifiedName -> TypeId -> Identifier ()
recordTypeQName qn typeId =
  modify $ \state -> state {typeQNames = Map.insert qn typeId state.typeQNames}

recordRequestQName :: QualifiedName -> RequestId -> Identifier ()
recordRequestQName qn requestId =
  modify $ \state -> state {requestQNames = Map.insert qn requestId state.requestQNames}

recordConstructorQName :: QualifiedName -> ConstructorId -> Identifier ()
recordConstructorQName qn constructorId =
  modify $ \state -> state {constructorQNames = Map.insert qn constructorId state.constructorQNames}

emitError :: IdentifierError -> Identifier ()
emitError newError = modify $ \state -> state {errors = newError : state.errors}

-- ---------------------------------------------------------------------------
-- SymbolEntry merge
-- ---------------------------------------------------------------------------

-- | Merge a new 'SymbolEntry' into an existing one. Slot collisions and
-- variable+module coexistence are reported via 'ErrorDuplicateName'. The
-- returned entry is the merged result (existing values are kept on conflict).
mergeSymbol ::
  -- | Source position of the new definition (for the error message).
  SourceSpan ->
  -- | Name (for the error message).
  Text ->
  -- | Existing entry.
  SymbolEntry ->
  -- | Incoming entry to merge.
  SymbolEntry ->
  Identifier SymbolEntry
mergeSymbol newPos name existing incoming = do
  -- Forbid variable + module coexistence in either direction.
  case (incoming.variableSymbol, existing.moduleSymbol) of
    (Just _, Just existingModuleId) -> reportFromModule existingModuleId
    _ -> pure ()
  case (incoming.moduleSymbol, existing.variableSymbol) of
    (Just _, Just existingVariableId) -> reportFromVariable existingVariableId
    _ -> pure ()
  -- Per-slot duplicate.
  mergedVariable <- mergeSlot reportFromVariable existing.variableSymbol incoming.variableSymbol
  mergedType <- mergeSlot reportFromType existing.typeSymbol incoming.typeSymbol
  mergedModule <- mergeSlot reportFromModule existing.moduleSymbol incoming.moduleSymbol
  mergedRequest <- mergeSlot reportFromRequest existing.requestSymbol incoming.requestSymbol
  mergedConstructor <- mergeSlot reportFromConstructor existing.constructorSymbol incoming.constructorSymbol
  pure
    SymbolEntry
      { variableSymbol = mergedVariable,
        typeSymbol = mergedType,
        moduleSymbol = mergedModule,
        requestSymbol = mergedRequest,
        constructorSymbol = mergedConstructor
      }
  where
    reportFromVariable variableId = do
      maybeSpan <- gets (fmap (.variableSourceSpan) . Map.lookup variableId . (.variables))
      maybe (pure ()) (emitError . ErrorDuplicateName newPos name) maybeSpan
    reportFromType typeId = do
      maybeSpan <- gets (fmap (.typeSourceSpan) . Map.lookup typeId . (.types))
      maybe (pure ()) (emitError . ErrorDuplicateName newPos name) maybeSpan
    reportFromModule moduleId = do
      maybeSpan <- gets (fmap (.moduleSourceSpan) . Map.lookup moduleId . (.modules))
      maybe (pure ()) (emitError . ErrorDuplicateName newPos name) maybeSpan
    reportFromRequest requestId = do
      maybeSpan <- gets (fmap (.requestSourceSpan) . Map.lookup requestId . (.requests))
      maybe (pure ()) (emitError . ErrorDuplicateName newPos name) maybeSpan
    reportFromConstructor constructorId = do
      maybeSpan <- gets (fmap (.constructorSourceSpan) . Map.lookup constructorId . (.constructors))
      maybe (pure ()) (emitError . ErrorDuplicateName newPos name) maybeSpan

-- | Generic per-slot merge. The first existing id wins on conflict; the
-- caller's @reportConflict@ records the duplicate-name error against it.
mergeSlot ::
  (a -> Identifier ()) ->
  Maybe a ->
  Maybe a ->
  Identifier (Maybe a)
mergeSlot _ existing Nothing = pure existing
mergeSlot _ Nothing newSlot = pure newSlot
mergeSlot reportConflict (Just existingId) (Just _) = do
  reportConflict existingId
  pure (Just existingId)

-- | Merge @incoming@ into the existing entry for @name@ in @table@ (if any),
-- then @Map.insert@ the result.
insertSymbolEntry ::
  SourceSpan ->
  Text ->
  SymbolEntry ->
  Map Text SymbolEntry ->
  Identifier (Map Text SymbolEntry)
insertSymbolEntry pos name incoming table = do
  let existing = Map.findWithDefault emptySymbolEntry name table
  merged <- mergeSymbol pos name existing incoming
  pure (Map.insert name merged table)

-- ---------------------------------------------------------------------------
-- Scope helpers
-- ---------------------------------------------------------------------------

-- | Bind a local variable in the innermost scope frame.
--
-- Shadowing rules (Rust-style):
--   * The new binding replaces any earlier binding for the same name in the
--     innermost frame (so @let x = 1; let x = 2@ is fine).
--   * Bindings in outer frames are not modified, but lookup honors the
--     innermost frame first, so they are effectively shadowed.
--   * Each slot (variable / type / module) is independent: a local variable
--     binding does not hide an outer frame's @typeSymbol@ for the same name.
--   * The only forbidden shadow is when any frame in the chain has a
--     @moduleSymbol@ for this name. Allowing that would silently change the
--     meaning of @name.foo@ from a qualified module reference to a field
--     access on a local variable.
bindLocalVariable :: NameRef Parsed 'VariableRef -> Identifier (NameRef Identified 'VariableRef)
bindLocalVariable nameRef = do
  context <- gets (.resolveContext)
  let name = nameRef.text
  when (chainHasModule name context.scopeStack) $
    emitError (ErrorShadowNonVariable nameRef.sourceSpan name)
  variableId <-
    freshVariableId
      VariableData
        { variableName = name,
          variableQualifiedName = Nothing,
          variableSourceSpan = nameRef.sourceSpan
        }
  modifyResolveContext $ \currentContext ->
    currentContext {scopeStack = insertInnermost name variableId currentContext.scopeStack}
  pure (identifiedNameRef (Just variableId) nameRef)
  where
    chainHasModule searchName = any (\frame -> isJust (Map.lookup searchName frame >>= (.moduleSymbol)))
    insertInnermost insertName variableId = \case
      [] -> [Map.singleton insertName (singletonVariable variableId)]
      (innermost : remaining) -> Map.insert insertName (singletonVariable variableId) innermost : remaining

-- | Push a fresh empty frame, run the action, then pop the frame.
withScopeFrame :: Identifier a -> Identifier a
withScopeFrame action = do
  modifyResolveContext $ \context -> context {scopeStack = Map.empty : context.scopeStack}
  result <- action
  modifyResolveContext $ \context -> context {scopeStack = drop 1 context.scopeStack}
  pure result

-- | Replace the resolve context for the duration of an action (used to switch
-- between modules in Phase D).
withResolveContext :: ResolveContext -> Identifier a -> Identifier a
withResolveContext newContext action = do
  oldContext <- gets (.resolveContext)
  modify $ \state -> state {resolveContext = newContext}
  result <- action
  modify $ \state -> state {resolveContext = oldContext}
  pure result

modifyResolveContext :: (ResolveContext -> ResolveContext) -> Identifier ()
modifyResolveContext update = modify $ \state -> state {resolveContext = update state.resolveContext}

-- ---------------------------------------------------------------------------
-- Lookup helpers
-- ---------------------------------------------------------------------------

-- | Walk the scope stack innermost-first looking for the first frame that has
-- the requested slot set for the given name. Per-slot lookup means a local
-- variable binding does not hide an outer frame's type binding for the same
-- name (they coexist).
lookupSlot :: (SymbolEntry -> Maybe a) -> Text -> Identifier (Maybe a)
lookupSlot getSlot name = do
  context <- gets (.resolveContext)
  pure (walk context.scopeStack)
  where
    walk [] = Nothing
    walk (frame : remaining) = case Map.lookup name frame of
      Just entry | Just slot <- getSlot entry -> Just slot
      _ -> walk remaining

lookupVariable :: Text -> Identifier (Maybe VariableId)
lookupVariable = lookupSlot (.variableSymbol)

lookupType :: Text -> Identifier (Maybe TypeId)
lookupType = lookupSlot (.typeSymbol)

lookupModule :: Text -> Identifier (Maybe ModuleId)
lookupModule = lookupSlot (.moduleSymbol)

lookupRequest :: Text -> Identifier (Maybe RequestId)
lookupRequest = lookupSlot (.requestSymbol)

lookupConstructor :: Text -> Identifier (Maybe ConstructorId)
lookupConstructor = lookupSlot (.constructorSymbol)

-- | Look up the variable slot of @name@ in the export table of @moduleId@.
lookupModuleExportVariable :: ModuleId -> Text -> Identifier (Maybe VariableId)
lookupModuleExportVariable = lookupModuleExportSlot (.variableSymbol)

-- | Look up the type slot of @name@ in the export table of @moduleId@.
lookupModuleExportType :: ModuleId -> Text -> Identifier (Maybe TypeId)
lookupModuleExportType = lookupModuleExportSlot (.typeSymbol)

lookupModuleExportRequest :: ModuleId -> Text -> Identifier (Maybe RequestId)
lookupModuleExportRequest = lookupModuleExportSlot (.requestSymbol)

lookupModuleExportConstructor :: ModuleId -> Text -> Identifier (Maybe ConstructorId)
lookupModuleExportConstructor = lookupModuleExportSlot (.constructorSymbol)

lookupModuleExportSlot ::
  (SymbolEntry -> Maybe a) ->
  ModuleId ->
  Text ->
  Identifier (Maybe a)
lookupModuleExportSlot getSlot moduleId name = do
  context <- gets (.resolveContext)
  pure $ do
    table <- Map.lookup moduleId context.moduleExports
    entry <- Map.lookup name table
    getSlot entry

-- ---------------------------------------------------------------------------
-- NameRef helpers
-- ---------------------------------------------------------------------------

-- | Replace just the @resolution@ of a 'NameRef', keeping @text@ and @sourceSpan@.
identifiedNameRef ::
  NameMeta Identified symbol ->
  NameRef Parsed symbol ->
  NameRef Identified symbol
identifiedNameRef resolution nameRef =
  NameRef {text = nameRef.text, sourceSpan = nameRef.sourceSpan, resolution = resolution}

labelRef :: NameRef Parsed 'LabelRef -> NameRef Identified 'LabelRef
labelRef = identifiedNameRef ()

-- ---------------------------------------------------------------------------
-- Phase A: assign ModuleIds
-- ---------------------------------------------------------------------------

-- | Allocate a 'ModuleId' for each input module. The Identified AST is built
-- separately in Phase D and stored in the result, so no placeholder is needed
-- here.
assignModuleIds :: Map Text (Module Parsed) -> Identifier (Map Text ModuleId)
assignModuleIds moduleMap =
  Map.fromList <$> mapM allocate (Map.toList moduleMap)
  where
    allocate (moduleName, parsedModule) = do
      moduleId <-
        freshModuleId
          ModuleData
            { moduleName = moduleName,
              moduleSourceSpan = parsedModule.sourceSpan
            }
      pure (moduleName, moduleId)

-- ---------------------------------------------------------------------------
-- Phase B: build per-module export tables
-- ---------------------------------------------------------------------------

-- | Walk each module's top-level declarations and build a
-- @Map Text SymbolEntry@ representing what the module exports.
-- agent / req / ext-agent → variableSymbol; data → variableSymbol + typeSymbol
-- under the same name; type synonym → typeSymbol.
buildExports :: Map Text (Module Parsed) -> Identifier (Map Text (Map Text SymbolEntry))
buildExports moduleMap =
  Map.fromList <$> mapM buildOne (Map.toList moduleMap)
  where
    buildOne (moduleName, parsedModule) = do
      table <- foldM (addDeclaration moduleName) Map.empty parsedModule.declarations
      pure (moduleName, table)

    addDeclaration moduleName table = \case
      DeclarationAgent declaration -> registerVariable moduleName table declaration.name
      DeclarationRequest declaration -> registerRequest moduleName table declaration.name
      DeclarationExternalAgent declaration -> registerVariable moduleName table declaration.name
      -- A data declaration occupies the variable slot (constructor function),
      -- the type slot (the data type), AND the constructor slot (the
      -- constructor identity used by match patterns). All three live under
      -- the same name and are issued together.
      DeclarationData declaration -> registerData moduleName table declaration.name
      DeclarationTypeSynonym declaration -> registerTypeOnly moduleName table declaration.name
      DeclarationImport _ -> pure table -- handled in Phase C
      -- Recovery sentinel: do not occupy any slot. References that would have
      -- pointed here will fall through to ErrorUndefinedName.
      DeclarationError _ -> pure table

    qnameOf moduleName name = QualifiedName {module_ = moduleName, name = name.text}

    registerVariable moduleName table name = do
      let qn = qnameOf moduleName name
      variableId <-
        freshVariableId
          VariableData
            { variableName = name.text,
              variableQualifiedName = Just qn,
              variableSourceSpan = name.sourceSpan
            }
      recordVariableQName qn variableId
      insertSymbolEntry name.sourceSpan name.text (singletonVariable variableId) table

    -- @req foo@ issues both a 'VariableId' (callable side: @foo(...)@) and a
    -- 'RequestId' (handler-target / effect-set side).
    registerRequest moduleName table name = do
      let qn = qnameOf moduleName name
      variableId <-
        freshVariableId
          VariableData
            { variableName = name.text,
              variableQualifiedName = Just qn,
              variableSourceSpan = name.sourceSpan
            }
      requestId <-
        freshRequestId
          RequestData
            { requestQualifiedName = qn,
              requestSourceSpan = name.sourceSpan,
              requestVariableId = variableId
            }
      recordVariableQName qn variableId
      recordRequestQName qn requestId
      let entry =
            emptySymbolEntry
              { variableSymbol = Just variableId,
                requestSymbol = Just requestId
              }
      insertSymbolEntry name.sourceSpan name.text entry table

    registerTypeOnly moduleName table name = do
      let qn = qnameOf moduleName name
      typeId <-
        freshTypeId
          TypeData
            { typeQualifiedName = qn,
              typeSourceSpan = name.sourceSpan,
              typeSynonymRhs = Nothing
            }
      recordTypeQName qn typeId
      insertSymbolEntry name.sourceSpan name.text (singletonType typeId) table

    -- @data Foo(...)@ issues 'VariableId' (constructor function), 'TypeId'
    -- (the data type), and 'ConstructorId' (the constructor identity used by
    -- match patterns).
    registerData moduleName table name = do
      let qn = qnameOf moduleName name
      variableId <-
        freshVariableId
          VariableData
            { variableName = name.text,
              variableQualifiedName = Just qn,
              variableSourceSpan = name.sourceSpan
            }
      typeId <-
        freshTypeId
          TypeData
            { typeQualifiedName = qn,
              typeSourceSpan = name.sourceSpan,
              typeSynonymRhs = Nothing
            }
      constructorId <-
        freshConstructorId
          ConstructorData
            { constructorQualifiedName = qn,
              constructorSourceSpan = name.sourceSpan,
              constructorTypeId = typeId,
              constructorVariableId = variableId
            }
      recordVariableQName qn variableId
      recordTypeQName qn typeId
      recordConstructorQName qn constructorId
      let entry =
            emptySymbolEntry
              { variableSymbol = Just variableId,
                typeSymbol = Just typeId,
                constructorSymbol = Just constructorId
              }
      insertSymbolEntry name.sourceSpan name.text entry table

-- ---------------------------------------------------------------------------
-- Phase C: build per-module top-level scope by resolving imports
-- ---------------------------------------------------------------------------

-- | Merge a module's own declarations with the symbols brought in by its
-- import statements to produce a flat @Map Text SymbolEntry@ for use as the
-- top-level frame.
buildTopLevels ::
  Map Text ModuleId ->
  Map Text (Map Text SymbolEntry) ->
  Map Text (Module Parsed) ->
  Identifier (Map Text (Map Text SymbolEntry))
buildTopLevels moduleNameToId exports moduleMap =
  Map.fromList <$> mapM buildOne (Map.toList moduleMap)
  where
    buildOne (currentModuleName, parsedModule) = do
      let ownExports = Map.findWithDefault Map.empty currentModuleName exports
      table <- foldM addImport ownExports parsedModule.declarations
      pure (currentModuleName, table)

    addImport table = \case
      DeclarationImport importDeclaration -> resolveImport table importDeclaration
      _ -> pure table

    resolveImport table importDeclaration =
      case importDeclaration.kind of
        ImportModule {moduleName, alias} ->
          resolveImportModule importDeclaration.sourceSpan moduleName alias table
        ImportNames {items, moduleName} ->
          resolveImportNames importDeclaration.sourceSpan moduleName items table

    resolveImportModule importPos targetModuleName maybeAlias table =
      case Map.lookup targetModuleName moduleNameToId of
        Nothing -> do
          emitError (ErrorImportModuleNotFound importPos targetModuleName)
          pure table
        Just targetModuleId -> do
          let bindName = case maybeAlias of
                Just aliasName -> aliasName
                Nothing -> moduleNameTail targetModuleName
          insertSymbolEntry importPos bindName (singletonModule targetModuleId) table

    resolveImportNames importPos targetModuleName items table =
      case Map.lookup targetModuleName moduleNameToId of
        Nothing -> do
          emitError (ErrorImportModuleNotFound importPos targetModuleName)
          pure table
        Just _ -> do
          let targetModuleExports = Map.findWithDefault Map.empty targetModuleName exports
          foldM (addImportItem importPos targetModuleName targetModuleExports) table items

    addImportItem importPos targetModuleName targetModuleExports table item =
      case Map.lookup item.name targetModuleExports of
        Nothing -> do
          emitError (ErrorImportNameNotFound importPos item.name targetModuleName)
          pure table
        Just entry ->
          case item.kind of
            -- @import { foo }@ — pulls in both the variable and type slots
            -- under the source name. Lets a data-shaped name (variable + type
            -- under one identifier) be imported in one go. At least one slot
            -- must exist on the source side.
            -- Bring in every value-side slot under the source name.
            -- @data Foo()@ exports variable + type + constructor; @req foo@
            -- exports variable + request; agent / ext exports variable only.
            ImportItemValue
              | isJust entry.variableSymbol
                  || isJust entry.typeSymbol
                  || isJust entry.requestSymbol
                  || isJust entry.constructorSymbol ->
                  insertSymbolEntry
                    importPos
                    item.name
                    SymbolEntry
                      { variableSymbol = entry.variableSymbol,
                        typeSymbol = entry.typeSymbol,
                        moduleSymbol = Nothing,
                        requestSymbol = entry.requestSymbol,
                        constructorSymbol = entry.constructorSymbol
                      }
                    table
              | otherwise -> do
                  emitError (ErrorImportNameNotFound importPos item.name targetModuleName)
                  pure table
            -- @import { type foo }@ — pulls in only the type slot.
            ImportItemType -> case entry.typeSymbol of
              Nothing -> do
                emitError (ErrorImportNameNotFound importPos item.name targetModuleName)
                pure table
              Just typeId ->
                insertSymbolEntry importPos item.name (singletonType typeId) table

-- | Extract @"module"@ from @"path.to.module"@. Returns the empty string if
-- given an empty input (the parser should never produce one, but this guards
-- against it anyway).
moduleNameTail :: Text -> Text
moduleNameTail path =
  case reverse (T.splitOn "." path) of
    [] -> path
    (lastSegment : _) -> lastSegment

-- ---------------------------------------------------------------------------
-- Phase D: convert each module body into an Identified AST
-- ---------------------------------------------------------------------------

-- | Resolve all module bodies into Identified ASTs. Sets up a fresh
-- 'ResolveContext' per module (top-level frame seeded from the module's own
-- declarations + import results) and returns a @ModuleId -> Module Identified@
-- map directly, avoiding the placeholder-then-overwrite pattern.
resolveModule ::
  Map Text (Map Text SymbolEntry) ->
  Map Text ModuleId ->
  Map Text (Map Text SymbolEntry) ->
  Map Text (Module Parsed) ->
  Identifier (Map ModuleId (Module Identified))
resolveModule topLevels moduleNameToId exports moduleMap = do
  -- Re-key moduleExports by ModuleId for convenient qualified lookup.
  let exportsById =
        Map.fromList
          [ (moduleId, Map.findWithDefault Map.empty moduleName exports)
            | (moduleName, moduleId) <- Map.toList moduleNameToId
          ]
  -- Build (ModuleId, Module Identified) pairs and assemble a Map at the end.
  pairs <- mapM (resolveOne exportsById) (Map.toList moduleMap)
  pure (Map.fromList (catMaybes pairs))
  where
    resolveOne exportsById (currentModuleName, parsedModule) = do
      let topLevelFrame = Map.findWithDefault Map.empty currentModuleName topLevels
          context =
            ResolveContext
              { scopeStack = [topLevelFrame],
                moduleExports = exportsById
              }
      identifiedModule <- withResolveContext context (resolveModuleAST parsedModule)
      pure (fmap (,identifiedModule) (Map.lookup currentModuleName moduleNameToId))

resolveModuleAST :: Module Parsed -> Identifier (Module Identified)
resolveModuleAST parsedModule = do
  declarations <- mapM resolveDeclaration parsedModule.declarations
  pure Module {declarations = declarations, sourceSpan = parsedModule.sourceSpan}

-- ---------------------------------------------------------------------------
-- Declaration
-- ---------------------------------------------------------------------------

resolveDeclaration :: Declaration Parsed -> Identifier (Declaration Identified)
resolveDeclaration = \case
  DeclarationAgent declaration -> DeclarationAgent <$> resolveAgent declaration
  DeclarationRequest declaration -> DeclarationRequest <$> resolveRequest declaration
  DeclarationExternalAgent declaration -> DeclarationExternalAgent <$> resolveExternalAgent declaration
  DeclarationData declaration -> DeclarationData <$> resolveData declaration
  DeclarationTypeSynonym declaration -> DeclarationTypeSynonym <$> resolveTypeSynonym declaration
  DeclarationImport declaration -> pure (DeclarationImport (resolveImportDecl declaration))
  -- Parser-recovery sentinel: passthrough unchanged. The parallel
  -- @[ParseError]@ list keeps the structured error detail; this phase has
  -- nothing to resolve here.
  DeclarationError sp -> pure (DeclarationError sp)

resolveImportDecl :: ImportDeclaration Parsed -> ImportDeclaration Identified
resolveImportDecl ImportDeclaration {kind, sourceSpan} =
  ImportDeclaration {kind = kind, sourceSpan = sourceSpan}

-- | Fill in the variable id for a signature-position 'NameRef' (the @name@ of
-- an agent / req / ext-agent / data declaration). Phase B has already issued
-- the id; this just looks it up. If lookup fails (only possible when Phase B
-- emitted a duplicate-name error), record an unresolved marker rather than
-- inventing a sentinel id.
liftSignatureVariable :: NameRef Parsed 'VariableRef -> Identifier (NameRef Identified 'VariableRef)
liftSignatureVariable = liftSignature lookupVariable

-- | Counterpart of 'liftSignatureVariable' for type signatures (enum / data
-- type role / type synonym name).
liftSignatureType :: NameRef Parsed 'TypeRef -> Identifier (NameRef Identified 'TypeRef)
liftSignatureType = liftSignature lookupType

-- | Shared lookup-and-wrap helper for signature-position 'NameRef's.
-- Phase B has already issued the id; here we just look it up and tag the
-- node with either the resolved id or 'Nothing' (lookup miss is recorded
-- separately as an 'IdentifierError').
liftSignature ::
  (Text -> Identifier (NameMeta Identified sym)) ->
  NameRef Parsed sym ->
  Identifier (NameRef Identified sym)
liftSignature lookupBy nameRef = do
  result <- lookupBy nameRef.text
  pure (identifiedNameRef result nameRef)

resolveSignatureBody ::
  [ParameterBinding Parsed] ->
  Maybe (SyntacticType Parsed) ->
  Maybe [SyntacticRequest Parsed] ->
  Block Parsed ->
  Identifier ([ParameterBinding Identified], Maybe (SyntacticType Identified), Maybe [SyntacticRequest Identified], Block Identified)
resolveSignatureBody parameters returnType withEffects body =
  withScopeFrame $ do
    parameters' <- mapM resolveParameter parameters
    returnType' <- traverse resolveType returnType
    withEffects' <- traverse (mapM resolveSyntacticRequest) withEffects
    body' <- resolveBlock body
    pure (parameters', returnType', withEffects', body')

resolveAgent :: AgentDeclaration Parsed -> Identifier (AgentDeclaration Identified)
resolveAgent AgentDeclaration {..} = do
  name' <- liftSignatureVariable name
  (parameters', returnType', withEffects', body') <- resolveSignatureBody parameters returnType withEffects body
  pure
    AgentDeclaration
      { annotation = annotation,
        name = name',
        parameters = parameters',
        returnType = returnType',
        withEffects = withEffects',
        body = body',
        sourceSpan = sourceSpan
      }

resolveRequest :: RequestDeclaration Parsed -> Identifier (RequestDeclaration Identified)
resolveRequest RequestDeclaration {..} = do
  name' <- liftSignatureVariable name
  withScopeFrame $ do
    parameters' <- mapM resolveParameter parameters
    returnType' <- resolveType returnType
    pure
      RequestDeclaration
        { annotation = annotation,
          name = name',
          parameters = parameters',
          returnType = returnType',
          sourceSpan = sourceSpan
        }

resolveExternalAgent :: ExternalAgentDeclaration Parsed -> Identifier (ExternalAgentDeclaration Identified)
resolveExternalAgent ExternalAgentDeclaration {..} = do
  name' <- liftSignatureVariable name
  withScopeFrame $ do
    parameters' <- mapM resolveParameter parameters
    returnType' <- resolveType returnType
    withEffects' <- mapM resolveSyntacticRequest withEffects
    pure
      ExternalAgentDeclaration
        { annotation = annotation,
          name = name',
          parameters = parameters',
          returnType = returnType',
          withEffects = withEffects',
          sourceSpan = sourceSpan
        }

-- | Resolve a @data ctor(name: type, ...)@ declaration. Fills in the
-- variable-role name and resolves each parameter's type. The type-role id
-- (the @typeSymbol@ slot) was already issued in Phase B and lives in the
-- module's @SymbolEntry@ under the same name.
resolveData :: DataDeclaration Parsed -> Identifier (DataDeclaration Identified)
resolveData DataDeclaration {..} = do
  name' <- liftSignatureVariable name
  typeName' <- liftSignatureType typeName
  parameters' <- mapM resolveDataParameter parameters
  pure
    DataDeclaration
      { annotation = annotation,
        name = name',
        typeName = typeName',
        parameters = parameters',
        sourceSpan = sourceSpan
      }

resolveDataParameter :: DataParameter Parsed -> Identifier (DataParameter Identified)
resolveDataParameter DataParameter {..} = do
  parameterType' <- resolveType parameterType
  pure
    DataParameter
      { annotation = annotation,
        name = name,
        parameterType = parameterType',
        sourceSpan = sourceSpan
      }

-- | Resolve a @type T = ...@ synonym. The name (TypeRef) was issued in Phase
-- B; here we resolve the rhs and stash it back into 'TypeData' so later
-- phases can expand the synonym transparently.
resolveTypeSynonym ::
  TypeSynonymDeclaration Parsed ->
  Identifier (TypeSynonymDeclaration Identified)
resolveTypeSynonym TypeSynonymDeclaration {..} = do
  name' <- liftSignatureType name
  rhs' <- resolveType rhs
  case name'.resolution of
    Just typeId -> updateTypeSynonymRhs typeId rhs'
    Nothing -> pure ()
  pure
    TypeSynonymDeclaration
      { name = name',
        rhs = rhs',
        sourceSpan = sourceSpan
      }

-- | Patch the @typeSynonymRhs@ field of an existing 'TypeData' entry. Phase B
-- creates the entry with @Nothing@; Phase D fills in the resolved RHS once the
-- type expression has been processed.
updateTypeSynonymRhs :: TypeId -> SyntacticType Identified -> Identifier ()
updateTypeSynonymRhs typeId rhs = modify $ \state ->
  state
    { types =
        Map.adjust
          (\typeData -> typeData {typeSynonymRhs = Just rhs})
          typeId
          state.types
    }

-- ---------------------------------------------------------------------------
-- Parameter / Pattern
-- ---------------------------------------------------------------------------

resolveParameter :: ParameterBinding Parsed -> Identifier (ParameterBinding Identified)
resolveParameter ParameterBinding {..} = do
  pattern' <- resolvePattern pattern
  pure
    ParameterBinding
      { annotation = annotation,
        label = label,
        pattern = pattern',
        sourceSpan = sourceSpan
      }

-- | Variable occurrences inside a pattern are fresh bindings.
-- 'VariablePattern' is what the parser produces for a bare identifier;
-- constructor-shaped patterns (with parens) come through as
-- 'QualifiedConstructorPattern' instead.
resolvePattern :: Pattern Parsed -> Identifier (Pattern Identified)
resolvePattern = \case
  PatternVariable parsedPattern -> PatternVariable <$> resolveVariablePattern parsedPattern
  PatternQualifiedConstructor parsedPattern -> PatternQualifiedConstructor <$> resolveConstructorPattern parsedPattern
  PatternTuple parsedPattern -> PatternTuple <$> resolveTuplePattern parsedPattern
  PatternWildcard parsedPattern -> PatternWildcard <$> resolveWildcardPattern parsedPattern
  PatternLiteral parsedPattern -> PatternLiteral <$> resolveLiteralPattern parsedPattern

resolveVariablePattern :: VariablePattern Parsed -> Identifier (VariablePattern Identified)
resolveVariablePattern VariablePattern {..} = do
  name' <- bindLocalVariable name
  typeAnnotation' <- traverse resolveType typeAnnotation
  pure
    VariablePattern
      { name = name',
        typeAnnotation = typeAnnotation',
        sourceSpan = sourceSpan,
        typeOf = ()
      }

resolveConstructorPattern ::
  QualifiedConstructorPattern Parsed ->
  Identifier (QualifiedConstructorPattern Identified)
resolveConstructorPattern QualifiedConstructorPattern {..} = do
  (moduleQualifier', constructorName') <-
    resolveQualifiedConstructorRef moduleQualifier constructorName
  parameters' <-
    mapM
      (\(label, fieldPattern) -> (labelRef label,) <$> resolvePattern fieldPattern)
      parameters
  pure
    QualifiedConstructorPattern
      { moduleQualifier = moduleQualifier',
        constructorName = constructorName',
        parameters = parameters',
        sourceSpan = sourceSpan,
        typeOf = ()
      }

resolveTuplePattern :: TuplePattern Parsed -> Identifier (TuplePattern Identified)
resolveTuplePattern TuplePattern {..} = do
  elements' <- mapM resolvePattern elements
  pure
    TuplePattern
      { elements = elements',
        sourceSpan = sourceSpan,
        typeOf = ()
      }

resolveWildcardPattern :: WildcardPattern Parsed -> Identifier (WildcardPattern Identified)
resolveWildcardPattern WildcardPattern {..} = do
  typeAnnotation' <- traverse resolveType typeAnnotation
  pure
    WildcardPattern
      { typeAnnotation = typeAnnotation',
        sourceSpan = sourceSpan,
        typeOf = ()
      }

resolveLiteralPattern :: LiteralPattern Parsed -> Identifier (LiteralPattern Identified)
resolveLiteralPattern LiteralPattern {..} =
  pure
    LiteralPattern
      { value = value,
        sourceSpan = sourceSpan,
        typeOf = ()
      }

-- | Resolve either a bare @name@ or a qualified @module.name@ as a variable
-- reference. Used by constructor patterns and request handler names.
--
-- All sub-resolvers return an 'Identified' marker (resolved id or the
-- corresponding @Unresolved@) so that the AST always carries a faithful trace
-- of the resolution outcome instead of a fabricated id.
resolveBareVariable :: NameRef Parsed 'VariableRef -> Identifier (NameMeta Identified 'VariableRef)
resolveBareVariable nameRef =
  lookupVariable nameRef.text >>= \case
    Just variableId -> pure (Just variableId)
    Nothing -> do
      emitError (ErrorUndefinedName nameRef.sourceSpan nameRef.text)
      pure Nothing

resolveModuleRef :: NameRef Parsed 'ModuleRef -> Identifier (NameMeta Identified 'ModuleRef)
resolveModuleRef nameRef =
  lookupModule nameRef.text >>= \case
    Just moduleId -> pure (Just moduleId)
    Nothing -> do
      emitError (ErrorNotAModule nameRef.sourceSpan nameRef.text)
      pure Nothing

-- | Resolve @[module.]name@ as a request reference (handler position). The
-- bare name must occupy the request slot of an in-scope binding; otherwise
-- 'ErrorNotARequest' (or 'ErrorUndefinedName' if the name is unknown
-- entirely) is recorded.
resolveQualifiedRequestRef ::
  Maybe (NameRef Parsed 'ModuleRef) ->
  NameRef Parsed 'RequestRef ->
  Identifier (Maybe (NameRef Identified 'ModuleRef), NameRef Identified 'RequestRef)
resolveQualifiedRequestRef = \cases
  Nothing nameRef -> do
    metadata <- resolveBareRequest nameRef
    pure (Nothing, identifiedNameRef metadata nameRef)
  (Just moduleRef) nameRef -> do
    moduleMetadata <- resolveModuleRef moduleRef
    metadata <- case moduleMetadata of
      Just moduleId -> resolveQualifiedRequest moduleId moduleRef.text nameRef
      Nothing -> pure Nothing
    pure
      ( Just (identifiedNameRef moduleMetadata moduleRef),
        identifiedNameRef metadata nameRef
      )

resolveBareRequest :: NameRef Parsed 'RequestRef -> Identifier (NameMeta Identified 'RequestRef)
resolveBareRequest nameRef =
  lookupRequest nameRef.text >>= \case
    Just rid -> pure (Just rid)
    Nothing -> do
      -- Distinguish "name does not exist" from "name exists but is not a
      -- request". The former is a generic K0102, the latter K0108.
      emitNotARequestOrUndefined nameRef
      pure Nothing
  where
    emitNotARequestOrUndefined ref =
      lookupVariable ref.text >>= \case
        Just _ -> emitError (ErrorNotARequest ref.sourceSpan ref.text)
        Nothing -> emitError (ErrorUndefinedName ref.sourceSpan ref.text)

resolveQualifiedRequest ::
  ModuleId ->
  Text ->
  NameRef Parsed 'RequestRef ->
  Identifier (NameMeta Identified 'RequestRef)
resolveQualifiedRequest moduleId qualifierName nameRef =
  lookupModuleExportRequest moduleId nameRef.text >>= \case
    Just rid -> pure (Just rid)
    Nothing -> do
      emitError (ErrorUndefinedQualified nameRef.sourceSpan qualifierName nameRef.text)
      pure Nothing

-- | Resolve @[module.]name@ as a constructor reference (match-pattern
-- position). The bare name must occupy the constructor slot of an in-scope
-- binding.
resolveQualifiedConstructorRef ::
  Maybe (NameRef Parsed 'ModuleRef) ->
  NameRef Parsed 'ConstructorRef ->
  Identifier (Maybe (NameRef Identified 'ModuleRef), NameRef Identified 'ConstructorRef)
resolveQualifiedConstructorRef = \cases
  Nothing nameRef -> do
    metadata <- resolveBareConstructor nameRef
    pure (Nothing, identifiedNameRef metadata nameRef)
  (Just moduleRef) nameRef -> do
    moduleMetadata <- resolveModuleRef moduleRef
    metadata <- case moduleMetadata of
      Just moduleId -> resolveQualifiedConstructor moduleId moduleRef.text nameRef
      Nothing -> pure Nothing
    pure
      ( Just (identifiedNameRef moduleMetadata moduleRef),
        identifiedNameRef metadata nameRef
      )

resolveBareConstructor ::
  NameRef Parsed 'ConstructorRef ->
  Identifier (NameMeta Identified 'ConstructorRef)
resolveBareConstructor nameRef =
  lookupConstructor nameRef.text >>= \case
    Just cid -> pure (Just cid)
    Nothing -> do
      emitNotAConstructorOrUndefined nameRef
      pure Nothing
  where
    emitNotAConstructorOrUndefined ref =
      lookupVariable ref.text >>= \case
        Just _ -> emitError (ErrorNotAConstructor ref.sourceSpan ref.text)
        Nothing -> emitError (ErrorUndefinedName ref.sourceSpan ref.text)

resolveQualifiedConstructor ::
  ModuleId ->
  Text ->
  NameRef Parsed 'ConstructorRef ->
  Identifier (NameMeta Identified 'ConstructorRef)
resolveQualifiedConstructor moduleId qualifierName nameRef =
  lookupModuleExportConstructor moduleId nameRef.text >>= \case
    Just cid -> pure (Just cid)
    Nothing -> do
      emitError (ErrorUndefinedQualified nameRef.sourceSpan qualifierName nameRef.text)
      pure Nothing

-- ---------------------------------------------------------------------------
-- SyntacticType
-- ---------------------------------------------------------------------------

resolveType :: SyntacticType Parsed -> Identifier (SyntacticType Identified)
resolveType = \case
  TypePrimitive node -> pure (TypePrimitive (rebuildPrimitive node))
  TypeName node -> TypeName <$> resolveTypeName node
  TypeFunction node -> TypeFunction <$> resolveFunctionType node
  TypeArray node -> TypeArray <$> resolveArrayType node
  TypeTuple node -> TypeTuple <$> resolveTupleType node
  TypeQualified node -> TypeQualified <$> resolveQualifiedType node
  -- Literal types have nothing to resolve (the LiteralValue is phase-agnostic).
  TypeLiteral node -> pure (TypeLiteral node)
  -- Union: recurse into each branch.
  TypeUnion TypeUnionNode {branches, sourceSpan} -> do
    branches' <- mapM resolveType branches
    pure (TypeUnion TypeUnionNode {branches = branches', sourceSpan = sourceSpan})
  -- never / unknown carry only a sourceSpan; phase change is mechanical.
  TypeNever NeverTypeNode {sourceSpan} ->
    pure (TypeNever NeverTypeNode {sourceSpan = sourceSpan})
  TypeUnknown UnknownTypeNode {sourceSpan} ->
    pure (TypeUnknown UnknownTypeNode {sourceSpan = sourceSpan})
  where
    rebuildPrimitive PrimitiveTypeNode {kind, sourceSpan} =
      PrimitiveTypeNode {kind = kind, sourceSpan = sourceSpan}

resolveTypeName :: TypeNameNode Parsed -> Identifier (TypeNameNode Identified)
resolveTypeName TypeNameNode {name, sourceSpan} = do
  metadata <-
    lookupType name.text >>= \case
      Just typeId -> pure (Just typeId)
      Nothing -> do
        emitError (ErrorNotAType name.sourceSpan name.text)
        pure Nothing
  pure
    TypeNameNode
      { name = identifiedNameRef metadata name,
        sourceSpan = sourceSpan
      }

resolveQualifiedType :: QualifiedTypeNode Parsed -> Identifier (QualifiedTypeNode Identified)
resolveQualifiedType QualifiedTypeNode {qualifier, target, sourceSpan} = do
  moduleMetadata <- resolveModuleRef qualifier
  typeMetadata <- case moduleMetadata of
    Just moduleId ->
      lookupModuleExportType moduleId target.text >>= \case
        Just typeId -> pure (Just typeId)
        Nothing -> do
          emitError (ErrorUndefinedQualified target.sourceSpan qualifier.text target.text)
          pure Nothing
    Nothing -> pure Nothing
  pure
    QualifiedTypeNode
      { qualifier = identifiedNameRef moduleMetadata qualifier,
        target = identifiedNameRef typeMetadata target,
        sourceSpan = sourceSpan
      }

resolveFunctionType :: FunctionTypeNode Parsed -> Identifier (FunctionTypeNode Identified)
resolveFunctionType FunctionTypeNode {parameterTypes, returnType, withEffects, sourceSpan} = do
  parameterTypes' <- mapM (\(label, parameterType) -> (label,) <$> resolveType parameterType) parameterTypes
  returnType' <- resolveType returnType
  withEffects' <- mapM resolveSyntacticRequest withEffects
  pure
    FunctionTypeNode
      { parameterTypes = parameterTypes',
        returnType = returnType',
        withEffects = withEffects',
        sourceSpan = sourceSpan
      }

resolveArrayType :: ArrayTypeNode Parsed -> Identifier (ArrayTypeNode Identified)
resolveArrayType ArrayTypeNode {elementType, sourceSpan} = do
  elementType' <- resolveType elementType
  pure ArrayTypeNode {elementType = elementType', sourceSpan = sourceSpan}

resolveTupleType :: TupleTypeNode Parsed -> Identifier (TupleTypeNode Identified)
resolveTupleType TupleTypeNode {elementTypes, sourceSpan} = do
  elementTypes' <- mapM resolveType elementTypes
  pure TupleTypeNode {elementTypes = elementTypes', sourceSpan = sourceSpan}

resolveSyntacticRequest :: SyntacticRequest Parsed -> Identifier (SyntacticRequest Identified)
resolveSyntacticRequest SyntacticRequest {name, sourceSpan} = do
  metadata <- resolveBareVariable name
  pure
    SyntacticRequest
      { name = identifiedNameRef metadata name,
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Block / Statement
-- ---------------------------------------------------------------------------

-- | A block's body and its @where@ clause are **independent scopes**: a
-- @let@ in the body is invisible from the where clause and vice versa, while
-- both inherit the surrounding outer scope.
-- | A block's body and its @where@ clause are **independent scopes**: a
-- @let@ in the body is invisible from the where clause and vice versa, while
-- both inherit the surrounding outer scope. State variables declared in
-- @where@ are visible to handlers (and the @then@ clause once revived) but
-- NOT to the body.
resolveBlock :: Block Parsed -> Identifier (Block Identified)
resolveBlock Block {statements, returnExpression, whereBlock, sourceSpan} = do
  -- Body: push a fresh frame.
  (statements', returnExpression') <- withScopeFrame $ do
    ss <- mapM resolveStatement statements
    re <- traverse resolveExpression returnExpression
    pure (ss, re)
  -- Where: resolved in its own fresh frame (sibling to the body's frame).
  whereBlock' <- traverse resolveWhereBlock whereBlock
  pure
    Block
      { statements = statements',
        returnExpression = returnExpression',
        whereBlock = whereBlock',
        sourceSpan = sourceSpan
      }

-- | Scope construction for a @where@ clause:
--
--   1. State vars are bound sequentially in declaration order (ML @let@
--      semantics, not @let rec@).
--   2. Handler names are NOT new bindings; they are references to existing
--      req declarations.
--   3. Handler bodies are resolved in a frame where all state vars are
--      already bound.
resolveWhereBlock :: WhereBlock Parsed -> Identifier (WhereBlock Identified)
resolveWhereBlock WhereBlock {stateVariables, handlers, thenClause, sourceSpan} = withScopeFrame $ do
  stateVariables' <- mapM resolveStateVariable stateVariables
  handlers' <- mapM resolveRequestHandler handlers
  -- The @then@ clause shares the where's frame, so it sees state vars but
  -- not body @let@ bindings. Its own pattern + block introduce a nested
  -- frame for the destructured pattern bindings.
  thenClause' <-
    traverse
      ( \(maybePattern, block) -> withScopeFrame $ do
          maybePattern' <- traverse resolvePattern maybePattern
          block' <- resolveBlock block
          pure (maybePattern', block')
      )
      thenClause
  pure
    WhereBlock
      { stateVariables = stateVariables',
        handlers = handlers',
        thenClause = thenClause',
        sourceSpan = sourceSpan
      }

-- | A state variable's initializer is resolved in the scope as it stands
-- BEFORE the binding (so only earlier state vars are visible). The binding is
-- introduced only after the initializer has been resolved.
resolveStateVariable :: StateVariableBinding Parsed -> Identifier (StateVariableBinding Identified)
resolveStateVariable StateVariableBinding {name, typeAnnotation, initial, sourceSpan} = do
  typeAnnotation' <- traverse resolveType typeAnnotation
  initial' <- resolveExpression initial
  -- ML-style let: bind only after resolving the initializer.
  name' <- bindLocalVariable name
  pure
    StateVariableBinding
      { name = name',
        typeAnnotation = typeAnnotation',
        initial = initial',
        sourceSpan = sourceSpan
      }

-- | Request handler. @name@ is NOT a new binding; it is a reference to an
-- existing req declaration (resolved like an ordinary variable name).
-- Handlers do not carry their own @with@ clause: effects raised inside the
-- handler bind to the surrounding agent, so handler-level effect annotation
-- is not part of the syntax.
resolveRequestHandler :: RequestHandler Parsed -> Identifier (RequestHandler Identified)
resolveRequestHandler RequestHandler {moduleQualifier, name, parameters, returnType, body, sourceSpan} = do
  (moduleQualifier', name') <- resolveQualifiedRequestRef moduleQualifier name
  (parameters', returnType', _noEffects, body') <- resolveSignatureBody parameters returnType Nothing body
  pure
    RequestHandler
      { moduleQualifier = moduleQualifier',
        name = name',
        parameters = parameters',
        returnType = returnType',
        body = body',
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Statement
-- ---------------------------------------------------------------------------

resolveStatement :: Statement Parsed -> Identifier (Statement Identified)
resolveStatement = \case
  StatementLet statement -> StatementLet <$> resolveLet statement
  StatementAgent statement -> StatementAgent <$> resolveAgentStatement statement
  StatementReturn statement -> StatementReturn <$> resolveReturn statement
  StatementExpression expression -> StatementExpression <$> resolveExpression expression
  StatementNext statement -> StatementNext <$> resolveNext statement
  StatementBreak statement -> StatementBreak <$> resolveBreak statement
  StatementForNext statement -> StatementForNext <$> resolveForNext statement
  StatementForBreak statement -> StatementForBreak <$> resolveForBreak statement
  StatementError sp -> pure (StatementError sp)

resolveLet :: LetStatement Parsed -> Identifier (LetStatement Identified)
resolveLet LetStatement {pattern, value, sourceSpan} = do
  -- ML-style let: resolve the value first, then bind the pattern.
  value' <- resolveExpression value
  pattern' <- resolvePattern pattern
  pure LetStatement {pattern = pattern', value = value', sourceSpan = sourceSpan}

-- | A local @agent@ statement. The name is bound (subject to local shadowing
-- rules) before resolving the body, so the agent may call itself recursively.
-- The body is resolved in a fresh scope frame.
resolveAgentStatement :: AgentStatement Parsed -> Identifier (AgentStatement Identified)
resolveAgentStatement AgentStatement {name, parameters, returnType, withEffects, body, sourceSpan} = do
  name' <- bindLocalVariable name
  (parameters', returnType', withEffects', body') <- resolveSignatureBody parameters returnType withEffects body
  pure
    AgentStatement
      { name = name',
        parameters = parameters',
        returnType = returnType',
        withEffects = withEffects',
        body = body',
        sourceSpan = sourceSpan
      }

resolveReturn :: ReturnStatement Parsed -> Identifier (ReturnStatement Identified)
resolveReturn ReturnStatement {value, sourceSpan} = do
  value' <- resolveExpression value
  pure ReturnStatement {value = value', sourceSpan = sourceSpan}

resolveNext :: NextStatement Parsed -> Identifier (NextStatement Identified)
resolveNext NextStatement {value, modifiers, sourceSpan} = do
  value' <- resolveExpression value
  modifiers' <- mapM resolveModifier modifiers
  pure NextStatement {value = value', modifiers = modifiers', sourceSpan = sourceSpan}

resolveBreak :: BreakStatement Parsed -> Identifier (BreakStatement Identified)
resolveBreak BreakStatement {value, sourceSpan} = do
  value' <- resolveExpression value
  pure BreakStatement {value = value', sourceSpan = sourceSpan}

resolveForNext :: ForNextStatement Parsed -> Identifier (ForNextStatement Identified)
resolveForNext ForNextStatement {modifiers, sourceSpan} = do
  modifiers' <- mapM resolveModifier modifiers
  pure ForNextStatement {modifiers = modifiers', sourceSpan = sourceSpan}

resolveForBreak :: ForBreakStatement Parsed -> Identifier (ForBreakStatement Identified)
resolveForBreak ForBreakStatement {value, sourceSpan} = do
  value' <- resolveExpression value
  pure ForBreakStatement {value = value', sourceSpan = sourceSpan}

-- | A modifier name refers back to a state variable or for-var binding.
resolveModifier :: Modifier Parsed -> Identifier (Modifier Identified)
resolveModifier Modifier {name, value, sourceSpan} = do
  metadata <- resolveBareVariable name
  value' <- resolveExpression value
  pure
    Modifier
      { name = identifiedNameRef metadata name,
        value = value',
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Expression
-- ---------------------------------------------------------------------------

resolveExpression :: Expression Parsed -> Identifier (Expression Identified)
resolveExpression = \case
  ExpressionLiteral expression -> ExpressionLiteral <$> resolveLiteralExpr expression
  ExpressionVariable expression -> resolveVariableExpr expression
  ExpressionTuple expression -> ExpressionTuple <$> resolveTupleExpr expression
  ExpressionArray expression -> ExpressionArray <$> resolveArrayExpr expression
  ExpressionCall expression -> ExpressionCall <$> resolveCallExpr expression
  ExpressionBinaryOperator expression -> ExpressionBinaryOperator <$> resolveBinaryExpr expression
  ExpressionUnaryOperator expression -> ExpressionUnaryOperator <$> resolveUnaryExpr expression
  ExpressionIf expression -> ExpressionIf <$> resolveIfExpr expression
  ExpressionMatch expression -> ExpressionMatch <$> resolveMatchExpr expression
  ExpressionFor expression -> ExpressionFor <$> resolveForExpr expression
  ExpressionBlock expression -> ExpressionBlock <$> resolveBlockExpr expression
  ExpressionFieldAccess expression -> resolveFieldAccess expression
  ExpressionIndexAccess expression -> ExpressionIndexAccess <$> resolveIndexExpr expression
  ExpressionTemplate expression -> ExpressionTemplate <$> resolveTemplateExpr expression
  ExpressionQualifiedReference _ ->
    -- The parser never produces this constructor on a Parsed AST. Treat it
    -- as an internal invariant violation and crash loudly.
    error "Identifier: ExpressionQualifiedReference encountered in Parsed AST"

resolveLiteralExpr :: LiteralExpression Parsed -> Identifier (LiteralExpression Identified)
resolveLiteralExpr LiteralExpression {value, sourceSpan} =
  pure
    LiteralExpression
      { value = value,
        sourceSpan = sourceSpan,
        typeOf = ()
      }

-- | A bare variable expression. May resolve to a constructor function, agent,
-- req, parameter, or local let binding.
resolveVariableExpr :: VariableExpression Parsed -> Identifier (Expression Identified)
resolveVariableExpr VariableExpression {name, sourceSpan} = do
  metadata <- resolveBareVariable name
  pure
    ( ExpressionVariable
        VariableExpression
          { name = identifiedNameRef metadata name,
            sourceSpan = sourceSpan,
            typeOf = ()
          }
    )

resolveTupleExpr :: TupleExpression Parsed -> Identifier (TupleExpression Identified)
resolveTupleExpr TupleExpression {elements, sourceSpan} = do
  elements' <- mapM resolveExpression elements
  pure
    TupleExpression
      { elements = elements',
        sourceSpan = sourceSpan,
        typeOf = ()
      }

resolveArrayExpr :: ArrayExpression Parsed -> Identifier (ArrayExpression Identified)
resolveArrayExpr ArrayExpression {elements, sourceSpan} = do
  elements' <- mapM resolveExpression elements
  pure
    ArrayExpression
      { elements = elements',
        sourceSpan = sourceSpan,
        typeOf = ()
      }

resolveCallExpr :: CallExpression Parsed -> Identifier (CallExpression Identified)
resolveCallExpr CallExpression {callee, arguments, sourceSpan} = do
  callee' <- resolveExpression callee
  arguments' <- mapM resolveCallArgument arguments
  pure
    CallExpression
      { callee = callee',
        arguments = arguments',
        sourceSpan = sourceSpan,
        typeOf = ()
      }

resolveCallArgument :: CallArgument Parsed -> Identifier (CallArgument Identified)
resolveCallArgument CallArgument {label, value, sourceSpan} = do
  value' <- resolveExpression value
  pure
    CallArgument
      { label = labelRef label,
        value = value',
        sourceSpan = sourceSpan
      }

resolveBinaryExpr :: BinaryOperatorExpression Parsed -> Identifier (BinaryOperatorExpression Identified)
resolveBinaryExpr BinaryOperatorExpression {operator, left, right, sourceSpan} = do
  left' <- resolveExpression left
  right' <- resolveExpression right
  pure
    BinaryOperatorExpression
      { operator = operator,
        left = left',
        right = right',
        sourceSpan = sourceSpan,
        typeOf = ()
      }

resolveUnaryExpr :: UnaryOperatorExpression Parsed -> Identifier (UnaryOperatorExpression Identified)
resolveUnaryExpr UnaryOperatorExpression {operator, operand, sourceSpan} = do
  operand' <- resolveExpression operand
  pure
    UnaryOperatorExpression
      { operator = operator,
        operand = operand',
        sourceSpan = sourceSpan,
        typeOf = ()
      }

resolveIfExpr :: IfExpression Parsed -> Identifier (IfExpression Identified)
resolveIfExpr IfExpression {condition, thenBlock, elseBlock, sourceSpan} = do
  condition' <- resolveExpression condition
  thenBlock' <- resolveBlock thenBlock
  elseBlock' <- traverse resolveBlock elseBlock
  pure
    IfExpression
      { condition = condition',
        thenBlock = thenBlock',
        elseBlock = elseBlock',
        sourceSpan = sourceSpan,
        typeOf = ()
      }

resolveMatchExpr :: MatchExpression Parsed -> Identifier (MatchExpression Identified)
resolveMatchExpr MatchExpression {subject, cases, sourceSpan} = do
  subject' <- resolveExpression subject
  cases' <- mapM resolveCaseArm cases
  pure
    MatchExpression
      { subject = subject',
        cases = cases',
        sourceSpan = sourceSpan,
        typeOf = ()
      }

-- | Case arm: pattern bindings are visible only inside the arm body, so we
-- introduce a fresh scope frame around it.
resolveCaseArm :: CaseArm Parsed -> Identifier (CaseArm Identified)
resolveCaseArm CaseArm {pattern, body, sourceSpan} = withScopeFrame $ do
  pattern' <- resolvePattern pattern
  body' <- resolveBlock body
  pure CaseArm {pattern = pattern', body = body', sourceSpan = sourceSpan}

-- | A @for@ loop. Source expressions of in-bindings are resolved in the
-- outer scope; the patterns and var-bindings introduce a fresh frame in which
-- the body and then-block are resolved.
resolveForExpr :: ForExpression Parsed -> Identifier (ForExpression Identified)
resolveForExpr ForExpression {inBindings, varBindings, body, thenBlock, sourceSpan} = do
  -- Resolve source expressions in the outer scope.
  inBindingsResolvedSources <-
    mapM
      ( \ForInBinding {pattern, source, sourceSpan = bindingSourceSpan} -> do
          source' <- resolveExpression source
          pure (pattern, source', bindingSourceSpan)
      )
      inBindings
  withScopeFrame $ do
    -- Bind patterns and var-bindings in the fresh frame.
    inBindings' <-
      mapM
        ( \(parsedPattern, source, bindingSourceSpan) -> do
            pattern' <- resolvePattern parsedPattern
            pure ForInBinding {pattern = pattern', source = source, sourceSpan = bindingSourceSpan}
        )
        inBindingsResolvedSources
    varBindings' <- mapM resolveForVarBinding varBindings
    body' <- resolveBlock body
    thenBlock' <- traverse resolveBlock thenBlock
    pure
      ForExpression
        { inBindings = inBindings',
          varBindings = varBindings',
          body = body',
          thenBlock = thenBlock',
          sourceSpan = sourceSpan,
          typeOf = ()
        }

-- | For var binding follows ML-style let semantics: the initializer is
-- resolved before the name is bound.
resolveForVarBinding :: ForVarBinding Parsed -> Identifier (ForVarBinding Identified)
resolveForVarBinding ForVarBinding {name, typeAnnotation, initial, sourceSpan} = do
  typeAnnotation' <- traverse resolveType typeAnnotation
  initial' <- resolveExpression initial
  name' <- bindLocalVariable name
  pure
    ForVarBinding
      { name = name',
        typeAnnotation = typeAnnotation',
        initial = initial',
        sourceSpan = sourceSpan
      }

resolveBlockExpr :: BlockExpression Parsed -> Identifier (BlockExpression Identified)
resolveBlockExpr BlockExpression {block, sourceSpan} = do
  block' <- resolveBlock block
  pure
    BlockExpression
      { block = block',
        sourceSpan = sourceSpan,
        typeOf = ()
      }

-- | Core of field-access handling. Peel the @a.b.c@ chain; if the deepest
-- segment is a 'VariableExpression', dispatch on whether it resolves to a
-- variable or module (the ordering of preference) and possibly rebuild the
-- chain into a 'QualifiedReferenceExpression'. Non-variable heads keep the
-- whole chain as 'FieldAccess'.
resolveFieldAccess :: FieldAccessExpression Parsed -> Identifier (Expression Identified)
resolveFieldAccess fieldExpr =
  case peelFieldChain (ExpressionFieldAccess fieldExpr) of
    (VariableHead headRef, labels, totalSpan) ->
      resolveFieldChainHead headRef labels totalSpan
    (OtherHead innerExpr, labels, _) -> do
      -- Deepest segment is not a bare variable: keep the whole chain as
      -- field accesses.
      innerResolved <- resolveExpression innerExpr
      pure (rebuildFieldAccessChain innerResolved labels)

resolveIndexExpr :: IndexAccessExpression Parsed -> Identifier (IndexAccessExpression Identified)
resolveIndexExpr IndexAccessExpression {array, index, sourceSpan} = do
  array' <- resolveExpression array
  index' <- resolveExpression index
  pure
    IndexAccessExpression
      { array = array',
        index = index',
        sourceSpan = sourceSpan,
        typeOf = ()
      }

resolveTemplateExpr :: TemplateExpression Parsed -> Identifier (TemplateExpression Identified)
resolveTemplateExpr TemplateExpression {elements, sourceSpan} = do
  elements' <- mapM resolveTemplateElement elements
  pure
    TemplateExpression
      { elements = elements',
        sourceSpan = sourceSpan,
        typeOf = ()
      }

resolveTemplateElement :: TemplateElement Parsed -> Identifier (TemplateElement Identified)
resolveTemplateElement = \case
  TemplateElementString TemplateStringElement {value, sourceSpan} ->
    pure (TemplateElementString TemplateStringElement {value = value, sourceSpan = sourceSpan})
  TemplateElementExpression TemplateExpressionElement {value, sourceSpan} -> do
    value' <- resolveExpression value
    pure (TemplateElementExpression TemplateExpressionElement {value = value', sourceSpan = sourceSpan})

-- ---------------------------------------------------------------------------
-- Field access chain peeling
-- ---------------------------------------------------------------------------

-- | Classification of the deepest segment of a peeled chain.
data ChainHead
  = VariableHead (NameRef Parsed 'VariableRef)
  | OtherHead (Expression Parsed)

-- | Peel a left-associative field-access chain into its deepest expression
-- and the list of labels in source order. For @a.b.c@ this yields
-- (head=a, [b, c], totalSpan). The head is 'VariableHead' if it is a bare
-- 'VariableExpression', otherwise 'OtherHead'.
peelFieldChain ::
  Expression Parsed ->
  (ChainHead, [NameRef Parsed 'LabelRef], SourceSpan)
peelFieldChain entryExpression =
  let (chainHead, labels, totalSpan) = go entryExpression []
   in (chainHead, labels, totalSpan)
  where
    go currentExpression accumulatedLabels = case currentExpression of
      ExpressionFieldAccess fieldAccess ->
        go fieldAccess.object (fieldAccess.fieldName : accumulatedLabels)
      ExpressionVariable variableExpression ->
        (VariableHead variableExpression.name, accumulatedLabels, sourceSpanOf entryExpression)
      _ -> (OtherHead currentExpression, accumulatedLabels, sourceSpanOf entryExpression)

-- | Rebuild a left-folding chain of 'FieldAccess' expressions on top of an
-- inner expression.
rebuildFieldAccessChain ::
  Expression Identified ->
  [NameRef Parsed 'LabelRef] ->
  Expression Identified
rebuildFieldAccessChain = foldl' step
  where
    step inner label =
      let mergedSpan =
            SrcSpan
              { filePath = (sourceSpanOf inner).filePath,
                start = (sourceSpanOf inner).start,
                end = label.sourceSpan.end
              }
       in ExpressionFieldAccess
            FieldAccessExpression
              { object = inner,
                fieldName = labelRef label,
                sourceSpan = mergedSpan,
                typeOf = ()
              }

-- | Drive the resolution of a chain whose head is a bare variable name.
-- If the head resolves to a variable, the whole chain is kept as field
-- accesses (labels deferred to the typechecker). If it resolves to a module,
-- the first label is interpreted as a qualified reference and any remaining
-- labels are kept as field accesses on top.
resolveFieldChainHead ::
  NameRef Parsed 'VariableRef ->
  [NameRef Parsed 'LabelRef] ->
  SourceSpan ->
  Identifier (Expression Identified)
resolveFieldChainHead headRef labels totalSpan = do
  maybeVariableId <- lookupVariable headRef.text
  case maybeVariableId of
    Just variableId ->
      -- Head is a variable: keep the whole chain as field access.
      pure (rebuildFieldAccessChain (varExpr (Just variableId)) labels)
    Nothing -> do
      maybeModuleId <- lookupModule headRef.text
      case maybeModuleId of
        Just moduleId -> resolveModuleQualifiedChain moduleId headRef labels totalSpan
        Nothing -> do
          -- Undefined: emit error and tag the head as Unresolved so downstream
          -- phases can see that resolution failed.
          emitError (ErrorUndefinedName headRef.sourceSpan headRef.text)
          pure (rebuildFieldAccessChain (varExpr Nothing) labels)
  where
    varExpr resolution =
      ExpressionVariable
        VariableExpression
          { name = identifiedNameRef resolution headRef,
            sourceSpan = headRef.sourceSpan,
            typeOf = ()
          }

-- | A @module . ...@ chain. The first label is folded into a
-- 'QualifiedReferenceExpression'; any remaining labels become field accesses.
resolveModuleQualifiedChain ::
  ModuleId ->
  NameRef Parsed 'VariableRef ->
  [NameRef Parsed 'LabelRef] ->
  SourceSpan ->
  Identifier (Expression Identified)
resolveModuleQualifiedChain moduleId moduleRef labels totalSpan =
  case labels of
    -- The only call site is 'resolveFieldChainHead', which itself is only
    -- reached via 'resolveFieldAccess' on an 'ExpressionFieldAccess' — that
    -- guarantees at least one label was peeled. A bare 'ExpressionVariable'
    -- never enters this code path.
    [] -> error "resolveModuleQualifiedChain: labels must be non-empty"
    (target : remainingLabels) -> do
      maybeVariableId <- lookupModuleExportVariable moduleId target.text
      variableMetadata <- case maybeVariableId of
        Just variableId -> pure (Just variableId)
        Nothing -> do
          emitError (ErrorUndefinedQualified target.sourceSpan moduleRef.text target.text)
          pure Nothing
      let qualifiedReferenceSpan =
            SrcSpan
              { filePath = totalSpan.filePath,
                start = moduleRef.sourceSpan.start,
                end = target.sourceSpan.end
              }
          -- Re-tag the LabelRef as a VariableRef while preserving text/span.
          targetVariableRef =
            NameRef
              { text = target.text,
                sourceSpan = target.sourceSpan,
                resolution = variableMetadata
              }
          moduleNameRef =
            NameRef
              { text = moduleRef.text,
                sourceSpan = moduleRef.sourceSpan,
                resolution = Just moduleId
              }
          qualifiedReference =
            ExpressionQualifiedReference
              QualifiedReferenceExpression
                { moduleQualifier = moduleNameRef,
                  target = targetVariableRef,
                  sourceSpan = qualifiedReferenceSpan,
                  typeOf = ()
                }
      pure (rebuildFieldAccessChain qualifiedReference remainingLabels)

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

-- | Entry point. Runs the four phases over a set of modules and returns
-- both a (possibly partial) 'IdentifierResult' and any accumulated errors.
--
-- The result is *always* produced — unresolved references show up as
-- @IdentifiedUnresolved*@ markers in the AST, allowing downstream phases
-- (e.g. type inference) to continue with a fresh type variable instead of
-- aborting on the first name-resolution failure. Callers that want the
-- old fail-fast behaviour can branch on @null errors@.
identify :: Map Text (Module Parsed) -> (IdentifierResult, [IdentifierError])
identify moduleMap =
  let (asts, finalState) =
        runIdentifier $ do
          moduleNameToId <- assignModuleIds moduleMap
          exports <- buildExports moduleMap
          topLevels <- buildTopLevels moduleNameToId exports moduleMap
          resolveModule topLevels moduleNameToId exports moduleMap
      result =
        IdentifierResult
          { identifiedModules = finalState.modules,
            identifiedVariables = finalState.variables,
            identifiedTypes = finalState.types,
            identifiedRequests = finalState.requests,
            identifiedConstructors = finalState.constructors,
            moduleASTs = asts,
            topLevelVariablesByQName = finalState.variableQNames,
            typesByQName = finalState.typeQNames,
            requestsByQName = finalState.requestQNames,
            constructorsByQName = finalState.constructorQNames
          }
   in (result, reverse finalState.errors)
