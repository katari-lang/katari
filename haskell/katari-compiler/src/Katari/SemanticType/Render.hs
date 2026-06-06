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
      ST.SemanticTypeRecord -> "record"
      ST.SemanticTypeTuple xs ->
        "(" <> Text.intercalate ", " (map (render False) xs) <> ")"
      ST.SemanticTypeUnion branches ->
        let body = Text.intercalate " | " (map (render True) branches)
         in if parenthesise then "(" <> body <> ")" else body
      ST.SemanticTypeData qualifiedName arguments
        | null arguments -> qualifiedName.name
        | otherwise ->
            qualifiedName.name <> "[" <> Text.intercalate ", " (map renderArgument arguments) <> "]"
      -- A raw generic parameter has no surface name in 'SemanticType' (the
      -- name lives in the declaration); hover usually sees the instantiated
      -- type instead, so a placeholder is sufficient here.
      ST.SemanticTypeGeneric _ -> "<generic>"
      ST.SemanticTypeObject fields ->
        "{ "
          <> Text.intercalate
            ", "
            [k <> renderField field | (k, field) <- Map.toAscList fields]
          <> " }"
      ST.SemanticTypeFunction parameterType returnType effects ->
        let -- The usual parameter type is an object (named params), rendered as
            -- @l1: T1, l2: T2@; a spread signature makes it some other type,
            -- rendered as @...T@.
            parameterText = case parameterType of
              ST.SemanticTypeObject parameters ->
                Text.intercalate
                  ", "
                  [ k <> renderField parameter
                    | (k, parameter) <- Map.toAscList parameters
                  ]
              other -> "..." <> render False other
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
    -- A parameter / object field. An optional one renders @?: T@ with @null@
    -- elided from its type (the @?@ already conveys it), undoing the @null | T@
    -- widening; a required one renders @: T@.
    renderField :: ST.Parameter ST.Resolved -> Text
    renderField field
      | field.optional = "?: " <> render False (stripNull field.parameterType)
      | otherwise = ": " <> render False field.parameterType
    stripNull :: ST.SemanticType ST.Resolved -> ST.SemanticType ST.Resolved
    stripNull = \case
      ST.SemanticTypeUnion branches -> ST.unionSemantic (filter (/= ST.SemanticTypeNull) branches)
      other -> other
    -- A generic @data@ argument: a type renders as itself, an effect as its
    -- @with@-style text.
    renderArgument :: ST.SemanticGenericArgument ST.Resolved -> Text
    renderArgument = \case
      ST.SemanticGenericArgumentType argumentType -> render False argumentType
      ST.SemanticGenericArgumentEffect argumentEffect -> renderSemanticEffect argumentEffect

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
      ST.SemanticEffectAll -> ["all"]
      ST.SemanticEffectRequest qualifiedName arguments
        | null arguments -> [qualifiedName.name]
        | otherwise -> [qualifiedName.name <> "[" <> Text.intercalate ", " (map renderArgument arguments) <> "]"]
      -- An effect generic has no surface name in 'SemanticEffect' (it lives in
      -- the declaration); a placeholder suffices for hover.
      ST.SemanticEffectGeneric _ -> ["<effect>"]
      ST.SemanticEffectUnion branches -> concatMap leaves branches
    renderArgument :: ST.SemanticGenericArgument ST.Resolved -> Text
    renderArgument = \case
      ST.SemanticGenericArgumentType argumentType -> renderSemanticType argumentType
      ST.SemanticGenericArgumentEffect argumentEffect -> renderSemanticEffect argumentEffect
