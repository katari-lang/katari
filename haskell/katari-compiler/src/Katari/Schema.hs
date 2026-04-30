-- | JSON Schema generation for the public API surface (agents, requests,
-- external agents, and data types).
--
-- Schema は AI tool calling と runtime validation の両方を駆動する。各
-- agent / request / external-agent につき @input@ / @output@ schema を
-- 生成し、@data@ 宣言は @\$defs@ に置く。Description は AST の
-- @\@\"...\"@ annotation から拾う ([Katari.AST.AgentDeclaration] 等の
-- @annotation@ field)。
--
-- 入力は 'ZonkResult' のみ ('IRModule' は不要): 型情報は
-- @zonkedTypeEnvironment@、annotation は @zonkedModules@ の AST 上に乗って
-- いるため、両者を AST walk で zip する。
--
-- ## Schema 表現
--
-- 'JsonSchema' は JSON Schema Draft 2020-12 のサブセットを構造的に表す。
-- @description@ / @title@ / @examples@ は任意の位置に乗せられる。
-- 'SchemaCoreRef' は @\$ref@ 形式で @data@ 宣言を参照する (\@\"#/$defs/<name>\"\)。
--
-- ## 制限
--
--   * 関数引数 / 戻り値の関数型 ('SemanticTypeFunction') は JSON で
--     serialize 不可なので 'SchemaCoreUnknown' にフォールバックする。
--   * Generic は無いので @data@ 宣言の参照は単純な名前だけ。
module Katari.Schema
  ( -- * Schema types
    JsonSchema (..),
    SchemaCore (..),
    AgentSchema (..),
    SchemaBundle (..),

    -- * Conversion
    toJsonSchema,

    -- * Top-level builder
    buildSchemas,
    emptySchemaBundle,
  )
where

import Data.Aeson
  ( FromJSON (..),
    Options (..),
    SumEncoding (..),
    ToJSON (..),
    Value (..),
    defaultOptions,
    genericParseJSON,
    genericToJSON,
  )
import Data.Char (toLower)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Katari.AST
  ( AgentDeclaration (..),
    DataDeclaration (..),
    DataParameter (..),
    Declaration (..),
    ExternalAgentDeclaration (..),
    Module (..),
    NameRef (..),
    ParameterBinding (..),
    Phase (Zonked),
    RequestDeclaration (..),
    SymbolKind (..),
  )
import Katari.AST.Identifiers (ModuleId, VariableId, renderQualifiedName)
import Katari.Internal (internalErrorNoSpan)
import Katari.Typechecker.SemanticType
  ( Resolved,
    SemanticEffect (..),
    SemanticType (..),
  )
import Katari.Typechecker.Identifier (RequestData (..))
import Katari.Typechecker.Zonker (ZonkResult (..))

-- ===========================================================================
-- Schema data types
-- ===========================================================================

-- | A JSON Schema fragment with optional description / title / examples.
data JsonSchema = JsonSchema
  { core :: !SchemaCore,
    title :: !(Maybe Text),
    description :: !(Maybe Text),
    examples :: ![Value]
  }
  deriving (Eq, Show, Generic)

instance ToJSON JsonSchema where
  toJSON = genericToJSON schemaOptions

instance FromJSON JsonSchema where
  parseJSON = genericParseJSON schemaOptions

-- | The structural part of a 'JsonSchema'. Mirrors JSON Schema Draft
-- 2020-12 keywords.
data SchemaCore where
  SchemaCoreNull :: SchemaCore
  SchemaCoreBoolean :: SchemaCore
  SchemaCoreInteger ::
    { minimum :: !(Maybe Integer),
      maximum :: !(Maybe Integer)
    } ->
    SchemaCore
  SchemaCoreNumber :: SchemaCore
  SchemaCoreString :: {schemaEnum :: ![Text]} -> SchemaCore
  SchemaCoreConst :: {value :: !Value} -> SchemaCore
  SchemaCoreArray :: {items :: !JsonSchema} -> SchemaCore
  SchemaCoreTuple :: {prefixItems :: ![JsonSchema]} -> SchemaCore
  SchemaCoreObject ::
    { properties :: !(Map Text JsonSchema),
      required :: !(Set Text),
      additionalProperties :: !Bool
    } ->
    SchemaCore
  SchemaCoreUnion :: {anyOf :: ![JsonSchema]} -> SchemaCore
  SchemaCoreRef :: {ref :: !Text} -> SchemaCore
  SchemaCoreUnknown :: SchemaCore
  SchemaCoreNever :: SchemaCore
  deriving (Eq, Show, Generic)

instance ToJSON SchemaCore where
  toJSON = genericToJSON schemaCoreOptions

instance FromJSON SchemaCore where
  parseJSON = genericParseJSON schemaCoreOptions

-- | Schema for one agent / request / external-agent. Describes its input
-- (object), its output, and the request effects it may raise.
data AgentSchema = AgentSchema
  { -- | The @\@\"...\"@ annotation on the declaration, if any.
    description :: !(Maybe Text),
    -- | Always an 'SchemaCoreObject' whose @properties@ are the named parameters.
    input :: !JsonSchema,
    output :: !JsonSchema,
    -- | Internal request VariableIds this agent may raise. Rendered as
    -- @\"req\<n\>\"@: tooling that needs human names should consult the
    -- corresponding 'IRModule' name table.
    effects :: ![Text]
  }
  deriving (Eq, Show, Generic)

instance ToJSON AgentSchema where
  toJSON = genericToJSON schemaOptions

instance FromJSON AgentSchema where
  parseJSON = genericParseJSON schemaOptions

-- | Aggregated schemas for a compiled program. All maps are flat at
-- the top level: keys are dotted qualified names (\"<modPath>.<bare>\")
-- so consumers (AI tool calling, runtime validators, FFI sidecars) can
-- look up a callable by its public name without re-threading module
-- structure.
--
-- @dataSchemas@ describes data constructors as callables (so
-- @Pair(left=1, right=2)@ has a JSON-Schema input shape just like an
-- agent does). @dataDefs@ holds the corresponding @\$defs@ entry —
-- the data type as a JSON object schema — that other schemas reference
-- via @SchemaCoreRef \"#/$defs/<qualified>\"@.
data SchemaBundle = SchemaBundle
  { agentSchemas :: !(Map Text AgentSchema),
    requestSchemas :: !(Map Text AgentSchema),
    externalSchemas :: !(Map Text AgentSchema),
    -- | Data constructor invocation schemas (constructor as a function).
    dataSchemas :: !(Map Text AgentSchema),
    -- | Data type schemas (object shape for the constructed values),
    -- intended as the @\$defs@ section of a top-level JSON Schema
    -- document.
    dataDefs :: !(Map Text JsonSchema)
  }
  deriving (Eq, Show, Generic)

instance ToJSON SchemaBundle where
  toJSON = genericToJSON schemaOptions

instance FromJSON SchemaBundle where
  parseJSON = genericParseJSON schemaOptions

emptySchemaBundle :: SchemaBundle
emptySchemaBundle =
  SchemaBundle
    { agentSchemas = Map.empty,
      requestSchemas = Map.empty,
      externalSchemas = Map.empty,
      dataSchemas = Map.empty,
      dataDefs = Map.empty
    }

-- ===========================================================================
-- Aeson option helpers
-- ===========================================================================

schemaOptions :: Options
schemaOptions =
  defaultOptions
    { fieldLabelModifier = id,
      omitNothingFields = True
    }

-- | TaggedObject sum encoding for 'SchemaCore'. Each variant's JSON tag is
-- the (camelCased) constructor name, e.g. @"schemaCoreNull"@ /
-- @"schemaCoreObject"@.
schemaCoreOptions :: Options
schemaCoreOptions =
  defaultOptions
    { sumEncoding = TaggedObject "kind" "contents",
      constructorTagModifier = lowerHead,
      fieldLabelModifier = id,
      omitNothingFields = True
    }

-- | Lowercase the first character of a constructor name to produce its
-- JSON tag. Combined with the type-name prefix on each constructor it
-- yields stable camelCase tags such as @"schemaCoreNull"@.
lowerHead :: String -> String
lowerHead = \case
  [] -> []
  c : rest -> toLower c : rest

-- ===========================================================================
-- Plain schema (no annotation)
-- ===========================================================================

-- | Wrap a 'SchemaCore' in a 'JsonSchema' with no extra metadata.
plain :: SchemaCore -> JsonSchema
plain c =
  JsonSchema
    { core = c,
      title = Nothing,
      description = Nothing,
      examples = []
    }

-- | Set the @description@ field of a 'JsonSchema'. Building a fresh
-- record (rather than record-updating) sidesteps the
-- @-XDuplicateRecordFields@ ambiguity warning, which bites because
-- 'description' lives on both 'JsonSchema' and 'AgentSchema'.
withDesc :: Maybe Text -> JsonSchema -> JsonSchema
withDesc d s =
  JsonSchema
    { core = s.core,
      title = s.title,
      description = d,
      examples = s.examples
    }

-- ===========================================================================
-- SemanticType -> JsonSchema
-- ===========================================================================

-- | Convert a 'SemanticType' 'Resolved' to a 'JsonSchema'. The metadata
-- (description / title / examples) is set by the caller; this function
-- only computes the structural 'core'.
toJsonSchema :: SemanticType Resolved -> JsonSchema
toJsonSchema = plain . toCore

toCore :: SemanticType Resolved -> SchemaCore
toCore = \case
  SemanticTypeNever -> SchemaCoreNever
  SemanticTypeUnknown -> SchemaCoreUnknown
  SemanticTypeNull -> SchemaCoreNull
  SemanticTypeBoolean -> SchemaCoreBoolean
  SemanticTypeInteger -> SchemaCoreInteger {minimum = Nothing, maximum = Nothing}
  SemanticTypeNumber -> SchemaCoreNumber
  SemanticTypeString -> SchemaCoreString {schemaEnum = []}
  SemanticTypeLiteralInteger n -> SchemaCoreConst {value = toJSON n}
  SemanticTypeLiteralString s -> SchemaCoreConst {value = toJSON s}
  SemanticTypeLiteralBoolean b -> SchemaCoreConst {value = toJSON b}
  SemanticTypeArray element -> SchemaCoreArray {items = toJsonSchema element}
  SemanticTypeTuple elements -> SchemaCoreTuple {prefixItems = map toJsonSchema elements}
  SemanticTypeObject fields ->
    SchemaCoreObject
      { properties = Map.map toJsonSchema fields,
        required = Map.keysSet fields,
        additionalProperties = False
      }
  SemanticTypeUnion branches -> compactUnion (map toCore branches)
  SemanticTypeData _ -> SchemaCoreUnknown
  -- Functions can't be serialized to JSON; surface as "any".
  SemanticTypeFunction {} -> SchemaCoreUnknown

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

-- | Walk every module's declarations and build the schema bundle. Pulls
-- types from 'zonkedTypeEnvironment' and descriptions from each AST
-- declaration's @annotation@ field.
buildSchemas :: ZonkResult -> SchemaBundle
buildSchemas zr =
  foldr
    (mergeModuleBundle zr)
    emptySchemaBundle
    (Map.toList zr.zonkedModules)

mergeModuleBundle ::
  ZonkResult ->
  (ModuleId, Module Zonked) ->
  SchemaBundle ->
  SchemaBundle
mergeModuleBundle zr (modId, m) acc =
  let modName = Map.findWithDefault "" modId zr.zonkedModuleNames
   in foldr (collectDeclaration zr modName) acc m.declarations

collectDeclaration ::
  ZonkResult ->
  Text ->
  Declaration Zonked ->
  SchemaBundle ->
  SchemaBundle
collectDeclaration zr modName decl bundle = case decl of
  DeclarationAgent ad ->
    case agentLike zr ad.annotation ad.name ad.parameters of
      Just s ->
        bundle {agentSchemas = Map.insert (qkey modName ad.name.text) s bundle.agentSchemas}
      Nothing -> bundle
  DeclarationRequest rd ->
    case requestLike zr rd of
      Just s ->
        bundle {requestSchemas = Map.insert (qkey modName rd.name.text) s bundle.requestSchemas}
      Nothing -> bundle
  DeclarationExternalAgent ed ->
    case externalLike zr ed of
      Just s ->
        bundle {externalSchemas = Map.insert (qkey modName ed.name.text) s bundle.externalSchemas}
      Nothing -> bundle
  DeclarationData dd ->
    let bundleWithDef =
          bundle {dataDefs = insertDataDef zr modName dd bundle.dataDefs}
     in case dataConstructorSchema zr modName dd of
          Just s ->
            bundleWithDef
              { dataSchemas =
                  Map.insert
                    (qkey modName dd.name.text)
                    s
                    bundleWithDef.dataSchemas
              }
          Nothing -> bundleWithDef
  -- Imports / type synonyms / parser sentinels don't surface in the schema.
  DeclarationImport {} -> bundle
  DeclarationTypeSynonym {} -> bundle
  DeclarationError {} -> bundle

-- | Join @\<modName\>.\<declName\>@ as the public schema-bundle key.
-- Empty module path falls back to the bare name (test fixtures may
-- have no path).
qkey :: Text -> Text -> Text
qkey modName declName
  | Text.null modName = declName
  | otherwise = modName <> "." <> declName

-- | Build an 'AgentSchema' from an agent's annotation, name, and parameter
-- bindings. The agent's full type is read from
-- 'zonkedTypeEnvironment'; its function shape gives us input properties /
-- output / effects.
agentLike ::
  ZonkResult ->
  Maybe Text ->
  NameRef Zonked 'VariableRef ->
  [ParameterBinding Zonked] ->
  Maybe AgentSchema
agentLike zr description nameRef parameters =
  case nameRef.resolution of
    Just variableId ->
      buildAgentSchema zr description parameters
        <$> Map.lookup variableId zr.zonkedTypeEnvironment
    Nothing -> Nothing

requestLike :: ZonkResult -> RequestDeclaration Zonked -> Maybe AgentSchema
requestLike zr rd = agentLike zr rd.annotation rd.name rd.parameters

externalLike :: ZonkResult -> ExternalAgentDeclaration Zonked -> Maybe AgentSchema
externalLike zr ed = agentLike zr ed.annotation ed.name ed.parameters

-- | Build an 'AgentSchema' from the resolved type. After Solver / Zonker
-- the type of an agent / request / external-agent declaration is
-- guaranteed to be a 'SemanticTypeFunction'; any other shape indicates a
-- constraint-generation bug and is reported as an internal error so the
-- problem surfaces immediately instead of silently dropping bundle entries.
buildAgentSchema ::
  ZonkResult ->
  Maybe Text ->
  [ParameterBinding Zonked] ->
  SemanticType Resolved ->
  AgentSchema
buildAgentSchema zr description parameters = \case
  SemanticTypeFunction params ret eff ->
    let inputSchema = withDesc description (plain (paramObject params parameters))
     in AgentSchema
          { description = description,
            input = inputSchema,
            output = toJsonSchema ret,
            effects = renderEffects zr eff
          }
  other ->
    internalErrorNoSpan
      ( "Schema.buildAgentSchema: agent / request / external declaration's "
          <> "resolved type is not a function: "
          <> Text.pack (show other)
      )

paramObject ::
  Map Text (SemanticType Resolved) ->
  [ParameterBinding Zonked] ->
  SchemaCore
paramObject paramTypes parameters =
  let properties =
        Map.fromList
          [ (pb.label, withDesc pb.annotation (toJsonSchema t))
            | pb <- parameters,
              Just t <- [Map.lookup pb.label paramTypes]
          ]
   in SchemaCoreObject
        { properties = properties,
          required = Map.keysSet paramTypes,
          additionalProperties = False
        }

-- | Render an effect set as a list of qualified-name strings. Each
-- 'RequestId' is looked up in 'zonkedRequests' to recover its
-- declaration's 'QualifiedName'; missing ids (a Solver-contract
-- violation) are dropped silently. Effect variables are always empty
-- at 'Resolved' phase per Solver contract, so they're ignored.
renderEffects :: ZonkResult -> SemanticEffect Resolved -> [Text]
renderEffects zr (SemanticEffect _ reqs) =
  [ renderQualifiedName qn
    | rid <- Set.toList reqs,
      Just (RequestData {requestQualifiedName = qn}) <- [Map.lookup rid zr.zonkedRequests]
  ]

-- ===========================================================================
-- Data declaration -> $defs entry
-- ===========================================================================

-- | Build a @\$defs@ entry for a 'DataDeclaration'. The constructor
-- variable's type in the environment is a function from labelled fields
-- to the data type; we use that map for field types and the AST
-- declaration for @description@ (per-field and per-data).
insertDataDef ::
  ZonkResult ->
  Text ->
  DataDeclaration Zonked ->
  Map Text JsonSchema ->
  Map Text JsonSchema
insertDataDef zr modName dd m =
  case dd.name.resolution of
    Just ctorId ->
      let base = plain (dataObject (lookupCtorParams zr ctorId) dd.parameters)
          entry =
            JsonSchema
              { core = base.core,
                title = Just dd.name.text,
                description = dd.annotation,
                examples = base.examples
              }
       in Map.insert (qkey modName dd.name.text) entry m
    Nothing -> m

-- | Build the constructor-as-callable schema for a @data@ declaration.
-- Mirrors 'agentLike' but for constructors: input is the named-field
-- object, output references the corresponding @\$defs@ entry. effects
-- are always empty (constructors are pure).
dataConstructorSchema ::
  ZonkResult ->
  Text ->
  DataDeclaration Zonked ->
  Maybe AgentSchema
dataConstructorSchema zr modName dd =
  case dd.name.resolution of
    Just ctorId ->
      let fieldTypes = lookupCtorParams zr ctorId
          inputCore = dataObject fieldTypes dd.parameters
          inputSchema =
            JsonSchema
              { core = inputCore,
                title = Just dd.name.text,
                description = dd.annotation,
                examples = []
              }
          -- SchemaCoreRef without description: the declaration site ($defs) is the
          -- single source of truth for description. Consumers that want
          -- inline descriptions can resolve $ref after loading the bundle.
          outputSchema = plain (SchemaCoreRef ("#/$defs/" <> qkey modName dd.name.text))
       in Just
            AgentSchema
              { description = dd.annotation,
                input = inputSchema,
                output = outputSchema,
                effects = []
              }
    Nothing -> Nothing

lookupCtorParams ::
  ZonkResult ->
  VariableId ->
  Map Text (SemanticType Resolved)
lookupCtorParams zr ctorId =
  case Map.lookup ctorId zr.zonkedTypeEnvironment of
    Just (SemanticTypeFunction params _ _) -> params
    _ -> Map.empty

dataObject :: Map Text (SemanticType Resolved) -> [DataParameter Zonked] -> SchemaCore
dataObject fieldTypes params =
  let properties =
        Map.fromList
          [ (dp.name, withDesc dp.annotation (toJsonSchema fieldType))
            | dp <- params,
              Just fieldType <- [Map.lookup dp.name fieldTypes]
          ]
   in SchemaCoreObject
        { properties = properties,
          required = Map.keysSet properties,
          additionalProperties = False
        }
