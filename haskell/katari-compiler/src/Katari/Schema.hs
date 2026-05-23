-- | JSON Schema generation for the public API surface (agents, requests,
-- external agents, and data constructors).
--
-- The output is a flat '[SchemaEntry]' array — one entry per top-level
-- callable. The @input@ / @output@ fields directly hold valid JSON Schema
-- Draft 2020-12 (a subset). Type references to @data@ declarations
-- ('SemanticTypeData') are inlined via 'DataDefs' (no @$defs@ / @$ref@).
-- Description text is pulled from the AST's @\@\"...\"@ annotations.
--
-- Input is 'ZonkResult' only ('IRModule' is not required).
module Katari.Schema
  ( -- * Output types
    SchemaEntry (..),
    RequestSchemaRef (..),
    JsonSchema (..),
    SchemaCore (..),

    -- * Internal helpers (exposed for testing)
    DataDefs,
    buildDataDefs,
    toJsonSchema,

    -- * Lowering-facing helpers (per-agent schema computation)
    buildInputObject,
    buildOutputSchema,
    jsonSchemaToText,

    -- * Top-level builder
    buildSchemas,
  )
where

import Control.Monad (join)
import Data.Aeson
  ( Options (..),
    ToJSON (..),
    Value (..),
    defaultOptions,
    encode,
    genericToJSON,
    object,
    (.=),
  )
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as Encoding
import GHC.Generics (Generic)
import Katari.AST
  ( AgentDeclaration (..),
    DataDeclaration (..),
    DataParameter (..),
    Declaration (..),
    ExternalAgentDeclaration (..),
    Module (..),
    NameRef (..),
    NameRefKind (..),
    ParameterBinding (..),
    Phase (Zonked),
    RequestDeclaration (..),
  )
import Katari.Id
  ( ModuleId,
    QualifiedName,
    RequestId,
    TypeId,
    renderQualifiedName,
  )
import Katari.SemanticType
  ( Resolved,
    SemanticRequest (..),
    SemanticRequestElement (..),
    SemanticType (..),
  )
import Katari.Typechecker.Identifier
  ( ConstructorData (..),
    IdentifierResult (..),
    RequestData (..),
    VariableData (..),
  )
import Katari.Typechecker.Zonker (ZonkResult (..))

-- ===========================================================================
-- Output types
-- ===========================================================================

-- | Schema for one top-level callable (agent / request / external-agent /
-- data constructor). @input@ is always an object schema whose properties are
-- the named parameters. @output@ is the return-type schema, inline-expanded.
-- @requests@ lists the request schemas this callable may raise.
data SchemaEntry = SchemaEntry
  { name :: Text,
    description :: Maybe Text,
    input :: JsonSchema,
    output :: JsonSchema,
    requests :: [RequestSchemaRef]
  }
  deriving (Eq, Show, Generic)

instance ToJSON SchemaEntry where
  toJSON = genericToJSON schemaOptions

-- | Schema for a single request type that an agent may raise.
data RequestSchemaRef = RequestSchemaRef
  { name :: Text,
    input :: JsonSchema,
    output :: JsonSchema
  }
  deriving (Eq, Show, Generic)

instance ToJSON RequestSchemaRef where
  toJSON = genericToJSON schemaOptions

-- ===========================================================================
-- JsonSchema types
-- ===========================================================================

-- | A JSON Schema fragment with optional description / title / examples.
-- Serialises as a flat JSON object: 'core' keywords are merged with the
-- metadata fields at the top level (no nesting).
data JsonSchema = JsonSchema
  { core :: SchemaCore,
    title :: Maybe Text,
    description :: Maybe Text,
    examples :: [Value]
  }
  deriving (Eq, Show, Generic)

-- | Merge 'core' fields with metadata fields into a flat JSON object.
instance ToJSON JsonSchema where
  toJSON JsonSchema {core, title, description, examples} =
    case toJSON core of
      Object coreMap ->
        let extras =
              KeyMap.fromList $
                catMaybes
                  [ ("title",) . toJSON <$> title,
                    ("description",) . toJSON <$> description
                  ]
                  ++ [("examples", toJSON examples) | not (null examples)]
         in Object (coreMap <> extras)
      -- Every SchemaCore variant's ToJSON instance produces an Object
      -- (the JSON Schema spec requires this). If this branch is ever
      -- reached, a SchemaCore variant was added without an Object-shaped
      -- encoder — that's a bug, not silent metadata loss.
      other ->
        error
          ( "Katari.Schema: SchemaCore did not serialise to an Object — \
            \this is a compiler bug. Got: "
              <> show other
          )

-- | The structural part of a 'JsonSchema'. Serialises to valid JSON Schema
-- Draft 2020-12 keywords (e.g. @{"type":"integer"}@, @{"anyOf":[...]}@).
data SchemaCore where
  SchemaCoreNull :: SchemaCore
  SchemaCoreBoolean :: SchemaCore
  SchemaCoreInteger ::
    { minimum :: Maybe Integer,
      maximum :: Maybe Integer
    } ->
    SchemaCore
  SchemaCoreNumber :: SchemaCore
  SchemaCoreString :: {schemaEnum :: [Text]} -> SchemaCore
  SchemaCoreConst :: {value :: Value} -> SchemaCore
  SchemaCoreArray :: {items :: JsonSchema} -> SchemaCore
  SchemaCoreTuple :: {prefixItems :: [JsonSchema]} -> SchemaCore
  SchemaCoreObject ::
    { properties :: Map Text JsonSchema,
      required :: Set Text,
      additionalProperties :: Bool
    } ->
    SchemaCore
  SchemaCoreUnion :: {anyOf :: [JsonSchema]} -> SchemaCore
  SchemaCoreUnknown :: SchemaCore
  SchemaCoreNever :: SchemaCore
  deriving (Eq, Show, Generic)

instance ToJSON SchemaCore where
  toJSON = \case
    SchemaCoreNull -> object ["type" .= ("null" :: Text)]
    SchemaCoreBoolean -> object ["type" .= ("boolean" :: Text)]
    SchemaCoreInteger {minimum = lowerBound, maximum = upperBound} ->
      object $
        ("type" .= ("integer" :: Text))
          : catMaybes
            [ ("minimum" .=) <$> lowerBound,
              ("maximum" .=) <$> upperBound
            ]
    SchemaCoreNumber -> object ["type" .= ("number" :: Text)]
    SchemaCoreString {schemaEnum = []} -> object ["type" .= ("string" :: Text)]
    SchemaCoreString {schemaEnum = xs} ->
      object ["type" .= ("string" :: Text), "enum" .= xs]
    SchemaCoreConst {value} -> object ["const" .= value]
    SchemaCoreArray {items} ->
      object ["type" .= ("array" :: Text), "items" .= items]
    SchemaCoreTuple {prefixItems} ->
      object ["type" .= ("array" :: Text), "prefixItems" .= prefixItems]
    SchemaCoreObject {properties, required, additionalProperties} ->
      object
        [ "type" .= ("object" :: Text),
          "properties" .= properties,
          "required" .= Set.toAscList required,
          "additionalProperties" .= additionalProperties
        ]
    SchemaCoreUnion {anyOf} -> object ["anyOf" .= anyOf]
    SchemaCoreUnknown -> Object KeyMap.empty
    SchemaCoreNever -> object ["not" .= Object KeyMap.empty]

-- ===========================================================================
-- Aeson option helpers
-- ===========================================================================

schemaOptions :: Options
schemaOptions =
  defaultOptions
    { fieldLabelModifier = id,
      omitNothingFields = True
    }

-- ===========================================================================
-- Plain schema helpers
-- ===========================================================================

-- | Wrap a 'SchemaCore' in a 'JsonSchema' with no extra metadata.
plain :: SchemaCore -> JsonSchema
plain c = JsonSchema {core = c, title = Nothing, description = Nothing, examples = []}

-- | Attach an optional description to a 'JsonSchema'.
withDesc :: Maybe Text -> JsonSchema -> JsonSchema
withDesc d JsonSchema {core, title, examples} =
  JsonSchema {core, title, description = d, examples}

-- ===========================================================================
-- DataDefs: pre-built map for inline data-type expansion
-- ===========================================================================

-- | Per-data-type metadata threaded through schema generation. Carries
-- the constructor's 'QualifiedName' so the emitted schema can stamp
-- a @"$ctor": {"const": "module.name"}@ discriminator on the resulting
-- object schema (required for raw ↔ Value round-trip without ambiguity
-- on unions). Field annotations come along so recursive
-- 'SemanticTypeData' references render with the same descriptions as
-- the original @data@ declaration.
data DataInfo = DataInfo
  { dataQName :: QualifiedName,
    dataFields :: Map Text DataFieldInfo
  }
  deriving (Eq, Show)

-- | One field of a 'DataInfo': its semantic type plus the original
-- @\@\"...\"@ annotation (if any) from the @data@ declaration.
data DataFieldInfo = DataFieldInfo
  { fieldType :: SemanticType Resolved,
    fieldAnnotation :: Maybe Text
  }
  deriving (Eq, Show)

-- | Maps each data type's 'TypeId' to its qname + per-field info.
type DataDefs = Map TypeId DataInfo

-- | Build 'DataDefs' from the Zonked output. Each @data@ declaration
-- contributes one entry: its 'TypeId' maps to the constructor qname,
-- field types (from 'zonkedTypeEnvironment'), and per-field
-- annotations (from the surface 'DataDeclaration' parameters).
buildDataDefs :: IdentifierResult -> ZonkResult -> DataDefs
buildDataDefs idResult zonkResult =
  let annotationsByQName :: Map QualifiedName (Map Text (Maybe Text))
      annotationsByQName =
        Map.fromList
          [ (qname, annotations)
            | m <- Map.elems zonkResult.zonkedModules,
              DeclarationData dataDecl <- m.declarations,
              let annotations =
                    Map.fromList [(p.name, p.annotation) | p <- dataDecl.parameters],
              Just variableId <- [dataDecl.name.resolution],
              Just variableData <-
                [ Map.lookup
                    variableId
                    idResult.identifiedVariables
                ],
              Just qname <- [variableData.variableQualifiedName]
          ]
   in Map.fromList
        [ ( cd.constructorTypeId,
            DataInfo
              cd.constructorQualifiedName
              ( Map.mapWithKey
                  ( \label ty ->
                      DataFieldInfo
                        { fieldType = ty,
                          fieldAnnotation =
                            Map.findWithDefault
                              Nothing
                              label
                              perFieldAnnotations
                        }
                  )
                  fieldTypes
              )
          )
          | (_, cd) <- Map.toList idResult.identifiedConstructors,
            let perFieldAnnotations =
                  Map.findWithDefault
                    Map.empty
                    cd.constructorQualifiedName
                    annotationsByQName,
            Just (SemanticTypeFunction fieldTypes _ _) <-
              [ Map.lookup
                  cd.constructorVariableId
                  zonkResult.zonkedTypeEnvironment
              ]
        ]

-- ===========================================================================
-- SemanticType -> JsonSchema
-- ===========================================================================

-- | Convert a 'SemanticType' 'Resolved' to a 'JsonSchema'. 'SemanticTypeData'
-- references are inline-expanded using 'DataDefs'; 'visited' guards against
-- circular references (passes 'SchemaCoreUnknown' on re-entry).
toJsonSchema :: DataDefs -> Set TypeId -> SemanticType Resolved -> JsonSchema
toJsonSchema dataDefs visited = plain . toCore dataDefs visited

toCore :: DataDefs -> Set TypeId -> SemanticType Resolved -> SchemaCore
toCore dataDefs visited = \case
  SemanticTypeNever -> SchemaCoreNever
  SemanticTypeUnknown -> SchemaCoreUnknown
  SemanticTypeNull -> SchemaCoreNull
  SemanticTypeBoolean -> SchemaCoreBoolean
  SemanticTypeInteger -> SchemaCoreInteger {minimum = Nothing, maximum = Nothing}
  SemanticTypeNumber -> SchemaCoreNumber
  SemanticTypeString -> SchemaCoreString {schemaEnum = []}
  -- 'secret' should not surface in AI tool-calling schemas; the AI must
  -- not be allowed to inspect credential values. Callers (e.g. the
  -- schema-bundle builder) should reject any callable whose param /
  -- result mentions @secret@ before reaching here. We fall back to
  -- 'SchemaCoreUnknown' as a defensive no-op (= maximally permissive)
  -- so a stray path doesn't crash; the proper guard belongs upstream.
  SemanticTypeSecret -> SchemaCoreUnknown
  SemanticTypeLiteralInteger n -> SchemaCoreConst {value = toJSON n}
  SemanticTypeLiteralString s -> SchemaCoreConst {value = toJSON s}
  SemanticTypeLiteralBoolean b -> SchemaCoreConst {value = toJSON b}
  SemanticTypeArray element ->
    SchemaCoreArray {items = toJsonSchema dataDefs visited element}
  SemanticTypeTuple elements ->
    SchemaCoreTuple {prefixItems = map (toJsonSchema dataDefs visited) elements}
  SemanticTypeObject fields ->
    SchemaCoreObject
      { properties = Map.map (toJsonSchema dataDefs visited) fields,
        required = Map.keysSet fields,
        additionalProperties = False
      }
  SemanticTypeUnion branches ->
    compactUnion (map (toCore dataDefs visited) branches)
  SemanticTypeData typeId
    | Set.member typeId visited ->
        -- Circular reference: break the cycle with an open schema.
        SchemaCoreUnknown
    | Just info <- Map.lookup typeId dataDefs ->
        let visited' = Set.insert typeId visited
            qnameStr = renderQualifiedName info.dataQName
            fieldProps =
              Map.map
                ( \fi ->
                    withDesc fi.fieldAnnotation (toJsonSchema dataDefs visited' fi.fieldType)
                )
                info.dataFields
            ctorProp = plain SchemaCoreConst {value = toJSON qnameStr}
            properties = Map.insert ctorDiscriminatorKey ctorProp fieldProps
         in SchemaCoreObject
              { properties = properties,
                required = Set.insert ctorDiscriminatorKey (Map.keysSet info.dataFields),
                additionalProperties = False
              }
    | otherwise -> SchemaCoreUnknown
  -- Concrete function types and the 'function' top type are both
  -- carried on the wire as a callable reference @{"$callable":
  -- "module.name" | "closure:N"}@. The reference is what 'get_metadata'
  -- returns in its 'id' field.
  SemanticTypeFunction {} -> callableRefCore
  SemanticTypeFunctionAny -> callableRefCore

-- | Reserved JSON-Schema property name carrying the tagged-value
-- constructor identifier on the wire. Receivers (CLI / REST clients /
-- AI tools) use the value as a discriminator when picking the matching
-- arm of a union.
ctorDiscriminatorKey :: Text
ctorDiscriminatorKey = "$ctor"

-- | Reserved JSON-Schema property name carrying a callable reference.
-- The value is the same string the @get_metadata@ prim returns in its
-- @id@ field: @"module.name"@ for top-level agents or @"closure:N"@
-- for local closures.
callableDiscriminatorKey :: Text
callableDiscriminatorKey = "$callable"

-- | Schema for a callable-reference object: a single required
-- @"$callable": string@ property. Used as the wire representation of
-- every value of a function-shaped type.
callableRefCore :: SchemaCore
callableRefCore =
  SchemaCoreObject
    { properties =
        Map.singleton
          callableDiscriminatorKey
          (plain SchemaCoreString {schemaEnum = []}),
      required = Set.singleton callableDiscriminatorKey,
      additionalProperties = False
    }

-- | Compact a union of string-literal types into a single string-enum
-- where possible. Mixed unions fall back to @anyOf@.
compactUnion :: [SchemaCore] -> SchemaCore
compactUnion cores =
  let stringEnums = [s | SchemaCoreConst {value = String s} <- cores]
      allStringConst = not (null cores) && length stringEnums == length cores
   in if allStringConst
        then SchemaCoreString {schemaEnum = stringEnums}
        else SchemaCoreUnion {anyOf = map plain cores}

-- ===========================================================================
-- Top-level builder
-- ===========================================================================

-- | Build schema entries for a compiled program. Walks every module's
-- declarations and emits one 'SchemaEntry' per top-level callable.
buildSchemas :: IdentifierResult -> ZonkResult -> [SchemaEntry]
buildSchemas idResult zonkResult =
  let dataDefs = buildDataDefs idResult zonkResult
   in concatMap
        (buildModuleEntries dataDefs idResult zonkResult)
        (Map.toList zonkResult.zonkedModules)

buildModuleEntries ::
  DataDefs ->
  IdentifierResult ->
  ZonkResult ->
  (ModuleId, Module Zonked) ->
  [SchemaEntry]
buildModuleEntries dataDefs idResult zonkResult (_, m) =
  mapMaybe (buildDeclarationEntry dataDefs idResult zonkResult) m.declarations

buildDeclarationEntry ::
  DataDefs ->
  IdentifierResult ->
  ZonkResult ->
  Declaration Zonked ->
  Maybe SchemaEntry
buildDeclarationEntry dataDefs idResult zonkResult = \case
  DeclarationAgent agentDecl ->
    buildAgentLike
      dataDefs
      idResult
      zonkResult
      agentDecl.annotation
      agentDecl.name
      agentDecl.parameters
  DeclarationRequest requestDecl ->
    buildAgentLike
      dataDefs
      idResult
      zonkResult
      requestDecl.annotation
      requestDecl.name
      requestDecl.parameters
  DeclarationExternalAgent externalDecl ->
    buildAgentLike
      dataDefs
      idResult
      zonkResult
      externalDecl.annotation
      externalDecl.name
      externalDecl.parameters
  -- Stdlib-owned prim agents are an implementation detail of the
  -- runtime; we don't surface them in the AI tool-calling schema bundle
  -- (they'd just clutter the discovered-tools list).
  DeclarationPrimAgent _ -> Nothing
  DeclarationData dataDecl ->
    buildDataEntry dataDefs idResult zonkResult dataDecl
  DeclarationImport {} -> Nothing
  DeclarationTypeSynonym {} -> Nothing
  DeclarationError {} -> Nothing

-- | Build a 'SchemaEntry' for an agent / request / external-agent.
-- The qualified name is recovered from 'zonkedVariables'; the type from
-- 'zonkedTypeEnvironment'. Returns 'Nothing' if either lookup fails (a
-- Solver-contract violation that was already reported as a diagnostic).
buildAgentLike ::
  DataDefs ->
  IdentifierResult ->
  ZonkResult ->
  Maybe Text ->
  NameRef Zonked VariableRef ->
  [ParameterBinding Zonked] ->
  Maybe SchemaEntry
buildAgentLike dataDefs idResult zonkResult annotation nameRef parameters = do
  variableId <- nameRef.resolution
  variableData <- Map.lookup variableId idResult.identifiedVariables
  qualifiedName <- variableData.variableQualifiedName
  SemanticTypeFunction paramTypes returnType requestSet <-
    Map.lookup variableId zonkResult.zonkedTypeEnvironment
  let inputCore = paramObject dataDefs paramTypes parameters
      requestRefs = buildRequestRefs dataDefs idResult zonkResult requestSet
  pure
    SchemaEntry
      { name = renderQualifiedName qualifiedName,
        description = annotation,
        input = plain inputCore,
        output = toJsonSchema dataDefs Set.empty returnType,
        requests = requestRefs
      }

-- | Build the input @properties@ object, attaching per-parameter annotation
-- as JSON Schema @description@.
paramObject ::
  DataDefs ->
  Map Text (SemanticType Resolved) ->
  [ParameterBinding Zonked] ->
  SchemaCore
paramObject dataDefs paramTypes parameters =
  let properties =
        Map.fromList
          [ (pb.label, withDesc pb.annotation (toJsonSchema dataDefs Set.empty t))
            | pb <- parameters,
              Just t <- [Map.lookup pb.label paramTypes]
          ]
   in SchemaCoreObject
        { properties = properties,
          required = Map.keysSet paramTypes,
          additionalProperties = False
        }

-- | Build a JSON Schema object describing the input parameters of any
-- callable. Lowering-facing variant of 'paramObject' that takes the raw
-- per-label annotations (Lowering doesn't always have a
-- @[ParameterBinding Zonked]@ — e.g. for prim wrappers it knows only
-- @(label, optionalAnnotation)@). Returns a wrapped 'JsonSchema' for
-- direct insertion into 'AgentBlock.inputSchema'.
buildInputObject ::
  DataDefs ->
  Map Text (SemanticType Resolved) ->
  [(Text, Maybe Text)] ->
  JsonSchema
buildInputObject dataDefs paramTypes labelsAndAnnotations =
  let annotationByLabel = Map.fromList labelsAndAnnotations
      properties =
        Map.mapWithKey
          ( \label t ->
              let ann = Map.findWithDefault Nothing label annotationByLabel
               in withDesc ann (toJsonSchema dataDefs Set.empty t)
          )
          paramTypes
   in plain
        ( SchemaCoreObject
            { properties = properties,
              required = Map.keysSet paramTypes,
              additionalProperties = False
            }
        )

-- | Build the output schema for a callable's return type. Thin wrapper
-- around 'toJsonSchema' exposed alongside 'buildInputObject' so
-- Lowering has a single API surface for per-agent schema computation.
buildOutputSchema ::
  DataDefs ->
  SemanticType Resolved ->
  JsonSchema
buildOutputSchema dataDefs = toJsonSchema dataDefs Set.empty

-- | Aeson-encode a 'JsonSchema' to a strict 'Text'. Used by Lowering to
-- persist precomputed schemas in 'AgentBlock.inputSchema' /
-- 'AgentBlock.outputSchema'.
jsonSchemaToText :: JsonSchema -> Text
jsonSchemaToText =
  Encoding.decodeUtf8
    . LazyByteString.toStrict
    . encode

-- | Build a 'SchemaEntry' for a @data@ constructor. The output schema is the
-- inline-expanded object shape of the constructed value.
buildDataEntry ::
  DataDefs ->
  IdentifierResult ->
  ZonkResult ->
  DataDeclaration Zonked ->
  Maybe SchemaEntry
buildDataEntry dataDefs idResult zonkResult dataDecl = do
  variableId <- dataDecl.name.resolution
  variableData <- Map.lookup variableId idResult.identifiedVariables
  qualifiedName <- variableData.variableQualifiedName
  let fieldTypes = case Map.lookup variableId zonkResult.zonkedTypeEnvironment of
        Just (SemanticTypeFunction paramTypes _ _) -> paramTypes
        _ -> Map.empty
      -- Input (call-side) is the ctor's parameter list — no @$ctor@
      -- discriminator needed since the caller already targets a
      -- specific constructor.
      inputCore = dataParamObject dataDefs fieldTypes dataDecl.parameters
      inputSchema =
        JsonSchema
          { core = inputCore,
            title = Just dataDecl.name.text,
            description = dataDecl.annotation,
            examples = []
          }
      -- Output (constructed tagged value) reuses the unified
      -- 'SemanticTypeData' rendering so the @$ctor@ discriminator
      -- automatically appears.
      outputCore = case dataDecl.typeName.resolution of
        Just typeId -> toCore dataDefs Set.empty (SemanticTypeData typeId)
        Nothing -> dataParamObject dataDefs fieldTypes dataDecl.parameters
  pure
    SchemaEntry
      { name = renderQualifiedName qualifiedName,
        description = dataDecl.annotation,
        input = inputSchema,
        output = plain outputCore,
        requests = []
      }

-- | Build the @data@ parameter object, attaching per-field annotation as
-- JSON Schema @description@.
dataParamObject ::
  DataDefs ->
  Map Text (SemanticType Resolved) ->
  [DataParameter Zonked] ->
  SchemaCore
dataParamObject dataDefs fieldTypes parameters =
  let properties =
        Map.fromList
          [ (dataParameter.name, withDesc dataParameter.annotation (toJsonSchema dataDefs Set.empty fieldType))
            | dataParameter <- parameters,
              Just fieldType <- [Map.lookup dataParameter.name fieldTypes]
          ]
   in SchemaCoreObject
        { properties = properties,
          required = Map.keysSet properties,
          additionalProperties = False
        }

-- ===========================================================================
-- Request schema expansion
-- ===========================================================================

buildRequestRefs :: DataDefs -> IdentifierResult -> ZonkResult -> SemanticRequest Resolved -> [RequestSchemaRef]
buildRequestRefs dataDefs idResult zonkResult (SemanticRequest elements) =
  mapMaybe buildRef (Set.toList elements)
  where
    buildRef (SemanticRequestElementConcrete requestId) =
      buildRequestRef dataDefs idResult zonkResult requestId

buildRequestRef :: DataDefs -> IdentifierResult -> ZonkResult -> RequestId -> Maybe RequestSchemaRef
buildRequestRef dataDefs idResult zonkResult requestId = do
  rd <- Map.lookup requestId idResult.identifiedRequests
  SemanticTypeFunction paramTypes returnType _ <-
    Map.lookup rd.requestVariableId zonkResult.zonkedTypeEnvironment
  let inputCore =
        SchemaCoreObject
          { properties =
              Map.mapWithKey
                ( \label t ->
                    let annotation = join (Map.lookup label rd.requestParameterAnnotations)
                     in withDesc annotation (toJsonSchema dataDefs Set.empty t)
                )
                paramTypes,
            required = Map.keysSet paramTypes,
            additionalProperties = False
          }
  pure
    RequestSchemaRef
      { name = renderQualifiedName rd.requestQualifiedName,
        input = plain inputCore,
        output = toJsonSchema dataDefs Set.empty returnType
      }
