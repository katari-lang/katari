-- | Pretty-printer for 'SemanticType' that produces Katari surface-like
-- syntax (@integer@, @string@, @[T]@, @(x: T1) -> T2@, @T1 | T2@…).
-- Used by hover / completion in the LSP layer.
--
-- The data-type case takes a name lookup ('TypeId' → name) so the
-- caller can resolve user-declared data names without exposing the
-- whole 'IdentifierResult' to this layer.
module Katari.SemanticType.Render
  ( renderSemanticType,
    renderSemanticRequest,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Id (RequestId, TypeId)
import Katari.SemanticType qualified as ST

-- | @typeNames@ resolves user-declared 'TypeId's to surface names.
-- @reqNames@ resolves request 'VariableId's to surface names. Both can
-- be empty if the caller does not have those tables handy — the
-- renderer falls back to a placeholder.
renderSemanticType ::
  Map TypeId Text ->
  Map RequestId Text ->
  ST.SemanticType ST.Resolved ->
  Text
renderSemanticType typeNames reqNames = render False
  where
    render :: Bool -> ST.SemanticType ST.Resolved -> Text
    render parenthesise semanticType = case semanticType of
      ST.SemanticTypeNever -> "never"
      ST.SemanticTypeUnknown -> "unknown"
      ST.SemanticTypeNull -> "null"
      ST.SemanticTypeInteger -> "integer"
      ST.SemanticTypeNumber -> "number"
      ST.SemanticTypeString -> "string"
      ST.SemanticTypeSecret -> "secret"
      ST.SemanticTypeBoolean -> "boolean"
      ST.SemanticTypeLiteralInteger n -> Text.pack (show n)
      ST.SemanticTypeLiteralString s -> "\"" <> s <> "\""
      ST.SemanticTypeLiteralBoolean True -> "true"
      ST.SemanticTypeLiteralBoolean False -> "false"
      ST.SemanticTypeFunctionAny -> "agent"
      ST.SemanticTypeArray inner -> "[" <> render False inner <> "]"
      ST.SemanticTypeRecord valueType ->
        "record[" <> render False valueType <> "]"
      ST.SemanticTypeTuple xs ->
        "(" <> Text.intercalate ", " (map (render False) xs) <> ")"
      ST.SemanticTypeUnion branches ->
        let body = Text.intercalate " | " (map (render True) branches)
         in if parenthesise then "(" <> body <> ")" else body
      ST.SemanticTypeData typeId ->
        case Map.lookup typeId typeNames of
          Just name -> name
          Nothing -> "<data:" <> Text.pack (show typeId) <> ">"
      ST.SemanticTypeObject fields ->
        "{ "
          <> Text.intercalate
            ", "
            [k <> ": " <> render False v | (k, v) <- Map.toAscList fields]
          <> " }"
      ST.SemanticTypeFunction parameters returnType effects ->
        let parameterText =
              Text.intercalate
                ", "
                [k <> ": " <> render False v | (k, v) <- Map.toAscList parameters]
            effectsText = renderSemanticRequest reqNames effects
            body =
              "("
                <> parameterText
                <> ") -> "
                <> render True returnType
                <> ( if Text.null effectsText
                       then ""
                       else " with " <> effectsText
                   )
         in if parenthesise then "(" <> body <> ")" else body

-- | Render a 'SemanticRequest' as @{a, b, c}@. Empty requests render
-- to the empty string (caller decides whether to elide a leading
-- @with@).
renderSemanticRequest ::
  Map RequestId Text ->
  ST.SemanticRequest ST.Resolved ->
  Text
renderSemanticRequest reqNames (ST.SemanticRequest elements) =
  let names = [renderElem e | e <- Set.toAscList elements]
   in if null names
        then ""
        else "{" <> Text.intercalate ", " names <> "}"
  where
    renderElem :: ST.SemanticRequestElement ST.Resolved -> Text
    renderElem = \case
      ST.SemanticRequestElementConcrete rid ->
        case Map.lookup rid reqNames of
          Just n -> n
          Nothing -> "<req:" <> Text.pack (show rid) <> ">"
