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
    Identified (..),
    SymbolEntry (..),
    ModuleData (..),
    VariableData (..),
    TypeData (..),
    IdentifierResult (..),
    IdentifierError (..),

    -- * Entry point
    identify,
  )
where

import Control.Monad (foldM, when)
import Control.Monad.State.Strict
import Data.Foldable (foldl')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Katari.AST
import Katari.Parser (Parsed (..))
import Katari.Prelude

-- ---------------------------------------------------------------------------
-- ID newtypes & Identified GADT
-- ---------------------------------------------------------------------------

-- | Unique id in the value namespace. Shared by agent / req / ext-agent /
-- constructor function / local variable.
newtype VariableId = VariableId Int
  deriving (Eq, Ord, Show)

-- | Unique id in the type namespace. Issued for data declarations and type
-- synonyms.
newtype TypeId = TypeId Int
  deriving (Eq, Ord, Show)

-- | Unique id in the module namespace.
newtype ModuleId = ModuleId Int
  deriving (Eq, Ord, Show)

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
data Identified (symbol :: SymbolKind) where
  IdentifiedVariable :: VariableId -> Identified 'VariableRef
  IdentifiedUnresolvedVariable :: Identified 'VariableRef
  IdentifiedType :: TypeId -> Identified 'TypeRef
  IdentifiedUnresolvedType :: Identified 'TypeRef
  IdentifiedModule :: ModuleId -> Identified 'ModuleRef
  IdentifiedUnresolvedModule :: Identified 'ModuleRef
  IdentifiedExpression :: Identified 'Expression
  IdentifiedPattern :: Identified 'Pattern
  -- | Argument / field labels are type-directed; resolution is deferred to
  -- the Typechecker.
  IdentifiedLabel :: Identified 'LabelRef

deriving instance Show (Identified symbol)

deriving instance Eq (Identified symbol)

-- ---------------------------------------------------------------------------
-- Top-level scope: SymbolEntry (3 slots per name)
-- ---------------------------------------------------------------------------

-- | The three slots a single name may simultaneously occupy. Invariants:
--
--   * A second registration into the same slot for the same name is an
--     'ErrorDuplicateName'.
--   * variable + module coexistence is forbidden (it would silently change the
--     meaning of @name.foo@ from qualified module access to field access).
--   * variable + type and type + module are allowed.
data SymbolEntry = SymbolEntry
  { variableSymbol :: Maybe VariableId,
    typeSymbol :: Maybe TypeId,
    moduleSymbol :: Maybe ModuleId
  }
  deriving (Eq, Show)

emptySymbolEntry :: SymbolEntry
emptySymbolEntry = SymbolEntry {variableSymbol = Nothing, typeSymbol = Nothing, moduleSymbol = Nothing}

singletonVariable :: VariableId -> SymbolEntry
singletonVariable vid = SymbolEntry {variableSymbol = Just vid, typeSymbol = Nothing, moduleSymbol = Nothing}

singletonType :: TypeId -> SymbolEntry
singletonType tid = SymbolEntry {variableSymbol = Nothing, typeSymbol = Just tid, moduleSymbol = Nothing}

singletonModule :: ModuleId -> SymbolEntry
singletonModule mid = SymbolEntry {variableSymbol = Nothing, typeSymbol = Nothing, moduleSymbol = Just mid}

-- ---------------------------------------------------------------------------
-- Result tables
-- ---------------------------------------------------------------------------

data ModuleData = ModuleData
  { moduleName :: Text,
    moduleSourceSpan :: SourceSpan
  }
  deriving (Eq, Show)

data VariableData = VariableData
  { variableName :: Text,
    variableSourceSpan :: SourceSpan
  }
  deriving (Eq, Show)

data TypeData = TypeData
  { typeName :: Text,
    typeSourceSpan :: SourceSpan
  }
  deriving (Eq, Show)

-- | Result of a successful Identifier pass. The Identified ASTs live in
-- 'moduleASTs' rather than nested inside 'ModuleData' so the State monad never
-- has to hold a placeholder AST that gets overwritten later.
data IdentifierResult = IdentifierResult
  { identifiedModules :: Map ModuleId ModuleData,
    identifiedVariables :: Map VariableId VariableData,
    identifiedTypes :: Map TypeId TypeData,
    moduleASTs :: Map ModuleId (Module Identified)
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

deriving instance Show IdentifierError

deriving instance Eq IdentifierError

-- ---------------------------------------------------------------------------
-- Identifier monad
-- ---------------------------------------------------------------------------

-- | Identifier-pass state: counters for the three id namespaces, the
-- materialized id → original-data maps, the accumulated error list, and the
-- per-module resolve context (only meaningful during Phase D; populated with a
-- dummy in earlier phases).
data IdentifierState = IdentifierState
  { nextVariableId :: Int,
    nextTypeId :: Int,
    nextModuleId :: Int,
    variables :: Map VariableId VariableData,
    types :: Map TypeId TypeData,
    modules :: Map ModuleId ModuleData,
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
          variables = Map.empty,
          types = Map.empty,
          modules = Map.empty,
          errors = [],
          resolveContext = emptyResolveContext
        }

-- ---------------------------------------------------------------------------
-- ID issuing helpers
-- ---------------------------------------------------------------------------

freshVariableId :: VariableData -> Identifier VariableId
freshVariableId vdata = do
  st <- get
  let vid = VariableId st.nextVariableId
  put st {nextVariableId = st.nextVariableId + 1, variables = Map.insert vid vdata st.variables}
  pure vid

freshTypeId :: TypeData -> Identifier TypeId
freshTypeId tdata = do
  st <- get
  let tid = TypeId st.nextTypeId
  put st {nextTypeId = st.nextTypeId + 1, types = Map.insert tid tdata st.types}
  pure tid

freshModuleId :: ModuleData -> Identifier ModuleId
freshModuleId mdata = do
  st <- get
  let mid = ModuleId st.nextModuleId
  put st {nextModuleId = st.nextModuleId + 1, modules = Map.insert mid mdata st.modules}
  pure mid

emitError :: IdentifierError -> Identifier ()
emitError err = modify $ \st -> st {errors = err : st.errors}

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
    (Just _, Just oldMid) -> reportFromModule oldMid
    _ -> pure ()
  case (incoming.moduleSymbol, existing.variableSymbol) of
    (Just _, Just oldVid) -> reportFromVariable oldVid
    _ -> pure ()
  -- Per-slot duplicate.
  variable' <- mergeVariableSlot existing.variableSymbol incoming.variableSymbol
  type' <- mergeTypeSlot existing.typeSymbol incoming.typeSymbol
  module' <- mergeModuleSlot existing.moduleSymbol incoming.moduleSymbol
  pure SymbolEntry {variableSymbol = variable', typeSymbol = type', moduleSymbol = module'}
  where
    reportFromVariable vid = do
      mPos <- gets (fmap (.variableSourceSpan) . Map.lookup vid . (.variables))
      maybe (pure ()) (emitError . ErrorDuplicateName newPos name) mPos
    reportFromType tid = do
      mPos <- gets (fmap (.typeSourceSpan) . Map.lookup tid . (.types))
      maybe (pure ()) (emitError . ErrorDuplicateName newPos name) mPos
    reportFromModule mid = do
      mPos <- gets (fmap (.moduleSourceSpan) . Map.lookup mid . (.modules))
      maybe (pure ()) (emitError . ErrorDuplicateName newPos name) mPos

    mergeVariableSlot existingSlot Nothing = pure existingSlot
    mergeVariableSlot Nothing newSlot = pure newSlot
    mergeVariableSlot (Just oldId) (Just _) = do
      reportFromVariable oldId
      pure (Just oldId)

    mergeTypeSlot existingSlot Nothing = pure existingSlot
    mergeTypeSlot Nothing newSlot = pure newSlot
    mergeTypeSlot (Just oldId) (Just _) = do
      reportFromType oldId
      pure (Just oldId)

    mergeModuleSlot existingSlot Nothing = pure existingSlot
    mergeModuleSlot Nothing newSlot = pure newSlot
    mergeModuleSlot (Just oldId) (Just _) = do
      reportFromModule oldId
      pure (Just oldId)

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
  ctx <- gets (.resolveContext)
  let name = nameRef.text
  when (chainHasModule name ctx.scopeStack)
    $ emitError (ErrorShadowNonVariable nameRef.sourceSpan name)
  vid <- freshVariableId VariableData {variableName = name, variableSourceSpan = nameRef.sourceSpan}
  modifyResolveContext $ \c -> c {scopeStack = insertInnermost name vid c.scopeStack}
  pure (identifiedNameRef (IdentifiedVariable vid) nameRef)
  where
    chainHasModule n = any (\frame -> isJust (Map.lookup n frame >>= (.moduleSymbol)))
    insertInnermost n vid = \case
      [] -> [Map.singleton n (singletonVariable vid)]
      (top : rest) -> Map.insert n (singletonVariable vid) top : rest

-- | Push a fresh empty frame, run the action, then pop the frame.
withScopeFrame :: Identifier a -> Identifier a
withScopeFrame action = do
  modifyResolveContext $ \c -> c {scopeStack = Map.empty : c.scopeStack}
  result <- action
  modifyResolveContext $ \c -> c {scopeStack = drop 1 c.scopeStack}
  pure result

-- | Replace the resolve context for the duration of an action (used to switch
-- between modules in Phase D).
withResolveContext :: ResolveContext -> Identifier a -> Identifier a
withResolveContext newCtx action = do
  oldCtx <- gets (.resolveContext)
  modify $ \st -> st {resolveContext = newCtx}
  result <- action
  modify $ \st -> st {resolveContext = oldCtx}
  pure result

modifyResolveContext :: (ResolveContext -> ResolveContext) -> Identifier ()
modifyResolveContext f = modify $ \st -> st {resolveContext = f st.resolveContext}

-- ---------------------------------------------------------------------------
-- Lookup helpers
-- ---------------------------------------------------------------------------

-- | Walk the scope stack innermost-first looking for the first frame that has
-- the requested slot set for the given name. Per-slot lookup means a local
-- variable binding does not hide an outer frame's type binding for the same
-- name (they coexist).
lookupSlot :: (SymbolEntry -> Maybe a) -> Text -> Identifier (Maybe a)
lookupSlot getSlot name = do
  ctx <- gets (.resolveContext)
  pure (walk ctx.scopeStack)
  where
    walk [] = Nothing
    walk (frame : rest) = case Map.lookup name frame of
      Just entry | Just x <- getSlot entry -> Just x
      _ -> walk rest

lookupVariable :: Text -> Identifier (Maybe VariableId)
lookupVariable = lookupSlot (.variableSymbol)

lookupType :: Text -> Identifier (Maybe TypeId)
lookupType = lookupSlot (.typeSymbol)

lookupModule :: Text -> Identifier (Maybe ModuleId)
lookupModule = lookupSlot (.moduleSymbol)

-- | Look up the variable slot of @name@ in the export table of @mid@.
lookupModuleExportVariable :: ModuleId -> Text -> Identifier (Maybe VariableId)
lookupModuleExportVariable = lookupModuleExportSlot (.variableSymbol)

-- | Look up the type slot of @name@ in the export table of @mid@.
lookupModuleExportType :: ModuleId -> Text -> Identifier (Maybe TypeId)
lookupModuleExportType = lookupModuleExportSlot (.typeSymbol)

lookupModuleExportSlot ::
  (SymbolEntry -> Maybe a) ->
  ModuleId ->
  Text ->
  Identifier (Maybe a)
lookupModuleExportSlot getSlot mid name = do
  ctx <- gets (.resolveContext)
  pure $ do
    table <- Map.lookup mid ctx.moduleExports
    entry <- Map.lookup name table
    getSlot entry

-- ---------------------------------------------------------------------------
-- NameRef helpers
-- ---------------------------------------------------------------------------

-- | Replace just the @metadata@ of a 'NameRef', keeping @text@ and @sourceSpan@.
identifiedNameRef ::
  Identified symbol ->
  NameRef Parsed symbol ->
  NameRef Identified symbol
identifiedNameRef meta ref = NameRef {text = ref.text, sourceSpan = ref.sourceSpan, metadata = meta}

labelRef :: NameRef Parsed 'LabelRef -> NameRef Identified 'LabelRef
labelRef = identifiedNameRef IdentifiedLabel

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
    allocate (modName, parsedModule) = do
      mid <-
        freshModuleId
          ModuleData
            { moduleName = modName,
              moduleSourceSpan = parsedModule.sourceSpan
            }
      pure (modName, mid)

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
    buildOne (modName, parsedModule) = do
      table <- foldM addDeclaration Map.empty parsedModule.declarations
      pure (modName, table)

    addDeclaration table = \case
      DeclarationAgent decl -> registerVariable table decl.name
      DeclarationRequest decl -> registerVariable table decl.name
      DeclarationExternalAgent decl -> registerVariable table decl.name
      -- A data declaration occupies both the variable slot (constructor
      -- function) and the type slot under the same name.
      DeclarationData decl -> registerData table decl.name
      DeclarationTypeSynonym decl -> registerTypeOnly table decl.name
      DeclarationImport _ -> pure table -- handled in Phase C
    registerVariable table name = do
      vid <-
        freshVariableId
          VariableData {variableName = name.text, variableSourceSpan = name.sourceSpan}
      insertSymbolEntry name.sourceSpan name.text (singletonVariable vid) table

    registerTypeOnly table name = do
      tid <-
        freshTypeId
          TypeData {typeName = name.text, typeSourceSpan = name.sourceSpan}
      insertSymbolEntry name.sourceSpan name.text (singletonType tid) table

    registerData table name = do
      vid <-
        freshVariableId
          VariableData {variableName = name.text, variableSourceSpan = name.sourceSpan}
      tid <-
        freshTypeId
          TypeData {typeName = name.text, typeSourceSpan = name.sourceSpan}
      let entry =
            SymbolEntry
              { variableSymbol = Just vid,
                typeSymbol = Just tid,
                moduleSymbol = Nothing
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
    buildOne (modName, parsedModule) = do
      let ownExports = Map.findWithDefault Map.empty modName exports
      table <- foldM (addImport modName) ownExports parsedModule.declarations
      pure (modName, table)

    addImport _ table = \case
      DeclarationImport importDecl -> resolveImport table importDecl
      _ -> pure table

    resolveImport table importDecl =
      case importDecl.kind of
        ImportModule {moduleName, alias} ->
          resolveImportModule importDecl.sourceSpan moduleName alias table
        ImportNames {items, moduleName} ->
          resolveImportNames importDecl.sourceSpan moduleName items table

    resolveImportModule importPos modName aliasMaybe table =
      case Map.lookup modName moduleNameToId of
        Nothing -> do
          emitError (ErrorImportModuleNotFound importPos modName)
          pure table
        Just mid -> do
          let bindName = case aliasMaybe of
                Just a -> a
                Nothing -> modulePostfix modName
          insertSymbolEntry importPos bindName (singletonModule mid) table

    resolveImportNames importPos modName items table =
      case Map.lookup modName moduleNameToId of
        Nothing -> do
          emitError (ErrorImportModuleNotFound importPos modName)
          pure table
        Just mid -> do
          let modExports = Map.findWithDefault Map.empty modName exports
          foldM (addImportItem importPos mid modName modExports) table items

    addImportItem importPos _ modName modExports table item =
      case Map.lookup item.name modExports of
        Nothing -> do
          emitError (ErrorImportNameNotFound importPos item.name modName)
          pure table
        Just entry ->
          case item.kind of
            -- @import { foo }@ — pulls in both the variable and type slots
            -- under the source name. Lets a data-shaped name (variable + type
            -- under one identifier) be imported in one go. At least one slot
            -- must exist on the source side.
            ImportItemValue
              | isJust entry.variableSymbol || isJust entry.typeSymbol ->
                  insertSymbolEntry
                    importPos
                    item.name
                    SymbolEntry
                      { variableSymbol = entry.variableSymbol,
                        typeSymbol = entry.typeSymbol,
                        moduleSymbol = Nothing
                      }
                    table
              | otherwise -> do
                  emitError (ErrorImportNameNotFound importPos item.name modName)
                  pure table
            -- @import { type foo }@ — pulls in only the type slot.
            ImportItemType -> case entry.typeSymbol of
              Nothing -> do
                emitError (ErrorImportNameNotFound importPos item.name modName)
                pure table
              Just tid ->
                insertSymbolEntry importPos item.name (singletonType tid) table

-- | Extract @"module"@ from @"path.to.module"@. Returns the empty string if
-- given an empty input (the parser should never produce one, but this guards
-- against it anyway).
modulePostfix :: Text -> Text
modulePostfix path =
  case reverse (T.splitOn "." path) of
    [] -> path
    (last' : _) -> last'

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
          [ (mid, Map.findWithDefault Map.empty modName exports)
            | (modName, mid) <- Map.toList moduleNameToId
          ]
  -- Build (ModuleId, Module Identified) pairs and assemble a Map at the end.
  pairs <- mapM (resolveOne exportsById) (Map.toList moduleMap)
  pure (Map.fromList (catMaybes pairs))
  where
    resolveOne exportsById (modName, parsedModule) = do
      let topLevelFrame = Map.findWithDefault Map.empty modName topLevels
          ctx =
            ResolveContext
              { scopeStack = [topLevelFrame],
                moduleExports = exportsById
              }
      identifiedModule <- withResolveContext ctx (resolveModuleAST parsedModule)
      pure (fmap (,identifiedModule) (Map.lookup modName moduleNameToId))

resolveModuleAST :: Module Parsed -> Identifier (Module Identified)
resolveModuleAST mod' = do
  decls <- mapM resolveDeclaration mod'.declarations
  pure Module {declarations = decls, sourceSpan = mod'.sourceSpan}

-- ---------------------------------------------------------------------------
-- Declaration
-- ---------------------------------------------------------------------------

resolveDeclaration :: Declaration Parsed -> Identifier (Declaration Identified)
resolveDeclaration = \case
  DeclarationAgent decl -> DeclarationAgent <$> resolveAgent decl
  DeclarationRequest decl -> DeclarationRequest <$> resolveRequest decl
  DeclarationExternalAgent decl -> DeclarationExternalAgent <$> resolveExternalAgent decl
  DeclarationData decl -> DeclarationData <$> resolveData decl
  DeclarationTypeSynonym decl -> DeclarationTypeSynonym <$> resolveTypeSynonym decl
  DeclarationImport decl -> pure (DeclarationImport (resolveImportDecl decl))

resolveImportDecl :: ImportDeclaration Parsed -> ImportDeclaration Identified
resolveImportDecl ImportDeclaration {kind, sourceSpan} =
  ImportDeclaration {kind = kind, sourceSpan = sourceSpan}

-- | Fill in the variable id for a signature-position 'NameRef' (the @name@ of
-- an agent / req / ext-agent / data declaration). Phase B has already issued
-- the id; this just looks it up. If lookup fails (only possible when Phase B
-- emitted a duplicate-name error), record an unresolved marker rather than
-- inventing a sentinel id.
liftSignatureVariable :: NameRef Parsed 'VariableRef -> Identifier (NameRef Identified 'VariableRef)
liftSignatureVariable ref = do
  result <- lookupVariable ref.text
  pure $ case result of
    Just vid -> identifiedNameRef (IdentifiedVariable vid) ref
    Nothing -> identifiedNameRef IdentifiedUnresolvedVariable ref

-- | Counterpart of 'liftSignatureVariable' for type signatures (enum / data
-- type role / type synonym name).
liftSignatureType :: NameRef Parsed 'TypeRef -> Identifier (NameRef Identified 'TypeRef)
liftSignatureType ref = do
  result <- lookupType ref.text
  pure $ case result of
    Just tid -> identifiedNameRef (IdentifiedType tid) ref
    Nothing -> identifiedNameRef IdentifiedUnresolvedType ref

resolveAgent :: AgentDeclaration Parsed -> Identifier (AgentDeclaration Identified)
resolveAgent AgentDeclaration {..} = do
  name' <- liftSignatureVariable name
  withScopeFrame $ do
    parameters' <- mapM resolveParameter parameters
    returnType' <- traverse resolveType returnType
    withEffects' <- traverse (mapM resolveSyntacticRequest) withEffects
    body' <- resolveBlock body
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
  parameters' <- mapM resolveDataParameter parameters
  pure
    DataDeclaration
      { annotation = annotation,
        name = name',
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
-- B; here we only need to resolve the rhs type expression.
resolveTypeSynonym ::
  TypeSynonymDeclaration Parsed ->
  Identifier (TypeSynonymDeclaration Identified)
resolveTypeSynonym TypeSynonymDeclaration {..} = do
  name' <- liftSignatureType name
  rhs' <- resolveType rhs
  pure
    TypeSynonymDeclaration
      { name = name',
        rhs = rhs',
        sourceSpan = sourceSpan
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
  PatternVariable p -> PatternVariable <$> resolveVariablePattern p
  PatternQualifiedConstructor p -> PatternQualifiedConstructor <$> resolveConstructorPattern p
  PatternTuple p -> PatternTuple <$> resolveTuplePattern p
  PatternWildcard p -> PatternWildcard <$> resolveWildcardPattern p
  PatternLiteral p -> PatternLiteral <$> resolveLiteralPattern p

resolveVariablePattern :: VariablePattern Parsed -> Identifier (VariablePattern Identified)
resolveVariablePattern VariablePattern {..} = do
  name' <- bindLocalVariable name
  typeAnnotation' <- traverse resolveType typeAnnotation
  pure
    VariablePattern
      { name = name',
        typeAnnotation = typeAnnotation',
        sourceSpan = sourceSpan,
        metadata = IdentifiedPattern
      }

resolveConstructorPattern ::
  QualifiedConstructorPattern Parsed ->
  Identifier (QualifiedConstructorPattern Identified)
resolveConstructorPattern QualifiedConstructorPattern {..} = do
  (moduleQualifier', constructorName') <-
    resolveQualifiedVariableRef moduleQualifier constructorName
  parameters' <-
    mapM
      (\(lbl, pat) -> (labelRef lbl,) <$> resolvePattern pat)
      parameters
  pure
    QualifiedConstructorPattern
      { moduleQualifier = moduleQualifier',
        constructorName = constructorName',
        parameters = parameters',
        sourceSpan = sourceSpan,
        metadata = IdentifiedPattern
      }

resolveTuplePattern :: TuplePattern Parsed -> Identifier (TuplePattern Identified)
resolveTuplePattern TuplePattern {..} = do
  elements' <- mapM resolvePattern elements
  pure
    TuplePattern
      { elements = elements',
        sourceSpan = sourceSpan,
        metadata = IdentifiedPattern
      }

resolveWildcardPattern :: WildcardPattern Parsed -> Identifier (WildcardPattern Identified)
resolveWildcardPattern WildcardPattern {..} = do
  typeAnnotation' <- traverse resolveType typeAnnotation
  pure
    WildcardPattern
      { typeAnnotation = typeAnnotation',
        sourceSpan = sourceSpan,
        metadata = IdentifiedPattern
      }

resolveLiteralPattern :: LiteralPattern Parsed -> Identifier (LiteralPattern Identified)
resolveLiteralPattern LiteralPattern {..} =
  pure
    LiteralPattern
      { value = value,
        sourceSpan = sourceSpan,
        metadata = IdentifiedPattern
      }

-- | Resolve either a bare @name@ or a qualified @module.name@ as a variable
-- reference. Used by constructor patterns and request handler names.
--
-- All sub-resolvers return an 'Identified' marker (resolved id or the
-- corresponding @Unresolved@) so that the AST always carries a faithful trace
-- of the resolution outcome instead of a fabricated id.
resolveQualifiedVariableRef ::
  Maybe (NameRef Parsed 'ModuleRef) ->
  NameRef Parsed 'VariableRef ->
  Identifier (Maybe (NameRef Identified 'ModuleRef), NameRef Identified 'VariableRef)
resolveQualifiedVariableRef = \cases
  Nothing nameRef -> do
    varMeta <- resolveBareVariable nameRef
    pure (Nothing, identifiedNameRef varMeta nameRef)
  (Just modRef) nameRef -> do
    modMeta <- resolveModuleRef modRef
    varMeta <- case modMeta of
      IdentifiedModule mid -> resolveQualifiedVariable mid modRef.text nameRef
      IdentifiedUnresolvedModule -> pure IdentifiedUnresolvedVariable
    pure
      ( Just (identifiedNameRef modMeta modRef),
        identifiedNameRef varMeta nameRef
      )

resolveBareVariable :: NameRef Parsed 'VariableRef -> Identifier (Identified 'VariableRef)
resolveBareVariable ref =
  lookupVariable ref.text >>= \case
    Just vid -> pure (IdentifiedVariable vid)
    Nothing -> do
      emitError (ErrorUndefinedName ref.sourceSpan ref.text)
      pure IdentifiedUnresolvedVariable

resolveModuleRef :: NameRef Parsed 'ModuleRef -> Identifier (Identified 'ModuleRef)
resolveModuleRef ref =
  lookupModule ref.text >>= \case
    Just mid -> pure (IdentifiedModule mid)
    Nothing -> do
      emitError (ErrorNotAModule ref.sourceSpan ref.text)
      pure IdentifiedUnresolvedModule

resolveQualifiedVariable ::
  ModuleId ->
  Text ->
  NameRef Parsed 'VariableRef ->
  Identifier (Identified 'VariableRef)
resolveQualifiedVariable mid modName ref =
  lookupModuleExportVariable mid ref.text >>= \case
    Just vid -> pure (IdentifiedVariable vid)
    Nothing -> do
      emitError (ErrorUndefinedQualified ref.sourceSpan modName ref.text)
      pure IdentifiedUnresolvedVariable

-- ---------------------------------------------------------------------------
-- SyntacticType
-- ---------------------------------------------------------------------------

resolveType :: SyntacticType Parsed -> Identifier (SyntacticType Identified)
resolveType = \case
  TypePrimitive p -> pure (TypePrimitive (rebuildPrimitive p))
  TypeName p -> TypeName <$> resolveTypeName p
  TypeFunction p -> TypeFunction <$> resolveFunctionType p
  TypeArray p -> TypeArray <$> resolveArrayType p
  TypeTuple p -> TypeTuple <$> resolveTupleType p
  TypeQualified p -> TypeQualified <$> resolveQualifiedType p
  -- Literal types have nothing to resolve (the LiteralValue is phase-agnostic).
  TypeLiteral n -> pure (TypeLiteral n)
  -- Union: recurse into each branch.
  TypeUnion TypeUnionNode {branches, sourceSpan} -> do
    branches' <- mapM resolveType branches
    pure (TypeUnion TypeUnionNode {branches = branches', sourceSpan = sourceSpan})
  where
    rebuildPrimitive PrimitiveTypeNode {kind, sourceSpan} =
      PrimitiveTypeNode {kind = kind, sourceSpan = sourceSpan}

resolveTypeName :: TypeNameNode Parsed -> Identifier (TypeNameNode Identified)
resolveTypeName TypeNameNode {name, sourceSpan} = do
  meta <-
    lookupType name.text >>= \case
      Just tid -> pure (IdentifiedType tid)
      Nothing -> do
        emitError (ErrorNotAType name.sourceSpan name.text)
        pure IdentifiedUnresolvedType
  pure
    TypeNameNode
      { name = identifiedNameRef meta name,
        sourceSpan = sourceSpan
      }

resolveQualifiedType :: QualifiedTypeNode Parsed -> Identifier (QualifiedTypeNode Identified)
resolveQualifiedType QualifiedTypeNode {qualifier, target, sourceSpan} = do
  modMeta <- resolveModuleRef qualifier
  typeMeta <- case modMeta of
    IdentifiedModule mid ->
      lookupModuleExportType mid target.text >>= \case
        Just tid -> pure (IdentifiedType tid)
        Nothing -> do
          emitError (ErrorUndefinedQualified target.sourceSpan qualifier.text target.text)
          pure IdentifiedUnresolvedType
    IdentifiedUnresolvedModule -> pure IdentifiedUnresolvedType
  pure
    QualifiedTypeNode
      { qualifier = identifiedNameRef modMeta qualifier,
        target = identifiedNameRef typeMeta target,
        sourceSpan = sourceSpan
      }

resolveFunctionType :: FunctionTypeNode Parsed -> Identifier (FunctionTypeNode Identified)
resolveFunctionType FunctionTypeNode {parameterTypes, returnType, withEffects, sourceSpan} = do
  parameterTypes' <- mapM (\(lbl, ty) -> (lbl,) <$> resolveType ty) parameterTypes
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
  meta <- resolveBareVariable name
  pure
    SyntacticRequest
      { name = identifiedNameRef meta name,
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Block / Statement
-- ---------------------------------------------------------------------------

-- | A block's body and its @where@ clause are **independent scopes**: a
-- @let@ in the body is invisible from the where clause and vice versa, while
-- both inherit the surrounding outer scope.
resolveBlock :: Block Parsed -> Identifier (Block Identified)
resolveBlock Block {statements, returnExpression, whereBlock, sourceSpan} = do
  -- Body: push a fresh frame.
  (statements', returnExpression') <- withScopeFrame $ do
    ss <- mapM resolveStatement statements
    re <- traverse resolveExpression returnExpression
    pure (ss, re)
  -- Where: resolved in its own fresh frame.
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
--   3. Handler bodies and the @then@ block are resolved in a frame where all
--      state vars are already bound.
resolveWhereBlock :: WhereBlock Parsed -> Identifier (WhereBlock Identified)
resolveWhereBlock WhereBlock {stateVariables, handlers, thenClause, sourceSpan} = withScopeFrame $ do
  stateVariables' <- mapM resolveStateVariable stateVariables
  handlers' <- mapM resolveRequestHandler handlers
  thenClause' <-
    traverse
      ( \(maybePat, block) -> withScopeFrame $ do
          maybePat' <- traverse resolvePattern maybePat
          block' <- resolveBlock block
          pure (maybePat', block')
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
resolveRequestHandler :: RequestHandler Parsed -> Identifier (RequestHandler Identified)
resolveRequestHandler RequestHandler {moduleQualifier, name, parameters, returnType, withEffects, body, sourceSpan} = do
  (moduleQualifier', name') <- resolveQualifiedVariableRef moduleQualifier name
  withScopeFrame $ do
    parameters' <- mapM resolveParameter parameters
    returnType' <- traverse resolveType returnType
    withEffects' <- traverse (mapM resolveSyntacticRequest) withEffects
    body' <- resolveBlock body
    pure
      RequestHandler
        { moduleQualifier = moduleQualifier',
          name = name',
          parameters = parameters',
          returnType = returnType',
          withEffects = withEffects',
          body = body',
          sourceSpan = sourceSpan
        }

-- ---------------------------------------------------------------------------
-- Statement
-- ---------------------------------------------------------------------------

resolveStatement :: Statement Parsed -> Identifier (Statement Identified)
resolveStatement = \case
  StatementLet s -> StatementLet <$> resolveLet s
  StatementAgent s -> StatementAgent <$> resolveAgentStatement s
  StatementReturn s -> StatementReturn <$> resolveReturn s
  StatementExpression e -> StatementExpression <$> resolveExpression e
  StatementNext s -> StatementNext <$> resolveNext s
  StatementBreak s -> StatementBreak <$> resolveBreak s
  StatementForNext s -> StatementForNext <$> resolveForNext s
  StatementForBreak s -> StatementForBreak <$> resolveForBreak s

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
  withScopeFrame $ do
    parameters' <- mapM resolveParameter parameters
    returnType' <- traverse resolveType returnType
    withEffects' <- traverse (mapM resolveSyntacticRequest) withEffects
    body' <- resolveBlock body
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
  meta <- resolveBareVariable name
  value' <- resolveExpression value
  pure
    Modifier
      { name = identifiedNameRef meta name,
        value = value',
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Expression
-- ---------------------------------------------------------------------------

resolveExpression :: Expression Parsed -> Identifier (Expression Identified)
resolveExpression = \case
  ExpressionLiteral e -> ExpressionLiteral <$> resolveLiteralExpr e
  ExpressionVariable e -> resolveVariableExpr e
  ExpressionTuple e -> ExpressionTuple <$> resolveTupleExpr e
  ExpressionArray e -> ExpressionArray <$> resolveArrayExpr e
  ExpressionCall e -> ExpressionCall <$> resolveCallExpr e
  ExpressionBinaryOperator e -> ExpressionBinaryOperator <$> resolveBinaryExpr e
  ExpressionUnaryOperator e -> ExpressionUnaryOperator <$> resolveUnaryExpr e
  ExpressionIf e -> ExpressionIf <$> resolveIfExpr e
  ExpressionMatch e -> ExpressionMatch <$> resolveMatchExpr e
  ExpressionFor e -> ExpressionFor <$> resolveForExpr e
  ExpressionBlock e -> ExpressionBlock <$> resolveBlockExpr e
  ExpressionFieldAccess e -> resolveFieldAccess e
  ExpressionIndexAccess e -> ExpressionIndexAccess <$> resolveIndexExpr e
  ExpressionTemplate e -> ExpressionTemplate <$> resolveTemplateExpr e
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
        metadata = IdentifiedExpression
      }

-- | A bare variable expression. May resolve to a constructor function, agent,
-- req, parameter, or local let binding.
resolveVariableExpr :: VariableExpression Parsed -> Identifier (Expression Identified)
resolveVariableExpr VariableExpression {name, sourceSpan} = do
  meta <- resolveBareVariable name
  pure
    ( ExpressionVariable
        VariableExpression
          { name = identifiedNameRef meta name,
            sourceSpan = sourceSpan,
            metadata = IdentifiedExpression
          }
    )

resolveTupleExpr :: TupleExpression Parsed -> Identifier (TupleExpression Identified)
resolveTupleExpr TupleExpression {elements, sourceSpan} = do
  elements' <- mapM resolveExpression elements
  pure
    TupleExpression
      { elements = elements',
        sourceSpan = sourceSpan,
        metadata = IdentifiedExpression
      }

resolveArrayExpr :: ArrayExpression Parsed -> Identifier (ArrayExpression Identified)
resolveArrayExpr ArrayExpression {elements, sourceSpan} = do
  elements' <- mapM resolveExpression elements
  pure
    ArrayExpression
      { elements = elements',
        sourceSpan = sourceSpan,
        metadata = IdentifiedExpression
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
        metadata = IdentifiedExpression
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
        metadata = IdentifiedExpression
      }

resolveUnaryExpr :: UnaryOperatorExpression Parsed -> Identifier (UnaryOperatorExpression Identified)
resolveUnaryExpr UnaryOperatorExpression {operator, operand, sourceSpan} = do
  operand' <- resolveExpression operand
  pure
    UnaryOperatorExpression
      { operator = operator,
        operand = operand',
        sourceSpan = sourceSpan,
        metadata = IdentifiedExpression
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
        metadata = IdentifiedExpression
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
        metadata = IdentifiedExpression
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
      ( \ForInBinding {pattern, source, sourceSpan = bSpan} -> do
          source' <- resolveExpression source
          pure (pattern, source', bSpan)
      )
      inBindings
  withScopeFrame $ do
    -- Bind patterns and var-bindings in the fresh frame.
    inBindings' <-
      mapM
        ( \(pat, src, bSpan) -> do
            pat' <- resolvePattern pat
            pure ForInBinding {pattern = pat', source = src, sourceSpan = bSpan}
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
          metadata = IdentifiedExpression
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
        metadata = IdentifiedExpression
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
        metadata = IdentifiedExpression
      }

resolveTemplateExpr :: TemplateExpression Parsed -> Identifier (TemplateExpression Identified)
resolveTemplateExpr TemplateExpression {elements, sourceSpan} = do
  elements' <- mapM resolveTemplateElement elements
  pure
    TemplateExpression
      { elements = elements',
        sourceSpan = sourceSpan,
        metadata = IdentifiedExpression
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
peelFieldChain expr0 =
  let (head', labels, totalSpan) = go expr0 []
   in (head', labels, totalSpan)
  where
    go expr accLabels = case expr of
      ExpressionFieldAccess fa ->
        go fa.object (fa.fieldName : accLabels)
      ExpressionVariable v ->
        (VariableHead v.name, accLabels, expressionSpanOuter expr0)
      _ -> (OtherHead expr, accLabels, expressionSpanOuter expr0)

    expressionSpanOuter = sourceSpanOf

-- | Rebuild a left-folding chain of 'FieldAccess' expressions on top of an
-- inner expression.
rebuildFieldAccessChain ::
  Expression Identified ->
  [NameRef Parsed 'LabelRef] ->
  Expression Identified
rebuildFieldAccessChain = foldl' step
  where
    step inner lbl =
      let span' =
            SrcSpan
              { filePath = (sourceSpanOf inner).filePath,
                start = (sourceSpanOf inner).start,
                end = lbl.sourceSpan.end
              }
       in ExpressionFieldAccess
            FieldAccessExpression
              { object = inner,
                fieldName = labelRef lbl,
                sourceSpan = span',
                metadata = IdentifiedExpression
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
  mvid <- lookupVariable headRef.text
  case mvid of
    Just vid ->
      -- Head is a variable: keep the whole chain as field access.
      pure (rebuildFieldAccessChain (varExpr (IdentifiedVariable vid)) labels)
    Nothing -> do
      mmid <- lookupModule headRef.text
      case mmid of
        Just mid -> resolveModuleQualifiedChain mid headRef labels totalSpan
        Nothing -> do
          -- Undefined: emit error and tag the head as Unresolved so downstream
          -- phases can see that resolution failed.
          emitError (ErrorUndefinedName headRef.sourceSpan headRef.text)
          pure (rebuildFieldAccessChain (varExpr IdentifiedUnresolvedVariable) labels)
  where
    varExpr meta =
      ExpressionVariable
        VariableExpression
          { name = identifiedNameRef meta headRef,
            sourceSpan = headRef.sourceSpan,
            metadata = IdentifiedExpression
          }

-- | A @module . ...@ chain. The first label is folded into a
-- 'QualifiedReferenceExpression'; any remaining labels become field accesses.
resolveModuleQualifiedChain ::
  ModuleId ->
  NameRef Parsed 'VariableRef ->
  [NameRef Parsed 'LabelRef] ->
  SourceSpan ->
  Identifier (Expression Identified)
resolveModuleQualifiedChain mid moduleRef labels totalSpan =
  case labels of
    [] -> do
      -- A bare module reference is not a valid expression.
      emitError (ErrorUndefinedName moduleRef.sourceSpan moduleRef.text)
      pure
        ( ExpressionVariable
            VariableExpression
              { name = identifiedNameRef IdentifiedUnresolvedVariable moduleRef,
                sourceSpan = moduleRef.sourceSpan,
                metadata = IdentifiedExpression
              }
        )
    (target : rest) -> do
      mvid <- lookupModuleExportVariable mid target.text
      varMeta <- case mvid of
        Just v -> pure (IdentifiedVariable v)
        Nothing -> do
          emitError (ErrorUndefinedQualified target.sourceSpan moduleRef.text target.text)
          pure IdentifiedUnresolvedVariable
      let qrefSpan =
            SrcSpan
              { filePath = totalSpan.filePath,
                start = moduleRef.sourceSpan.start,
                end = target.sourceSpan.end
              }
          -- Re-tag the LabelRef as a VariableRef while preserving text/span.
          targetVarRef =
            NameRef
              { text = target.text,
                sourceSpan = target.sourceSpan,
                metadata = varMeta
              }
          moduleNameRef =
            NameRef
              { text = moduleRef.text,
                sourceSpan = moduleRef.sourceSpan,
                metadata = IdentifiedModule mid
              }
          qref =
            ExpressionQualifiedReference
              QualifiedReferenceExpression
                { moduleQualifier = moduleNameRef,
                  target = targetVarRef,
                  sourceSpan = qrefSpan,
                  metadata = IdentifiedExpression
                }
      pure (rebuildFieldAccessChain qref rest)

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

-- | Entry point. Runs the four phases over a set of modules and produces an
-- 'IdentifierResult' on success, or the list of errors on failure.
identify :: Map Text (Module Parsed) -> Either [IdentifierError] IdentifierResult
identify moduleMap =
  let (asts, st) =
        runIdentifier $ do
          moduleNameToId <- assignModuleIds moduleMap
          exports <- buildExports moduleMap
          topLevels <- buildTopLevels moduleNameToId exports moduleMap
          resolveModule topLevels moduleNameToId exports moduleMap
   in case reverse st.errors of
        [] ->
          Right
            IdentifierResult
              { identifiedModules = st.modules,
                identifiedVariables = st.variables,
                identifiedTypes = st.types,
                moduleASTs = asts
              }
        errs -> Left errs
