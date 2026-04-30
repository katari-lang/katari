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
-- 'SCRef' は @\$ref@ 形式で @data@ 宣言を参照する (\@\"#/$defs/<name>\"\)。
--
-- ## 制限
--
--   * 関数引数 / 戻り値の関数型 ('SemanticTypeFunction') は JSON で
--     serialize 不可なので 'SCUnknown' にフォールバックする。
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
import Katari.AST.Identifiers (ModuleId, RequestId, VariableId, unRequestId)
import Katari.Typechecker.SemanticType
  ( Resolved,
    SemanticEffect (..),
    SemanticType (..),
  )
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
data SchemaCore
  = SCNull
  | SCBoolean
  | SCInteger
      { minimum :: !(Maybe Integer),
        maximum :: !(Maybe Integer)
      }
  | SCNumber
  | SCString
      { schemaEnum :: ![Text]
      }
  | SCConst {value :: !Value}
  | SCArray {items :: !JsonSchema}
  | SCTuple {prefixItems :: ![JsonSchema]}
  | SCObject
      { properties :: !(Map Text JsonSchema),
        required :: !(Set Text),
        additionalProperties :: !Bool
      }
  | SCUnion {anyOf :: ![JsonSchema]}
  | SCRef {ref :: !Text}
  | SCUnknown
  | SCNever
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
    -- | Always an 'SCObject' whose @properties@ are the named parameters.
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

-- | Aggregated schemas for a compiled program. Top-level maps are keyed
-- by module name; inner maps by declaration name.
data SchemaBundle = SchemaBundle
  { agentSchemas :: !(Map Text (Map Text AgentSchema)),
    requestSchemas :: !(Map Text (Map Text AgentSchema)),
    externalSchemas :: !(Map Text (Map Text AgentSchema)),
    -- | @data@ definitions live in @\$defs@ keyed by a stable name
    -- (currently @\"<module>.<typeName>\"@).
    dataSchemas :: !(Map Text JsonSchema)
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
      dataSchemas = Map.empty
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

-- | TaggedObject sum encoding for 'SchemaCore' so each variant carries its
-- @\"kind\"@ tag (lowercased, 'SC' prefix stripped).
schemaCoreOptions :: Options
schemaCoreOptions =
  defaultOptions
    { sumEncoding = TaggedObject "kind" "contents",
      constructorTagModifier = stripSCPrefix,
      fieldLabelModifier = id,
      omitNothingFields = True
    }

stripSCPrefix :: String -> String
stripSCPrefix s = case drop (length ("SC" :: String)) s of
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
  SemanticTypeNever -> SCNever
  SemanticTypeUnknown -> SCUnknown
  SemanticTypeNull -> SCNull
  SemanticTypeBoolean -> SCBoolean
  SemanticTypeInteger -> SCInteger {minimum = Nothing, maximum = Nothing}
  SemanticTypeNumber -> SCNumber
  SemanticTypeString -> SCString {schemaEnum = []}
  SemanticTypeLiteralInteger n -> SCConst {value = toJSON n}
  SemanticTypeLiteralString s -> SCConst {value = toJSON s}
  SemanticTypeLiteralBoolean b -> SCConst {value = toJSON b}
  SemanticTypeArray element -> SCArray {items = toJsonSchema element}
  SemanticTypeTuple elements -> SCTuple {prefixItems = map toJsonSchema elements}
  SemanticTypeObject fields ->
    SCObject
      { properties = Map.map toJsonSchema fields,
        required = Map.keysSet fields,
        additionalProperties = False
      }
  SemanticTypeUnion branches -> compactUnion (map toCore branches)
  SemanticTypeData _ -> SCUnknown
  -- Functions can't be serialized to JSON; surface as "any".
  SemanticTypeFunction {} -> SCUnknown

-- | Compact a union of string-literal types into a single string-enum
-- where possible. Mixed unions fall back to @anyOf@.
compactUnion :: [SchemaCore] -> SchemaCore
compactUnion cores =
  let stringEnums = [s | SCConst {value = String s} <- cores]
      allStringConst = not (null cores) && length stringEnums == length cores
   in if allStringConst
        then SCString {schemaEnum = stringEnums}
        else SCUnion {anyOf = map plain cores}

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
  DeclarationAgent ad -> insertAgentLike modName ad.name.text agentField (agentLike zr ad.annotation ad.name ad.parameters) bundle
    where
      agentField b s = b {agentSchemas = insertNested modName ad.name.text s b.agentSchemas}
  DeclarationRequest rd -> insertAgentLike modName rd.name.text requestField (requestLike zr rd) bundle
    where
      requestField b s = b {requestSchemas = insertNested modName rd.name.text s b.requestSchemas}
  DeclarationExternalAgent ed -> insertAgentLike modName ed.name.text externalField (externalLike zr ed) bundle
    where
      externalField b s = b {externalSchemas = insertNested modName ed.name.text s b.externalSchemas}
  DeclarationData dd ->
    bundle {dataSchemas = insertDataSchema zr modName dd bundle.dataSchemas}
  -- Imports / type synonyms / parser sentinels don't surface in the schema.
  DeclarationImport {} -> bundle
  DeclarationTypeSynonym {} -> bundle
  DeclarationError {} -> bundle

insertAgentLike ::
  Text ->
  Text ->
  (SchemaBundle -> AgentSchema -> SchemaBundle) ->
  Maybe AgentSchema ->
  SchemaBundle ->
  SchemaBundle
insertAgentLike _ _ _ Nothing bundle = bundle
insertAgentLike _ _ merge (Just s) bundle = merge bundle s

insertNested ::
  Text ->
  Text ->
  AgentSchema ->
  Map Text (Map Text AgentSchema) ->
  Map Text (Map Text AgentSchema)
insertNested modName declName s =
  Map.insertWith Map.union modName (Map.singleton declName s)

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
      buildAgentSchema description parameters
        =<< Map.lookup variableId zr.zonkedTypeEnvironment
    Nothing -> Nothing

requestLike :: ZonkResult -> RequestDeclaration Zonked -> Maybe AgentSchema
requestLike zr rd = agentLike zr rd.annotation rd.name rd.parameters

externalLike :: ZonkResult -> ExternalAgentDeclaration Zonked -> Maybe AgentSchema
externalLike zr ed = agentLike zr ed.annotation ed.name ed.parameters

buildAgentSchema ::
  Maybe Text ->
  [ParameterBinding Zonked] ->
  SemanticType Resolved ->
  Maybe AgentSchema
buildAgentSchema description parameters = \case
  SemanticTypeFunction params ret eff ->
    let inputSchema = withDesc description (plain (paramObject params parameters))
     in Just
          AgentSchema
            { description = description,
              input = inputSchema,
              output = toJsonSchema ret,
              effects = renderEffects eff
            }
  -- A non-function semantic type for an agent / request / external
  -- declaration would indicate a constraint-generation bug; skip
  -- gracefully so we still emit the rest of the bundle.
  _ -> Nothing

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
   in SCObject
        { properties = properties,
          required = Map.keysSet paramTypes,
          additionalProperties = False
        }

-- | Render an effect set as @\"req\<n\>\"@ identifiers. Effect variables
-- are empty at 'Resolved' phase by Solver contract.
--
-- TODO (Phase 15-H): switch to qualified-name strings via 'zonkedRequests'.
renderEffects :: SemanticEffect Resolved -> [Text]
renderEffects (SemanticEffect _ reqs) = map renderRequestId (Set.toList reqs)
  where
    renderRequestId :: RequestId -> Text
    renderRequestId rid = "req" <> Text.pack (show (unRequestId rid))

-- ===========================================================================
-- Data declaration -> $defs entry
-- ===========================================================================

-- | Build a @\$defs@ entry for a 'DataDeclaration'. The constructor
-- variable's type in the environment is a function from labelled fields
-- to the data type; we use that map for field types and the AST
-- declaration for @description@ (per-field and per-data).
insertDataSchema ::
  ZonkResult ->
  Text ->
  DataDeclaration Zonked ->
  Map Text JsonSchema ->
  Map Text JsonSchema
insertDataSchema zr modName dd m =
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
          key = qualifiedDataKey modName dd.name.text
       in Map.insert key entry m
    Nothing -> m

lookupCtorParams ::
  ZonkResult ->
  VariableId ->
  Map Text (SemanticType Resolved)
lookupCtorParams zr ctorId =
  case Map.lookup ctorId zr.zonkedTypeEnvironment of
    Just (SemanticTypeFunction params _ _) -> params
    _ -> Map.empty

qualifiedDataKey :: Text -> Text -> Text
qualifiedDataKey modName declName
  | Text.null modName = declName
  | otherwise = modName <> "." <> declName

dataObject :: Map Text (SemanticType Resolved) -> [DataParameter Zonked] -> SchemaCore
dataObject fieldTypes params =
  let properties =
        Map.fromList
          [ (dp.name, withDesc dp.annotation (toJsonSchema fieldType))
            | dp <- params,
              Just fieldType <- [Map.lookup dp.name fieldTypes]
          ]
   in SCObject
        { properties = properties,
          required = Map.keysSet properties,
          additionalProperties = False
        }
