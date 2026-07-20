-- | Completion queries over a 'QuerySnapshot'. Three sources, matching the LSP handler's dispatch:
--
--   * 'completionsAt' — everything visible at a position (locals, top-levels, imports, and the
--     default-import module qualifiers), for bare-identifier completion.
--   * 'resolveDottedPath' + 'completionsOfModule' / 'completionsOfFields' — member completion after
--     @lhs.@: the left-hand side resolves to a module (list its exports) or to a typed value (list
--     its object fields).
--   * 'completionsOfCallLabels' — parameter-label completion inside a call's argument list.
--
-- The LSP client applies the prefix filter, so every query returns the full candidate set.
module Katari.Query.Completion where

import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Data.Id (TypeResolution (..), VariableResolution (..))
import Katari.Data.ModuleName (ModuleName, covers, lastSegment, moduleNameFromSegments, renderModuleName)
import Katari.Data.SemanticType (FieldInformation (..), SemanticType, renderSemanticType)
import Katari.Data.SourceSpan (Position)
import Katari.Identifier (defaultImportScope)
import Katari.Identifier.Monad
  ( ExportedSymbol (..),
    ImportContext (..),
    ModuleInterface (..),
    Scope (..),
    scopeAt,
  )
import Katari.Query
  ( DeclarationInformation (..),
    DeclarationKind (..),
    QuerySnapshot (..),
    localVariableTypeOf,
    objectFieldsOf,
    parameterObjectFields,
    stripAttributes,
    topLevelValueTypeOf,
  )
import Katari.Stdlib qualified as Stdlib

---------------------------------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------------------------------

data CompletionKind
  = CompletionKindLocalVariable
  | CompletionKindAgent
  | CompletionKindRequest
  | CompletionKindConstructor
  | CompletionKindTypeName
  | CompletionKindModule
  | CompletionKindField
  deriving stock (Eq, Show)

data CompletionItem = CompletionItem
  { label :: Text,
    kind :: CompletionKind,
    -- | Short type / signature line shown next to the label.
    detail :: Maybe Text,
    -- | The declaration's doc annotation, when present.
    documentation :: Maybe Text,
    -- | What accepting the item inserts, when that differs from the label — a parameter label
    -- inserts @name = @ so the caller lands ready to type the argument value.
    insertText :: Maybe Text
  }
  deriving stock (Eq, Show)

---------------------------------------------------------------------------------------------------
-- Scope completion (bare identifiers)
---------------------------------------------------------------------------------------------------

-- | Everything visible at a position: the module's recorded symbols (locals, top-levels, imports)
-- over the default-import base scope (the stdlib qualifiers, which are installed as ambient scope
-- rather than recorded symbols — see 'Katari.Identifier.defaultImportScope').
completionsAt :: QuerySnapshot -> ModuleName -> Position -> List CompletionItem
completionsAt snapshot moduleName position =
  moduleItems <> variableItems <> typeItems
  where
    scope = scopeAtPosition snapshot moduleName position
    variableItems =
      [ valueItem snapshot moduleName name resolution
        | (name, resolution) <- Map.toAscList scope.variableBindings
      ]
    typeItems =
      [ typeItem snapshot name resolution
        | (name, resolution) <- Map.toAscList scope.typeBindings
      ]
    moduleItems =
      [ moduleItem name
        | (name, _) <- Map.toAscList scope.moduleBindings
      ]

-- | The resolution scope at a position: recorded symbols win over the ambient default-import base.
scopeAtPosition :: QuerySnapshot -> ModuleName -> Position -> Scope
scopeAtPosition snapshot moduleName position =
  Scope
    { variableBindings = Map.union symbolScope.variableBindings baseScope.variableBindings,
      typeBindings = Map.union symbolScope.typeBindings baseScope.typeBindings,
      moduleBindings = Map.union symbolScope.moduleBindings baseScope.moduleBindings
    }
  where
    symbolScope = case Map.lookup moduleName snapshot.symbolTables of
      Nothing -> emptySymbolScope
      Just table -> scopeAt table position
    emptySymbolScope = Scope {variableBindings = Map.empty, typeBindings = Map.empty, moduleBindings = Map.empty}
    baseScope =
      defaultImportScope
        ImportContext
          { moduleInterfaces = snapshot.moduleInterfaces,
            defaultImports = Stdlib.defaultImports
          }

---------------------------------------------------------------------------------------------------
-- Member completion (after `lhs.`)
---------------------------------------------------------------------------------------------------

-- | What a dotted left-hand side resolves to.
data Anchor
  = AnchorModule ModuleName
  | AnchorTyped SemanticType
  deriving stock (Show)

-- | Resolve a dotted path like @foo.bar@ at a position: the head segment through the scope, each
-- further segment through the module's exports (one level — module members are @qualifier.name@)
-- and then through object fields.
resolveDottedPath :: QuerySnapshot -> ModuleName -> Position -> Text -> Maybe Anchor
resolveDottedPath snapshot moduleName position path = case Text.splitOn "." path of
  [] -> Nothing
  headSegment : rest -> do
    let scope = scopeAtPosition snapshot moduleName position
    case Map.lookup headSegment scope.moduleBindings of
      Just referencedModule -> resolveInModule snapshot referencedModule rest
      Nothing -> do
        resolution <- Map.lookup headSegment scope.variableBindings
        anchorType <- typeOfVariableResolution snapshot moduleName resolution
        chaseFields anchorType rest

resolveInModule :: QuerySnapshot -> ModuleName -> List Text -> Maybe Anchor
resolveInModule snapshot referencedModule = \case
  [] -> Just (AnchorModule referencedModule)
  segment : rest -> case exportedResolution segment of
    Just resolution -> do
      anchorType <- typeOfVariableResolution snapshot referencedModule resolution
      chaseFields anchorType rest
    -- Not an export: the segment may name a submodule (@prelude.oauth@, @ai.types@), which has an
    -- interface of its own but no entry in the parent's exports.
    Nothing -> do
      let submodule = submoduleOf referencedModule segment
      _ <- Map.lookup submodule snapshot.moduleInterfaces
      resolveInModule snapshot submodule rest
  where
    exportedResolution segment = do
      interface <- Map.lookup referencedModule snapshot.moduleInterfaces
      exported <- Map.lookup segment interface.exports
      exported.variable

-- | Walk the remaining path segments through object fields.
chaseFields :: SemanticType -> List Text -> Maybe Anchor
chaseFields semanticType = \case
  [] -> Just (AnchorTyped semanticType)
  segment : rest -> do
    field <- Map.lookup segment (objectFieldsOf semanticType)
    chaseFields field.semanticType rest

typeOfVariableResolution :: QuerySnapshot -> ModuleName -> VariableResolution -> Maybe SemanticType
typeOfVariableResolution snapshot moduleName = \case
  VariableResolutionLocalVariable localVariableId ->
    localVariableTypeOf snapshot moduleName localVariableId
  VariableResolutionQualifiedName qualifiedName ->
    topLevelValueTypeOf snapshot qualifiedName

-- | A module's exports as completion items, followed by its direct submodules (@prelude.@ lists
-- @string@, @oauth@, ... alongside @throw@). A name exporting both a value and a type (a request /
-- data declaration) yields one item, classified by its value side.
completionsOfModule :: QuerySnapshot -> ModuleName -> List CompletionItem
completionsOfModule snapshot referencedModule = exportItems <> submoduleItems
  where
    exportItems = case Map.lookup referencedModule snapshot.moduleInterfaces of
      Nothing -> []
      Just interface ->
        [ item
          | (name, exported) <- Map.toAscList interface.exports,
            item <- exportedItems name exported
        ]
    exportedItems name exported = case (exported.variable, exported.typeLevel) of
      (Just resolution, _) -> [valueItem snapshot referencedModule name resolution]
      (Nothing, Just resolution) -> [typeItem snapshot name resolution]
      (Nothing, Nothing) -> []
    submoduleItems =
      [ moduleItem (lastSegment interfaceModule)
        | interfaceModule <- Map.keys snapshot.moduleInterfaces,
          isDirectSubmodule referencedModule interfaceModule
      ]

-- | Whether @candidate@ is exactly one segment below @parent@ (@prelude@ → @prelude.oauth@ yes,
-- @prelude.oauth.deeper@ no).
isDirectSubmodule :: ModuleName -> ModuleName -> Bool
isDirectSubmodule parent candidate =
  parent /= candidate
    && covers parent candidate
    && not ("." `Text.isInfixOf` remainder)
  where
    remainder = Text.drop (Text.length (renderModuleName parent) + 1) (renderModuleName candidate)

-- | The submodule of @parent@ named by one further segment.
submoduleOf :: ModuleName -> Text -> ModuleName
submoduleOf parent segment = moduleNameFromSegments [renderModuleName parent, segment]

-- | A typed value's object fields as completion items.
completionsOfFields :: SemanticType -> List CompletionItem
completionsOfFields semanticType =
  [ CompletionItem
      { label = name,
        kind = CompletionKindField,
        detail = Just (renderSemanticType field.semanticType),
        documentation = Nothing,
        insertText = Nothing
      }
    | (name, field) <- Map.toAscList (objectFieldsOf semanticType)
  ]

---------------------------------------------------------------------------------------------------
-- Call-label completion
---------------------------------------------------------------------------------------------------

-- | The parameter labels a callable still accepts, given the labels already written in the call.
-- Accepting one inserts @name = @, leaving the cursor ready for the argument value.
completionsOfCallLabels :: SemanticType -> Set Text -> List CompletionItem
completionsOfCallLabels callableType usedLabels =
  [ CompletionItem
      { label = name,
        kind = CompletionKindField,
        detail = Just (renderSemanticType parameterType),
        documentation = Nothing,
        insertText = Just (name <> " = ")
      }
    | (name, parameterType) <- Map.toAscList (parameterObjectFields (stripAttributes callableType)),
      not (Set.member name usedLabels)
  ]

---------------------------------------------------------------------------------------------------
-- Item builders
---------------------------------------------------------------------------------------------------

valueItem :: QuerySnapshot -> ModuleName -> Text -> VariableResolution -> CompletionItem
valueItem snapshot moduleName name resolution = case resolution of
  VariableResolutionLocalVariable localVariableId ->
    CompletionItem
      { label = name,
        kind = CompletionKindLocalVariable,
        detail = renderSemanticType <$> localVariableTypeOf snapshot moduleName localVariableId,
        documentation = Nothing,
        insertText = Nothing
      }
  VariableResolutionQualifiedName qualifiedName ->
    case Map.lookup qualifiedName snapshot.valueDeclarations of
      Nothing ->
        CompletionItem
          { label = name,
            kind = CompletionKindAgent,
            detail = Nothing,
            documentation = Nothing,
            insertText = Nothing
          }
      Just declaration ->
        CompletionItem
          { label = name,
            kind = valueKindOf declaration.kind,
            detail = renderSemanticType <$> declaration.declaredType,
            documentation = declaration.documentation,
            insertText = Nothing
          }
  where
    valueKindOf = \case
      DeclarationKindAgent -> CompletionKindAgent
      DeclarationKindRequest -> CompletionKindRequest
      DeclarationKindConstructor -> CompletionKindConstructor
      DeclarationKindType -> CompletionKindTypeName

typeItem :: QuerySnapshot -> Text -> TypeResolution -> CompletionItem
typeItem snapshot name resolution = case resolution of
  TypeResolutionGeneric _ ->
    CompletionItem
      { label = name,
        kind = CompletionKindTypeName,
        detail = Nothing,
        documentation = Nothing,
        insertText = Nothing
      }
  TypeResolutionQualifiedName qualifiedName ->
    case Map.lookup qualifiedName snapshot.typeDeclarations of
      Nothing ->
        CompletionItem
          { label = name,
            kind = CompletionKindTypeName,
            detail = Nothing,
            documentation = Nothing,
            insertText = Nothing
          }
      Just declaration ->
        CompletionItem
          { label = name,
            kind = typeKindOf declaration.kind,
            detail = Nothing,
            documentation = declaration.documentation,
            insertText = Nothing
          }
  where
    typeKindOf = \case
      DeclarationKindRequest -> CompletionKindRequest
      _ -> CompletionKindTypeName

moduleItem :: Text -> CompletionItem
moduleItem name =
  CompletionItem
    { label = name,
      kind = CompletionKindModule,
      detail = Nothing,
      documentation = Nothing,
      insertText = Nothing
    }
