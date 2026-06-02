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
    collectDataAnnotations,
    toJsonSchema,

    -- * Lowering-facing helpers (per-agent schema computation)
    buildInputObject,
    buildOutputSchema,
    jsonSchemaToText,

    -- * Per-module schema builder
    SchemaContext (..),
    buildModuleSchemas,

    -- * Wire-format helpers
    schemaBundleJson,
    schemaEntryToAgent,
  )
where

import Control.Monad (join)
import Data.Aeson
  ( FromJSON (..),
    Options (..),
    ToJSON (..),
    Value (..),
    defaultOptions,
    encode,
    genericParseJSON,
    genericToJSON,
    object,
    withObject,
    (.:?),
    (.=),
  )
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types qualified
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as Encoding
import GHC.Generics (Generic)
import Katari.AST
  ( DataDeclaration (..),
    DataParameter (..),
    Declaration (..),
    Module (..),
    NameRef (..),
    Phase (Zonked),
  )
import Katari.Id
  ( QualifiedName (..),
    VariableResolution (..),
    renderQualifiedName,
  )
import Katari.SemanticType
  ( Parameter (..),
    Resolved,
    SemanticRequest (..),
    SemanticRequestElement (..),
    SemanticType (..),
  )
import Katari.Typechecker.Identifier
  ( ConstructorData (..),
    RequestData (..),
    VariableData (..),
  )

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

instance FromJSON SchemaEntry where
  parseJSON = genericParseJSON schemaOptions

-- | Schema for a single request type that an agent may raise.
data RequestSchemaRef = RequestSchemaRef
  { name :: Text,
    input :: JsonSchema,
    output :: JsonSchema
  }
  deriving (Eq, Show, Generic)

instance ToJSON RequestSchemaRef where
  toJSON = genericToJSON schemaOptions

instance FromJSON RequestSchemaRef where
  parseJSON = genericParseJSON schemaOptions

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
      -- Unreachable: every SchemaCore constructor is either nullary
      -- (SchemaCoreNull, SchemaCoreBoolean, etc.) or a record type
      -- (SchemaCoreInteger, SchemaCoreString, SchemaCoreObject, ...),
      -- and the hand-written ToJSON SchemaCore instance above maps
      -- each one to a JSON `object [...]`. genericToJSON is not used
      -- for SchemaCore, so the invariant is enforced by exhaustive
      -- pattern match in that instance. If a new constructor is added
      -- without an Object-producing clause, this error surfaces the
      -- bug immediately rather than silently dropping metadata.
      other ->
        error
          ( "Katari.Schema: SchemaCore did not serialise to an Object — \
            \this is a compiler bug. Got: "
              <> show other
          )

instance FromJSON JsonSchema where
  parseJSON = withObject "JsonSchema" $ \obj -> do
    title <- obj .:? "title"
    description <- obj .:? "description"
    examples <- fromMaybe [] <$> obj .:? "examples"
    core <- parseJSON (Object obj)
    pure JsonSchema {core, title, description, examples}

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

instance FromJSON SchemaCore where
  parseJSON = withObject "SchemaCore" $ \obj -> do
    mNot <- obj .:? "not"
    case mNot of
      Just (Object _) -> pure SchemaCoreNever
      _ -> do
        mAnyOf <- obj .:? "anyOf"
        case mAnyOf of
          Just xs -> pure SchemaCoreUnion {anyOf = xs}
          Nothing -> do
            mConst <- obj .:? "const"
            case mConst of
              Just v -> pure SchemaCoreConst {value = v}
              Nothing -> do
                mType <- obj .:? "type" :: Data.Aeson.Types.Parser (Maybe Text)
                case mType of
                  Just "null" -> pure SchemaCoreNull
                  Just "boolean" -> pure SchemaCoreBoolean
                  Just "integer" -> do
                    mn <- obj .:? "minimum"
                    mx <- obj .:? "maximum"
                    pure SchemaCoreInteger {minimum = mn, maximum = mx}
                  Just "number" -> pure SchemaCoreNumber
                  Just "string" -> do
                    mEnum <- obj .:? "enum"
                    pure SchemaCoreString {schemaEnum = fromMaybe [] mEnum}
                  Just "array" -> do
                    mItems <- obj .:? "items"
                    mPrefix <- obj .:? "prefixItems"
                    case mPrefix of
                      Just ps -> pure SchemaCoreTuple {prefixItems = ps}
                      Nothing -> case mItems of
                        Just i -> pure SchemaCoreArray {items = i}
                        Nothing -> pure SchemaCoreArray {items = plain SchemaCoreUnknown}
                  Just "object" -> do
                    props <- fromMaybe Map.empty <$> obj .:? "properties"
                    req <- maybe Set.empty Set.fromList <$> obj .:? "required"
                    addl <- fromMaybe False <$> obj .:? "additionalProperties"
                    pure SchemaCoreObject {properties = props, required = req, additionalProperties = addl}
                  _ -> pure SchemaCoreUnknown

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
-- a @"$constructor": {"const": "module.name"}@ discriminator on the resulting
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

-- | Maps each data type's 'QualifiedName' to its qname + per-field info.
type DataDefs = Map QualifiedName DataInfo

-- | Extract per-field @\@\"...\"@ annotations from a Zonked module's
-- @data@ declarations. Used to seed 'buildDataDefs' with the surface
-- annotation strings.
collectDataAnnotations ::
  Map QualifiedName VariableData ->
  Module Zonked ->
  Map QualifiedName (Map Text (Maybe Text))
collectDataAnnotations variableMap m =
  Map.fromList
    [ (qualifiedName, annotations)
      | DeclarationData dataDecl <- m.declarations,
        Just (ResolvedTopLevel qualifiedName) <- [dataDecl.name.resolution],
        Map.member qualifiedName variableMap,
        let annotations = Map.fromList [(p.name, p.annotation) | p <- dataDecl.parameters]
    ]

-- | Build 'DataDefs' from per-module pieces. The caller is responsible
-- for unioning constructor / variable / type / annotation maps across
-- the module and its transitive imports before passing them in.
buildDataDefs ::
  Map QualifiedName ConstructorData ->
  Map QualifiedName (SemanticType Resolved) ->
  Map QualifiedName (Map Text (Maybe Text)) ->
  DataDefs
buildDataDefs constructorMap topLevelTypes annotationsByQName =
  Map.fromList
    [ ( cd.constructorTypeQName,
        DataInfo
          ctorQName
          ( Map.mapWithKey
              ( \label ty ->
                  DataFieldInfo
                    { fieldType = ty.parameterType,
                      fieldAnnotation =
                        Map.findWithDefault Nothing label perFieldAnnotations
                    }
              )
              fieldTypes
          )
      )
      | (ctorQName, cd) <- Map.toList constructorMap,
        let perFieldAnnotations =
              Map.findWithDefault Map.empty ctorQName annotationsByQName,
        Just (SemanticTypeFunction fieldTypes _ _) <-
          [Map.lookup ctorQName topLevelTypes]
    ]

-- ===========================================================================
-- SemanticType -> JsonSchema
-- ===========================================================================

-- | Convert a 'SemanticType' 'Resolved' to a 'JsonSchema'. 'SemanticTypeData'
-- references are inline-expanded using 'DataDefs'; 'visited' guards against
-- circular references (passes 'SchemaCoreUnknown' on re-entry).
toJsonSchema :: DataDefs -> Set QualifiedName -> SemanticType Resolved -> JsonSchema
toJsonSchema dataDefs visited = plain . toCore dataDefs visited

toCore :: DataDefs -> Set QualifiedName -> SemanticType Resolved -> SchemaCore
toCore dataDefs visited = \case
  SemanticTypeNever -> SchemaCoreNever
  SemanticTypeUnknown -> SchemaCoreUnknown
  SemanticTypeNull -> SchemaCoreNull
  SemanticTypeBoolean -> SchemaCoreBoolean
  SemanticTypeInteger -> SchemaCoreInteger {minimum = Nothing, maximum = Nothing}
  SemanticTypeNumber -> SchemaCoreNumber
  SemanticTypeString -> SchemaCoreString {schemaEnum = []}
  -- 'secret' must not surface in AI tool-calling schemas; the AI must not
  -- inspect credential shapes. 'buildVariableEntry' already drops any
  -- callable whose param / result mentions @secret@, so this branch is
  -- unreachable on the bundle path. Kept as a defensive no-op (maximally
  -- permissive 'SchemaCoreUnknown') so a stray internal call can't crash.
  SemanticTypeSecret -> SchemaCoreUnknown
  -- 'file' is carried on the wire as a value reference @{"$ref": {...},
  -- "as": "file", "hash": ..., "size": ...}@ (a blob handle). The AI
  -- cannot produce a file inline; file params are supplied by
  -- orchestration. The schema documents the reference shape for
  -- validation of runtime-passed refs.
  SemanticTypeFile -> fileRefCore
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
  -- carried on the wire as a callable reference @{"$agent":
  -- "module.name" | "closureref:<ref id>"}@. The reference is what
  -- 'get_metadata' returns in its 'id' field.
  SemanticTypeFunction {} -> callableRefCore
  SemanticTypeFunctionAny -> callableRefCore
  -- Records map to JSON Schema's @additionalProperties@ pattern:
  -- a plain object whose values all match @V@'s schema. The key type
  -- is fixed to @string@ at the Identifier pass in v0.1.0, so we
  -- don't emit a @propertyNames@ refinement.
  -- TODO(Phase 2): emit @additionalProperties@ as a typed schema once
  -- the schema model supports it.
  SemanticTypeRecord _valueType ->
    SchemaCoreObject
      { properties = Map.empty,
        required = Set.empty,
        additionalProperties = True
      }

-- | Reserved JSON-Schema property name carrying the tagged-value
-- constructor identifier on the wire. Receivers (CLI / REST clients /
-- AI tools) use the value as a discriminator when picking the matching
-- arm of a union.
ctorDiscriminatorKey :: Text
ctorDiscriminatorKey = "$constructor"

-- | Reserved JSON-Schema property name carrying a callable reference.
-- The value is the same string the @get_metadata@ prim returns in its
-- @id@ field: @"module.name"@ for top-level agents or
-- @"closureref:<ref id>"@ for closures. (The schema declares it as an
-- open @string@ — there is no closure enumeration.)
callableDiscriminatorKey :: Text
callableDiscriminatorKey = "$agent"

-- | Schema for a callable-reference object: a single required
-- @"$agent": string@ property. Used as the wire representation of
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

-- | Reserved JSON-Schema property name carrying a value reference (blob
-- handle) for @file@ values.
fileRefDiscriminatorKey :: Text
fileRefDiscriminatorKey = "$ref"

-- | Schema for a @file@ value reference: the @"$ref"@ handle object plus
-- @as@ / @hash@ / @size@ metadata. See docs/2026-05-30-value-and-streaming.md §11.
fileRefCore :: SchemaCore
fileRefCore =
  SchemaCoreObject
    { properties =
        Map.fromList
          [ (fileRefDiscriminatorKey, plain SchemaCoreUnknown),
            ("as", plain SchemaCoreConst {value = toJSON ("file" :: Text)}),
            ("hash", plain SchemaCoreString {schemaEnum = []}),
            ("size", plain SchemaCoreInteger {minimum = Nothing, maximum = Nothing})
          ],
      required = Set.fromList [fileRefDiscriminatorKey, "as", "hash"],
      additionalProperties = True
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

-- | Build schema entries for a compiled program.
--
-- Decl-agnostic walk of every top-level callable: any 'VariableData'
-- carrying a 'variableQualifiedName' whose zonked type is a
-- 'SemanticTypeFunction' becomes one 'SchemaEntry'. The Identifier pass
-- attaches the declaration's @\@"..."@ annotation and its per-parameter
-- annotations to the 'VariableData' itself, so this builder doesn't need
-- to inspect 'Declaration' shapes — all decl kinds (agent / ext agent /
-- prim agent / req / data ctor) flow through the same path uniformly.
--
-- That means @prim agent add@ etc. ARE in the bundle now — AI tool
-- calling consumers read the runtime-side 'get_metadata' prim for
-- their tool discovery (the global bundle is operator / IDE facing),
-- so there's no reason to filter out stdlib prims here. Consumers that
-- want to hide @prim.*@ from a display list can filter by qualified-name
-- prefix on their side.
-- | Cross-module context needed to build schemas for one module's
-- declarations. The orchestrator builds this once per scope (M +
-- transitive imports) and reuses it across the module's entries.
data SchemaContext = SchemaContext
  { dataDefs :: DataDefs,
    topLevelTypes :: Map QualifiedName (SemanticType Resolved),
    requestData :: Map QualifiedName RequestData
  }

-- | Build 'SchemaEntry's for one module's own variables. The caller
-- passes only @M@'s @identifiedVariables@; cross-module info travels
-- via 'SchemaContext'.
buildModuleSchemas ::
  SchemaContext ->
  Map QualifiedName VariableData ->
  [SchemaEntry]
buildModuleSchemas ctx variableMap =
  mapMaybe (buildVariableEntry ctx) (Map.toList variableMap)

-- | One 'SchemaEntry' per top-level callable 'QualifiedName'. Returns
-- 'Nothing' for non-callable bindings (= not a function in the type
-- env) and any Solver-contract violation (= the diagnostic was already
-- emitted upstream).
buildVariableEntry ::
  SchemaContext ->
  (QualifiedName, VariableData) ->
  Maybe SchemaEntry
buildVariableEntry ctx (qualifiedName, variableData) = do
  SemanticTypeFunction parameters returnType requestSet <-
    Map.lookup qualifiedName ctx.topLevelTypes
  let paramTypes = (.parameterType) <$> parameters
  -- Credential (secret) types must never surface in an AI tool-calling
  -- schema — the AI must not be able to inspect credential shapes. Drop any
  -- callable whose parameters or result mention @secret@ (directly or
  -- transitively through a data field). The callable stays callable in the
  -- IR; only its schema is withheld from the bundle.
  if any (mentionsSecret ctx.dataDefs Set.empty) (returnType : Map.elems paramTypes)
    then Nothing
    else
      pure
        SchemaEntry
          { name = renderQualifiedName qualifiedName,
            description = variableData.variableAnnotation,
            input = buildInputObject ctx.dataDefs parameters variableData.variableParameterAnnotations,
            output = toJsonSchema ctx.dataDefs Set.empty returnType,
            requests = buildRequestRefs ctx requestSet
          }

-- | Does a resolved type mention 'SemanticTypeSecret' anywhere — directly
-- or transitively through a 'SemanticTypeData' field? Used to keep
-- credential-typed callables out of the AI tool-calling schema bundle.
-- @visited@ breaks cycles in recursive data types.
mentionsSecret :: DataDefs -> Set QualifiedName -> SemanticType Resolved -> Bool
mentionsSecret dataDefs visited = \case
  SemanticTypeSecret -> True
  SemanticTypeArray element -> recurse element
  SemanticTypeTuple elements -> any recurse elements
  SemanticTypeUnion branches -> any recurse branches
  SemanticTypeObject fields -> any recurse (Map.elems fields)
  SemanticTypeRecord valueType -> recurse valueType
  SemanticTypeFunction parameters returnType _ ->
    any (recurse . (.parameterType)) (Map.elems parameters) || recurse returnType
  SemanticTypeData qualifiedName
    | Set.member qualifiedName visited -> False
    | Just info <- Map.lookup qualifiedName dataDefs ->
        any
          (mentionsSecret dataDefs (Set.insert qualifiedName visited) . (.fieldType))
          (Map.elems info.dataFields)
    | otherwise -> False
  _ -> False
  where
    recurse = mentionsSecret dataDefs visited

-- | Build a JSON Schema object describing the input parameters of any
-- callable. Lowering-facing variant of 'paramObject' that takes the raw
-- per-label annotations (Lowering doesn't always have a
-- @[ParameterBinding Zonked]@ — e.g. for prim wrappers it knows only
-- @(label, optionalAnnotation)@). Returns a wrapped 'JsonSchema' for
-- direct insertion into 'AgentBlock.inputSchema'.
buildInputObject ::
  DataDefs ->
  Map Text (Parameter Resolved) ->
  [(Text, Maybe Text)] ->
  JsonSchema
buildInputObject dataDefs parameters labelsAndAnnotations =
  let annotationByLabel = Map.fromList labelsAndAnnotations
      properties =
        Map.mapWithKey
          ( \label parameter ->
              let ann = Map.findWithDefault Nothing label annotationByLabel
               in withDesc ann (toJsonSchema dataDefs Set.empty parameter.parameterType)
          )
          parameters
   in plain
        ( SchemaCoreObject
            { properties = properties,
              -- Optional parameters (those with a default) may be omitted by
              -- the caller, so they are excluded from @required@.
              required = Map.keysSet (Map.filter (not . (.optional)) parameters),
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

-- ===========================================================================
-- Request schema expansion
-- ===========================================================================

buildRequestRefs :: SchemaContext -> SemanticRequest Resolved -> [RequestSchemaRef]
buildRequestRefs ctx (SemanticRequest elements) =
  mapMaybe buildRef (Set.toList elements)
  where
    buildRef (SemanticRequestElementConcrete qualifiedName) =
      buildRequestRef ctx qualifiedName

buildRequestRef :: SchemaContext -> QualifiedName -> Maybe RequestSchemaRef
buildRequestRef ctx qualifiedName = do
  rd <- Map.lookup qualifiedName ctx.requestData
  SemanticTypeFunction parameters returnType _ <-
    Map.lookup qualifiedName ctx.topLevelTypes
  let paramTypes = (.parameterType) <$> parameters
      inputCore =
        SchemaCoreObject
          { properties =
              Map.mapWithKey
                ( \label t ->
                    let annotation = join (Map.lookup label rd.requestParameterAnnotations)
                     in withDesc annotation (toJsonSchema ctx.dataDefs Set.empty t)
                )
                paramTypes,
            required = Map.keysSet (Map.filter (not . (.optional)) parameters),
            additionalProperties = False
          }
  pure
    RequestSchemaRef
      { name = renderQualifiedName qualifiedName,
        input = plain inputCore,
        output = toJsonSchema ctx.dataDefs Set.empty returnType
      }

-- ===========================================================================
-- Wire-format helpers
-- ===========================================================================

-- | The on-the-wire schema-bundle JSON shape that both @katari apply@
-- and @katari build@ produce. Shared here so the two output paths
-- can't drift apart (= snapshot upload uses this shape; build emits
-- it nested under @"schemaBundle"@ in the local IR-bundle file).
schemaBundleJson :: Maybe [SchemaEntry] -> Value
schemaBundleJson mEntries =
  object
    [ "schemaVersion" .= (1 :: Int),
      "agents" .= maybe ([] :: [Value]) (map schemaEntryToAgent) mEntries
    ]

-- | Single 'SchemaEntry' to wire-format agent definition. Surface
-- shape used by both CLI commands and consumed by AI tool-calling
-- consumers via the api-server's @/agent@ endpoints.
schemaEntryToAgent :: SchemaEntry -> Value
schemaEntryToAgent SchemaEntry {..} =
  object
    [ "qualifiedName" .= name,
      "parameters" .= input,
      "returns" .= output,
      "description" .= description
    ]
