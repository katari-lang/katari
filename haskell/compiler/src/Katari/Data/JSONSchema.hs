-- | A passive representation of the subset of JSON Schema the Katari runtime needs (the @input@ /
-- @output@ / @requests@ schemas carried by every callable, see "Katari.Data.IR"). It only models
-- the keywords Katari emits and serialises to a standard JSON Schema document via its 'ToJSON'
-- instance.
--
-- This is the representation only. The (non-trivial) conversion from a 'Katari.Data.SemanticType'
-- to a 'JSONSchema' — @file@ / @agent@ / @data@ / @private@-attributed types are not obvious — will
-- live in "Katari.Lowering" (which fills each callable's 'Katari.Data.IR.SchemaInfo', keyed by
-- 'Katari.Data.IR.BlockId') and is intentionally not implemented yet.
module Katari.Data.JSONSchema where

import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Text (Text)
import GHC.List (List)

-- | A JSON Schema document. The shapes the compiler emits: the primitive @type@s, @const@, @array@,
-- @object@, @anyOf@ unions, the empty schema (anything), and the @{"not": {}}@ bottom.
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
  -- | @{"type": "array", "items": s}@
  SchemaArray :: JSONSchema -> JSONSchema
  -- | @{"type": "object", "properties": {...}, "required": [...], "additionalProperties": b}@
  SchemaObject :: ObjectSchema -> JSONSchema
  -- | @{"anyOf": [...]}@ — a union.
  SchemaAnyOf :: List JSONSchema -> JSONSchema
  deriving stock (Eq, Show)

-- | The body of a 'SchemaObject'. Field order is preserved as written.
data ObjectSchema = ObjectSchema
  { properties :: List (Text, JSONSchema),
    required :: List Text,
    additionalProperties :: Bool
  }
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
    SchemaObject objectSchema ->
      object
        [ "type" .= ("object" :: Text),
          "properties" .= object [Key.fromText fieldName .= fieldSchema | (fieldName, fieldSchema) <- objectSchema.properties],
          "required" .= objectSchema.required,
          "additionalProperties" .= objectSchema.additionalProperties
        ]
    SchemaAnyOf branches -> object ["anyOf" .= branches]
    where
      typed :: Text -> Value
      typed typeName = object ["type" .= typeName]
