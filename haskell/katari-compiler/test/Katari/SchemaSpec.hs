-- | Tests for 'Katari.Schema' — primarily the @SemanticType -> JsonSchema@
-- conversion and JSON round-trip stability.
module Katari.SchemaSpec (spec) where

import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Katari.Schema
import Katari.Typechecker.SemanticType
  ( Resolved,
    SemanticEffect (..),
    SemanticType (..),
  )
import Test.Hspec

-- ===========================================================================
-- Helpers
-- ===========================================================================

shouldHaveCore :: SemanticType Resolved -> SchemaCore -> Expectation
shouldHaveCore t expected = (toJsonSchema t).core `shouldBe` expected

roundTrip :: (Aeson.ToJSON a, Aeson.FromJSON a, Eq a, Show a) => a -> Expectation
roundTrip value =
  case Aeson.fromJSON (Aeson.toJSON value) of
    Aeson.Success decoded -> decoded `shouldBe` value
    Aeson.Error msg -> expectationFailure ("decode failed: " <> msg)

-- ===========================================================================
-- Spec
-- ===========================================================================

spec :: Spec
spec = describe "Katari.Schema" $ do
  toJsonSchemaSpec
  unionCompactionSpec
  jsonRoundTripSpec

toJsonSchemaSpec :: Spec
toJsonSchemaSpec = describe "toJsonSchema (SemanticType -> JsonSchema)" $ do
  it "primitives map to their JSON Schema counterparts" $ do
    SemanticTypeNull `shouldHaveCore` SCNull
    SemanticTypeBoolean `shouldHaveCore` SCBoolean
    SemanticTypeNumber `shouldHaveCore` SCNumber
    SemanticTypeInteger `shouldHaveCore` SCInteger {minimum = Nothing, maximum = Nothing}
    SemanticTypeString `shouldHaveCore` SCString {schemaEnum = []}
    SemanticTypeNever `shouldHaveCore` SCNever
    SemanticTypeUnknown `shouldHaveCore` SCUnknown

  it "literal types become SCConst" $ do
    SemanticTypeLiteralInteger 42 `shouldHaveCore` SCConst {value = Aeson.Number 42}
    SemanticTypeLiteralString "hi" `shouldHaveCore` SCConst {value = String "hi"}
    SemanticTypeLiteralBoolean True `shouldHaveCore` SCConst {value = Bool True}

  it "arrays nest the element schema under 'items'" $ do
    let core = (toJsonSchema (SemanticTypeArray SemanticTypeInteger)).core
    case core of
      SCArray {items} -> items.core `shouldBe` SCInteger {minimum = Nothing, maximum = Nothing}
      _ -> expectationFailure "expected SCArray"

  it "tuples become SCTuple with prefixItems" $ do
    let t = SemanticTypeTuple [SemanticTypeBoolean, SemanticTypeInteger]
        core = (toJsonSchema t).core
    case core of
      SCTuple {prefixItems} -> map (.core) prefixItems `shouldBe` [SCBoolean, SCInteger {minimum = Nothing, maximum = Nothing}]
      _ -> expectationFailure "expected SCTuple"

  it "objects become SCObject with required = all field labels" $ do
    let t =
          SemanticTypeObject $
            Map.fromList
              [ ("name", SemanticTypeString),
                ("age", SemanticTypeInteger)
              ]
    case (toJsonSchema t).core of
      SCObject {properties, required, additionalProperties} -> do
        Map.keysSet properties `shouldBe` Set.fromList ["age", "name"]
        required `shouldBe` Set.fromList ["age", "name"]
        additionalProperties `shouldBe` False
      _ -> expectationFailure "expected SCObject"

  it "function types fall back to SCUnknown (not JSON-serialisable)" $ do
    let t =
          SemanticTypeFunction
            Map.empty
            SemanticTypeNull
            (SemanticEffect Set.empty Set.empty)
    t `shouldHaveCore` SCUnknown

unionCompactionSpec :: Spec
unionCompactionSpec = describe "union compaction" $ do
  it "string-literal union folds into string-enum" $ do
    let t =
          SemanticTypeUnion
            [ SemanticTypeLiteralString "red",
              SemanticTypeLiteralString "green",
              SemanticTypeLiteralString "blue"
            ]
    case (toJsonSchema t).core of
      SCString {schemaEnum} -> schemaEnum `shouldBe` ["red", "green", "blue"]
      other -> expectationFailure ("expected SCString enum, got: " <> show other)

  it "mixed union falls back to anyOf" $ do
    let t =
          SemanticTypeUnion
            [ SemanticTypeLiteralString "ok",
              SemanticTypeNull
            ]
    case (toJsonSchema t).core of
      SCUnion {anyOf} -> length anyOf `shouldBe` 2
      other -> expectationFailure ("expected SCUnion, got: " <> show other)

jsonRoundTripSpec :: Spec
jsonRoundTripSpec = describe "JSON round-trip" $ do
  it "JsonSchema round-trips" $ do
    roundTrip (toJsonSchema (SemanticTypeArray SemanticTypeInteger))
    roundTrip
      ( toJsonSchema
          ( SemanticTypeObject
              ( Map.fromList
                  [ ("x", SemanticTypeInteger),
                    ("y", SemanticTypeNumber)
                  ]
              )
          )
      )

  it "empty SchemaBundle round-trips" $ do
    roundTrip emptySchemaBundle
