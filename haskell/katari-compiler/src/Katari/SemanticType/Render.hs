-- | Pretty-printer for 'SemanticType' that produces Katari surface-like
-- syntax (@integer@, @string@, @[T]@, @(x: T1) -> T2@, @T1 | T2@…).
-- Used by hover / completion in the LSP layer.
--
-- The data-type case takes a name lookup ('TypeId' → name) so the
-- caller can resolve user-declared data names without exposing the
-- whole 'IdentifierResult' to this layer.
module Katari.SemanticType.Render
  ( renderSemanticType,
    renderSemanticEffect,
  )
where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Common (QualifiedName (..))
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
      ST.SemanticTypeFile -> "file"
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
      -- A raw generic parameter has no surface name in 'SemanticType' (the
      -- name lives in the declaration); hover usually sees the instantiated
      -- type instead, so a placeholder is sufficient here.
      ST.SemanticTypeGeneric _ -> "<generic>"
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
                [ k <> (if parameter.optional then "?: " else ": ") <> render False parameter.parameterType
                  | (k, parameter) <- Map.toAscList parameters
                ]
            effectsText = renderSemanticEffect effects
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

-- | Render a 'SemanticEffect' as @a | b | c@ (the surface @with@ syntax),
-- flattening the union tree. The empty (pure) effect renders to the empty
-- string (the caller decides whether to elide a leading @with@).
renderSemanticEffect ::
  ST.SemanticEffect ST.Resolved ->
  Text
renderSemanticEffect = Text.intercalate " | " . leaves
  where
    leaves :: ST.SemanticEffect ST.Resolved -> [Text]
    leaves = \case
      -- 'pure' elides to nothing here so a pure function renders as
      -- @() -> R@ (no @with@ clause), matching the prior empty-effect output.
      ST.SemanticEffectPure -> []
      ST.SemanticEffectRequest qualifiedName -> [qualifiedName.name]
      -- An effect generic has no surface name in 'SemanticEffect' (it lives in
      -- the declaration); a placeholder suffices for hover.
      ST.SemanticEffectGeneric _ -> ["<effect>"]
      ST.SemanticEffectUnion branches -> concatMap leaves branches
