-- | Conversion from a 'Katari.Data.SemanticType' to a JSON Schema ('Katari.Data.JSONSchema'), the
-- public, AI- / wire-facing description of a value. The output describes the runtime's @RawValue@ form
-- (plain JSON), not its internal tagged value model, and follows JSON Schema Draft 2020-12 wherever the
-- standard has a canonical shape (@array@ via @items@, a tuple via @prefixItems@, a @record@ via a
-- schema-valued @additionalProperties@, a union via @anyOf@). The four concepts JSON Schema cannot
-- express get a @$@-prefixed extension property, ignored by standard validators:
--
--   * a @data@ value carries its constructor identity under @$constructor@ (a union discriminator);
--   * a callable (agent / closure) value is a @$agent@ reference object;
--   * a @file@ value is a @$ref@ blob-handle object;
--   * a not-yet-instantiated type generic is a @$generic@ placeholder ('SchemaGeneric'), filled by
--     'fillGenericSchema' at an instantiation site.
--
-- A @data@ reference is inline-expanded from 'DataDefinitions' (no @$defs@ / @$ref@); a recursive data
-- type breaks the cycle with an open schema. An attribute (the @public@ / @private@ information-flow
-- label) has no JSON Schema counterpart, so the schema reflects the attributed base type only —
-- withholding a private callable from the AI bundle, if wanted, is a builder-level policy.
--
-- This module is pure over 'SemanticType'. Building 'DataDefinitions' (denormalizing each @data@
-- declaration's constructor fields) and assembling per-callable 'Katari.Data.IR.SchemaInformation'
-- happen in "Katari.Lowering", which has the type environment.
module Katari.Schema where

import Data.Aeson (toJSON)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Data.Id (GenericId)
import Katari.Data.JSONSchema
  ( AdditionalProperties (..),
    JSONSchema (..),
    ObjectSchema (..),
  )
import Katari.Data.QualifiedName (QualifiedName, renderQualifiedName)
import Katari.Data.SemanticType
  ( FieldInformation (..),
    SemanticGenericArgument,
    SemanticType (..),
    substituteGenerics,
  )

-- | The denormalized shape of one @data@ declaration, prepared for inline expansion. 'fields' are the
-- constructor's fields as 'SemanticType's (the caller denormalizes them from the type environment);
-- 'parameterGenericIds' maps each generic parameter's name to its 'GenericId' so a @foo[args]@
-- reference — whose arguments are keyed by parameter name — becomes a 'GenericId'-keyed substitution
-- over the field types.
data DataDefinition = DataDefinition
  { fields :: Map Text FieldInformation,
    parameterGenericIds :: Map Text GenericId
  }
  deriving stock (Eq, Show)

-- | Every @data@ declaration reachable from the type being converted, keyed by name.
type DataDefinitions = Map QualifiedName DataDefinition

-- | Reserved property name carrying a tagged value's constructor identity — the discriminator a
-- consumer uses to pick the matching arm of a union of @data@ types.
constructorDiscriminatorKey :: Text
constructorDiscriminatorKey = "$constructor"

-- | Reserved property nesting a tagged value's fields under their own object, so no field name can ever
-- collide with the @$constructor@ discriminator — the wire form is a disjoint union (a @data@ value's
-- two keys, @$constructor@ and @value@, cannot be produced by a bare record, whose @$@-keys are escaped).
valueNestingKey :: Text
valueNestingKey = "value"

-- | Reserved property name marking a callable (agent / closure) reference value.
callableReferenceKey :: Text
callableReferenceKey = "$agent"

-- | Reserved property name marking a @file@ value's blob handle.
fileReferenceKey :: Text
fileReferenceKey = "$ref"

-- | Convert a 'SemanticType' to its JSON Schema. @data@ references are inline-expanded from
-- 'DataDefinitions'; a recursive reference is broken with an open schema.
toJSONSchema :: DataDefinitions -> SemanticType -> JSONSchema
toJSONSchema dataDefinitions = convert Set.empty
  where
    convert visited semanticType = case semanticType of
      SemanticTypeNever -> SchemaNever
      SemanticTypeUnknown -> SchemaAny
      SemanticTypeNull -> SchemaNull
      SemanticTypeInteger -> SchemaInteger
      SemanticTypeNumber -> SchemaNumber
      SemanticTypeString -> SchemaString
      SemanticTypeBoolean -> SchemaBoolean
      -- A @file@ is a blob handle supplied by orchestration, never produced inline by the AI; the
      -- schema documents the @$ref@ reference object so a runtime-passed handle validates.
      SemanticTypeFile -> fileReferenceSchema
      SemanticTypeArray itemType -> SchemaArray (convert visited itemType)
      SemanticTypeTuple itemTypes -> SchemaTuple (convert visited <$> itemTypes)
      SemanticTypeObject fields -> convertObject visited fields
      -- A @record[V]@ is an object whose every key holds a @V@. Keys are strings in v0.1.0, so there
      -- is no @propertyNames@ refinement.
      SemanticTypeRecord valueType ->
        SchemaObject
          ObjectSchema
            { properties = [],
              required = [],
              additionalProperties = AdditionalPropertiesSchema (convert visited valueType)
            }
      SemanticTypeUnion branches -> SchemaAnyOf (convert visited <$> branches)
      -- A generic parameter becomes the @$generic@ placeholder; 'fillGenericSchema' replaces it with
      -- the concrete type's schema at instantiation.
      SemanticTypeGeneric genericId -> SchemaGeneric genericId
      -- An attribute carries no JSON Schema meaning (it is compile-time information-flow control), so
      -- the schema reflects the attributed base type only.
      SemanticTypeAttribute baseType _ -> convert visited baseType
      -- A callable value is a reference the AI cannot build inline; emit the @$agent@ reference
      -- object. Its signature is discoverable via @get_metadata@ on the referenced agent.
      SemanticTypeAgent {} -> callableReferenceSchema
      SemanticTypeData qualifiedName arguments -> convertData visited qualifiedName arguments

    -- A Katari object names only the fields it requires; a value may legitimately carry more, so the
    -- schema stays open. An optional field is dropped from @required@.
    convertObject visited fields =
      SchemaObject
        ObjectSchema
          { properties = [(fieldName, convert visited field.semanticType) | (fieldName, field) <- Map.toAscList fields],
            required = [fieldName | (fieldName, field) <- Map.toAscList fields, not field.optional],
            additionalProperties = AdditionalPropertiesBoolean True
          }

    convertData visited qualifiedName arguments
      -- A recursive @data@ reference: break the cycle with an open schema rather than diverging.
      | Set.member qualifiedName visited = SchemaAny
      | Just definition <- Map.lookup qualifiedName dataDefinitions =
          let visitedWithSelf = Set.insert qualifiedName visited
              substitution = buildSubstitution definition.parameterGenericIds arguments
              expandedFields = Map.toAscList definition.fields
              fieldProperties =
                [ (fieldName, convert visitedWithSelf (substituteGenerics substitution field.semanticType))
                  | (fieldName, field) <- expandedFields
                ]
              -- The constructor's fields, nested under @value@ as their own object (an open object — a
              -- value may legitimately carry more; a declared field is required unless optional).
              valueObject =
                SchemaObject
                  ObjectSchema
                    { properties = fieldProperties,
                      required = [fieldName | (fieldName, field) <- expandedFields, not field.optional],
                      additionalProperties = AdditionalPropertiesBoolean True
                    }
              -- The qualified constructor name tags the value; consumers use it as the discriminator
              -- when picking a union arm.
              constructorProperty = (constructorDiscriminatorKey, SchemaConst (toJSON (renderQualifiedName qualifiedName)))
           in SchemaObject
                ObjectSchema
                  { properties = [constructorProperty, (valueNestingKey, valueObject)],
                    -- The wire form is exactly the discriminator and the nested fields object; both are
                    -- always present, and no other top-level key is admitted (the two are disjoint from a
                    -- bare record's escaped keys).
                    required = [constructorDiscriminatorKey, valueNestingKey],
                    additionalProperties = AdditionalPropertiesBoolean False
                  }
      -- An unknown @data@ name (should not arise once 'DataDefinitions' is complete): stay open
      -- rather than emit a wrong shape.
      | otherwise = SchemaAny

-- | The 'GenericId'-keyed substitution for a @data@ reference: each declared parameter (looked up by
-- name in 'DataDefinition.parameterGenericIds') is bound to the argument supplied at that name.
buildSubstitution :: Map Text GenericId -> Map Text SemanticGenericArgument -> Map GenericId SemanticGenericArgument
buildSubstitution parameterGenericIds arguments =
  Map.fromList
    [ (genericId, argument)
      | (parameterName, genericId) <- Map.toList parameterGenericIds,
        Just argument <- [Map.lookup parameterName arguments]
    ]

-- | The schema of a callable value: a @$agent@-tagged reference object. Loose by design — the AI does
-- not construct callables; they are runtime-supplied, and the precise reference field set follows the
-- runtime @RawValue@ codec.
callableReferenceSchema :: JSONSchema
callableReferenceSchema = referenceSchema callableReferenceKey

-- | The schema of a @file@ value: a slim @$ref@ blob handle — IDENTITY ONLY. The blob's metadata
-- (size / hash / contentType) lives on its runtime row, never on the handle, so a bare
-- @{"$ref": id}@ is a complete handle: exactly what an AI replays from a conversation into a tool
-- call, with nothing to copy wrong. @semanticKind@ is accepted (the engine writes it; decode
-- defaults a missing one to @file@) and the object stays open for older full handles.
fileReferenceSchema :: JSONSchema
fileReferenceSchema =
  SchemaObject
    ObjectSchema
      { properties = [(fileReferenceKey, SchemaString), ("semanticKind", SchemaString)],
        required = [fileReferenceKey],
        additionalProperties = AdditionalPropertiesBoolean True
      }

-- | An open object requiring just one @$@-prefixed discriminator property (whose value is left
-- unconstrained). The shape behind 'callableReferenceSchema' (loose by design — the AI does not
-- construct callables; they are runtime-supplied).
referenceSchema :: Text -> JSONSchema
referenceSchema discriminatorKey =
  SchemaObject
    ObjectSchema
      { properties = [(discriminatorKey, SchemaAny)],
        required = [discriminatorKey],
        additionalProperties = AdditionalPropertiesBoolean True
      }

-- | Replace every @$generic@ placeholder ('SchemaGeneric') with the substitution's concrete schema,
-- recovering a placeholder-free schema. A placeholder whose 'GenericId' is absent from the map is left
-- unchanged (a partial fill). This is the single function the compiler and the runtime share to
-- instantiate a generic callable's schema.
fillGenericSchema :: Map GenericId JSONSchema -> JSONSchema -> JSONSchema
fillGenericSchema substitution = fill
  where
    fill schema = case schema of
      SchemaGeneric genericId -> Map.findWithDefault schema genericId substitution
      SchemaArray itemSchema -> SchemaArray (fill itemSchema)
      SchemaTuple itemSchemas -> SchemaTuple (fill <$> itemSchemas)
      SchemaObject objectSchema ->
        SchemaObject
          ObjectSchema
            { properties = [(fieldName, fill fieldSchema) | (fieldName, fieldSchema) <- objectSchema.properties],
              required = objectSchema.required,
              additionalProperties = case objectSchema.additionalProperties of
                AdditionalPropertiesSchema valueSchema -> AdditionalPropertiesSchema (fill valueSchema)
                allowed -> allowed
            }
      SchemaAnyOf branches -> SchemaAnyOf (fill <$> branches)
      other -> other

-- | Whether a schema still mentions a @$generic@ placeholder anywhere. (A schema is /proper/ once this
-- is 'False'; the runtime never serialises a proper schema's placeholders to the AI.)
mentionsGeneric :: JSONSchema -> Bool
mentionsGeneric schema = case schema of
  SchemaGeneric _ -> True
  SchemaArray itemSchema -> mentionsGeneric itemSchema
  SchemaTuple itemSchemas -> any mentionsGeneric itemSchemas
  SchemaObject objectSchema ->
    any (mentionsGeneric . snd) objectSchema.properties
      || case objectSchema.additionalProperties of
        AdditionalPropertiesSchema valueSchema -> mentionsGeneric valueSchema
        AdditionalPropertiesBoolean _ -> False
  SchemaAnyOf branches -> any mentionsGeneric branches
  _ -> False
