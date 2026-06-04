-- | Tests for 'Katari.Schema' — the SemanticType → JsonSchema conversion
-- and the end-to-end schema generation pipeline.
module Katari.SchemaSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Compile (CompileInput (..), CompileResult (..), SourceEntry (..))
import Katari.TestSupport (compileSync)
import Katari.Diagnostic (Diagnostic (..))
import Katari.Schema
import Katari.SemanticType
  ( Resolved,
    SemanticType (..),
    emptyEffect,
    functionType,
    requiredParameter,
  )
import Test.Hspec

-- ===========================================================================
-- Helpers
-- ===========================================================================

-- | Call 'toJsonSchema' without data-type expansion (suitable for tests
-- that don't involve 'SemanticTypeData').
simpleToJson :: SemanticType Resolved -> SchemaCore
simpleToJson t = (toJsonSchema Map.empty Set.empty t).core

shouldHaveCore :: SemanticType Resolved -> SchemaCore -> Expectation
shouldHaveCore t expected = simpleToJson t `shouldBe` expected

findEntry :: Text -> [SchemaEntry] -> Maybe SchemaEntry
findEntry n = find (\e -> e.name == n)

-- ===========================================================================
-- Spec
-- ===========================================================================

spec :: Spec
spec = describe "Katari.Schema" $ do
  toJsonSchemaSpec
  unionCompactionSpec
  schemaCoreJsonSpec
  descriptionEndToEndSpec
  secretGuardSpec

toJsonSchemaSpec :: Spec
toJsonSchemaSpec = describe "toJsonSchema (SemanticType -> JsonSchema)" $ do
  it "primitives map to their JSON Schema counterparts" $ do
    SemanticTypeNull `shouldHaveCore` SchemaCoreNull
    SemanticTypeBoolean `shouldHaveCore` SchemaCoreBoolean
    SemanticTypeNumber `shouldHaveCore` SchemaCoreNumber
    SemanticTypeInteger `shouldHaveCore` SchemaCoreInteger {minimum = Nothing, maximum = Nothing}
    SemanticTypeString `shouldHaveCore` SchemaCoreString {schemaEnum = []}
    SemanticTypeNever `shouldHaveCore` SchemaCoreNever
    SemanticTypeUnknown `shouldHaveCore` SchemaCoreUnknown

  it "literal types become SchemaCoreConst" $ do
    SemanticTypeLiteralInteger 42 `shouldHaveCore` SchemaCoreConst {value = Aeson.Number 42}
    SemanticTypeLiteralString "hi" `shouldHaveCore` SchemaCoreConst {value = String "hi"}
    SemanticTypeLiteralBoolean True `shouldHaveCore` SchemaCoreConst {value = Bool True}

  it "arrays nest the element schema under 'items'" $ do
    let core = simpleToJson (SemanticTypeArray SemanticTypeInteger)
    case core of
      SchemaCoreArray {items} ->
        items.core `shouldBe` SchemaCoreInteger {minimum = Nothing, maximum = Nothing}
      _ -> expectationFailure "expected SchemaCoreArray"

  it "tuples become SchemaCoreTuple with prefixItems" $ do
    let t = SemanticTypeTuple [SemanticTypeBoolean, SemanticTypeInteger]
        core = simpleToJson t
    case core of
      SchemaCoreTuple {prefixItems} ->
        map (.core) prefixItems
          `shouldBe` [SchemaCoreBoolean, SchemaCoreInteger {minimum = Nothing, maximum = Nothing}]
      _ -> expectationFailure "expected SchemaCoreTuple"

  it "objects become SchemaCoreObject with required = all field labels" $ do
    let t =
          SemanticTypeObject $
            Map.fromList
              [ ("name", requiredParameter SemanticTypeString),
                ("age", requiredParameter SemanticTypeInteger)
              ]
    case simpleToJson t of
      SchemaCoreObject {properties, required, additionalProperties} -> do
        Map.keysSet properties `shouldBe` Set.fromList ["age", "name"]
        required `shouldBe` Set.fromList ["age", "name"]
        -- Open: a Katari object names only its minimum required fields, so a
        -- value may carry more — the schema must permit additional properties.
        additionalProperties `shouldBe` True
      _ -> expectationFailure "expected SchemaCoreObject"

  it "function types emit a callable-reference object with required $agent: string" $ do
    let t =
          functionType
            Map.empty
            SemanticTypeNull
            emptyEffect
    case simpleToJson t of
      SchemaCoreObject {properties, required, additionalProperties} -> do
        Map.keys properties `shouldBe` ["$agent"]
        required `shouldBe` Set.singleton "$agent"
        -- Schemas are uniformly open (additionalProperties = true).
        additionalProperties `shouldBe` True
      _ -> expectationFailure "expected SchemaCoreObject (callable reference)"

unionCompactionSpec :: Spec
unionCompactionSpec = describe "union compaction" $ do
  it "string-literal union folds into string-enum" $ do
    let t =
          SemanticTypeUnion
            [ SemanticTypeLiteralString "red",
              SemanticTypeLiteralString "green",
              SemanticTypeLiteralString "blue"
            ]
    case simpleToJson t of
      SchemaCoreString {schemaEnum} -> schemaEnum `shouldBe` ["red", "green", "blue"]
      other -> expectationFailure ("expected SchemaCoreString enum, got: " <> show other)

  it "mixed union falls back to anyOf" $ do
    let t =
          SemanticTypeUnion
            [ SemanticTypeLiteralString "ok",
              SemanticTypeNull
            ]
    case simpleToJson t of
      SchemaCoreUnion {anyOf} -> length anyOf `shouldBe` 2
      other -> expectationFailure ("expected SchemaCoreUnion, got: " <> show other)

-- | Pin the JSON wire format of 'SchemaCore' variants as valid JSON Schema.
schemaCoreJsonSpec :: Spec
schemaCoreJsonSpec = describe "SchemaCore JSON output (valid JSON Schema)" $ do
  it "SchemaCoreNull → {\"type\":\"null\"}" $
    Aeson.toJSON (simpleToJson SemanticTypeNull)
      `shouldBe` object ["type" .= ("null" :: Text)]

  it "SchemaCoreBoolean → {\"type\":\"boolean\"}" $
    Aeson.toJSON (simpleToJson SemanticTypeBoolean)
      `shouldBe` object ["type" .= ("boolean" :: Text)]

  it "SchemaCoreInteger → {\"type\":\"integer\"}" $
    Aeson.toJSON (simpleToJson SemanticTypeInteger)
      `shouldBe` object ["type" .= ("integer" :: Text)]

  it "SchemaCoreNumber → {\"type\":\"number\"}" $
    Aeson.toJSON (simpleToJson SemanticTypeNumber)
      `shouldBe` object ["type" .= ("number" :: Text)]

  it "SchemaCoreString → {\"type\":\"string\"}" $
    Aeson.toJSON (simpleToJson SemanticTypeString)
      `shouldBe` object ["type" .= ("string" :: Text)]

  it "SchemaCoreUnknown → {}" $
    Aeson.toJSON (simpleToJson SemanticTypeUnknown)
      `shouldBe` object []

  it "SchemaCoreNever → {\"not\":{}}" $
    Aeson.toJSON (simpleToJson SemanticTypeNever)
      `shouldBe` object ["not" .= object []]

  it "string-literal union → {\"type\":\"string\",\"enum\":[...]}" $
    Aeson.toJSON (simpleToJson (SemanticTypeUnion (map SemanticTypeLiteralString ["a", "b"])))
      `shouldBe` object
        [ "type" .= ("string" :: Text),
          "enum" .= (["a", "b"] :: [Text])
        ]

  it "SchemaCoreConst → {\"const\":...}" $
    Aeson.toJSON (simpleToJson (SemanticTypeLiteralInteger 42))
      `shouldBe` object ["const" .= (42 :: Int)]

-- ===========================================================================
-- Phase 17: annotation → description end-to-end
-- ===========================================================================

secretGuardSpec :: Spec
secretGuardSpec = describe "secret credential guard" $ do
  let src =
        "agent withSecret(s: secret) -> string { \"ok\" }\n\
        \agent plain(n: integer) -> integer { n }"
      result =
        compileSync
          CompileInput
            { sources = Map.singleton "main" SourceEntry {filePath = "main", sourceText = src},
              cache = Map.empty
            }
      entries = case result.schemaEntries of
        Just es -> es
        Nothing -> error ("compile failed: " <> show (map (.code) result.diagnostics))
  it "hides a callable with a secret parameter from the schema bundle" $
    findEntry "main.withSecret" entries `shouldBe` Nothing
  it "keeps non-secret callables in the bundle" $
    fmap (.name) (findEntry "main.plain" entries) `shouldBe` Just "main.plain"

descriptionEndToEndSpec :: Spec
descriptionEndToEndSpec = describe "annotation → description (end-to-end)" $ do
  let src =
        "@\"a 2D point\"\n\
        \data Point(@\"horizontal coordinate\" x: number, @\"vertical coordinate\" y: number)\n\
        \\n\
        \@\"format a point\"\n\
        \agent show(@\"the point\" p: Point) -> string {\n\
        \  \"\"\n\
        \}"
  let result = compileSync CompileInput {sources = Map.singleton "main" SourceEntry {filePath = "main", sourceText = src}, cache = Map.empty}
  let entries :: [SchemaEntry]
      entries = case result.schemaEntries of
        Just es -> es
        Nothing -> error ("compile failed: " <> show (map (.code) result.diagnostics))

  it "agent description comes from @-annotation" $
    (findEntry "main.show" entries >>= (.description))
      `shouldBe` (Just "format a point" :: Maybe Text)

  it "agent input property description comes from parameter @-annotation" $ do
    let prop :: Maybe Text
        prop = do
          entry <- findEntry "main.show" entries
          props <- case entry.input.core of
            SchemaCoreObject {properties = p} -> Just p
            _ -> Nothing
          paramSchema <- Map.lookup "p" props
          paramSchema.description
    prop `shouldBe` Just "the point"

  it "data SchemaEntry description comes from data @-annotation" $
    (findEntry "main.Point" entries >>= (.description))
      `shouldBe` (Just "a 2D point" :: Maybe Text)

  it "data output field descriptions come from field @-annotations" $ do
    let fieldDesc :: Text -> Maybe Text
        fieldDesc label = do
          entry <- findEntry "main.Point" entries
          props <- case entry.output.core of
            SchemaCoreObject {properties = p} -> Just p
            _ -> Nothing
          field <- Map.lookup label props
          field.description
    fieldDesc "x" `shouldBe` Just "horizontal coordinate"
    fieldDesc "y" `shouldBe` Just "vertical coordinate"

  it "data input field descriptions come from field @-annotations" $ do
    let fieldDesc :: Text -> Maybe Text
        fieldDesc label = do
          entry <- findEntry "main.Point" entries
          props <- case entry.input.core of
            SchemaCoreObject {properties = p} -> Just p
            _ -> Nothing
          field <- Map.lookup label props
          field.description
    fieldDesc "x" `shouldBe` Just "horizontal coordinate"
    fieldDesc "y" `shouldBe` Just "vertical coordinate"
