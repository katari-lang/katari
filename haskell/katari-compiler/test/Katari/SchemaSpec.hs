-- | Tests for 'Katari.Schema' — the SemanticType → JsonSchema conversion
-- and the end-to-end schema generation pipeline.
module Katari.SchemaSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Compile (CompileInput (..), CompileResult (..), compile)
import Katari.Schema
import Katari.SemanticType
  ( Resolved,
    SemanticRequest (..),
    SemanticType (..),
  )
import Test.Hspec

-- ===========================================================================
-- Helpers
-- ===========================================================================

-- | Call 'toJsonSchema' without data-type expansion (suitable for tests
-- that don't involve 'SemanticTypeData').
simpleToJson :: SemanticType Resolved -> JsonSchema
simpleToJson = toJsonSchema Map.empty Set.empty

shouldHaveCore :: SemanticType Resolved -> SchemaCore -> Expectation
shouldHaveCore t expected = (simpleToJson t).core `shouldBe` expected

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
    let core = (simpleToJson (SemanticTypeArray SemanticTypeInteger)).core
    case core of
      SchemaCoreArray {items} ->
        items.core `shouldBe` SchemaCoreInteger {minimum = Nothing, maximum = Nothing}
      _ -> expectationFailure "expected SchemaCoreArray"

  it "tuples become SchemaCoreTuple with prefixItems" $ do
    let t = SemanticTypeTuple [SemanticTypeBoolean, SemanticTypeInteger]
        core = (simpleToJson t).core
    case core of
      SchemaCoreTuple {prefixItems} ->
        map (.core) prefixItems
          `shouldBe` [SchemaCoreBoolean, SchemaCoreInteger {minimum = Nothing, maximum = Nothing}]
      _ -> expectationFailure "expected SchemaCoreTuple"

  it "objects become SchemaCoreObject with required = all field labels" $ do
    let t =
          SemanticTypeObject $
            Map.fromList
              [ ("name", SemanticTypeString),
                ("age", SemanticTypeInteger)
              ]
    case (simpleToJson t).core of
      SchemaCoreObject {properties, required, additionalProperties} -> do
        Map.keysSet properties `shouldBe` Set.fromList ["age", "name"]
        required `shouldBe` Set.fromList ["age", "name"]
        additionalProperties `shouldBe` False
      _ -> expectationFailure "expected SchemaCoreObject"

  it "function types fall back to SchemaCoreUnknown (not JSON-serialisable)" $ do
    let t =
          SemanticTypeFunction
            Map.empty
            SemanticTypeNull
            (SemanticRequest Set.empty)
    t `shouldHaveCore` SchemaCoreUnknown

unionCompactionSpec :: Spec
unionCompactionSpec = describe "union compaction" $ do
  it "string-literal union folds into string-enum" $ do
    let t =
          SemanticTypeUnion
            [ SemanticTypeLiteralString "red",
              SemanticTypeLiteralString "green",
              SemanticTypeLiteralString "blue"
            ]
    case (simpleToJson t).core of
      SchemaCoreString {schemaEnum} -> schemaEnum `shouldBe` ["red", "green", "blue"]
      other -> expectationFailure ("expected SchemaCoreString enum, got: " <> show other)

  it "mixed union falls back to anyOf" $ do
    let t =
          SemanticTypeUnion
            [ SemanticTypeLiteralString "ok",
              SemanticTypeNull
            ]
    case (simpleToJson t).core of
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
      result = compile CompileInput {sources = Map.singleton "main" src, rootModule = "main"}
      entries :: [SchemaEntry]
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
