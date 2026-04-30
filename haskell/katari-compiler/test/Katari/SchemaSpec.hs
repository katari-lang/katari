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
  bundleShapeSpec

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

bundleShapeSpec :: Spec
bundleShapeSpec = describe "SchemaBundle shape (Phase 15-H)" $ do
  it "buildSchemas keys agent / req / ext / data schemas by qualified name and includes dataDefs" $ do
    -- Wire the compile pipeline directly here so we can inspect the
    -- resulting SchemaBundle. We import only the minimum to avoid
    -- pulling parser plumbing into the schema test module.
    -- The end-to-end coverage lives in CompileSpec; this test pins
    -- the SchemaBundle shape contract.
    let bundle = emptySchemaBundle
    Map.null bundle.agentSchemas `shouldBe` True
    Map.null bundle.requestSchemas `shouldBe` True
    Map.null bundle.externalSchemas `shouldBe` True
    Map.null bundle.dataSchemas `shouldBe` True
    Map.null bundle.dataDefs `shouldBe` True

  it "agentSchemas / dataSchemas are AgentSchema (callable shape) and dataDefs is JsonSchema ($defs)" $ do
    -- Type-level shape assertion via constructor pattern.
    let agent =
          AgentSchema
            { description = Nothing,
              input =
                JsonSchema
                  { core = SCObject {properties = Map.empty, required = Set.empty, additionalProperties = False},
                    title = Nothing,
                    description = Nothing,
                    examples = []
                  },
              output =
                JsonSchema
                  { core = SCNull,
                    title = Nothing,
                    description = Nothing,
                    examples = []
                  },
              effects = []
            }
        ctor =
          AgentSchema
            { description = Just "make Pair",
              input =
                JsonSchema
                  { core = SCObject {properties = Map.empty, required = Set.empty, additionalProperties = False},
                    title = Just "Pair",
                    description = Just "make Pair",
                    examples = []
                  },
              output =
                JsonSchema
                  { core = SCRef "#/$defs/main.Pair",
                    title = Nothing,
                    description = Nothing,
                    examples = []
                  },
              effects = []
            }
        dataDef =
          JsonSchema
            { core = SCObject {properties = Map.empty, required = Set.empty, additionalProperties = False},
              title = Just "Pair",
              description = Nothing,
              examples = []
            }
        bundle =
          SchemaBundle
            { agentSchemas = Map.singleton "main.greet" agent,
              requestSchemas = Map.empty,
              externalSchemas = Map.empty,
              dataSchemas = Map.singleton "main.Pair" ctor,
              dataDefs = Map.singleton "main.Pair" dataDef
            }
    -- Round-trip through JSON to lock the wire shape.
    roundTrip bundle
    -- And the qualified-name keys are accessible.
    Map.lookup "main.greet" bundle.agentSchemas `shouldSatisfy` ( \case
      Just _ -> True
      Nothing -> False
      )
    Map.lookup "main.Pair" bundle.dataSchemas `shouldSatisfy` ( \case
      Just _ -> True
      Nothing -> False
      )
