-- | A passive representation of the subset of JSON Schema the Katari runtime needs (the @input@ /
-- @output@ / @requests@ schemas carried by every callable, see "Katari.Data.IR"). It only models
-- the keywords Katari emits and serialises to a standard JSON Schema document via its 'ToJSON'
-- instance — apart from the generic-reference sentinel ('SchemaGeneric'), which the runtime resolves
-- into a standard schema at @get_metadata@.
--
-- This is the representation only. The conversion from a 'Katari.Data.SemanticType' to a 'JSONSchema'
-- — @file@ / @agent@ / @data@ / @private@-attributed types are not obvious — lives in "Katari.Schema";
-- "Katari.Lowering" then threads its results into each callable's 'Katari.Data.IR.SchemaInformation'.
--
-- The 'FromJSON' instance is the wire's inverse, for consumers that read schemas back out of a
-- deployed IR (the CLI walks them to prompt for agent arguments). One lossy spot: JSON object keys
-- are unordered, so a decoded 'ObjectSchema' holds its properties in key order, not declaration
-- order — readers must not rely on the written order.
module Katari.Data.JSONSchema where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.Id (GenericId)

-- | A JSON Schema document. The shapes the compiler emits: the primitive @type@s, @const@, @array@,
-- @object@, @anyOf@ unions, the empty schema (anything), the @{"not": {}}@ bottom, and a generic
-- reference slot ('SchemaGeneric') serialised as a sentinel for the runtime to fill.
data JSONSchema where
  -- | @{}@ — matches any value (e.g. @unknown@, @json@).
  SchemaAny :: JSONSchema
  -- | @{"not": {}}@ — matches nothing (e.g. the output of a @-> never@ request).
  SchemaNever :: JSONSchema
  -- | @{"type": "null"}@
  SchemaNull :: JSONSchema
  -- | @{"type": "boolean"}@
  SchemaBoolean :: JSONSchema
  -- | @{"type": "integer"}@
  SchemaInteger :: JSONSchema
  -- | @{"type": "number"}@
  SchemaNumber :: JSONSchema
  -- | @{"type": "string"}@
  SchemaString :: JSONSchema
  -- | @{"const": v}@ — exactly this literal (e.g. a data constructor's @$constructor@ tag).
  SchemaConst :: Value -> JSONSchema
  -- | @{"type": "array", "items": s}@ — a homogeneous array (every element matches @s@).
  SchemaArray :: JSONSchema -> JSONSchema
  -- | @{"type": "array", "prefixItems": [...]}@ — a fixed-length tuple (one schema per position).
  SchemaTuple :: List JSONSchema -> JSONSchema
  -- | @{"type": "object", "properties": {...}, "required": [...], "additionalProperties": b | s}@
  SchemaObject :: ObjectSchema -> JSONSchema
  -- | @{"anyOf": [...]}@ — a union.
  SchemaAnyOf :: List JSONSchema -> JSONSchema
  -- | A type-generic reference slot (by 'GenericId'). Serialised to the IR wire as a @{"$generic": id}@
  -- sentinel; the runtime fills it at @get_metadata@ from a value's attached substitution (mapped onto
  -- this id through 'Katari.Data.IR.SchemaInfo.genericBindings'), so it never appears in the final
  -- AI-facing schema.
  SchemaGeneric :: GenericId -> JSONSchema
  deriving stock (Eq, Show)

-- | The body of a 'SchemaObject'. Field order is preserved as written.
data ObjectSchema = ObjectSchema
  { properties :: List (Text, JSONSchema),
    required :: List Text,
    additionalProperties :: AdditionalProperties
  }
  deriving stock (Eq, Show)

-- | A JSON Schema @additionalProperties@ value: a boolean (an open or closed object) or the schema
-- every not-explicitly-named key must satisfy (the value type of a @record[T]@).
data AdditionalProperties where
  AdditionalPropertiesBoolean :: Bool -> AdditionalProperties
  AdditionalPropertiesSchema :: JSONSchema -> AdditionalProperties
  deriving stock (Eq, Show)

instance ToJSON JSONSchema where
  toJSON schema = case schema of
    SchemaAny -> object []
    SchemaNever -> object ["not" .= object []]
    SchemaNull -> typed "null"
    SchemaBoolean -> typed "boolean"
    SchemaInteger -> typed "integer"
    SchemaNumber -> typed "number"
    SchemaString -> typed "string"
    SchemaConst constant -> object ["const" .= constant]
    SchemaArray items -> object ["type" .= ("array" :: Text), "items" .= items]
    SchemaTuple itemSchemas -> object ["type" .= ("array" :: Text), "prefixItems" .= itemSchemas]
    SchemaObject objectSchema ->
      object
        [ "type" .= ("object" :: Text),
          "properties" .= object [Key.fromText fieldName .= fieldSchema | (fieldName, fieldSchema) <- objectSchema.properties],
          "required" .= objectSchema.required,
          "additionalProperties" .= objectSchema.additionalProperties
        ]
    SchemaAnyOf branches -> object ["anyOf" .= branches]
    -- A generic-reference sentinel preserved on the wire (the id must survive so the runtime can match
    -- it against 'SchemaInfo.genericBindings'); the runtime replaces it at get_metadata, so it must not
    -- survive into the final AI-facing schema.
    SchemaGeneric genericId -> object ["$generic" .= genericId]
    where
      typed :: Text -> Value
      typed typeName = object ["type" .= typeName]

instance ToJSON AdditionalProperties where
  toJSON additionalProperties = case additionalProperties of
    AdditionalPropertiesBoolean allowed -> toJSON allowed
    AdditionalPropertiesSchema valueSchema -> toJSON valueSchema

-- | The inverse of 'ToJSON', classifying by the discriminating keyword. The order mirrors emission:
-- the sentinel and structural keywords are checked before @type@, and an object carrying none of the
-- modelled keywords decodes as 'SchemaAny' (the empty schema admits extra keys by design).
instance FromJSON JSONSchema where
  parseJSON = withObject "JSONSchema" $ \schemaObject -> do
    generic <- schemaObject .:? "$generic"
    notKeyword <- schemaObject .:? "not"
    -- @const@ is looked up by key membership, not @.:?@ — a @{"const": null}@ pins the literal null,
    -- which @.:?@ would conflate with the key being absent.
    let constant = KeyMap.lookup "const" schemaObject
    anyOfBranches <- schemaObject .:? "anyOf"
    typeName <- schemaObject .:? "type"
    case (generic, notKeyword :: Maybe Value, constant, anyOfBranches) of
      (Just genericId, _, _, _) -> pure (SchemaGeneric genericId)
      (_, Just _, _, _) -> pure SchemaNever
      (_, _, Just value, _) -> pure (SchemaConst value)
      (_, _, _, Just branches) -> pure (SchemaAnyOf branches)
      _ -> case typeName :: Maybe Text of
        Just "null" -> pure SchemaNull
        Just "boolean" -> pure SchemaBoolean
        Just "integer" -> pure SchemaInteger
        Just "number" -> pure SchemaNumber
        Just "string" -> pure SchemaString
        Just "array" -> do
          prefixItems <- schemaObject .:? "prefixItems"
          case prefixItems of
            Just itemSchemas -> pure (SchemaTuple itemSchemas)
            Nothing -> do
              items <- schemaObject .:? "items"
              pure (SchemaArray (resolveOptionalSchema items))
        Just "object" -> SchemaObject <$> parseObjectSchema schemaObject
        Just other -> fail ("unsupported schema type: " <> show other)
        Nothing -> pure SchemaAny

-- | Decode the object-schema keywords off an already-opened @{"type": "object", ...}@ document.
-- JSON object keys are unordered, so properties come back in key order.
parseObjectSchema :: KeyMap.KeyMap Value -> Parser ObjectSchema
parseObjectSchema schemaObject = do
  propertiesMap <- schemaObject .:? "properties"
  properties <- case propertiesMap of
    Nothing -> pure []
    Just keyMap ->
      traverse
        (\(key, value) -> (Key.toText key,) <$> parseJSON value)
        (KeyMap.toAscList keyMap)
  required <- schemaObject .:? "required"
  additionalProperties <- schemaObject .:? "additionalProperties"
  pure
    ObjectSchema
      { properties = properties,
        required = resolveOptionalList required,
        -- JSON Schema's default: absent means additional keys are admitted.
        additionalProperties = resolveOptionalAdditional additionalProperties
      }
  where
    resolveOptionalList = \case
      Just names -> names
      Nothing -> []
    resolveOptionalAdditional = \case
      Just value -> value
      Nothing -> AdditionalPropertiesBoolean True

-- | @{"type": "array"}@ with no @items@ constrains its elements not at all.
resolveOptionalSchema :: Maybe JSONSchema -> JSONSchema
resolveOptionalSchema = \case
  Just schema -> schema
  Nothing -> SchemaAny

instance FromJSON AdditionalProperties where
  parseJSON value = case value of
    Bool allowed -> pure (AdditionalPropertiesBoolean allowed)
    _ -> AdditionalPropertiesSchema <$> parseJSON value
