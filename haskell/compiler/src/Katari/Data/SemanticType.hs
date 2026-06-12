module Katari.Data.SemanticType where

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Data.Id (GenericId (..))
import Katari.Data.QualifiedName (QualifiedName (..))

data FieldInformation where
  FieldInformation ::
    { semanticType :: SemanticType,
      optional :: Bool
    } ->
    FieldInformation
  deriving (Eq, Ord, Show)

data SemanticType where
  SemanticTypeNever :: SemanticType
  SemanticTypeUnknown :: SemanticType
  SemanticTypeNull :: SemanticType
  SemanticTypeInteger :: SemanticType
  SemanticTypeNumber :: SemanticType
  SemanticTypeString :: SemanticType
  SemanticTypeBoolean :: SemanticType
  SemanticTypeFile :: SemanticType
  SemanticTypeAgent :: SemanticType -> SemanticType -> SemanticEffect -> SemanticType
  SemanticTypeArray :: SemanticType -> SemanticType
  SemanticTypeTuple :: List SemanticType -> SemanticType
  SemanticTypeData :: QualifiedName -> Map Text SemanticGenericArgument -> SemanticType
  SemanticTypeObject :: Map Text FieldInformation -> SemanticType
  SemanticTypeRecord :: SemanticType -> SemanticType
  SemanticTypeUnion :: List SemanticType -> SemanticType
  SemanticTypeGeneric :: GenericId -> SemanticType
  SemanticTypeAttribute :: SemanticType -> SemanticAttribute -> SemanticType
  deriving (Eq, Ord, Show)

-- | Attribute: Public (default) <: Private
--   Public values cannot assign to agent parameters with private attributes.
--   let x : number of public = secret -- Error
--   let y : number of private = non_secret -- OK
data SemanticAttribute where
  SemanticAttributePublic :: SemanticAttribute -- Public Value (default)
  SemanticAttributePrivate :: SemanticAttribute -- Private Value
  SemanticAttributeUnion :: List SemanticAttribute -> SemanticAttribute -- Union of attributes
  SemanticAttributeGeneric :: GenericId -> SemanticAttribute -- Generic attribute
  deriving (Eq, Ord, Show)

data SemanticEffect where
  SemanticEffectPure :: SemanticEffect
  SemanticEffectAny :: SemanticEffect
  SemanticEffectRequest :: QualifiedName -> Map Text SemanticGenericArgument -> SemanticEffect
  SemanticEffectUnion :: List SemanticEffect -> SemanticEffect
  -- | {...(eff expr), req1[generics], req2[generics]}
  -- Union:  req1[int] | req1[string] ~> req1[int | string]  (if covariant)
  -- Overwrite: {...req1[int], req1[string]} ~> req1[string]
  SemanticEffectOverwrite :: SemanticEffect -> List (QualifiedName, Map Text SemanticGenericArgument) -> SemanticEffect
  SemanticEffectGeneric :: GenericId -> SemanticEffect
  deriving (Eq, Ord, Show)

data SemanticGenericArgument where
  SemanticGenericArgumentType :: SemanticType -> SemanticGenericArgument
  SemanticGenericArgumentEffect :: SemanticEffect -> SemanticGenericArgument
  SemanticGenericArgumentAttribute :: SemanticAttribute -> SemanticGenericArgument
  deriving (Eq, Ord, Show)

-- | Render a type in Katari surface syntax (@integer@, @array[T]@, @{x: T, y?: U}@,
-- @agent(x: T) -> R with req@, @T1 | T2@, @T of private@ …).
--
-- Display-oriented liberties:
--   * a generic id renders as a kind-tagged placeholder (@T0@ / @E0@ / @A0@) until declaration
--     names are threaded through;
--   * a data type or request with several arguments labels them (@foo[A: integer, B: string]@),
--     because the semantic representation is keyed by parameter name, not position;
--   * an agent whose argument is not an object (e.g. a generic) has no surface form and renders
--     its argument as @...T@.
renderSemanticType :: SemanticType -> Text
renderSemanticType = render False
  where
    render parenthesise semanticType = case semanticType of
      SemanticTypeNever -> "never"
      SemanticTypeUnknown -> "unknown"
      SemanticTypeNull -> "null"
      SemanticTypeInteger -> "integer"
      SemanticTypeNumber -> "number"
      SemanticTypeString -> "string"
      SemanticTypeBoolean -> "boolean"
      SemanticTypeFile -> "file"
      SemanticTypeArray itemType -> "array[" <> render False itemType <> "]"
      SemanticTypeRecord SemanticTypeUnknown -> "record"
      SemanticTypeRecord valueType -> "record[" <> render False valueType <> "]"
      SemanticTypeTuple itemTypes -> "(" <> Text.intercalate ", " (render False <$> itemTypes) <> ")"
      SemanticTypeData qualifiedName arguments -> qualifiedName.name <> renderSemanticGenericArguments arguments
      SemanticTypeGeneric genericId -> "T" <> renderGenericId genericId
      SemanticTypeObject fields ->
        "{" <> Text.intercalate ", " [fieldName <> renderField field | (fieldName, field) <- Map.toAscList fields] <> "}"
      SemanticTypeAgent parameterType returnType effect ->
        let parameterText = case parameterType of
              SemanticTypeObject parameters ->
                Text.intercalate ", " [parameterName <> renderField parameter | (parameterName, parameter) <- Map.toAscList parameters]
              other -> "..." <> render False other
            withText = case renderSemanticEffectLeaves effect of
              [] -> "" -- NOTE: a pure agent elides the `with` clause
              effectLeaves -> " with " <> Text.intercalate " | " effectLeaves
         in parenthesiseIf parenthesise $ "agent(" <> parameterText <> ") -> " <> render True returnType <> withText
      SemanticTypeUnion branches ->
        parenthesiseIf parenthesise $ Text.intercalate " | " (render True <$> branches)
      SemanticTypeAttribute baseType attribute ->
        let attributeText = case attribute of
              SemanticAttributeUnion _ -> "(" <> renderSemanticAttribute attribute <> ")"
              _ -> renderSemanticAttribute attribute
         in render True baseType <> " of " <> attributeText
    -- An optional field renders @?: T@ with @null@ elided from its type (the @?@ already conveys
    -- it, undoing the @null | T@ widening); a required one renders @: T@.
    renderField field
      | field.optional = "?: " <> render False (stripNull field.semanticType)
      | otherwise = ": " <> render False field.semanticType
    stripNull = \case
      SemanticTypeUnion branches -> case filter (/= SemanticTypeNull) branches of
        [single] -> single
        remaining -> SemanticTypeUnion remaining
      other -> other
    parenthesiseIf parenthesise body = if parenthesise then "(" <> body <> ")" else body

-- | Render an effect in the surface @with@ syntax: @pure@, @all@, @req[T]@, @a | b@,
-- @{...base, req[T]}@.
renderSemanticEffect :: SemanticEffect -> Text
renderSemanticEffect effect = case renderSemanticEffectLeaves effect of
  [] -> "pure"
  effectLeaves -> Text.intercalate " | " effectLeaves

-- | The effect rendered as union leaves; empty means pure (the caller decides whether to spell it
-- @pure@ or elide a @with@ clause).
renderSemanticEffectLeaves :: SemanticEffect -> List Text
renderSemanticEffectLeaves = \case
  SemanticEffectPure -> []
  SemanticEffectAny -> ["all"]
  SemanticEffectRequest qualifiedName arguments -> [qualifiedName.name <> renderSemanticGenericArguments arguments]
  SemanticEffectGeneric genericId -> ["E" <> renderGenericId genericId]
  SemanticEffectUnion effects -> concatMap renderSemanticEffectLeaves effects
  SemanticEffectOverwrite baseEffect overwrites ->
    [ "{..."
        <> renderSemanticEffect baseEffect
        <> Text.concat [", " <> qualifiedName.name <> renderSemanticGenericArguments arguments | (qualifiedName, arguments) <- overwrites]
        <> "}"
    ]

renderSemanticAttribute :: SemanticAttribute -> Text
renderSemanticAttribute = \case
  SemanticAttributePublic -> "public"
  SemanticAttributePrivate -> "private"
  SemanticAttributeGeneric genericId -> "A" <> renderGenericId genericId
  SemanticAttributeUnion attributes -> Text.intercalate " | " (renderSemanticAttribute <$> attributes)

renderSemanticGenericArgument :: SemanticGenericArgument -> Text
renderSemanticGenericArgument = \case
  SemanticGenericArgumentType semanticType -> renderSemanticType semanticType
  SemanticGenericArgumentEffect effect -> renderSemanticEffect effect
  SemanticGenericArgumentAttribute attribute -> renderSemanticAttribute attribute

-- | The bracketed argument list of a data type or request; empty renders to nothing. A single
-- argument renders positionally (@foo[integer]@); several are labelled by parameter name
-- (@foo[A: integer, B: string]@) since the map carries no declaration order.
renderSemanticGenericArguments :: Map Text SemanticGenericArgument -> Text
renderSemanticGenericArguments arguments = case Map.toAscList arguments of
  [] -> ""
  [(_, argument)] -> "[" <> renderSemanticGenericArgument argument <> "]"
  manyArguments -> "[" <> Text.intercalate ", " [argumentName <> ": " <> renderSemanticGenericArgument argument | (argumentName, argument) <- manyArguments] <> "]"

renderGenericId :: GenericId -> Text
renderGenericId (GenericId identifier) = Text.pack (show identifier)
