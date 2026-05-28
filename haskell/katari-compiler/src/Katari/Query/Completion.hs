-- | Position-based completion query for LSP.
--
-- Given a 'CompileResult', returns the symbols visible at a source
-- position:
--
--   * Locals from 'Katari.Typechecker.ScopeIndex' — every binding in
--     scope on the enclosing block / pattern / etc.
--   * The enclosing module's bare-name top-level visibility from
--     'IdentifierResult.moduleVisibleSymbols' — own declarations,
--     named imports, automatic stdlib injections, and module-import
--     aliases. Names from modules the user did not import are
--     intentionally hidden.
--
-- The query intentionally does /not/ filter by prefix or by syntactic
-- context. The LSP server is responsible for two follow-up steps:
--
--   1. Slice the prefix out of the current line (the token the user is
--      typing) and pass it to the LSP client; clients always prefix-filter.
--   2. Optionally narrow the kinds based on more refined context
--      (type positions, label slots, ...) — none of which v1 does.
--
-- Pure: no IO, no compiler state. Suitable for caching the result keyed
-- by file + position.
module Katari.Query.Completion
  ( CompletionItem (..),
    CompletionKind (..),
    completionsAt,

    -- * Anchor-based (type-driven) completion
    CompletionAnchor (..),
    resolveDottedPath,
    completionsOfModule,
    completionsOfFields,
    completionsOfCallLabels,
    findModuleIdByFilePath,
  )
where

import Control.Monad (foldM)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, listToMaybe, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.AST (Module (..), Phase (Zonked))
import Katari.Id (QualifiedName (..), VariableResolution (..))
import Katari.SemanticType (Resolved, SemanticType (..))
import Katari.SemanticType.Render (renderSemanticType)
import Katari.SourceSpan (Position, SourceSpan (..))
import Katari.Typechecker.Identifier
  ( ConstructorData (..),
    IdentifierResult (..),
    SymbolEntry (..),
  )
import Katari.Typechecker.ScopeIndex qualified as Scope
import Katari.Typechecker.Zonker (ZonkResult (..), lookupTopLevelType, lookupTypeInModule)

-- | Convenience alias for the resolved semantic type used in
-- label / member completion signatures.
type SemTy = SemanticType Resolved

-- | What "kind" of thing this completion represents — drives the icon
-- the editor renders.
data CompletionKind
  = CKLocalVariable
  | CKAgent
  | CKRequest
  | CKConstructor
  | CKTypeName
  | CKModule
  deriving (Eq, Show)

-- | A single suggestion entry returned to the LSP for a completion
-- request. Carries the surface label to insert, the kind for icon /
-- sorting, a one-line detail string (typically the type), and optional
-- documentation pulled from the declaration's @\"...\"@ annotation.
data CompletionItem = CompletionItem
  { ciLabel :: Text,
    ciKind :: CompletionKind,
    -- | Short detail (typically the inferred / declared type). Shown to
    -- the right of the label in the suggestion popup.
    ciDetail :: Maybe Text,
    -- | Documentation (typically the @\"...\"@ annotation, if any).
    ciDoc :: Maybe Text
  }
  deriving (Eq, Show)

-- | Compute completion candidates visible at @position@ inside @filePath@.
-- Returns lexical locals (walking the scope chain inside-out) plus the
-- module's visible top-level symbols (imported + own declarations), with
-- duplicate labels collapsed to the most-specific kind. The result is
-- in display order, suitable for handing straight back to the LSP.
completionsAt ::
  IdentifierResult ->
  ZonkResult ->
  FilePath ->
  Position ->
  [CompletionItem]
completionsAt idResult zonkResult filePath position =
  let localItems = localsAt
      topLevelItems = case currentModule of
        Nothing -> []
        Just moduleName ->
          let visible = Map.findWithDefault Map.empty moduleName idResult.moduleVisibleSymbols
           in concatMap symbolEntryToItems (Map.toList visible)
   in mergeByLabel (localItems ++ topLevelItems)
  where
    currentModule = findModuleNameByFilePath zonkResult filePath
    renderType = renderSemanticType

    -- Locals: walk the scope chain at position. Each frame is flattened
    -- with innermost first (= inner shadows outer on collisions).
    localsAt :: [CompletionItem]
    localsAt =
      let frames = Scope.scopeAt idResult.scopeIndex filePath position
       in concatMap symbolEntryToItems (Map.toList (Map.unions frames))

    -- A scope-level SymbolEntry may carry multiple slots (e.g. a data
    -- decl registers in variable + type + constructor); fan them out
    -- so completion shows each role distinctly. mergeByLabel later
    -- collapses duplicate labels to the most-specific kind.
    symbolEntryToItems :: (Text, SymbolEntry) -> [CompletionItem]
    symbolEntryToItems (name, entry) =
      catMaybes
        [ entry.variableSymbol >>= mkVariableItem name,
          entry.typeSymbol >>= mkTypeItem name,
          entry.moduleSymbol >>= mkModuleItem name
        ]

    lookupTypeHere :: VariableResolution -> Maybe (SemanticType Resolved)
    lookupTypeHere variableResolution = case (currentModule, variableResolution) of
      (_, ResolvedTopLevel qualifiedName) -> lookupTopLevelType qualifiedName zonkResult
      (Just moduleName, ResolvedLocal _) -> lookupTypeInModule moduleName variableResolution zonkResult
      _ -> Nothing

    mkVariableItem :: Text -> VariableResolution -> Maybe CompletionItem
    mkVariableItem name variableResolution = case variableResolution of
      ResolvedTopLevel qualifiedName -> do
        _vdata <- Map.lookup qualifiedName idResult.identifiedVariables
        let isCtor = Map.member qualifiedName idResult.identifiedConstructors
            isReq = Map.member qualifiedName idResult.identifiedRequests
            kind
              | isCtor = CKConstructor
              | isReq = CKRequest
              | otherwise = CKAgent
            detail = fmap renderType (lookupTypeHere variableResolution)
        pure
          CompletionItem
            { ciLabel = name,
              ciKind = kind,
              ciDetail = detail,
              ciDoc = Nothing
            }
      ResolvedLocal _ ->
        let detail = fmap renderType (lookupTypeHere variableResolution)
         in pure
              CompletionItem
                { ciLabel = name,
                  ciKind = CKLocalVariable,
                  ciDetail = detail,
                  ciDoc = Nothing
                }

    mkTypeItem :: Text -> QualifiedName -> Maybe CompletionItem
    mkTypeItem name qualifiedName = do
      _ <- Map.lookup qualifiedName idResult.identifiedTypes
      pure
        CompletionItem
          { ciLabel = name,
            ciKind = CKTypeName,
            ciDetail = Nothing,
            ciDoc = Nothing
          }

    mkModuleItem :: Text -> Text -> Maybe CompletionItem
    mkModuleItem name moduleName = do
      _ <- Map.lookup moduleName idResult.identifiedModules
      pure
        CompletionItem
          { ciLabel = name,
            ciKind = CKModule,
            ciDetail = Nothing,
            ciDoc = Nothing
          }

-- | Locate the module name that owns @filePath@. Mirrors the same lookup
-- used by hover / def-jump (= scan zonked modules by sourceSpan).
findModuleIdByFilePath :: IdentifierResult -> ZonkResult -> FilePath -> Maybe Text
findModuleIdByFilePath _ = findModuleNameByFilePath

findModuleNameByFilePath :: ZonkResult -> FilePath -> Maybe Text
findModuleNameByFilePath zonkResult filePath =
  listToMaybe
    [ moduleName
      | (moduleName, m :: Module Zonked) <- Map.toList zonkResult.zonkedModules,
        m.sourceSpan.filePath == filePath
    ]

-- ---------------------------------------------------------------------------
-- Anchor-based (type-driven) completion
-- ---------------------------------------------------------------------------

-- | The "thing" the cursor's LHS resolves to: either a module
-- reference (member completion lists the module's exports) or a
-- typed value (field / label completion based on the type's
-- structure).
data CompletionAnchor
  = AnchorModule Text
  | AnchorTyped SemTy
  deriving (Show)

-- | Resolve a dotted text path (= @foo@, @mod.bar@, @record.sub.field@…)
-- to a 'CompletionAnchor', using the scope at @position@ to resolve
-- the root segment and then walking each subsequent segment through
-- either module exports or structural field projection.
--
-- Returns 'Nothing' when the path doesn't resolve to a usable anchor
-- (= unknown name, segment not found, intermediate value of an
-- unrecognised shape).
resolveDottedPath ::
  IdentifierResult ->
  ZonkResult ->
  FilePath ->
  Position ->
  Text ->
  Maybe CompletionAnchor
resolveDottedPath idResult zonkResult filePath position dotted = do
  let segs = filter (not . Text.null) (Text.splitOn "." dotted)
  case segs of
    [] -> Nothing
    (rootSeg : rest) -> do
      root <- resolveRoot rootSeg
      foldM (stepAnchor idResult zonkResult) root rest
  where
    resolveRoot :: Text -> Maybe CompletionAnchor
    resolveRoot name = resolveLocal name `orElse` resolveModuleScoped name

    -- Locals (via ScopeIndex) — innermost shadows outer.
    resolveLocal name = do
      let frames = Scope.scopeAt idResult.scopeIndex filePath position
          merged = Map.unions frames
      entry <- Map.lookup name merged
      anchorFromEntry entry

    -- Module-level visibility (= imports + own decls + auto-injected).
    resolveModuleScoped name = do
      moduleName <- findModuleNameByFilePath zonkResult filePath
      visible <- Map.lookup moduleName idResult.moduleVisibleSymbols
      entry <- Map.lookup name visible
      anchorFromEntry entry

    anchorFromEntry :: SymbolEntry -> Maybe CompletionAnchor
    anchorFromEntry entry =
      (AnchorModule <$> entry.moduleSymbol)
        `orElse` (entry.variableSymbol >>= variableAnchor)

    variableAnchor :: VariableResolution -> Maybe CompletionAnchor
    variableAnchor variableResolution = case variableResolution of
      ResolvedTopLevel qualifiedName -> AnchorTyped <$> lookupTopLevelType qualifiedName zonkResult
      ResolvedLocal _ -> do
        moduleName <- findModuleNameByFilePath zonkResult filePath
        AnchorTyped <$> lookupTypeInModule moduleName variableResolution zonkResult

-- | Walk one path segment forward from an existing anchor.
stepAnchor ::
  IdentifierResult ->
  ZonkResult ->
  CompletionAnchor ->
  Text ->
  Maybe CompletionAnchor
stepAnchor idResult zonkResult anchor segment = case anchor of
  AnchorModule moduleName -> do
    exports <- Map.lookup moduleName idResult.moduleExports
    entry <- Map.lookup segment exports
    (AnchorModule <$> entry.moduleSymbol)
      `orElse` ( entry.variableSymbol
                   >>= \case
                     ResolvedTopLevel qualifiedName ->
                       AnchorTyped <$> lookupTopLevelType qualifiedName zonkResult
                     ResolvedLocal _ -> Nothing
               )
  AnchorTyped ty -> AnchorTyped <$> fieldTypeOf idResult zonkResult ty segment

-- | Project a single field out of a value-side semantic type. Mirrors
-- the dispatch table 'completionsOfFields' uses, but returns the
-- field's type rather than building completion items.
fieldTypeOf ::
  IdentifierResult ->
  ZonkResult ->
  SemTy ->
  Text ->
  Maybe SemTy
fieldTypeOf idResult zonkResult ty field = case ty of
  SemanticTypeData typeId -> do
    parameters <- dataConstructorParameters idResult zonkResult typeId
    Map.lookup field parameters
  SemanticTypeObject fields -> Map.lookup field fields
  SemanticTypeUnion branches -> do
    let projected = mapMaybe (\branch -> fieldTypeOf idResult zonkResult branch field) branches
    if length projected == length branches
      then Just (unionOfTypes projected)
      else Nothing
  _ -> Nothing

-- | Field map of the constructor that produces values of @typeQName@:
-- the @x: integer, y: string@ portion of @data Foo(x: integer, y: string)@.
dataConstructorParameters ::
  IdentifierResult ->
  ZonkResult ->
  QualifiedName ->
  Maybe (Map Text SemTy)
dataConstructorParameters idResult zonkResult typeQName = do
  (ctorQName, _cdata) <-
    listToMaybe
      [ (qualifiedName, c)
        | (qualifiedName, c) <- Map.toList idResult.identifiedConstructors,
          c.constructorTypeQName == typeQName
      ]
  ctorType <- lookupTopLevelType ctorQName zonkResult
  case ctorType of
    SemanticTypeFunction parameters _ _ -> Just parameters
    _ -> Nothing

-- | Smart join of multiple resolved branch types into a single
-- 'SemanticType Union'. Mirrors 'unionSemantic' but operates in
-- the 'Resolved' phase.
unionOfTypes :: [SemTy] -> SemTy
unionOfTypes = \case
  [] -> SemanticTypeNever
  [single] -> single
  branches -> SemanticTypeUnion branches

-- | Completion items for the public surface of @moduleId@: every
-- exported agent / req / data ctor / type. Used for @alias.@.
completionsOfModule ::
  IdentifierResult ->
  ZonkResult ->
  Text ->
  [CompletionItem]
completionsOfModule idResult zonkResult moduleName =
  let exports = Map.findWithDefault Map.empty moduleName idResult.moduleExports
      entryToItems (name, entry) =
        catMaybes
          [ entry.variableSymbol >>= mkVariableItemFor idResult zonkResult name,
            entry.typeSymbol >>= mkTypeItemFor idResult name,
            entry.moduleSymbol >>= mkModuleItemFor idResult name
          ]
   in mergeByLabel (concatMap entryToItems (Map.toList exports))

-- | Field labels reachable via @.@ on a value of @ty@. Handles:
--
--   * 'SemanticTypeData typeId' — fields are the data ctor's parameter labels.
--   * 'SemanticTypeObject fields' — fields are the structural object's keys.
--   * 'SemanticTypeUnion branches' — intersection of every branch's
--     field set (= safe: only labels present in /all/ branches are offered).
--   * Anything else — empty list.
completionsOfFields ::
  IdentifierResult ->
  ZonkResult ->
  SemTy ->
  [CompletionItem]
completionsOfFields idResult zonkResult ty =
  let renderType = renderSemanticType
      fields = fieldsOf ty
   in [ CompletionItem
          { ciLabel = label,
            ciKind = CKLocalVariable,
            ciDetail = Just (renderType fieldTy),
            ciDoc = Nothing
          }
        | (label, fieldTy) <- Map.toAscList fields
      ]
  where
    fieldsOf :: SemTy -> Map Text SemTy
    fieldsOf = \case
      SemanticTypeData typeId ->
        fromMaybe Map.empty (dataConstructorParameters idResult zonkResult typeId)
      SemanticTypeObject m -> m
      SemanticTypeUnion branches ->
        let perBranch = map fieldsOf branches
            common label = all (Map.member label) perBranch
            allLabels = Set.unions (map Map.keysSet perBranch)
            unionFor label = unionOfTypes [m Map.! label | m <- perBranch]
         in Map.fromList [(label, unionFor label) | label <- Set.toList allLabels, common label]
      _ -> Map.empty

-- | Call-argument labels reachable via @(@ on a value of @ty@.
-- Handles:
--
--   * 'SemanticTypeFunction params _ _' — labels are 'Map.keys params'.
--   * 'SemanticTypeUnion branches' — intersection of every branch's
--     label set (= only labels common to all branches; safe by
--     construction).
--   * Anything else — empty list.
--
-- @usedLabels@ filters out labels already supplied in the current call.
completionsOfCallLabels :: SemTy -> Set Text -> [CompletionItem]
completionsOfCallLabels ty usedLabels =
  [ CompletionItem
      { ciLabel = label,
        ciKind = CKLocalVariable,
        ciDetail = Nothing,
        ciDoc = Nothing
      }
    | label <- Set.toAscList (labelsOf ty),
      not (Set.member label usedLabels)
  ]
  where
    labelsOf :: SemTy -> Set Text
    labelsOf = \case
      SemanticTypeFunction parameters _ _ -> Map.keysSet parameters
      SemanticTypeUnion branches ->
        case map labelsOf branches of
          [] -> Set.empty
          (first : rest) -> foldr Set.intersection first rest
      _ -> Set.empty

-- ---------------------------------------------------------------------------
-- Per-kind item constructors (shared between bare completions, module
-- exports, and any future anchor-driven path)
-- ---------------------------------------------------------------------------

mkVariableItemFor ::
  IdentifierResult ->
  ZonkResult ->
  Text ->
  VariableResolution ->
  Maybe CompletionItem
mkVariableItemFor idResult zonkResult name variableResolution = case variableResolution of
  ResolvedTopLevel qualifiedName -> do
    _vdata <- Map.lookup qualifiedName idResult.identifiedVariables
    let isCtor = Map.member qualifiedName idResult.identifiedConstructors
        isReq = Map.member qualifiedName idResult.identifiedRequests
        kind
          | isCtor = CKConstructor
          | isReq = CKRequest
          | otherwise = CKAgent
        renderType = renderSemanticType
        detail = fmap renderType (lookupTopLevelType qualifiedName zonkResult)
    pure
      CompletionItem
        { ciLabel = name,
          ciKind = kind,
          ciDetail = detail,
          ciDoc = Nothing
        }
  ResolvedLocal _ ->
    pure
      CompletionItem
        { ciLabel = name,
          ciKind = CKLocalVariable,
          ciDetail = Nothing,
          ciDoc = Nothing
        }

mkTypeItemFor ::
  IdentifierResult ->
  Text ->
  QualifiedName ->
  Maybe CompletionItem
mkTypeItemFor idResult name qualifiedName = do
  _ <- Map.lookup qualifiedName idResult.identifiedTypes
  pure
    CompletionItem
      { ciLabel = name,
        ciKind = CKTypeName,
        ciDetail = Nothing,
        ciDoc = Nothing
      }

mkModuleItemFor ::
  IdentifierResult ->
  Text ->
  Text ->
  Maybe CompletionItem
mkModuleItemFor idResult name moduleName = do
  _ <- Map.lookup moduleName idResult.identifiedModules
  pure
    CompletionItem
      { ciLabel = name,
        ciKind = CKModule,
        ciDetail = Nothing,
        ciDoc = Nothing
      }

-- | Lightweight 'Maybe' biased choice. Replaces ad-hoc @orElse@ helpers.
orElse :: Maybe a -> Maybe a -> Maybe a
orElse Nothing b = b
orElse a _ = a

-- | When multiple items share a label, prefer the one with the more
-- specific kind. Order of preference: local > callable > type > module.
mergeByLabel :: [CompletionItem] -> [CompletionItem]
mergeByLabel items =
  Map.elems $
    Map.fromListWith pickMoreSpecific [(ci.ciLabel, ci) | ci <- items]
  where
    pickMoreSpecific :: CompletionItem -> CompletionItem -> CompletionItem
    pickMoreSpecific a b
      | rank a.ciKind <= rank b.ciKind = a
      | otherwise = b
    rank :: CompletionKind -> Int
    rank = \case
      CKLocalVariable -> 0
      CKConstructor -> 1
      CKAgent -> 2
      CKRequest -> 3
      CKTypeName -> 4
      CKModule -> 5

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
