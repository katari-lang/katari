module Katari.Data.JSONSchemaSpec (spec) where

import Data.Aeson (Value (..), decode, encode, object, toJSON, (.=))
import GHC.List (List)
import Katari.Data.Id (GenericId (..), wireModuleName)
import Katari.Data.JSONSchema
  ( AdditionalProperties (..),
    DescribedSchema (..),
    JSONSchema (..),
    ObjectSchema (..),
  )
import Test.Hspec

-- | Every wire shape the compiler emits, with object properties already in key order (the wire loses
-- declaration order, so only key-ordered fixtures can round-trip exactly).
fixtures :: List JSONSchema
fixtures =
  [ SchemaAny,
    SchemaNever,
    SchemaNull,
    SchemaBoolean,
    SchemaInteger,
    SchemaNumber,
    SchemaString,
    SchemaConst (toJSON ("tag" :: String)),
    SchemaConst Null,
    SchemaArray SchemaString,
    SchemaTuple [SchemaInteger, SchemaString],
    SchemaObject
      ObjectSchema
        { properties = [("age", SchemaInteger), ("name", SchemaString)],
          required = ["age"],
          additionalProperties = AdditionalPropertiesBoolean False
        },
    SchemaObject
      ObjectSchema
        { properties = [],
          required = [],
          additionalProperties = AdditionalPropertiesSchema SchemaNumber
        },
    SchemaAnyOf [SchemaConst (toJSON ("a" :: String)), SchemaConst (toJSON ("b" :: String))],
    -- The wire drops a generic's declaring module; only an id already carrying the wire-side sentinel
    -- module can round-trip exactly.
    SchemaGeneric (GenericId wireModuleName 3),
    SchemaDescribed DescribedSchema {description = "The city name.", schema = SchemaString},
    -- A described any-schema is the bare @{"description": ...}@ document.
    SchemaDescribed DescribedSchema {description = "Anything goes.", schema = SchemaAny},
    SchemaObject
      ObjectSchema
        { properties = [("city", SchemaDescribed DescribedSchema {description = "The city name.", schema = SchemaString})],
          required = ["city"],
          additionalProperties = AdditionalPropertiesBoolean False
        }
  ]

spec :: Spec
spec = describe "JSONSchema FromJSON" $ do
  it "round-trips every emitted shape through encode/decode" $
    mapM_ (\schema -> decode (encode schema) `shouldBe` Just schema) fixtures

  it "decodes a bare array type as unconstrained elements" $
    decode (encode (object ["type" .= ("array" :: String)])) `shouldBe` Just (SchemaArray SchemaAny)

  it "applies the JSON Schema defaults to a bare object type" $
    decode (encode (object ["type" .= ("object" :: String)]))
      `shouldBe` Just
        ( SchemaObject
            ObjectSchema
              { properties = [],
                required = [],
                additionalProperties = AdditionalPropertiesBoolean True
              }
        )

  it "rejects a type it does not model" $
    (decode (encode (object ["type" .= ("integerish" :: String)])) :: Maybe JSONSchema)
      `shouldBe` Nothing

  it "merges a description into the inner schema's encoding" $
    toJSON (SchemaDescribed DescribedSchema {description = "The city name.", schema = SchemaString})
      `shouldBe` object ["type" .= ("string" :: String), "description" .= ("The city name." :: String)]
