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
    SymbolEntry (..),
    ModuleData (..),
    VariableData (..),
    TypeData (..),
    RequestData (..),
    ConstructorData (..),
    IdentifierError (..),

    -- * Diagnostics
    toDiagnostic,

    -- * Per-module identification
    ModuleIdentifyResult (..),
    IdentifierState (..),
    initialIdentifierState,
    identifyModule,
    runIdentifier,
    runIdentifierFrom,

    -- * Import-cycle detection
    importCycleErrors,
  )
where

import Control.Monad (foldM, when)
import Control.Monad.State.Strict (State, get, gets, modify, put, runState)
import Data.Foldable (foldl')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Katari.AST
import Katari.Diagnostic (Diagnostic (..), DiagnosticNote (..), diagnosticError)
import Katari.Id
  ( LocalVarId (..),
    QualifiedName (..),
    VariableResolution (..),
  )
import Katari.Internal qualified as Internal
import Katari.Prim (PrimRule)
import Katari.Prim qualified as Prim
import Katari.SourceSpan (HasSourceSpan (..), SourceSpan (..))
import Katari.Typechecker.ImportGraph (findImportCycles)
import Katari.Typechecker.ScopeIndex (ScopeFrame (..))

-- ---------------------------------------------------------------------------
-- Identified GADT
--
-- Top-level declarations are identified by 'QualifiedName' and local
-- bindings by 'LocalVarId' (both wrapped in 'VariableResolution'). These
-- live in 'Katari.Id' so that 'Katari.AST' and 'Katari.SemanticType' can
-- both depend on them without a circular import.
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
-- The 'Identified' phase carries 'NameRefResolution Identified s' for name
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
--     'ErrorDuplicateName'. (exeptions: shadwing)
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
  { variableSymbol :: Maybe VariableResolution,
    typeSymbol :: Maybe QualifiedName,
    moduleSymbol :: Maybe Text,
    requestSymbol :: Maybe QualifiedName,
    constructorSymbol :: Maybe QualifiedName
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

singletonVariable :: VariableResolution -> SymbolEntry
singletonVariable resolution = emptySymbolEntry {variableSymbol = Just resolution}

singletonType :: QualifiedName -> SymbolEntry
singletonType qualifiedName = emptySymbolEntry {typeSymbol = Just qualifiedName}

singletonModule :: Text -> SymbolEntry
singletonModule moduleName = emptySymbolEntry {moduleSymbol = Just moduleName}

-- ---------------------------------------------------------------------------
-- Result tables
-- ---------------------------------------------------------------------------

-- | Identifier-pass metadata for one module. Keyed by module name ('Text')
-- in 'IdentifierResult.identifiedModules'; lets later phases (and the
-- LSP) recover the file-level source span for go-to-definition / hover
-- on a module identifier.
data ModuleData = ModuleData
  { moduleSourceSpan :: SourceSpan
  }
  deriving (Eq, Show)

-- | Metadata for a top-level callable (agent / req / ext / ctor's value side).
-- Keyed by 'QualifiedName' in 'IdentifierResult.identifiedVariables'. Local
-- variables are not stored in this map (they use 'LocalVarId' only).
data VariableData = VariableData
  { variableName :: Text,
    variableSourceSpan :: SourceSpan,
    -- | Set on the variable issued for a 'DeclarationPrimAgent' when its
    -- @using@ clause names a known 'PrimRule'. Read by the constraint
    -- generator to apply operand-aware return typing at call sites.
    -- 'Nothing' for ordinary variables and prims without a @using@ clause.
    variablePrimRule :: Maybe PrimRule,
    -- | The @\@"..."@ annotation on the top-level declaration that
    -- introduced this variable, or 'Nothing' for decls without an
    -- annotation. Schema generation reads this directly so it can be
    -- decl-kind-agnostic (every top-level callable, regardless of whether
    -- it was @agent@ / @ext agent@ / @prim agent@ / @req@ / @data@,
    -- exposes its annotation here).
    variableAnnotation :: Maybe Text,
    -- | Per-parameter @\@"..."@ annotations in source order. Empty for
    -- parameter-less decls. Schema generation maps these to the JSON
    -- Schema @description@ field on each property.
    variableParameterAnnotations :: [(Text, Maybe Text)]
  }
  deriving (Eq, Show)

-- | Metadata for a type (data / type synonym). Keyed by 'QualifiedName'
-- in 'IdentifierResult.identifiedTypes'. The 'typeId' is the semantic
-- identifier used by 'SemanticTypeData' and the constraint solver.
data TypeData = TypeData
  { typeSourceSpan :: SourceSpan,
    typeSynonymRhs :: Maybe (SyntacticType Identified)
  }
  deriving (Eq, Show)

-- | Metadata for a @req@ declaration. Keyed by 'QualifiedName' in
-- 'IdentifierResult.identifiedRequests'. The 'requestId' is the semantic
-- identifier used by 'SemanticEffect' and the bidirectional checker. The
-- request's call-side type lives in the type environment under the same
-- 'QualifiedName' (via 'ResolvedTopLevel'), so no separate variable
-- pointer is needed.
data RequestData = RequestData
  { requestSourceSpan :: SourceSpan,
    requestParameterAnnotations :: Map Text (Maybe Text)
  }
  deriving (Eq, Show)

-- | Metadata for a data constructor. Keyed by 'QualifiedName' in
-- 'IdentifierResult.identifiedConstructors'. The 'constructorId' is the
-- semantic identifier used by 'CtorTag' in exhaustiveness checking and
-- the IR. 'constructorTypeQName' points to the corresponding data type's
-- 'QualifiedName' so downstream phases can recover the data type.
data ConstructorData = ConstructorData
  { constructorSourceSpan :: SourceSpan,
    constructorTypeQName :: QualifiedName
  }
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

-- | Errors raised by the Identifier (name-resolution + import) pass.
-- Each variant carries enough context — the offending 'SourceSpan',
-- the bare name, and any colliding definition site — to render a
-- self-contained diagnostic without re-walking the AST. Codes
-- K0100-K0199 are reserved for this phase; see 'toDiagnostic' for the
-- mapping.
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
  -- | An import cycle was detected. The list contains every module name in the
  -- cycle. The diagnostic span points at the first module in the list.
  ErrorImportCycle :: SourceSpan -> [Text] -> IdentifierError
  -- | A name appears in @req@ handler position but does not name a @req@
  -- declaration (or names nothing at all).
  ErrorNotARequest :: SourceSpan -> Text -> IdentifierError
  -- | A name appears in match-pattern constructor position but does not name
  -- a @data@ declaration (or names nothing at all).
  ErrorNotAConstructor :: SourceSpan -> Text -> IdentifierError
  -- | An @ext agent@ declaration has no @\@\"...\"@ annotation (which serves as
  -- the server identifier).
  ErrorMissingExternalAgentAnnotation :: SourceSpan -> Text -> IdentifierError
  -- | An @ext agent@ declaration's @\@\"...\"@ annotation is empty or whitespace.
  ErrorEmptyExternalAgentAnnotation :: SourceSpan -> Text -> IdentifierError
  -- | A @prim agent ... using <name>@ declaration's @<name>@ is not one
  -- of the special typing rules the compiler knows about (currently
  -- @numeric_join_binary@ / @numeric_join_unary@). Carries the source
  -- span of the declaration and the offending rule name.
  ErrorUnknownPrimRule :: SourceSpan -> Text -> IdentifierError
  -- | A variable / wildcard pattern carried a type annotation
  -- (@case y: integer => ...@) inside a refutable position (match arm).
  -- This is rejected because Katari has no runtime type-narrowing for
  -- non-tagged scalars — the annotation would either be redundant or
  -- silently lie about the bound variable's runtime type. For
  -- type-directed narrowing, use a tagged @data@ union.
  ErrorPatternTypeAnnotation :: SourceSpan -> IdentifierError
  -- | A user definition collided with a built-in primitive name (root
  -- prim flat-injected into every module's top-level scope, or an
  -- alias module from @prim.\<sub\>@).
  ErrorPrimitiveConflict :: SourceSpan -> Text -> IdentifierError
  -- | The user tried to declare a module under the reserved @prim@ /
  -- @prim.*@ namespace.
  ErrorReservedPrimitiveModule :: SourceSpan -> Text -> IdentifierError
  -- | A 'K9999' invariant violation (compiler bug). Wraps a fully-formed
  -- 'Diagnostic' produced by 'Katari.Internal' so it surfaces in the
  -- diagnostic stream without panicking the host.
  ErrorInternal :: Diagnostic -> IdentifierError

deriving instance Show IdentifierError

deriving instance Eq IdentifierError

instance HasSourceSpan IdentifierError where
  sourceSpanOf = \case
    ErrorDuplicateName sourceSpan _ _ -> sourceSpan
    ErrorShadowNonVariable sourceSpan _ -> sourceSpan
    ErrorUndefinedName sourceSpan _ -> sourceSpan
    ErrorUndefinedQualified sourceSpan _ _ -> sourceSpan
    ErrorNotAType sourceSpan _ -> sourceSpan
    ErrorNotAModule sourceSpan _ -> sourceSpan
    ErrorImportNameNotFound sourceSpan _ _ -> sourceSpan
    ErrorImportModuleNotFound sourceSpan _ -> sourceSpan
    ErrorImportCycle sourceSpan _ -> sourceSpan
    ErrorNotARequest sourceSpan _ -> sourceSpan
    ErrorNotAConstructor sourceSpan _ -> sourceSpan
    ErrorMissingExternalAgentAnnotation sourceSpan _ -> sourceSpan
    ErrorEmptyExternalAgentAnnotation sourceSpan _ -> sourceSpan
    ErrorUnknownPrimRule sourceSpan _ -> sourceSpan
    ErrorPatternTypeAnnotation sourceSpan -> sourceSpan
    ErrorPrimitiveConflict sourceSpan _ -> sourceSpan
    ErrorReservedPrimitiveModule sourceSpan _ -> sourceSpan
    ErrorInternal diagnostic -> diagnostic.span

-- | Convert an 'IdentifierError' to a unified 'Diagnostic'. Codes
-- K0100-K0199 are reserved for the identifier pass.
toDiagnostic :: IdentifierError -> Diagnostic
toDiagnostic = \case
  ErrorDuplicateName sourceSpan name firstSourceSpan ->
    let base = diagnosticError "K0100" ("duplicate definition of '" <> name <> "'") sourceSpan
     in base
          { notes =
              [ DiagnosticNote
                  { span = firstSourceSpan,
                    message = "first defined here"
                  }
              ]
          }
  ErrorShadowNonVariable sourceSpan name ->
    diagnosticError
      "K0101"
      ("'" <> name <> "' shadows a non-variable binding (modules/types cannot be shadowed)")
      sourceSpan
  ErrorUndefinedName sourceSpan name ->
    diagnosticError "K0102" ("undefined name '" <> name <> "'") sourceSpan
  ErrorUndefinedQualified sourceSpan moduleName memberName ->
    diagnosticError
      "K0103"
      ("module '" <> moduleName <> "' does not export '" <> memberName <> "'")
      sourceSpan
  ErrorNotAType sourceSpan name ->
    diagnosticError
      "K0104"
      ("'" <> name <> "' is not a type")
      sourceSpan
  ErrorNotAModule sourceSpan name ->
    diagnosticError
      "K0105"
      ("'" <> name <> "' is not a module")
      sourceSpan
  ErrorImportNameNotFound sourceSpan moduleName memberName ->
    diagnosticError
      "K0106"
      ("import: '" <> memberName <> "' is not exported by module '" <> moduleName <> "'")
      sourceSpan
  ErrorImportModuleNotFound sourceSpan moduleName ->
    diagnosticError
      "K0107"
      ("import: module '" <> moduleName <> "' not found")
      sourceSpan
  ErrorImportCycle sourceSpan modules ->
    let rendered = case modules of
          (m : _) -> T.intercalate " → " (modules <> [m])
          [] -> ""
     in diagnosticError "K0110" ("import cycle: " <> rendered) sourceSpan
  ErrorNotARequest sourceSpan name ->
    diagnosticError
      "K0108"
      ("'" <> name <> "' is not a request (only @req@ declarations can be handled)")
      sourceSpan
  ErrorNotAConstructor sourceSpan name ->
    diagnosticError
      "K0109"
      ("'" <> name <> "' is not a data constructor")
      sourceSpan
  ErrorMissingExternalAgentAnnotation sourceSpan name ->
    diagnosticError
      "K0150"
      ("external agent '" <> name <> "' requires a @\"server\" annotation (server identifier)")
      sourceSpan
  ErrorEmptyExternalAgentAnnotation sourceSpan name ->
    diagnosticError
      "K0151"
      ("external agent '" <> name <> "' has an empty @\"\" annotation (server identifier must not be blank)")
      sourceSpan
  ErrorUnknownPrimRule sourceSpan ruleName ->
    diagnosticError
      "K0152"
      ("prim agent uses unknown 'using' rule: '" <> ruleName <> "' (known rules: numeric_join_binary, numeric_join_unary, fstring_join)")
      sourceSpan
  ErrorPatternTypeAnnotation sourceSpan ->
    diagnosticError
      "K0160"
      "type annotation on a match pattern is not supported (Katari has no runtime type narrowing for non-tagged values; use a tagged `data` union if you need to discriminate)"
      sourceSpan
  ErrorPrimitiveConflict sourceSpan name ->
    diagnosticError
      "K0112"
      ("'" <> name <> "' conflicts with a built-in primitive name")
      sourceSpan
  ErrorReservedPrimitiveModule sourceSpan name ->
    diagnosticError
      "K0113"
      ("module name '" <> name <> "' is reserved for the primitive namespace")
      sourceSpan
  ErrorInternal diagnostic -> diagnostic

-- ---------------------------------------------------------------------------
-- Identifier monad
-- ---------------------------------------------------------------------------

data IdentifierState = IdentifierState
  { nextLocalVarId :: Int,
    variables :: Map QualifiedName VariableData,
    types :: Map QualifiedName TypeData,
    modules :: Map Text ModuleData,
    requests :: Map QualifiedName RequestData,
    constructors :: Map QualifiedName ConstructorData,
    errors :: [IdentifierError],
    resolveContext :: ResolveContext,
    -- | Captured (span, innermost-frame-symbols) pairs. Each
    -- 'withScopeFrameAt' invocation pushes one entry on exit. The
    -- raw list is grouped into a 'ScopeIndex' by the caller.
    capturedScopeFrames :: [(SourceSpan, Map Text SymbolEntry)]
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
    moduleExports :: Map Text (Map Text SymbolEntry)
  }

emptyResolveContext :: ResolveContext
emptyResolveContext =
  ResolveContext
    { scopeStack = [],
      moduleExports = Map.empty
    }

type Identifier a = State IdentifierState a

runIdentifier :: Identifier a -> (a, IdentifierState)
runIdentifier = runIdentifierFrom initialIdentifierState

initialIdentifierState :: IdentifierState
initialIdentifierState =
  IdentifierState
    { nextLocalVarId = 0,
      variables = Map.empty,
      types = Map.empty,
      modules = Map.empty,
      requests = Map.empty,
      constructors = Map.empty,
      errors = [],
      resolveContext = emptyResolveContext,
      capturedScopeFrames = []
    }

runIdentifierFrom :: IdentifierState -> Identifier a -> (a, IdentifierState)
runIdentifierFrom state action = runState action state

-- ---------------------------------------------------------------------------
-- ID issuing helpers
-- ---------------------------------------------------------------------------

registerTopLevelVariable :: QualifiedName -> VariableData -> Identifier ()
registerTopLevelVariable qualifiedName variableData = do
  state <- get
  case Map.lookup qualifiedName state.variables of
    Just existing ->
      emitError (ErrorDuplicateName variableData.variableSourceSpan qualifiedName.name existing.variableSourceSpan)
    Nothing -> pure ()
  modify $ \state' -> state' {variables = Map.insert qualifiedName variableData state'.variables}

freshLocalVarId :: Identifier LocalVarId
freshLocalVarId = do
  state <- get
  let localVarId = LocalVarId state.nextLocalVarId
  put state {nextLocalVarId = state.nextLocalVarId + 1}
  pure localVarId

registerType :: QualifiedName -> TypeData -> Identifier ()
registerType qualifiedName typeData = do
  existingTypes <- gets (.types)
  case Map.lookup qualifiedName existingTypes of
    Just existing ->
      emitError (ErrorDuplicateName typeData.typeSourceSpan qualifiedName.name existing.typeSourceSpan)
    Nothing -> pure ()
  modify $ \state -> state {types = Map.insert qualifiedName typeData state.types}

registerRequest :: QualifiedName -> RequestData -> Identifier ()
registerRequest qualifiedName requestData =
  modify $ \state ->
    state {requests = Map.insert qualifiedName requestData state.requests}

registerConstructor :: QualifiedName -> ConstructorData -> Identifier ()
registerConstructor qualifiedName constructorData =
  modify $ \state ->
    state {constructors = Map.insert qualifiedName constructorData state.constructors}

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
    reportFromVariable :: VariableResolution -> Identifier ()
    reportFromVariable = \case
      ResolvedTopLevel qualifiedName -> do
        maybeSpan <- gets (fmap (.variableSourceSpan) . Map.lookup qualifiedName . (.variables))
        maybe (pure ()) (emitError . ErrorDuplicateName newPos name) maybeSpan
      ResolvedLocal _ -> pure ()
    reportFromType :: QualifiedName -> Identifier ()
    reportFromType qualifiedName = do
      maybeSpan <- gets (fmap (.typeSourceSpan) . Map.lookup qualifiedName . (.types))
      maybe (pure ()) (emitError . ErrorDuplicateName newPos name) maybeSpan
    reportFromModule :: Text -> Identifier ()
    reportFromModule moduleName = do
      maybeSpan <- gets (fmap (.moduleSourceSpan) . Map.lookup moduleName . (.modules))
      maybe (pure ()) (emitError . ErrorDuplicateName newPos name) maybeSpan
    reportFromRequest :: QualifiedName -> Identifier ()
    reportFromRequest qualifiedName = do
      maybeSpan <- gets (fmap (.requestSourceSpan) . Map.lookup qualifiedName . (.requests))
      maybe (pure ()) (emitError . ErrorDuplicateName newPos name) maybeSpan
    reportFromConstructor :: QualifiedName -> Identifier ()
    reportFromConstructor qualifiedName = do
      maybeSpan <- gets (fmap (.constructorSourceSpan) . Map.lookup qualifiedName . (.constructors))
      maybe (pure ()) (emitError . ErrorDuplicateName newPos name) maybeSpan

-- | Generic per-slot merge. The first existing id wins on conflict; the
-- caller's @reportConflict@ records the duplicate-name error against it.
-- If @existing@ and @new@ refer to the same id (e.g. a redundant
-- @import "primitive"@ on top of the implicit primitive injection), the merge is
-- a no-op rather than a duplicate-name error.
mergeSlot ::
  (Eq a) =>
  (a -> Identifier ()) ->
  Maybe a ->
  Maybe a ->
  Identifier (Maybe a)
mergeSlot _ existing Nothing = pure existing
mergeSlot _ Nothing newSlot = pure newSlot
mergeSlot reportConflict (Just existingId) (Just newId)
  | existingId == newId = pure (Just existingId)
  | otherwise = do
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
--     innermost frame first, so they are requestively shadowed.
--   * Each slot (variable / type / module) is independent: a local variable
--     binding does not hide an outer frame's @typeSymbol@ for the same name.
--   * The only forbidden shadow is when any frame in the chain has a
--     @moduleSymbol@ for this name. Allowing that would silently change the
--     meaning of @name.foo@ from a qualified module reference to a field
--     access on a local variable.
bindLocalVariable :: NameRef Parsed VariableRef -> Identifier (NameRef Identified VariableRef)
bindLocalVariable nameRef = do
  context <- gets (.resolveContext)
  let name = nameRef.text
  when (chainHasModule name context.scopeStack) $
    emitError (ErrorShadowNonVariable nameRef.sourceSpan name)
  primShadow <- isShadowingPrim name
  when primShadow $
    emitError (ErrorShadowNonVariable nameRef.sourceSpan name)
  localVarId <- freshLocalVarId
  let resolution = ResolvedLocal localVarId
  modifyResolveContext $ \currentContext ->
    currentContext {scopeStack = insertInnermost name resolution currentContext.scopeStack}
  pure (identifiedNameRef (Just resolution) nameRef)
  where
    -- Module bindings only ever appear in the top-level frame (imports are
    -- top-level only), but we walk the full stack defensively so that the
    -- check remains correct if that invariant ever changes.
    chainHasModule searchName = any (\frame -> isJust (Map.lookup searchName frame >>= (.moduleSymbol)))
    -- Local scope frames contain only variable bindings (type and module
    -- declarations are top-level only), so overwriting the entire SymbolEntry
    -- with singletonVariable is safe and does not discard other slots.
    insertInnermost insertName resolution = \case
      [] -> [Map.singleton insertName (singletonVariable resolution)]
      (innermost : remaining) -> Map.insert insertName (singletonVariable resolution) innermost : remaining

-- | Push a fresh empty frame, run the action, then pop the frame.
-- Right before popping, snapshot the innermost frame together with the
-- given source span into 'capturedScopeFrames' so the LSP / completion
-- query layer can later answer "what is visible at position P?".
--
-- If the stack is unexpectedly empty when popping (compiler bug), emit
-- a 'K9999' internal-error diagnostic via 'ErrorInternal' and skip the
-- pop instead of panicking.
withScopeFrameAt :: SourceSpan -> Identifier a -> Identifier a
withScopeFrameAt span_ action = do
  modifyResolveContext $ \context -> context {scopeStack = Map.empty : context.scopeStack}
  result <- action
  scope <- gets ((.scopeStack) . (.resolveContext))
  case scope of
    (innermost : _) -> do
      modify $ \state ->
        state {capturedScopeFrames = (span_, innermost) : state.capturedScopeFrames}
      modifyResolveContext $ \context ->
        context {scopeStack = drop 1 context.scopeStack}
    [] ->
      emitError $
        ErrorInternal $
          Internal.internalErrorNoSpan
            "withScopeFrameAt: scope stack underflow (compiler bug)"
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

lookupVariable :: Text -> Identifier (Maybe VariableResolution)
lookupVariable = lookupSlot (.variableSymbol)

lookupType :: Text -> Identifier (Maybe QualifiedName)
lookupType = lookupSlot (.typeSymbol)

lookupModule :: Text -> Identifier (Maybe Text)
lookupModule = lookupSlot (.moduleSymbol)

lookupRequest :: Text -> Identifier (Maybe QualifiedName)
lookupRequest = lookupSlot (.requestSymbol)

lookupConstructor :: Text -> Identifier (Maybe QualifiedName)
lookupConstructor = lookupSlot (.constructorSymbol)

-- | Look up a variable by name, returning its resolution directly.
lookupVariableResolution :: Text -> Identifier (Maybe VariableResolution)
lookupVariableResolution = lookupVariable

-- | Look up the variable slot of @name@ in the export table of @moduleName@.
lookupModuleExportVariable :: Text -> Text -> Identifier (Maybe VariableResolution)
lookupModuleExportVariable = lookupModuleExportSlot (.variableSymbol)

-- | Look up the type slot of @name@ in the export table of @moduleName@.
lookupModuleExportType :: Text -> Text -> Identifier (Maybe QualifiedName)
lookupModuleExportType = lookupModuleExportSlot (.typeSymbol)

lookupModuleExportRequest :: Text -> Text -> Identifier (Maybe QualifiedName)
lookupModuleExportRequest = lookupModuleExportSlot (.requestSymbol)

lookupModuleExportConstructor :: Text -> Text -> Identifier (Maybe QualifiedName)
lookupModuleExportConstructor = lookupModuleExportSlot (.constructorSymbol)

lookupModuleExportSlot ::
  (SymbolEntry -> Maybe a) ->
  Text ->
  Text ->
  Identifier (Maybe a)
lookupModuleExportSlot getSlot moduleName name = do
  context <- gets (.resolveContext)
  pure $ do
    table <- Map.lookup moduleName context.moduleExports
    entry <- Map.lookup name table
    getSlot entry

-- | True if @name@ is the bare name of an operator-desugar target prim
-- (e.g. @add@, @eq@, @neg@). Local bindings that shadow such a name are
-- rejected with K0101 because the user-facing semantics of @a + b@
-- would silently flip between operator-prim and a local binding.
--
-- We only need to protect operator-targeted names — other prim names
-- (e.g. @get_metadata@) can be safely shadowed since they have no
-- syntactic-sugar reliance.
operatorPrimNameSet :: Set Text
operatorPrimNameSet =
  Set.fromList $
    [Prim.binaryOperatorPrimName op | op <- [minBound .. maxBound]]
      ++ [Prim.unaryOperatorPrimName op | op <- [minBound .. maxBound]]

isShadowingPrim :: Text -> Identifier Bool
isShadowingPrim name = pure (Set.member name operatorPrimNameSet)

-- ---------------------------------------------------------------------------
-- NameRef helpers
-- ---------------------------------------------------------------------------

-- | Replace just the @resolution@ of a 'NameRef', keeping @text@ and @sourceSpan@.
identifiedNameRef ::
  NameRefResolution Identified symbol ->
  NameRef Parsed symbol ->
  NameRef Identified symbol
identifiedNameRef resolution nameRef =
  NameRef {text = nameRef.text, sourceSpan = nameRef.sourceSpan, resolution = resolution}

labelRef :: NameRef Parsed LabelRef -> NameRef Identified LabelRef
labelRef = identifiedNameRef ()

-- ---------------------------------------------------------------------------
-- Module-name helper
-- ---------------------------------------------------------------------------

-- | Extract @"module"@ from @"path.to.module"@. Returns the empty string if
-- given an empty input (the parser should never produce one, but this guards
-- against it anyway).
moduleNameTail :: Text -> Text
moduleNameTail path =
  case reverse (T.splitOn "." path) of
    [] -> path
    (lastSegment : _) -> lastSegment

-- ---------------------------------------------------------------------------
-- Phase D: resolve a single module's AST
-- ---------------------------------------------------------------------------

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
  DeclarationPrimAgent declaration -> DeclarationPrimAgent <$> resolvePrimAgent declaration
  DeclarationData declaration -> DeclarationData <$> resolveData declaration
  DeclarationTypeSynonym declaration -> DeclarationTypeSynonym <$> resolveTypeSynonym declaration
  DeclarationImport declaration -> pure (DeclarationImport declaration)
  -- Parser-recovery sentinel: passthrough unchanged. The parallel
  -- @[ParseError]@ list keeps the structured error detail; this phase has
  -- nothing to resolve here.
  DeclarationError sourceSpan -> pure (DeclarationError sourceSpan)

-- | Fill in the variable id for a signature-position 'NameRef' (the @name@ of
-- an agent / req / ext-agent / data declaration). Phase B has already issued
-- the id; this just looks it up. If lookup fails (only possible when Phase B
-- emitted a duplicate-name error), record an unresolved marker rather than
-- inventing a sentinel id.
liftSignatureVariable :: NameRef Parsed VariableRef -> Identifier (NameRef Identified VariableRef)
liftSignatureVariable = liftSignature lookupVariableResolution

-- | Counterpart of 'liftSignatureVariable' for type signatures (enum / data
-- type role / type synonym name).
liftSignatureType :: NameRef Parsed TypeRef -> Identifier (NameRef Identified TypeRef)
liftSignatureType = liftSignature lookupType

liftSignatureRequest :: NameRef Parsed RequestRef -> Identifier (NameRef Identified RequestRef)
liftSignatureRequest = liftSignature lookupRequest

liftSignatureConstructor :: NameRef Parsed ConstructorRef -> Identifier (NameRef Identified ConstructorRef)
liftSignatureConstructor = liftSignature lookupConstructor

-- | Shared lookup-and-wrap helper for signature-position 'NameRef's.
-- Phase B has already issued the id; here we just look it up and tag the
-- node with either the resolved id or 'Nothing' (lookup miss is recorded
-- separately as an 'IdentifierError').
liftSignature ::
  (Text -> Identifier (NameRefResolution Identified sym)) ->
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
resolveSignatureBody parameters returnType withRequests body =
  -- The signature frame covers the body block — that is where param
  -- references typically occur. Param bindings shown by completion at
  -- any position inside the body.
  withScopeFrameAt body.sourceSpan $ do
    parameters' <- mapM resolveParameter parameters
    returnType' <- traverse resolveType returnType
    withRequests' <- traverse (mapM resolveSyntacticRequest) withRequests
    body' <- resolveBlock body
    pure (parameters', returnType', withRequests', body')

resolveAgent :: AgentDeclaration Parsed -> Identifier (AgentDeclaration Identified)
resolveAgent AgentDeclaration {..} = do
  name' <- liftSignatureVariable name
  (parameters', returnType', withRequests', body') <- resolveSignatureBody parameters returnType withRequests body
  pure
    AgentDeclaration
      { annotation = annotation,
        name = name',
        parameters = parameters',
        returnType = returnType',
        withRequests = withRequests',
        body = body',
        sourceSpan = sourceSpan
      }

resolveRequest :: RequestDeclaration Parsed -> Identifier (RequestDeclaration Identified)
resolveRequest RequestDeclaration {..} = do
  name' <- liftSignatureVariable name
  reqestName' <- liftSignatureRequest requestName
  withScopeFrameAt sourceSpan $ do
    parameters' <- mapM resolveParameter parameters
    returnType' <- resolveType returnType
    pure
      RequestDeclaration
        { annotation = annotation,
          name = name',
          requestName = reqestName',
          parameters = parameters',
          returnType = returnType',
          sourceSpan = sourceSpan
        }

resolveExternalAgent :: ExternalAgentDeclaration Parsed -> Identifier (ExternalAgentDeclaration Identified)
resolveExternalAgent ExternalAgentDeclaration {..} = do
  name' <- liftSignatureVariable name
  case annotation of
    Nothing -> emitError (ErrorMissingExternalAgentAnnotation sourceSpan name.text)
    Just t | T.null (T.strip t) -> emitError (ErrorEmptyExternalAgentAnnotation sourceSpan name.text)
    _ -> pure ()
  withScopeFrameAt sourceSpan $ do
    parameters' <- mapM resolveParameter parameters
    returnType' <- resolveType returnType
    withRequests' <- mapM resolveSyntacticRequest withRequests
    pure
      ExternalAgentDeclaration
        { annotation = annotation,
          name = name',
          parameters = parameters',
          returnType = returnType',
          withRequests = withRequests',
          endpoint = endpoint,
          dispatchName = dispatchName,
          sourceSpan = sourceSpan
        }

-- | Resolve a @prim agent@ declaration. Mirrors 'resolveExternalAgent'
-- but additionally validates the optional @using@ clause and stamps the
-- decoded 'PrimRule' onto the bound 'VariableData'.
resolvePrimAgent :: PrimAgentDeclaration Parsed -> Identifier (PrimAgentDeclaration Identified)
resolvePrimAgent PrimAgentDeclaration {..} = do
  name' <- liftSignatureVariable name
  -- Decode the @using@ rule (if any) and validate; an unknown rule name
  -- is reported but doesn't abort. Then attach the rule to the
  -- 'VariableData' so the constraint generator can consult it at call sites.
  primRule <- case using of
    Nothing -> pure Nothing
    Just ruleName -> case Prim.parsePrimRule ruleName of
      Just rule -> pure (Just rule)
      Nothing -> do
        emitError (ErrorUnknownPrimRule sourceSpan ruleName)
        pure Nothing
  -- Look up the QualifiedName internally to patch the VariableData.
  maybeResolution <- lookupVariable name.text
  case maybeResolution of
    Just (ResolvedTopLevel qualifiedName) -> modify $ \s ->
      s
        { variables =
            Map.adjust
              (\vd -> vd {variablePrimRule = primRule})
              qualifiedName
              s.variables
        }
    _ -> pure ()
  withScopeFrameAt sourceSpan $ do
    parameters' <- mapM resolveParameter parameters
    returnType' <- resolveType returnType
    withRequests' <- mapM resolveSyntacticRequest withRequests
    pure
      PrimAgentDeclaration
        { annotation = annotation,
          name = name',
          parameters = parameters',
          returnType = returnType',
          withRequests = withRequests',
          using = using,
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
  constructorName' <- liftSignatureConstructor constructorName
  parameters' <- mapM resolveDataParameter parameters
  pure
    DataDeclaration
      { annotation = annotation,
        name = name',
        constructorName = constructorName',
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
  -- Look up the QualifiedName internally to patch the TypeData.
  maybeQualifiedName <- lookupType name.text
  case maybeQualifiedName of
    Just qualifiedName -> updateTypeSynonymRhs qualifiedName rhs'
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
updateTypeSynonymRhs :: QualifiedName -> SyntacticType Identified -> Identifier ()
updateTypeSynonymRhs qualifiedName rhs = modify $ \state ->
  state
    { types =
        Map.adjust
          (\typeData -> typeData {typeSynonymRhs = Just rhs})
          qualifiedName
          state.types
    }

-- ---------------------------------------------------------------------------
-- Parameter / Pattern
-- ---------------------------------------------------------------------------

resolveParameter :: ParameterBinding Parsed -> Identifier (ParameterBinding Identified)
resolveParameter ParameterBinding {annotation, name, typeAnnotation, defaultValue, sourceSpan} = do
  name' <- bindLocalVariable name
  typeAnnotation' <- traverse resolveType typeAnnotation
  pure
    ParameterBinding
      { annotation = annotation,
        name = name',
        typeAnnotation = typeAnnotation',
        defaultValue = defaultValue,
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
  PatternType parsedPattern -> PatternType <$> resolveTypePattern parsedPattern
  PatternRecord parsedPattern -> PatternRecord <$> resolveRecordPattern parsedPattern

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

resolveTypePattern :: TypePattern Parsed -> Identifier (TypePattern Identified)
resolveTypePattern TypePattern {..} = do
  inner' <- resolvePattern inner
  pure
    TypePattern
      { typeTag = typeTag,
        inner = inner',
        sourceSpan = sourceSpan,
        typeOf = ()
      }

resolveRecordPattern :: RecordPattern Parsed -> Identifier (RecordPattern Identified)
resolveRecordPattern RecordPattern {..} = do
  entries' <-
    mapM
      (\(entryLabel, entryPattern) -> (entryLabel,) <$> resolvePattern entryPattern)
      entries
  pure
    RecordPattern
      { entries = entries',
        sourceSpan = sourceSpan,
        typeOf = ()
      }

-- | Resolve either a bare @name@ or a qualified @module.name@ as a variable
-- reference. Used by constructor patterns and request handler names.
--
-- All sub-resolvers return an 'Identified' marker (resolved id or the
-- corresponding @Unresolved@) so that the AST always carries a faithful trace
-- of the resolution outcome instead of a fabricated id.
resolveBareVariable :: NameRef Parsed VariableRef -> Identifier (NameRefResolution Identified VariableRef)
resolveBareVariable nameRef =
  lookupVariable nameRef.text >>= \case
    Just resolution -> pure (Just resolution)
    Nothing -> do
      emitError (ErrorUndefinedName nameRef.sourceSpan nameRef.text)
      pure Nothing

-- | Resolve @[module.]name@ as a request reference (handler position). The
-- bare name must occupy the request slot of an in-scope binding; otherwise
-- 'ErrorNotARequest' (or 'ErrorUndefinedName' if the name is unknown
-- entirely) is recorded.
resolveQualifiedRequestRef ::
  Maybe (NameRef Parsed ModuleRef) ->
  NameRef Parsed RequestRef ->
  Identifier (Maybe (NameRef Identified ModuleRef), NameRef Identified RequestRef)
resolveQualifiedRequestRef = \cases
  Nothing nameRef -> do
    metadata <- resolveBareRequest nameRef
    pure (Nothing, identifiedNameRef metadata nameRef)
  (Just moduleRef) nameRef -> do
    maybeModuleName <- lookupModule moduleRef.text
    moduleMetadata <- case maybeModuleName of
      Just _ -> pure (Just moduleRef.text)
      Nothing -> do
        emitError (ErrorNotAModule moduleRef.sourceSpan moduleRef.text)
        pure Nothing
    metadata <- case maybeModuleName of
      Just moduleName -> resolveQualifiedRequest moduleName moduleRef.text nameRef
      Nothing -> pure Nothing
    pure
      ( Just (identifiedNameRef moduleMetadata moduleRef),
        identifiedNameRef metadata nameRef
      )

resolveBareRequest :: NameRef Parsed RequestRef -> Identifier (NameRefResolution Identified RequestRef)
resolveBareRequest nameRef =
  lookupRequest nameRef.text >>= \case
    Just qualifiedName -> pure (Just qualifiedName)
    Nothing -> do
      -- Distinguish "name does not exist" from "name exists but is not a
      -- request". The former is a generic K0102, the latter K0108.
      lookupVariable nameRef.text >>= \case
        Just _ -> emitError (ErrorNotARequest nameRef.sourceSpan nameRef.text)
        Nothing -> emitError (ErrorUndefinedName nameRef.sourceSpan nameRef.text)
      pure Nothing

resolveQualifiedRequest ::
  Text ->
  Text ->
  NameRef Parsed RequestRef ->
  Identifier (NameRefResolution Identified RequestRef)
resolveQualifiedRequest moduleName qualifierName nameRef =
  lookupModuleExportRequest moduleName nameRef.text >>= \case
    Just qualifiedName -> pure (Just qualifiedName)
    Nothing -> do
      emitError (ErrorUndefinedQualified nameRef.sourceSpan qualifierName nameRef.text)
      pure Nothing

-- | Resolve @[module.]name@ as a constructor reference (match-pattern
-- position). The bare name must occupy the constructor slot of an in-scope
-- binding.
resolveQualifiedConstructorRef ::
  Maybe (NameRef Parsed ModuleRef) ->
  NameRef Parsed ConstructorRef ->
  Identifier (Maybe (NameRef Identified ModuleRef), NameRef Identified ConstructorRef)
resolveQualifiedConstructorRef = \cases
  Nothing nameRef -> do
    metadata <- resolveBareConstructor nameRef
    pure (Nothing, identifiedNameRef metadata nameRef)
  (Just moduleRef) nameRef -> do
    maybeModuleName <- lookupModule moduleRef.text
    moduleMetadata <- case maybeModuleName of
      Just _ -> pure (Just moduleRef.text)
      Nothing -> do
        emitError (ErrorNotAModule moduleRef.sourceSpan moduleRef.text)
        pure Nothing
    metadata <- case maybeModuleName of
      Just moduleName -> resolveQualifiedConstructor moduleName moduleRef.text nameRef
      Nothing -> pure Nothing
    pure
      ( Just (identifiedNameRef moduleMetadata moduleRef),
        identifiedNameRef metadata nameRef
      )

resolveBareConstructor ::
  NameRef Parsed ConstructorRef ->
  Identifier (NameRefResolution Identified ConstructorRef)
resolveBareConstructor nameRef =
  lookupConstructor nameRef.text >>= \case
    Just qualifiedName -> pure (Just qualifiedName)
    Nothing -> do
      lookupVariable nameRef.text >>= \case
        Just _ -> emitError (ErrorNotAConstructor nameRef.sourceSpan nameRef.text)
        Nothing -> emitError (ErrorUndefinedName nameRef.sourceSpan nameRef.text)
      pure Nothing

resolveQualifiedConstructor ::
  Text ->
  Text ->
  NameRef Parsed ConstructorRef ->
  Identifier (NameRefResolution Identified ConstructorRef)
resolveQualifiedConstructor moduleName qualifierName nameRef =
  lookupModuleExportConstructor moduleName nameRef.text >>= \case
    Just qualifiedName -> pure (Just qualifiedName)
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
  -- never / unknown / function carry only a sourceSpan; phase change is mechanical.
  TypeNever NeverTypeNode {sourceSpan} ->
    pure (TypeNever NeverTypeNode {sourceSpan = sourceSpan})
  TypeUnknown UnknownTypeNode {sourceSpan} ->
    pure (TypeUnknown UnknownTypeNode {sourceSpan = sourceSpan})
  TypeFunctionAny FunctionAnyTypeNode {sourceSpan} ->
    pure (TypeFunctionAny FunctionAnyTypeNode {sourceSpan = sourceSpan})
  TypeRecord RecordTypeNode {valueType, sourceSpan} -> do
    valueType' <- resolveType valueType
    pure
      ( TypeRecord
          RecordTypeNode
            { valueType = valueType',
              sourceSpan = sourceSpan
            }
      )
  TypeObject ObjectTypeNode {fields, sourceSpan} -> do
    fields' <- mapM (\(label, fieldType) -> (label,) <$> resolveType fieldType) fields
    pure
      ( TypeObject
          ObjectTypeNode
            { fields = fields',
              sourceSpan = sourceSpan
            }
      )
  where
    rebuildPrimitive PrimitiveTypeNode {kind, sourceSpan} =
      PrimitiveTypeNode {kind = kind, sourceSpan = sourceSpan}

resolveTypeName :: TypeNameNode Parsed -> Identifier (TypeNameNode Identified)
resolveTypeName TypeNameNode {name, sourceSpan} = do
  metadata <-
    lookupType name.text >>= \case
      Just qualifiedName -> pure (Just qualifiedName)
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
  maybeModuleName <- lookupModule qualifier.text
  moduleMetadata <- case maybeModuleName of
    Just _ -> pure (Just qualifier.text)
    Nothing -> do
      emitError (ErrorNotAModule qualifier.sourceSpan qualifier.text)
      pure Nothing
  typeMetadata <- case maybeModuleName of
    Just moduleName ->
      lookupModuleExportType moduleName target.text >>= \case
        Just qualifiedName -> pure (Just qualifiedName)
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
resolveFunctionType FunctionTypeNode {parameterTypes, returnType, withRequests, sourceSpan} = do
  parameterTypes' <- mapM (\(label, parameterType) -> (label,) <$> resolveType parameterType) parameterTypes
  returnType' <- resolveType returnType
  withRequests' <- mapM resolveSyntacticRequest withRequests
  pure
    FunctionTypeNode
      { parameterTypes = parameterTypes',
        returnType = returnType',
        withRequests = withRequests',
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
  metadata <- resolveBareRequest name
  pure
    SyntacticRequest
      { name = identifiedNameRef metadata name,
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Block / Statement
-- ---------------------------------------------------------------------------

-- | A block introduces a fresh scope frame for its statements and return
-- expression. Bindings declared in the block are not visible outside it.
resolveBlock :: Block Parsed -> Identifier (Block Identified)
resolveBlock Block {statements, returnExpression, sourceSpan} = do
  (statements', returnExpression') <- withScopeFrameAt sourceSpan $ do
    resolvedStatements <- mapM resolveStatement statements
    resolvedReturnExpression <- traverse resolveExpression returnExpression
    pure (resolvedStatements, resolvedReturnExpression)
  pure
    Block
      { statements = statements',
        returnExpression = returnExpression',
        sourceSpan = sourceSpan
      }

-- | Resolve a handle expression. The body (continuation) is resolved in the
-- current scope. State variables, handlers, and the then clause are resolved
-- in their own sub-frame (state vars visible to handlers and then, but not
-- to the body).
resolveHandleExpr :: HandleExpression Parsed -> Identifier (HandleExpression Identified)
resolveHandleExpr HandleExpression {parallel, stateVariables, handlers, thenClause, body, sourceSpan} = do
  -- Body resolves in the OUTER scope (before handle's internal frame).
  body' <- resolveBlock body
  -- Handle internals in their own frame (state vars visible to handlers/then, not body).
  (stateVariables', handlers', thenClause') <- withScopeFrameAt sourceSpan $ do
    stateVariables' <- mapM resolveStateVariable stateVariables
    handlers' <- mapM resolveRequestHandler handlers
    -- The @then@ clause shares the handle's frame, so it sees state vars.
    -- Its own pattern + block introduce a nested frame for the destructured
    -- pattern bindings.
    thenClause' <-
      traverse
        ( \(maybePattern, block) -> withScopeFrameAt block.sourceSpan $ do
            maybePattern' <- traverse resolvePattern maybePattern
            block' <- resolveBlock block
            pure (maybePattern', block')
        )
        thenClause
    pure (stateVariables', handlers', thenClause')
  pure
    HandleExpression
      { parallel = parallel,
        stateVariables = stateVariables',
        handlers = handlers',
        thenClause = thenClause',
        body = body',
        sourceSpan = sourceSpan,
        typeOf = ()
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
-- Handlers do not carry their own @with@ clause: requests raised inside the
-- handler bind to the surrounding agent, so handler-level request annotation
-- is not part of the syntax.
resolveRequestHandler :: RequestHandler Parsed -> Identifier (RequestHandler Identified)
resolveRequestHandler RequestHandler {moduleQualifier, name, parameters, returnType, body, sourceSpan} = do
  (moduleQualifier', name') <- resolveQualifiedRequestRef moduleQualifier name
  (parameters', returnType', _noRequests, body') <- resolveSignatureBody parameters returnType Nothing body
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
  StatementError sourceSpan -> pure (StatementError sourceSpan)

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
resolveAgentStatement AgentStatement {annotation, name, parameters, returnType, withRequests, body, sourceSpan} = do
  name' <- bindLocalVariable name
  (parameters', returnType', withRequests', body') <- resolveSignatureBody parameters returnType withRequests body
  pure
    AgentStatement
      { annotation = annotation,
        name = name',
        parameters = parameters',
        returnType = returnType',
        withRequests = withRequests',
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
  ExpressionRecord expression -> ExpressionRecord <$> resolveRecordExpr expression
  ExpressionCall expression -> ExpressionCall <$> resolveCallExpr expression
  ExpressionBinaryOperator expression -> resolveBinaryOperatorAsCall expression
  ExpressionUnaryOperator expression -> resolveUnaryOperatorAsCall expression
  ExpressionIf expression -> ExpressionIf <$> resolveIfExpr expression
  ExpressionMatch expression -> ExpressionMatch <$> resolveMatchExpr expression
  ExpressionFor expression -> ExpressionFor <$> resolveForExpr expression
  ExpressionBlock expression -> ExpressionBlock <$> resolveBlockExpr expression
  ExpressionFieldAccess expression -> resolveFieldAccess expression
  ExpressionIndexAccess expression -> ExpressionIndexAccess <$> resolveIndexExpr expression
  ExpressionTemplate expression -> ExpressionTemplate <$> resolveTemplateExpr expression
  ExpressionHandle expression -> ExpressionHandle <$> resolveHandleExpr expression
  ExpressionParTuple expression -> ExpressionParTuple <$> resolveParTupleExpr expression
  ExpressionQualifiedReference qref -> do
    -- The parser never produces this constructor on a Parsed AST.
    -- Surface as a 'K9999' invariant-violation diagnostic and fall
    -- back to an unresolved bare-variable expression so downstream
    -- phases can keep walking the tree.
    emitError $
      ErrorInternal $
        Internal.internalError
          qref.sourceSpan
          "Identifier: ExpressionQualifiedReference encountered in Parsed AST (parser invariant violation)"
    pure $
      ExpressionVariable
        VariableExpression
          { name = identifiedNameRef Nothing qref.target,
            sourceSpan = qref.sourceSpan,
            typeOf = ()
          }

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

resolveRecordExpr :: RecordExpression Parsed -> Identifier (RecordExpression Identified)
resolveRecordExpr RecordExpression {entries, sourceSpan} = do
  entries' <- mapM (\(lbl, e) -> (lbl,) <$> resolveExpression e) entries
  pure
    RecordExpression
      { entries = entries',
        sourceSpan = sourceSpan,
        typeOf = ()
      }

resolveParTupleExpr :: ParTupleExpression Parsed -> Identifier (ParTupleExpression Identified)
resolveParTupleExpr ParTupleExpression {elements, sourceSpan} = do
  elements' <- mapM resolveExpression elements
  pure
    ParTupleExpression
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

-- | Desugar a binary operator into a call to the matching root prim.
-- @a \<op\> b@ becomes @add(lhs=a, rhs=b)@ (or whichever prim matches
-- 'binaryOperatorPrimName'). The synthesised callee 'NameRef' carries
-- the prim's pre-allocated 'VariableResolution' so the constraint generator
-- and lowering can dispatch as if the user wrote @add(...)@ directly.
resolveBinaryOperatorAsCall ::
  BinaryOperatorExpression Parsed -> Identifier (Expression Identified)
resolveBinaryOperatorAsCall BinaryOperatorExpression {operator, left, right, sourceSpan} = do
  left' <- resolveExpression left
  right' <- resolveExpression right
  let primName = Prim.binaryOperatorPrimName operator
  metadata <- lookupPrimVariable primName
  -- Narrow span for the synthetic callee: the gap between operands
  -- (where the operator token actually sits). Keeps hover / diagnostics
  -- anchored on the @+@ instead of swallowing the whole expression.
  let operatorSpan =
        SrcSpan
          sourceSpan.filePath
          (sourceSpanOf left').end
          (sourceSpanOf right').start
  pure (mkPrimCall primName metadata sourceSpan operatorSpan [("lhs", left'), ("rhs", right')])

-- | Desugar a unary operator into a call to the matching root prim
-- (@!x@ → @not(value=x)@; @-x@ → @neg(value=x)@).
resolveUnaryOperatorAsCall ::
  UnaryOperatorExpression Parsed -> Identifier (Expression Identified)
resolveUnaryOperatorAsCall UnaryOperatorExpression {operator, operand, sourceSpan} = do
  operand' <- resolveExpression operand
  let primName = Prim.unaryOperatorPrimName operator
  metadata <- lookupPrimVariable primName
  let operatorSpan =
        SrcSpan
          sourceSpan.filePath
          sourceSpan.start
          (sourceSpanOf operand').start
  pure (mkPrimCall primName metadata sourceSpan operatorSpan [("value", operand')])

-- | Look up a root prim's 'VariableResolution' from the preregistered map.
-- Missing entries indicate a compiler bug (every operator name in
-- 'Prim.binaryOperatorPrimName' / 'Prim.unaryOperatorPrimName' must be
-- present in 'Prim.primDefinitions') and are surfaced as a K9999.
lookupPrimVariable :: Text -> Identifier (NameRefResolution Identified VariableRef)
lookupPrimVariable primName =
  -- Operator desugaring runs inside the module body, where the root prims
  -- have been flat-injected into the top-level scope. Resolve through the
  -- scope (not a global variable registry) so per-module identification
  -- sees the prim even though it lives in another module's variable map.
  lookupVariable primName >>= \case
    Just resolution -> pure (Just resolution)
    Nothing -> do
      emitError $
        ErrorInternal $
          Internal.internalErrorNoSpan
            ("Identifier: prim '" <> primName <> "' not in scope (compiler bug)")
      pure Nothing

-- | Build a synthesised 'ExpressionCall' targeting a root prim.
--
--   * @outerSpan@: the original operator expression's full span. Used
--     for the outer 'CallExpression' and for diagnostics that fire on
--     the whole expression.
--   * @operatorSpan@: the narrow span covering just the operator token (= the
--     gap between operands for binary, leading prefix for unary). Used
--     for the synthetic callee and label spans so hover / go-to-def on
--     the operator anchors to its source location, not to the whole
--     expression.
--   * Each @arg.value@ keeps its own real span, and @arg.sourceSpan@
--     mirrors that so the CallArgument doesn't shadow the operand on
--     position queries.
mkPrimCall ::
  Text ->
  NameRefResolution Identified VariableRef ->
  SourceSpan ->
  SourceSpan ->
  [(Text, Expression Identified)] ->
  Expression Identified
mkPrimCall primName metadata outerSpan operatorSpan arguments =
  ExpressionCall
    CallExpression
      { callee =
          ExpressionVariable
            VariableExpression
              { name =
                  NameRef
                    { text = primName,
                      sourceSpan = operatorSpan,
                      resolution = metadata
                    },
                sourceSpan = operatorSpan,
                typeOf = ()
              },
        arguments =
          [ CallArgument
              { label =
                  NameRef
                    { text = label,
                      sourceSpan = operatorSpan,
                      resolution = ()
                    },
                value = value,
                sourceSpan = sourceSpanOf value
              }
            | (label, value) <- arguments
          ],
        sourceSpan = outerSpan,
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
resolveCaseArm CaseArm {pattern, body, sourceSpan} = do
  rejectPatternAnnotations pattern
  withScopeFrameAt sourceSpan $ do
    pattern' <- resolvePattern pattern
    body' <- resolveBlock body
    pure CaseArm {pattern = pattern', body = body', sourceSpan = sourceSpan}

-- | Walk a match-arm pattern and emit 'ErrorPatternTypeAnnotation' for
-- every variable / wildcard sub-pattern that carries an explicit type
-- annotation. Match arms must dispatch by structure (constructor /
-- tuple / literal); a type annotation on a variable or wildcard there
-- has no runtime effect and would silently mislead about the bound
-- variable's actual runtime type.
rejectPatternAnnotations :: Pattern Parsed -> Identifier ()
rejectPatternAnnotations = \case
  PatternVariable vp ->
    when (isJust vp.typeAnnotation) $
      emitError (ErrorPatternTypeAnnotation vp.sourceSpan)
  PatternWildcard wp ->
    when (isJust wp.typeAnnotation) $
      emitError (ErrorPatternTypeAnnotation wp.sourceSpan)
  PatternTuple tp -> mapM_ rejectPatternAnnotations tp.elements
  PatternQualifiedConstructor qp ->
    mapM_ (rejectPatternAnnotations . snd) qp.parameters
  PatternLiteral _ -> pure ()
  PatternType tp -> rejectPatternAnnotations tp.inner
  PatternRecord rp -> mapM_ (rejectPatternAnnotations . snd) rp.entries

-- | A @for@ loop. Source expressions of in-bindings are resolved in the
-- outer scope; the patterns and var-bindings introduce a fresh frame in which
-- the body and then-block are resolved.
resolveForExpr :: ForExpression Parsed -> Identifier (ForExpression Identified)
resolveForExpr ForExpression {parallel, inBindings, varBindings, body, thenBlock, sourceSpan} = do
  -- Resolve source expressions in the outer scope.
  inBindingsResolvedSources <-
    mapM
      ( \ForInBinding {pattern, source, sourceSpan = bindingSourceSpan} -> do
          source' <- resolveExpression source
          pure (pattern, source', bindingSourceSpan)
      )
      inBindings
  withScopeFrameAt sourceSpan $ do
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
        { parallel = parallel,
          inBindings = inBindings',
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
  = VariableHead (NameRef Parsed VariableRef)
  | OtherHead (Expression Parsed)

-- | Peel a left-associative field-access chain into its deepest expression
-- and the list of labels in source order. For @a.b.c@ this yields
-- (head=a, [b, c], totalSpan). The head is 'VariableHead' if it is a bare
-- 'VariableExpression', otherwise 'OtherHead'.
peelFieldChain ::
  Expression Parsed ->
  (ChainHead, [NameRef Parsed LabelRef], SourceSpan)
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
  [NameRef Parsed LabelRef] ->
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
  NameRef Parsed VariableRef ->
  [NameRef Parsed LabelRef] ->
  SourceSpan ->
  Identifier (Expression Identified)
resolveFieldChainHead headRef labels totalSpan = do
  maybeResolution <- lookupVariable headRef.text
  case maybeResolution of
    Just resolution -> do
      -- Head is a variable: keep the whole chain as field access.
      pure (rebuildFieldAccessChain (varExpr (Just resolution)) labels)
    Nothing -> do
      maybeModuleName <- lookupModule headRef.text
      case maybeModuleName of
        Just moduleName -> resolveModuleQualifiedChain moduleName headRef labels totalSpan
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
  Text ->
  NameRef Parsed VariableRef ->
  [NameRef Parsed LabelRef] ->
  SourceSpan ->
  Identifier (Expression Identified)
resolveModuleQualifiedChain moduleName moduleRef labels totalSpan =
  case labels of
    -- The only call site is 'resolveFieldChainHead', which itself is only
    -- reached via 'resolveFieldAccess' on an 'ExpressionFieldAccess' — that
    -- guarantees at least one label was peeled. A bare 'ExpressionVariable'
    -- never enters this code path. If it ever does, surface a 'K9999'
    -- diagnostic and fall back to an unresolved bare-variable expression
    -- using the module name as the placeholder.
    [] -> do
      emitError $
        ErrorInternal $
          Internal.internalError
            totalSpan
            "resolveModuleQualifiedChain: labels must be non-empty (caller invariant violation)"
      pure $
        ExpressionVariable
          VariableExpression
            { name = identifiedNameRef Nothing moduleRef,
              sourceSpan = totalSpan,
              typeOf = ()
            }
    (target : remainingLabels) -> do
      maybeResolution <- lookupModuleExportVariable moduleName target.text
      variableMetadata <- case maybeResolution of
        Just resolution -> pure (Just resolution)
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
                resolution = Just moduleName
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
-- Per-module identification
-- ---------------------------------------------------------------------------

-- | Result of identifying one module independently. Because identification
-- runs from a fresh state, every @module*@ map holds only entries owned by
-- this module; the caller unions them across modules to build cross-module
-- views (e.g. 'Katari.Query.QuerySnapshot') without re-filtering.
data ModuleIdentifyResult = ModuleIdentifyResult
  { identifiedAST :: Module Identified,
    moduleData :: ModuleData,
    moduleVariables :: Map QualifiedName VariableData,
    moduleTypes :: Map QualifiedName TypeData,
    moduleRequests :: Map QualifiedName RequestData,
    moduleConstructors :: Map QualifiedName ConstructorData,
    moduleExportTable :: Map Text SymbolEntry,
    moduleTopLevel :: Map Text SymbolEntry,
    moduleScopeFrames :: [ScopeFrame SymbolEntry],
    moduleNewErrors :: [IdentifierError]
  }

-- | Identify a single module independently, from a fresh 'IdentifierState'
-- (the local-variable counter starts at 0). Runs the reserved-namespace
-- check (K0113), builds the export table, builds the top-level scope (own
-- exports + imports + prim injection), and resolves names in the body.
--
-- The caller supplies:
--
--   * @allModuleData@ — every module's 'ModuleData' (file span), so a
--     duplicate-name clash against an imported module name can cite its span.
--   * @depExportTables@ — export tables of the modules this one depends on
--     (its imports + the @primitive@ root); the module's own exports are
--     added internally for qualified self-references.
--   * @allModuleNames@ — every module name, for import-existence validation.
--   * @trustedStdlibNames@ — compiler-owned modules exempt from K0113.
--
-- Because the state is fresh, every entry in the returned maps belongs to
-- this module, so no cross-module filtering is needed.
identifyModule ::
  Map Text ModuleData ->
  Map Text (Map Text SymbolEntry) ->
  Set Text ->
  Set Text ->
  Text ->
  Module Parsed ->
  ModuleIdentifyResult
identifyModule allModuleData depExportTables allModuleNames trustedStdlibNames currentModuleName parsedModule =
  let ((identifiedModuleAST, exportTable, topLevelTable), finalState) =
        runIdentifierFrom (initialIdentifierState {modules = allModuleData}) $ do
          -- Reserved @prim@ / @prim.*@ namespace check (K0113), own module only.
          when
            ( Prim.isPrimReservedModuleName currentModuleName
                && not (Set.member currentModuleName trustedStdlibNames)
            )
            $ emitError (ErrorReservedPrimitiveModule parsedModule.sourceSpan currentModuleName)
          -- Phase B: build export table for this module.
          thisExportTable <- buildModuleExports currentModuleName parsedModule
          -- Phase C: build top-level scope (own exports + imports + prim injection).
          thisTopLevel <- buildModuleTopLevel allModuleNames depExportTables currentModuleName parsedModule thisExportTable
          -- Phase D: resolve names in the body. The module's own exports are
          -- visible alongside its dependencies (qualified self-references).
          let allExportsWithSelf = Map.insert currentModuleName thisExportTable depExportTables
              context =
                ResolveContext
                  { scopeStack = [thisTopLevel],
                    moduleExports = allExportsWithSelf
                  }
          identifiedAST' <- withResolveContext context (resolveModuleAST parsedModule)
          pure (identifiedAST', thisExportTable, thisTopLevel)
      moduleFrames =
        [ ScopeFrame {frameSpan = sp, frameSymbols = sym}
          | (sp, sym) <- finalState.capturedScopeFrames
        ]
   in ModuleIdentifyResult
        { identifiedAST = identifiedModuleAST,
          moduleData =
            Map.findWithDefault
              (ModuleData {moduleSourceSpan = parsedModule.sourceSpan})
              currentModuleName
              allModuleData,
          moduleVariables = finalState.variables,
          moduleTypes = finalState.types,
          moduleRequests = finalState.requests,
          moduleConstructors = finalState.constructors,
          moduleExportTable = exportTable,
          moduleTopLevel = topLevelTable,
          moduleScopeFrames = moduleFrames,
          moduleNewErrors = reverse finalState.errors
        }
  where
    -- Phase B for a single module: walk declarations and build the export table.
    buildModuleExports :: Text -> Module Parsed -> Identifier (Map Text SymbolEntry)
    buildModuleExports moduleName moduleAST =
      foldM (addDeclaration moduleName) Map.empty moduleAST.declarations

    addDeclaration moduleName table = \case
      DeclarationAgent declaration ->
        registerVariableDecl
          moduleName
          table
          declaration.name
          declaration.annotation
          (parameterBindingsToAnnotationPairs declaration.parameters)
      DeclarationRequest declaration ->
        registerRequestDecl
          moduleName
          table
          declaration.name
          declaration.annotation
          declaration.parameters
      DeclarationExternalAgent declaration ->
        registerVariableDecl
          moduleName
          table
          declaration.name
          declaration.annotation
          (parameterBindingsToAnnotationPairs declaration.parameters)
      DeclarationPrimAgent declaration ->
        registerVariableDecl
          moduleName
          table
          declaration.name
          declaration.annotation
          (parameterBindingsToAnnotationPairs declaration.parameters)
      DeclarationData declaration ->
        registerDataDecl
          moduleName
          table
          declaration.name
          declaration.annotation
          (dataParametersToAnnotationPairs declaration.parameters)
      DeclarationTypeSynonym declaration -> registerTypeOnly moduleName table declaration.name
      DeclarationImport _ -> pure table
      DeclarationError _ -> pure table

    qnameOf moduleName name = QualifiedName {module_ = moduleName, name = name.text}

    parameterBindingsToAnnotationPairs ps = [(p.name.text, p.annotation) | p <- ps]
    dataParametersToAnnotationPairs ps = [(p.name, p.annotation) | p <- ps]

    registerVariableDecl moduleName table name annotation parameterAnnotations = do
      let qualifiedName = qnameOf moduleName name
      registerTopLevelVariable
        qualifiedName
        VariableData
          { variableName = name.text,
            variableSourceSpan = name.sourceSpan,
            variablePrimRule = Nothing,
            variableAnnotation = annotation,
            variableParameterAnnotations = parameterAnnotations
          }
      insertSymbolEntry name.sourceSpan name.text (singletonVariable (ResolvedTopLevel qualifiedName)) table

    registerRequestDecl moduleName table name annotation parameters = do
      let qualifiedName = qnameOf moduleName name
          parameterAnnotations = parameterBindingsToAnnotationPairs parameters
      registerTopLevelVariable
        qualifiedName
        VariableData
          { variableName = name.text,
            variableSourceSpan = name.sourceSpan,
            variablePrimRule = Nothing,
            variableAnnotation = annotation,
            variableParameterAnnotations = parameterAnnotations
          }
      registerRequest
        qualifiedName
        RequestData
          { requestSourceSpan = name.sourceSpan,
            requestParameterAnnotations = Map.fromList parameterAnnotations
          }
      let entry =
            emptySymbolEntry
              { variableSymbol = Just (ResolvedTopLevel qualifiedName),
                requestSymbol = Just qualifiedName
              }
      insertSymbolEntry name.sourceSpan name.text entry table

    registerTypeOnly moduleName table name = do
      let qualifiedName = qnameOf moduleName name
      registerType
        qualifiedName
        TypeData
          { typeSourceSpan = name.sourceSpan,
            typeSynonymRhs = Nothing
          }
      insertSymbolEntry name.sourceSpan name.text (singletonType qualifiedName) table

    registerDataDecl moduleName table name annotation parameterAnnotations = do
      let qualifiedName = qnameOf moduleName name
      registerTopLevelVariable
        qualifiedName
        VariableData
          { variableName = name.text,
            variableSourceSpan = name.sourceSpan,
            variablePrimRule = Nothing,
            variableAnnotation = annotation,
            variableParameterAnnotations = parameterAnnotations
          }
      registerType
        qualifiedName
        TypeData
          { typeSourceSpan = name.sourceSpan,
            typeSynonymRhs = Nothing
          }
      registerConstructor
        qualifiedName
        ConstructorData
          { constructorSourceSpan = name.sourceSpan,
            constructorTypeQName = qualifiedName
          }
      let entry =
            emptySymbolEntry
              { variableSymbol = Just (ResolvedTopLevel qualifiedName),
                typeSymbol = Just qualifiedName,
                constructorSymbol = Just qualifiedName
              }
      insertSymbolEntry name.sourceSpan name.text entry table

    -- Phase C for a single module: merge own exports + imports + prim injection.
    buildModuleTopLevel ::
      Set Text ->
      Map Text (Map Text SymbolEntry) ->
      Text ->
      Module Parsed ->
      Map Text SymbolEntry ->
      Identifier (Map Text SymbolEntry)
    buildModuleTopLevel moduleNames allExports modName moduleAST ownExports = do
      base <-
        if modName == "primitive"
          then pure ownExports
          else
            injectPrimitives
              (Prim.isPrimReservedModuleName modName)
              moduleAST.sourceSpan
              ownExports
              moduleNames
              allExports
      foldM (addImport moduleNames allExports) base moduleAST.declarations

    injectPrimitives ::
      Bool ->
      SourceSpan ->
      Map Text SymbolEntry ->
      Set Text ->
      Map Text (Map Text SymbolEntry) ->
      Identifier (Map Text SymbolEntry)
    injectPrimitives isStdlibSubModule moduleSourceSpan userTable moduleNames allExports = do
      let rootExports = Map.findWithDefault Map.empty "primitive" allExports
      base <- foldM (injectOne isStdlibSubModule moduleSourceSpan) userTable (Map.toList rootExports)
      if isStdlibSubModule
        then pure base
        else foldM (injectSubModule moduleSourceSpan) base (Set.toList moduleNames)

    injectSubModule ::
      SourceSpan ->
      Map Text SymbolEntry ->
      Text ->
      Identifier (Map Text SymbolEntry)
    injectSubModule moduleSourceSpan table fullName =
      case T.stripPrefix "primitive." fullName of
        Nothing -> pure table
        Just tail_
          | T.any (== '.') tail_ -> pure table
          | otherwise ->
              insertSymbolEntry
                moduleSourceSpan
                tail_
                (singletonModule fullName)
                table

    injectOne ::
      Bool ->
      SourceSpan ->
      Map Text SymbolEntry ->
      (Text, SymbolEntry) ->
      Identifier (Map Text SymbolEntry)
    injectOne isStdlibSubModule moduleSourceSpan table (name, primEntry) =
      case Map.lookup name table of
        -- A stdlib sub-module may legitimately declare a name that also
        -- exists as a root flat prim (e.g. @primitive.array@'s @concat@ vs
        -- the root @concat@). Its own declaration shadows the injected root
        -- name inside its scope; only user modules are barred from this.
        Just _
          | isStdlibSubModule -> pure table
          | otherwise -> do
              emitError (ErrorPrimitiveConflict moduleSourceSpan name)
              pure table
        Nothing -> pure (Map.insert name primEntry table)

    addImport moduleNames allExports table = \case
      DeclarationImport importDeclaration -> resolveImport moduleNames allExports table importDeclaration
      _ -> pure table

    resolveImport moduleNames allExports table importDeclaration =
      case importDeclaration.kind of
        ImportModule {moduleName, alias} ->
          resolveImportModule moduleNames importDeclaration.sourceSpan moduleName alias table
        ImportNames {items, moduleName} ->
          resolveImportNames moduleNames allExports importDeclaration.sourceSpan moduleName items table

    resolveImportModule moduleNames importPos written maybeAlias table =
      if not (Set.member written moduleNames)
        then do
          emitError (ErrorImportModuleNotFound importPos written)
          pure table
        else do
          let bindName = case maybeAlias of
                Just aliasName -> aliasName
                Nothing -> moduleNameTail written
          insertSymbolEntry importPos bindName (singletonModule written) table

    resolveImportNames moduleNames allExports importPos written items table =
      if not (Set.member written moduleNames)
        then do
          emitError (ErrorImportModuleNotFound importPos written)
          pure table
        else do
          let targetModuleExports = Map.findWithDefault Map.empty written allExports
          foldM (addImportItem importPos written targetModuleExports) table items

    addImportItem importPos targetModuleName targetModuleExports table item =
      case Map.lookup item.name targetModuleExports of
        Nothing -> do
          emitError (ErrorImportNameNotFound importPos item.name targetModuleName)
          pure table
        Just entry ->
          case item.kind of
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
            ImportItemType -> case entry.typeSymbol of
              Nothing -> do
                emitError (ErrorImportNameNotFound importPos item.name targetModuleName)
                pure table
              Just qualifiedName ->
                insertSymbolEntry importPos item.name (singletonType qualifiedName) table

-- ---------------------------------------------------------------------------
-- Import-cycle detection
-- ---------------------------------------------------------------------------

-- | Report an 'ErrorImportCycle' for each cycle in the import graph. The
-- diagnostic span is taken from the first module in the cycle.
importCycleErrors :: Map Text (Module Parsed) -> [IdentifierError]
importCycleErrors moduleMap =
  [ ErrorImportCycle module_.sourceSpan cycle_
  | cycle_ <- findImportCycles moduleMap,
    firstName : _ <- [cycle_],
    Just module_ <- [Map.lookup firstName moduleMap]
  ]

