module Katari.Cli.PromptSpec (spec) where

import Data.Aeson (Value (..), toJSON)
import Data.Map qualified as Map
import Data.Text (Text)
import GHC.List (List)
import Katari.Cli.Prompt
  ( TypedInputKind (..),
    coerceTypedInput,
    constLabels,
    renderSchemaBrief,
  )
import Katari.Data.JSONSchema
  ( AdditionalProperties (..),
    JSONSchema (..),
    ObjectSchema (..),
  )
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SemanticType (FieldInformation (..), SemanticType (..))
import Katari.Schema (DataDefinition (..), DataDefinitions, toJSONSchema)
import Test.Hspec

spec :: Spec
spec = do
  describe "coerceTypedInput" $ do
    it "accepts a whole number as an integer" $
      coerceTypedInput InputInteger " 42 " `shouldBe` Right (toJSON (42 :: Int))

    it "rejects a fractional answer to an integer question" $
      coerceTypedInput InputInteger "1.5" `shouldSatisfy` either (const True) (const False)

    it "rejects prose where a number is expected" $
      coerceTypedInput InputNumber "many" `shouldSatisfy` either (const True) (const False)

    it "accepts a fraction as a number" $
      coerceTypedInput InputNumber "1.5" `shouldBe` Right (toJSON (1.5 :: Double))

    it "accepts any JSON document in raw mode" $
      coerceTypedInput InputRawJson "{\"a\": [1, null]}" `shouldSatisfy` either (const False) (const True)

    it "rejects an unquoted string in raw mode with a hint about quotes" $
      coerceTypedInput InputRawJson "hello" `shouldBe` Left "not valid JSON — try again (strings need quotes)"

  describe "constLabels" $ do
    it "labels a union made entirely of literals" $
      constLabels [SchemaConst (toJSON ("a" :: String)), SchemaConst (toJSON (1 :: Int))]
        `shouldBe` Just [("\"a\"", toJSON ("a" :: String)), ("1", toJSON (1 :: Int))]

    it "declines when any branch is not a literal" $
      constLabels [SchemaConst (toJSON ("a" :: String)), SchemaString] `shouldBe` Nothing

  describe "renderSchemaBrief" $ do
    it "renders a record by its field names" $
      renderSchemaBrief
        ( SchemaObject
            ObjectSchema
              { properties = [("name", SchemaString), ("age", SchemaInteger)],
                required = ["name"],
                additionalProperties = AdditionalPropertiesBoolean False
              }
        )
        `shouldBe` "record {name, age}"

    it "renders a union by its branches" $
      renderSchemaBrief (SchemaAnyOf [SchemaNull, SchemaString]) `shouldBe` "null | string"

    it "renders nested arrays inside out" $
      renderSchemaBrief (SchemaArray (SchemaArray SchemaInteger)) `shouldBe` "array of array of integer"

    it "renders a literal as its JSON" $
      renderSchemaBrief (SchemaConst Null) `shouldBe` "null"

    it "names a documented data arm by its constructor, seeing through the descriptions" $
      -- The fixture is the COMPILER's own output — `toJSONSchema` over two documented `data`
      -- declarations — rather than a hand-transcribed copy of the wire encoding: a transcription stays
      -- green when the encoding moves out from under the reader, which is exactly the drift this test
      -- exists to catch. The compiler documents the arm, its discriminator and each annotated field, so
      -- the brief must peel all three; a picker that fell through would show two identical `record {…}`.
      -- Field order follows the encoding's own (ascending by name), not declaration order.
      renderSchemaBrief
        ( toJSONSchema
            targetDefinitions
            (SemanticTypeUnion [SemanticTypeData urlTargetName Map.empty, SemanticTypeData channelTargetName Map.empty])
        )
        `shouldBe` "test.url_target {interval_seconds, url} | test.channel_target {channel_id}"

-- | Two documented @data@ declarations as "Katari.Lowering" denormalizes them for inline expansion:
-- each carries its own docstring and its per-field docstrings, so 'toJSONSchema' emits every
-- description overlay a brief has to see through.
targetDefinitions :: DataDefinitions
targetDefinitions =
  Map.fromList
    [ ( urlTargetName,
        documentedDefinition
          "A URL to poll."
          [("url", "Where to poll."), ("interval_seconds", "How often to poll it.")]
      ),
      ( channelTargetName,
        documentedDefinition "A channel to watch." [("channel_id", "Which channel.")]
      )
    ]

-- | One documented declaration: every field a required @string@, annotated with the given docstring.
documentedDefinition :: Text -> List (Text, Text) -> DataDefinition
documentedDefinition annotation fieldDocumentation =
  DataDefinition
    { fields =
        Map.fromList
          [ (fieldName, FieldInformation {semanticType = SemanticTypeString, optional = False})
            | (fieldName, _) <- fieldDocumentation
          ],
      parameterGenericIds = Map.empty,
      annotation = Just annotation,
      fieldAnnotations = Map.fromList fieldDocumentation
    }

urlTargetName :: QualifiedName
urlTargetName = QualifiedName {moduleName = ModuleName "test", name = "url_target"}

channelTargetName :: QualifiedName
channelTargetName = QualifiedName {moduleName = ModuleName "test", name = "channel_target"}
