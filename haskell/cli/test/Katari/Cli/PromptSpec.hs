module Katari.Cli.PromptSpec (spec) where

import Data.Aeson (Value (..), toJSON)
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
