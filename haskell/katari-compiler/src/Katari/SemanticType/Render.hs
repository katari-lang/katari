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

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Common (QualifiedName (..), renderQualifiedName)
import Katari.SemanticType qualified as ST

renderSemanticType ::
  ST.SemanticType ST.Resolved ->
  Text
renderSemanticType = render False
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
      ST.SemanticTypeData qualifiedName -> qualifiedName.name
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
            effectsText = renderSemanticRequest effects
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
  ST.SemanticRequest ST.Resolved ->
  Text
renderSemanticRequest (ST.SemanticRequest elements) =
  let names = [renderElem e | e <- Set.toAscList elements]
   in if null names
        then ""
        else "{" <> Text.intercalate ", " names <> "}"
  where
    renderElem :: ST.SemanticRequestElement ST.Resolved -> Text
    renderElem = \case
      ST.SemanticRequestElementConcrete qualifiedName -> qualifiedName.name
