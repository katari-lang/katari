-- | Conversion from a 'Katari.Data.SemanticType' to a JSON Schema ('Katari.Data.JSONSchema'), the
-- public, AI- / wire-facing description of a value. The output describes the runtime's @RawValue@ form
-- (plain JSON), not its internal tagged value model, and follows JSON Schema Draft 2020-12 wherever the
-- standard has a canonical shape (@array@ via @items@, a tuple via @prefixItems@, a @record@ via a
-- schema-valued @additionalProperties@, a union via @anyOf@). The four concepts JSON Schema cannot
-- express get a @$katari_@-prefixed extension property (the reserved wire namespace), ignored by standard
-- validators:
--
--   * a @data@ value carries its constructor identity under @$katari_constructor@ (a union discriminator);
--   * a callable (agent / closure) value is a @$katari_agent@ reference object;
--   * a @file@ value is a @$katari_ref@ blob-handle object;
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

import Data.Aeson (Value (String), toJSON)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.Id (GenericId)
import Katari.Data.JSONSchema
  ( AdditionalProperties (..),
    DescribedSchema (..),
    JSONSchema (..),
    ObjectSchema (..),
  )
import Katari.Data.QualifiedName (QualifiedName (..), renderQualifiedName)
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
-- over the field types. 'annotation' and 'fieldAnnotations' are the declaration's @\@"..."@ docstrings,
-- carried here so an inline expansion documents itself: a @data@ reached through a union arm has no
-- other site at which a description could be attached.
data DataDefinition = DataDefinition
  { fields :: Map Text FieldInformation,
    parameterGenericIds :: Map Text GenericId,
    annotation :: Maybe Text,
    fieldAnnotations :: Map Text Text
  }
  deriving stock (Eq, Show)

-- | Every @data@ declaration reachable from the type being converted, keyed by name.
type DataDefinitions = Map QualifiedName DataDefinition

-- | Reserved property name carrying a tagged value's constructor identity — the discriminator a
-- consumer uses to pick the matching arm of a union of @data@ types.
constructorDiscriminatorKey :: Text
constructorDiscriminatorKey = "$katari_constructor"

-- | Reserved property nesting a tagged value's fields under their own object, so no field name can ever
-- collide with the @$katari_constructor@ discriminator. Both keys live in the reserved @$katari_@
-- namespace, which a program never authors, so a @data@ value's wire form is disjoint from any bare record.
valueNestingKey :: Text
valueNestingKey = "$katari_value"

-- | Reserved property name marking a callable (agent / closure) reference value.
callableReferenceKey :: Text
callableReferenceKey = "$katari_agent"

-- | Reserved property name marking a @file@ value's blob handle.
fileReferenceKey :: Text
fileReferenceKey = "$katari_ref"

-- | Reserved property name carrying a blob handle's semantic kind. The engine writes it and decode
-- defaults a missing one to @file@, so the schema only ACCEPTS it — but it is wire vocabulary all the
-- same, and lives here beside its siblings rather than inline, so every reserved name this module emits
-- is greppable from one place (and stays checkable against the runtime's @wire.ts@).
semanticKindKey :: Text
semanticKindKey = "$katari_semantic_kind"

-- | The description carried by every @$katari_constructor@ property. The reserved @$katari_@ namespace
-- is a Katari wire convention, not anything a JSON Schema consumer could infer, so the schema states
-- outright what the property is for and that its value is copied verbatim — otherwise a model reading
-- a union of @data@ types has no way to learn that the tag is what selects an arm.
constructorDiscriminatorDescription :: Text
constructorDiscriminatorDescription = "The tag that selects this variant. Write this exact string."

-- | Overlay a description on a schema when there is one to overlay. An absent description leaves the
-- schema untouched rather than emitting an empty one, so an undocumented declaration adds no noise.
describedWith :: Maybe Text -> JSONSchema -> JSONSchema
describedWith maybeDescription schema = case maybeDescription of
  Just description -> SchemaDescribed DescribedSchema {description = description, schema = schema}
  Nothing -> schema

-- | Peel every 'SchemaDescribed' overlay off a schema, exposing the shape beneath. A description
-- annotates and never constrains, so a consumer that dispatches on STRUCTURE must look through one:
-- otherwise documenting a declaration silently changes how its schema is recognised.
undescribed :: JSONSchema -> JSONSchema
undescribed schema = case schema of
  SchemaDescribed described -> undescribed described.schema
  other -> other

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
      -- A string literal singleton admits exactly one value, which is what @const@ says. The runtime's
      -- conformance walk already checks @const@ schemas, so a literal-instantiated generic validates.
      SemanticTypeStringLiteral value -> SchemaConst (toJSON value)
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
              -- A documented field carries its own docstring. The overlay sits outside whatever
              -- description the field's type already contributed, and the wire encoding keeps the
              -- outermost, so the more specific text — this declaration's, about this field — wins.
              fieldProperties =
                [ ( fieldName,
                    describedWith
                      (Map.lookup fieldName definition.fieldAnnotations)
                      (convert visitedWithSelf (substituteGenerics substitution field.semanticType))
                  )
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
              constructorProperty =
                ( constructorDiscriminatorKey,
                  SchemaDescribed
                    DescribedSchema
                      { description = constructorDiscriminatorDescription,
                        schema = SchemaConst (toJSON (renderQualifiedName qualifiedName))
                      }
                )
              taggedObject =
                SchemaObject
                  ObjectSchema
                    { properties = [constructorProperty, (valueNestingKey, valueObject)],
                      -- The wire form is exactly the discriminator and the nested fields object; both are
                      -- always present, and no other top-level key is admitted (both live in the reserved
                      -- @$katari_@ namespace, disjoint from any bare record).
                      required = [constructorDiscriminatorKey, valueNestingKey],
                      additionalProperties = AdditionalPropertiesBoolean False
                    }
           in -- The declaration's own docstring describes the whole variant. It is prefixed with the
              -- constructor's short name so that an arm of a union reads as a labelled choice, which is
              -- the only place this schema is ever expanded more than once. An undocumented declaration
              -- gets no description: the tag const already names it, so a bare name would be noise.
              describedWith ((\documentation -> qualifiedName.name <> ": " <> documentation) <$> definition.annotation) taggedObject
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

-- | What 'dataValueSchemaParts' recovers from a @data@ value's wire schema: the constructor name the
-- @$katari_constructor@ discriminator pins, and the constructor's field schemas exactly as they sit
-- nested under @$katari_value@ (in declaration order, each still carrying whatever description the
-- producer overlaid on it).
data DataValueSchema = DataValueSchema
  { constructorName :: Text,
    fields :: List (Text, JSONSchema)
  }
  deriving stock (Eq, Show)

-- | Recognise a @data@ value's wire schema — the inverse of the tagged object 'toJSONSchema' emits for a
-- @data@ reference, and the ONE place that knowledge is written down for consumers. A consumer that
-- dispatches on the encoding (the CLI's argument interview, which names a union arm by its constructor
-- instead of showing two indistinguishable @record {…}@ labels) reads it through here rather than
-- rebuilding the inverse by hand, so the encoding cannot drift away from a hand-written reader.
--
-- Both reserved properties are read through 'undescribed': the producer documents the discriminator
-- (always) and any annotated field, and a documented declaration must still be recognised as the @data@
-- shape it is. The declaration's OWN docstring wraps the whole object, so a caller holding a
-- 'JSONSchema' peels that outer overlay first ('undescribed') and passes the 'ObjectSchema' beneath.
dataValueSchemaParts :: ObjectSchema -> Maybe DataValueSchema
dataValueSchemaParts objectSchema = case undescribed <$> lookup constructorDiscriminatorKey objectSchema.properties of
  Just (SchemaConst (String name)) ->
    Just
      DataValueSchema
        { constructorName = name,
          fields = case undescribed <$> lookup valueNestingKey objectSchema.properties of
            Just (SchemaObject valueObject) -> valueObject.properties
            -- The discriminator alone identifies the encoding; a nesting property that is missing or not
            -- an object means a constructor with nothing to list, not a non-@data@ shape.
            _ -> []
        }
  _ -> Nothing

-- | The schema of a callable value: a @$agent@-tagged reference object. Loose by design — the AI does
-- not construct callables; they are runtime-supplied, and the precise reference field set follows the
-- runtime @RawValue@ codec.
callableReferenceSchema :: JSONSchema
callableReferenceSchema = referenceSchema callableReferenceKey

-- | The schema of a @file@ value: a slim @$katari_ref@ blob handle — IDENTITY ONLY. The blob's metadata
-- (size / hash / contentType) lives on its runtime row, never on the handle, so a bare
-- @{"$katari_ref": id}@ is a complete handle: exactly what an AI replays from a conversation into a tool
-- call, with nothing to copy wrong. @$katari_semantic_kind@ is accepted (the engine writes it; decode
-- defaults a missing one to @file@) and the object stays open.
fileReferenceSchema :: JSONSchema
fileReferenceSchema =
  SchemaObject
    ObjectSchema
      { properties = [(fileReferenceKey, SchemaString), (semanticKindKey, SchemaString)],
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
      SchemaDescribed described -> SchemaDescribed DescribedSchema {description = described.description, schema = fill described.schema}
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
  SchemaDescribed described -> mentionsGeneric described.schema
  _ -> False
